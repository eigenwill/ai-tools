#!/usr/bin/env bash
# =============================================================================
# run_vivado.sh — Vivado synthesis & xsim simulation batch runner
# =============================================================================
#
# Purpose
# -------
# Wraps Vivado's batch flow behind a single CLI so an agent (or human) can run
# synthesis and/or simulation, then read a structured summary instead of
# parsing logs.
#
# Invocation model
# ----------------
# This script is meant to be called in place from a skill directory, e.g.:
#   bash ~/.claude/skills/vivado-runner/scripts/run_vivado.sh ...
# Do NOT copy it into user projects — outputs are controlled via --outdir,
# and the script uses absolute paths internally so location is irrelevant.
#
# Outputs (under <outdir>/result/vivado_log/)
# -------------------------------------------
#   summary.json      Structured pass/fail report. Read this first.
#   syn.log           Vivado synthesis log.
#   sim.log           Vivado simulation log (top-level, not the runtime one).
#   simulate.log      xsim runtime log — contains $display output and is the
#                     authoritative source for pass/fail markers.
#   elaborate.log     xelab output (signal elaboration).
#   compile.log       xvlog/xvhdl output (HDL compile).
#   utilization.rpt   Synthesis resource usage (only after successful synth).
#   timing.rpt        Synthesis timing summary (only after successful synth).
#   syn.tcl, sim.tcl  Generated TCL scripts (kept for inspection).
#   *.wdb             Waveform database (only when --wave passed).
#   project/          Vivado project (large; safe to ignore for review).
#
# Exit codes
# ----------
#   0   overall passed
#   1   overall failed (synthesis errors, sim errors, or sim FAIL marker)
#   2   environment error (vivado not in PATH)
#   3   unknown — sim ran cleanly but no PASS/FAIL marker found
#   4   timeout — simulation hit the wall-clock limit
# =============================================================================

set -euo pipefail
# -e: exit on any uncaught error
# -u: unset variable is an error
# -o pipefail: a pipeline fails if any stage fails (not just the last)

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
# These are overridable via CLI flags. The defaults target a Zynq-7020 dev
# board (Pynq-Z1/Z2, Zedboard-ish). Override with --part for other devices.
FPGA_PART="xc7z020clg400-1"
JOBS=4              # parallel synth jobs; passed to launch_runs -jobs
SIM_TIMEOUT="1h"    # wall-clock cap on simulation; uses timeout(1) syntax

# -----------------------------------------------------------------------------
# CLI state (populated by argument parsing)
# -----------------------------------------------------------------------------
OUTDIR=""           # output root; defaults to cwd if empty
MODE="both"         # one of: sim | syn | both
TOP=""              # required: top RTL module name
TB_TOP=""           # testbench top; defaults to <TOP>_tb if empty
XDC=""              # optional constraints file (synthesis only)
WAVE=false          # enable waveform dump (xsim WDB)
ARCHIVE=false       # save a timestamped copy of the result directory
RTL_FILES=()        # accumulated from --rtl flags
TB_FILES=()         # accumulated from --tb flags
RTL_LIST=""         # path to a file listing RTL paths (--rtl-list)
TB_LIST=""          # path to a file listing TB paths (--tb-list)

# -----------------------------------------------------------------------------
# usage(): print help and exit
# -----------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: run_vivado.sh [options]

Required:
  --mode {sim|syn|both}     What to run.
  --top <module>            Top RTL module name.
  One of:
    --rtl <file>            RTL source file (repeatable).
    --rtl-list <file>       File containing RTL paths, one per line.
                            Paths are resolved relative to the list file.
                            '#' starts a comment; blank lines are ignored.

Optional:
  --tb <file>               Testbench file (repeatable).
  --tb-list <file>          Testbench list file (same format as --rtl-list).
  --tb_top <module>         Testbench top module. Default: <top>_tb.
  --xdc <file>              Constraints file (synthesis only).
  --outdir <dir>            Output root. Results go to <dir>/result/vivado_log/.
                            Default: current directory.
  --part <part>             FPGA part. Default: xc7z020clg400-1.
  --jobs <n>                Parallel synth jobs. Default: 4.
  --sim-timeout <duration>  Sim wall-clock cap (timeout(1) syntax). Default: 1h.
  --wave                    Enable WDB waveform dump.
  --archive                 Save a timestamped copy of results.
  -h, --help                Show this help.
USAGE
    exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Self-locate: print where this script actually lives. If multiple copies of
# the script exist (which shouldn't happen, but does), this makes it obvious
# which one is running. Cheap, no side effects.
# -----------------------------------------------------------------------------
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
echo "[run_vivado.sh] script:  ${SCRIPT_PATH}"
echo "[run_vivado.sh] cwd:     $(pwd)"

# -----------------------------------------------------------------------------
# Pre-flight: vivado must be in PATH. If not, the user almost certainly forgot
# to source settings64.sh. Fail fast with a useful hint rather than letting
# Vivado's own error message bubble up cryptically.
# -----------------------------------------------------------------------------
if ! command -v vivado >/dev/null 2>&1; then
    echo "Error: 'vivado' not found in PATH." >&2
    echo "       Source the Vivado settings first, e.g.:" >&2
    echo "       source /opt/Xilinx/Vivado/<version>/settings64.sh" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Parse arguments. Standard while/case loop. Each branch consumes either 1 or
# 2 positional args via `shift`.
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --rtl)         RTL_FILES+=("$2");  shift 2 ;;
        --rtl-list)    RTL_LIST="$2";      shift 2 ;;
        --tb)          TB_FILES+=("$2");   shift 2 ;;
        --tb-list)     TB_LIST="$2";       shift 2 ;;
        --outdir)      OUTDIR="$2";        shift 2 ;;
        --top)         TOP="$2";           shift 2 ;;
        --tb_top)      TB_TOP="$2";        shift 2 ;;
        --mode)        MODE="$2";          shift 2 ;;
        --xdc)         XDC="$2";           shift 2 ;;
        --part)        FPGA_PART="$2";     shift 2 ;;
        --jobs)        JOBS="$2";          shift 2 ;;
        --sim-timeout) SIM_TIMEOUT="$2";   shift 2 ;;
        --wave)        WAVE=true;          shift   ;;
        --archive)     ARCHIVE=true;       shift   ;;
        -h|--help)     usage 0 ;;
        *)             echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# read_list(): read a file-list (.f-style) and emit absolute paths on stdout.
#
# Behavior:
#   - Comments (everything after '#') are stripped.
#   - Blank lines are skipped.
#   - Whitespace is trimmed.
#   - Relative paths are resolved against the list file's directory, NOT cwd.
#     This is the convention everyone expects from .f files — it lets the list
#     be portable: move the list and its files together and it still works.
#   - Absolute paths pass through unchanged.
#
# Stdout: one absolute path per line.
# -----------------------------------------------------------------------------
read_list() {
    local list_file="$1"
    local list_dir
    list_dir="$(dirname "$(realpath "$list_file")")"

    # `|| [[ -n "$line" ]]` handles files without a trailing newline:
    # `read` returns 1 on EOF, but $line may still hold the last line.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                        # strip "# comment"
        line="$(echo "$line" | xargs || true)"    # trim whitespace; xargs is
                                                  # a concise trim trick
        [[ -z "$line" ]] && continue              # skip empty/comment-only lines

        if [[ "$line" = /* ]]; then
            echo "$line"                          # already absolute
        else
            echo "${list_dir}/${line}"            # resolve against list dir
        fi
    done < "$list_file"
}

# Load list files if provided. Append to the same arrays that --rtl/--tb
# already populated, so users can mix list files with explicit flags freely.
if [[ -n "${RTL_LIST}" ]]; then
    [[ ! -f "${RTL_LIST}" ]] && { echo "Error: RTL list not found: ${RTL_LIST}" >&2; exit 1; }
    while IFS= read -r f; do RTL_FILES+=("$f"); done < <(read_list "${RTL_LIST}")
fi
if [[ -n "${TB_LIST}" ]]; then
    [[ ! -f "${TB_LIST}" ]] && { echo "Error: TB list not found: ${TB_LIST}" >&2; exit 1; }
    while IFS= read -r f; do TB_FILES+=("$f"); done < <(read_list "${TB_LIST}")
fi

# -----------------------------------------------------------------------------
# Validate required arguments. Done after list expansion so we can check the
# final RTL/TB file counts rather than just the flag presence.
# -----------------------------------------------------------------------------
[[ "${MODE}" != "sim" && "${MODE}" != "syn" && "${MODE}" != "both" ]] && {
    echo "Error: --mode must be sim, syn, or both" >&2; usage 1
}
[[ ${#RTL_FILES[@]} -eq 0 ]] && {
    echo "Error: no RTL files (use --rtl or --rtl-list)" >&2; usage 1
}
[[ -z "${TOP}" ]] && { echo "Error: --top is required" >&2; usage 1; }

# Testbench is required for any flow that includes simulation.
if [[ "${MODE}" == "sim" || "${MODE}" == "both" ]]; then
    [[ ${#TB_FILES[@]} -eq 0 ]] && {
        echo "Error: testbench required for sim (use --tb or --tb-list)" >&2; usage 1
    }
fi

# Default testbench top follows the common <module>_tb convention.
TB_TOP="${TB_TOP:-${TOP}_tb}"

# -----------------------------------------------------------------------------
# Resolve paths. Everything goes to absolute form so generated TCL doesn't
# depend on which directory Vivado is launched from.
# -----------------------------------------------------------------------------
if [[ -n "${OUTDIR}" ]]; then
    OUTDIR="$(realpath "${OUTDIR}")"
else
    OUTDIR="$(pwd)"
fi
RESULT_DIR="${OUTDIR}/result/vivado_log"
PROJECT_DIR="${RESULT_DIR}/project"
SUMMARY="${RESULT_DIR}/summary.json"

echo "[run_vivado.sh] outdir:  ${OUTDIR}"
echo "[run_vivado.sh] mode:    ${MODE}"
echo "[run_vivado.sh] top:     ${TOP}"

# Verify each RTL/TB file exists. Doing this up front avoids partial runs
# where Vivado launches, then errors on a missing file, leaving stale state.
RTL_ABS=()
for f in "${RTL_FILES[@]}"; do
    [[ ! -f "$f" ]] && { echo "Error: RTL file not found: $f" >&2; exit 1; }
    RTL_ABS+=("$(realpath "$f")")
done

TB_ABS=()
for f in "${TB_FILES[@]}"; do
    [[ ! -f "$f" ]] && { echo "Error: TB file not found: $f" >&2; exit 1; }
    TB_ABS+=("$(realpath "$f")")
done

XDC_ABS=""
if [[ -n "${XDC}" ]]; then
    [[ ! -f "${XDC}" ]] && { echo "Error: XDC file not found: ${XDC}" >&2; exit 1; }
    XDC_ABS="$(realpath "${XDC}")"
fi

# -----------------------------------------------------------------------------
# Reset the result directory. We wipe it each run rather than appending —
# stale logs from a previous run mixed with current ones cause more confusion
# than they solve. Use --archive if preservation matters.
#
# The `:?` is a guard: if RESULT_DIR were somehow empty, `rm -rf /*` would
# be catastrophic. `${VAR:?}` makes bash abort if the variable is unset/empty.
# -----------------------------------------------------------------------------
mkdir -p "${RESULT_DIR}"
rm -rf "${RESULT_DIR:?}"/*

# =============================================================================
# TCL generation
# =============================================================================

# -----------------------------------------------------------------------------
# generate_syn_tcl(): emit ${RESULT_DIR}/syn.tcl for project-mode synthesis.
#
# Approach: project-based flow with launch_runs. This is heavier than a flat
# `synth_design` call but produces standard utilization/timing reports as a
# side effect, and matches what the Vivado GUI does. Easier for users to
# correlate with their normal workflow.
#
# Note on string matching: Vivado's run STATUS strings vary by version
# ("Complete!", "synth_design Complete!", "Complete with warnings", etc.).
# We treat "contains errors" or "missing 'Complete'" as failure; everything
# else passes. "Complete with warnings" therefore correctly counts as success.
# -----------------------------------------------------------------------------
generate_syn_tcl() {
    {
        # Header: project creation. -force overwrites any prior project at
        # this path. Path is wrapped in {} so spaces in absolute paths are
        # safe — TCL list-quoting, not shell quoting.
        echo "create_project syn_proj ${PROJECT_DIR}/syn -part ${FPGA_PART} -force"

        # Add each RTL file. add_files imports references; it does not copy.
        for f in "${RTL_ABS[@]}"; do echo "add_files {$f}"; done

        # Constraints go into the constrs_1 fileset, not sources_1.
        [[ -n "$XDC_ABS" ]] && echo "add_files -fileset constrs_1 {$XDC_ABS}"

        # Body: pin the top, refresh compile order, kick the run, wait for it.
        # The status check uses TCL string matching with -nocase to be tolerant
        # of "Error" vs "ERROR" capitalization across Vivado versions.
        cat <<EOF
set_property top ${TOP} [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs ${JOBS}
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS: \$synth_status"
if {[string match -nocase "*error*" \$synth_status] || ![string match "*Complete*" \$synth_status]} {
    puts "ERROR: Synthesis did not complete successfully (status: \$synth_status)"
    exit 1
}

# Extract utilization and timing reports. These live inside the run dir
# normally, but copying them out to RESULT_DIR makes them trivially findable.
open_run synth_1 -name synth_1
report_utilization -file ${RESULT_DIR}/utilization.rpt
report_timing_summary -file ${RESULT_DIR}/timing.rpt
close_design

close_project
EOF
    } > "${RESULT_DIR}/syn.tcl"
}

# -----------------------------------------------------------------------------
# generate_sim_tcl(): emit ${RESULT_DIR}/sim.tcl for xsim behavioral simulation.
#
# Note on `run all`: this runs until $finish/$stop or no events remain. If the
# testbench doesn't call $finish and the design keeps clocking, simulation
# runs forever — that's where the SIM_TIMEOUT comes in (the bash side wraps
# the vivado invocation with timeout(1)).
# -----------------------------------------------------------------------------
generate_sim_tcl() {
    {
        echo "create_project sim_proj ${PROJECT_DIR}/sim -part ${FPGA_PART} -force"

        # Design sources go to sources_1 (default fileset).
        for f in "${RTL_ABS[@]}"; do echo "add_files {$f}"; done

        # Testbench sources go to sim_1 — they should NOT be synthesized.
        for f in "${TB_ABS[@]}"; do echo "add_files -fileset sim_1 {$f}"; done

        cat <<EOF
set_property top ${TB_TOP} [get_filesets sim_1]
update_compile_order -fileset sim_1
EOF

        # Waveform logging: if --wave is set, tell xsim to capture all signals
        # for WDB output. Default is off because WDBs are large.
        if [[ "${WAVE}" == true ]]; then
            echo 'set_property -name xsim.simulate.log_all_signals -value true -objects [get_filesets sim_1]'
        fi

        cat <<EOF
launch_simulation
run all
close_sim
close_project
EOF
    } > "${RESULT_DIR}/sim.tcl"
}

# =============================================================================
# Log analysis
# =============================================================================
# These functions emit a JSON object on stdout describing what happened in
# each phase. The main flow assembles them into summary.json. Keeping them as
# separate functions makes it easy to test them independently and to extend
# (e.g., add utilization parsing) without touching the main flow.

# -----------------------------------------------------------------------------
# analyze_syn_log(): grade synthesis based on syn.log contents.
#
# Vivado writes errors as lines starting with "ERROR:", warnings with
# "WARNING:", and a stricter class with "CRITICAL WARNING:". We count each
# and also check for our own injected "Synthesis did not complete" marker
# (emitted by the TCL when STATUS isn't acceptable).
# -----------------------------------------------------------------------------
analyze_syn_log() {
    local log="${RESULT_DIR}/syn.log"
    if [[ ! -f "$log" ]]; then
        echo '{"ran":true,"status":"failed","reason":"log_missing"}'
        return
    fi

    # `|| true` keeps grep's nonzero exit (no matches) from tripping `set -e`.
    local errors warnings crit
    errors=$(grep -cE '^ERROR:' "$log" 2>/dev/null || true)
    warnings=$(grep -cE '^WARNING:' "$log" 2>/dev/null || true)
    crit=$(grep -cE '^CRITICAL WARNING:' "$log" 2>/dev/null || true)

    local status="passed"
    if [[ ${errors:-0} -gt 0 ]] || grep -q "ERROR: Synthesis did not complete" "$log" 2>/dev/null; then
        status="failed"
    fi

    printf '{"ran":true,"status":"%s","errors":%d,"warnings":%d,"critical_warnings":%d,"log":"syn.log"}' \
        "$status" "${errors:-0}" "${warnings:-0}" "${crit:-0}"
}

# -----------------------------------------------------------------------------
# analyze_sim_log(): grade simulation, with three-state result.
#
# The xsim runtime log (simulate.log) is the authoritative source — it has
# the actual $display output from the testbench. sim.log is the higher-level
# Vivado log and is used as fallback only.
#
# Status logic (in order of precedence):
#   1. Explicit FAIL marker found       -> failed
#   2. Errors or fatals in log          -> failed
#   3. Explicit PASS marker found       -> passed
#   4. Otherwise (clean run, no marker) -> unknown
#
# "unknown" is a deliberate third state, not a synonym for failure. It tells
# the caller "the simulator ran without complaint, but your testbench didn't
# tell us whether it actually verified anything." The fix is on the user's
# side — add a TEST PASSED / TEST FAILED $display.
# -----------------------------------------------------------------------------
analyze_sim_log() {
    # Prefer the xsim runtime log; fall back to vivado's top-level log.
    local log="${RESULT_DIR}/simulate.log"
    [[ ! -f "$log" ]] && log="${RESULT_DIR}/sim.log"
    if [[ ! -f "$log" ]]; then
        echo '{"ran":true,"status":"failed","reason":"log_missing"}'
        return
    fi

    local errors fatals pass_marker fail_marker status
    errors=$(grep -cE '^Error:|^ERROR:|FATAL_ERROR' "$log" 2>/dev/null || true)
    fatals=$(grep -cE 'Fatal:|\$fatal called|\$finish.*due to.*error' "$log" 2>/dev/null || true)

    pass_marker=0
    fail_marker=0
    grep -qE 'TEST[ _]PASSED|SIMULATION PASSED|ALL TESTS PASSED' "$log" 2>/dev/null && pass_marker=1
    grep -qE 'TEST[ _]FAILED|SIMULATION FAILED|ASSERTION FAILED' "$log" 2>/dev/null && fail_marker=1

    if [[ $fail_marker -eq 1 ]]; then
        status="failed"
    elif [[ ${errors:-0} -gt 0 || ${fatals:-0} -gt 0 ]]; then
        status="failed"
    elif [[ $pass_marker -eq 1 ]]; then
        status="passed"
    else
        status="unknown"
    fi

    printf '{"ran":true,"status":"%s","errors":%d,"fatals":%d,"pass_marker":%d,"fail_marker":%d,"log":"%s"}' \
        "$status" "${errors:-0}" "${fatals:-0}" "$pass_marker" "$fail_marker" "$(basename "$log")"
}

# -----------------------------------------------------------------------------
# diagnose_sim_timeout(): when xsim hits the wall-clock timeout, classify why.
#
# Five hypotheses, in roughly decreasing likelihood:
#   1. No $finish — clock keeps toggling, run all never returns.
#   2. Sim time advancing but slowly — the design is correct, just big.
#      Tell user to bump --sim-timeout.
#   3. Sim time stalled — likely deadlock/livelock in the design under test.
#      Suggest --wave for waveform inspection.
#   4. Stuck in compile/elaborate — fail before sim even starts.
#   5. Truly nothing in the log — Vivado itself hung early.
#
# We emit a best-guess "likely_cause" string and the last 30 lines of the log
# so the agent can show the user something actionable rather than just
# "timed out, sorry".
# -----------------------------------------------------------------------------
diagnose_sim_timeout() {
    local sim_log="${RESULT_DIR}/simulate.log"
    local elab_log="${RESULT_DIR}/elaborate.log"
    local compile_log="${RESULT_DIR}/compile.log"
    local cause="unknown"
    local hint=""
    local tail_lines=""

    if [[ -f "$compile_log" && ! -f "$elab_log" ]]; then
        cause="stuck_in_compile"
        hint="Timed out during HDL compilation. Check compile.log — likely a syntax issue or extremely slow xvlog/xvhdl on a large source set."
    elif [[ -f "$elab_log" && ! -f "$sim_log" ]]; then
        cause="stuck_in_elaboration"
        hint="Timed out during xelab. Often caused by deeply nested generate blocks, large parameterized modules, or unresolved hierarchies."
    elif [[ -f "$sim_log" ]]; then
        # Look at the last few lines and the simulation-time progression.
        tail_lines="$(tail -30 "$sim_log" 2>/dev/null || true)"

        # Did $finish appear at all? If so, the simulation actually completed
        # — odd that we still timed out. Worth flagging.
        if grep -q '\$finish called' "$sim_log" 2>/dev/null; then
            cause="finished_but_killed_late"
            hint="Sim called \$finish but the wrapper still hit the wall clock — unusual. Check if there are multiple \$finish calls or post-finish work."
        else
            # Compare time-progression markers across the log. xsim's $monitor
            # and similar emit "Time:"-prefixed lines. If the last 200 lines
            # have many such markers, simulation is still progressing —
            # design is probably fine, the run is just long. If the markers
            # appear early but stop late, we're likely deadlocked.
            local time_count
            time_count=$(grep -cE '^Time:|at time' "$sim_log" 2>/dev/null || true)

            if [[ ${time_count:-0} -eq 0 ]]; then
                cause="no_finish_no_progress"
                hint="No \$finish in testbench AND no time progression visible. Either the testbench never starts driving (check initial blocks) or output is fully suppressed. Add a top-level timeout watchdog with #<N>; \$finish; in your TB."
            else
                local last_chunk first_chunk
                last_chunk=$(tail -200 "$sim_log" | grep -cE '^Time:|at time' || true)
                first_chunk=$(head -200 "$sim_log" | grep -cE '^Time:|at time' || true)

                if [[ ${last_chunk:-0} -gt 0 ]]; then
                    cause="long_running_simulation"
                    hint="Simulation appears to be progressing (time advancing in recent log lines). Likely just a long-running TB — try --sim-timeout 4h, or shorten the stimulus."
                else
                    cause="sim_time_stalled"
                    hint="Time progression appears to have stopped (markers seen early but not recently). Likely deadlock: a handshake stuck on ready/valid, a state machine stuck in a state, or a full FIFO with no drain. Re-run with --wave and inspect the WDB."
                fi
                # Reference these so shellcheck doesn't complain about unused.
                : "$first_chunk"
            fi
        fi
    else
        cause="vivado_hung_early"
        hint="No simulation logs were produced before timeout. Vivado may have hung during project setup."
    fi

    # Emit JSON. tail_lines is escaped minimally — we strip backslashes and
    # double-quotes since this is a best-effort diagnostic, not a full JSON
    # serializer. Newlines become \n.
    local tail_escaped
    tail_escaped=$(printf '%s' "$tail_lines" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}')

    printf '{"likely_cause":"%s","hint":"%s","log_tail":"%s"}' \
        "$cause" "$hint" "$tail_escaped"
}

# =============================================================================
# Run phases
# =============================================================================

# Track whether each phase actually executed, for accurate summary reporting.
SYN_RAN=false
SIM_RAN=false
SIM_TIMED_OUT=false   # set when timeout(1) returns 124

# -----------------------------------------------------------------------------
# run_syn(): execute synthesis. Returns nonzero if Vivado itself fails.
# -----------------------------------------------------------------------------
run_syn() {
    SYN_RAN=true
    echo "=== Running Synthesis ==="
    generate_syn_tcl

    # `|| rc=$?` captures Vivado's exit code without tripping `set -e`.
    local rc=0
    vivado -mode batch -source "${RESULT_DIR}/syn.tcl" \
        -log "${RESULT_DIR}/syn.log" \
        -journal "${RESULT_DIR}/syn.jou" || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "Synthesis tool exited with code: $rc"
        return 1
    fi
    echo "=== Synthesis Done ==="
}

# -----------------------------------------------------------------------------
# run_sim(): execute simulation under a timeout(1) wrapper.
#
# timeout(1) exit codes:
#   124  killed for exceeding the time limit
#   137  killed by SIGKILL (rare; kernel OOM or similar)
#   <other>  the wrapped command's own exit code
#
# We don't return failure here on its own — log analysis decides pass/fail
# afterwards. We only set SIM_TIMED_OUT so the summary can report it.
# -----------------------------------------------------------------------------
run_sim() {
    SIM_RAN=true
    echo "=== Running Simulation ==="
    generate_sim_tcl

    local rc=0
    timeout "${SIM_TIMEOUT}" vivado -mode batch -source "${RESULT_DIR}/sim.tcl" \
        -log "${RESULT_DIR}/sim.log" \
        -journal "${RESULT_DIR}/sim.jou" || rc=$?

    if [[ $rc -eq 124 ]]; then
        echo "Simulation TIMED OUT after ${SIM_TIMEOUT}"
        SIM_TIMED_OUT=true
    elif [[ $rc -ne 0 ]]; then
        echo "Simulation tool exited with code: $rc"
    fi

    # Copy xsim outputs to RESULT_DIR for easy log inspection. xsim normally
    # buries them in <project>/<project>.sim/sim_1/behav/xsim/ which is
    # tedious to remember.
    local sim_out="${PROJECT_DIR}/sim/sim_proj.sim/sim_1/behav/xsim"
    if [[ -d "$sim_out" ]]; then
        for f in simulate.log elaborate.log compile.log xvlog.log; do
            [[ -f "$sim_out/$f" ]] && cp "$sim_out/$f" "${RESULT_DIR}/"
        done
        if [[ "${WAVE}" == true ]]; then
            local wdb
            wdb=$(find "$sim_out" -maxdepth 1 -name "*.wdb" | head -1)
            [[ -n "$wdb" ]] && cp "$wdb" "${RESULT_DIR}/"
        fi
    fi
    echo "=== Simulation Done ==="
}

# =============================================================================
# Main dispatch
# =============================================================================

# In `both` mode, skip simulation if synthesis fails — saves an hour of useless
# sim time when the design isn't even synthesizable.
case "${MODE}" in
    syn)
        run_syn || true
        ;;
    sim)
        run_sim || true   # log analysis decides pass/fail
        ;;
    both)
        if ! run_syn; then
            echo "Skipping simulation due to synthesis failure."
        else
            run_sim || true
        fi
        ;;
esac

# =============================================================================
# Build summary.json
# =============================================================================

# Collect per-phase JSON. If a phase didn't run, mark it skipped.
if [[ "$SYN_RAN" == true ]]; then
    syn_json=$(analyze_syn_log)
else
    syn_json='{"ran":false,"status":"skipped"}'
fi

if [[ "$SIM_RAN" == true ]]; then
    sim_json=$(analyze_sim_log)
else
    sim_json='{"ran":false,"status":"skipped"}'
fi

# If we hit the wall-clock timeout, run the diagnostic and inject it into
# the simulation portion of the summary. Override the sim status to "timeout"
# so the caller can branch on it specifically.
if [[ "$SIM_TIMED_OUT" == true ]]; then
    timeout_diag=$(diagnose_sim_timeout)
    # Surgery on the existing sim_json: drop the closing brace, add fields.
    # This is mildly hacky but avoids pulling jq in as a dependency.
    sim_json="${sim_json%\}},\"status_override\":\"timeout\",\"timeout_after\":\"${SIM_TIMEOUT}\",\"diagnosis\":${timeout_diag}}"
fi

# Determine overall status. Order matters: failed beats unknown beats timeout
# beats passed. We check timeout last (lowest priority) because if there's
# a real failure visible in the logs, that's more informative.
overall="passed"
if [[ "$SIM_TIMED_OUT" == true ]]; then
    overall="timeout"
fi
if grep -q '"status":"failed"' <<< "$syn_json$sim_json"; then
    overall="failed"
elif [[ "$overall" != "timeout" ]] && grep -q '"status":"unknown"' <<< "$sim_json"; then
    overall="unknown"
fi

# Write summary.json. Heredoc with substitutions for the top-level fields,
# and pre-built JSON strings for the nested phase results.
cat > "${SUMMARY}" <<EOF
{
  "overall_status": "${overall}",
  "mode": "${MODE}",
  "top": "${TOP}",
  "tb_top": "${TB_TOP}",
  "part": "${FPGA_PART}",
  "timestamp": "$(date -Iseconds)",
  "result_dir": "${RESULT_DIR}",
  "synthesis": ${syn_json},
  "simulation": ${sim_json}
}
EOF

echo ""
echo "=== Summary ==="
cat "${SUMMARY}"
echo ""

# -----------------------------------------------------------------------------
# Optional: archive a timestamped copy of the result directory.
# Useful for keeping multiple runs side-by-side when exploring synthesis
# settings or comparing TB versions. Off by default to avoid disk bloat.
# -----------------------------------------------------------------------------
if [[ "$ARCHIVE" == true ]]; then
    TS_DIR="${OUTDIR}/result/vivado_log_$(date +%Y%m%d_%H%M%S)"
    cp -r "${RESULT_DIR}" "${TS_DIR}"
    echo "Archived to ${TS_DIR}"
fi

echo "Results in: ${RESULT_DIR}"

# -----------------------------------------------------------------------------
# Exit code maps to overall_status. Distinct codes let an agent or CI script
# branch on outcomes without parsing JSON if it doesn't want to.
# -----------------------------------------------------------------------------
case "$overall" in
    passed)  exit 0 ;;
    failed)  exit 1 ;;
    unknown) exit 3 ;;
    timeout) exit 4 ;;
    *)       exit 1 ;;
esac
