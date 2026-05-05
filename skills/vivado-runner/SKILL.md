---
name: vivado-runner
description: Run Xilinx Vivado synthesis and/or xsim simulation for FPGA RTL projects. Use when the user wants to compile, synthesize, simulate, or check Verilog/SystemVerilog/VHDL designs targeting Xilinx 7-series, Zynq, UltraScale, or other Vivado-supported parts. Triggers on mentions of Vivado, xsim, synthesis, RTL simulation, testbench runs, "run my testbench", "synthesize this design", "check if this compiles", or any FPGA workflow involving .v/.sv/.vhd files plus an XDC.
---

# Vivado Runner

Wraps Vivado batch-mode synthesis and xsim simulation behind a single shell script that produces a structured `summary.json` plus log files. The script handles project creation, TCL generation, log parsing, and pass/fail detection.

## Critical: invoke in place, do not copy

Always call the script from this skill directory:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run_vivado.sh" [args...]
```

If `${CLAUDE_PLUGIN_ROOT}` is not set in your environment, use the absolute path to this skill folder. **Do not copy `run_vivado.sh` into the user's project.** The script is location-independent — it uses absolute paths internally and writes outputs to `--outdir`. Copying creates version drift and pollutes user repositories.

## Pre-flight before running

1. **Verify Vivado is on PATH.** Run `command -v vivado`. If it's missing, tell the user to source their Vivado settings (e.g. `source /opt/Xilinx/Vivado/2023.2/settings64.sh`) and stop. The script will fail with a clear message anyway, but catching it early avoids wasted setup.
2. **Identify the inputs.** Locate RTL files, testbench files, optional XDC. For more than a handful of files, generate a file list rather than passing many `--rtl` flags.
3. **Confirm the top module.** If unclear from the file structure, ask the user.

## Calling the script

### Few files

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run_vivado.sh" \
    --mode both \
    --top adder \
    --rtl ./rtl/adder.v \
    --tb  ./tb/adder_tb.v \
    --outdir .
```

### Many files (preferred for real projects)

Create a file list — paths resolve relative to the list file's directory. Lines starting with `#` and blank lines are ignored.

```text
# rtl_files.f
core/alu.sv
core/regfile.sv
core/control.sv
top/cpu.sv
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run_vivado.sh" \
    --mode both \
    --top cpu \
    --rtl-list ./rtl_files.f \
    --tb-list  ./sim/tb_files.f \
    --xdc      ./constraints/zynq.xdc \
    --outdir   .
```

### All flags

| Flag                       | Purpose |
|----------------------------|---------|
| `--mode {sim,syn,both}`    | **Required.** What to run. |
| `--top <module>`           | **Required.** Top RTL module. |
| `--rtl <file>`             | RTL source (repeatable). At least one of `--rtl`/`--rtl-list` required. |
| `--rtl-list <file>`        | File of RTL paths, one per line. |
| `--tb <file>`              | Testbench file (repeatable). Required for `sim`/`both`. |
| `--tb-list <file>`         | File of testbench paths. |
| `--tb_top <module>`        | Testbench top. Default: `<top>_tb`. |
| `--xdc <file>`             | Constraints file (synthesis only). |
| `--outdir <dir>`           | Output root. Results go to `<dir>/result/vivado_log/`. Default: cwd. |
| `--part <part>`            | FPGA part. Default: `xc7z020clg400-1`. |
| `--jobs <n>`               | Parallel synth jobs. Default: `4`. |
| `--sim-timeout <duration>` | Sim timeout (`timeout(1)` syntax). Default: `1h`. |
| `--wave`                   | Enable WDB waveform dump. |
| `--archive`                | Save a timestamped copy of results (off by default). |

## CRITICAL: After the script returns

The exit code alone is **not enough**. xsim sometimes returns 0 even when assertions fail, and warnings can hide real problems. Always do all three steps below, in order:

### Step 1 — Read `summary.json`

```bash
cat <outdir>/result/vivado_log/summary.json
```

Structure:

```json
{
  "overall_status": "passed | failed | unknown | timeout",
  "mode": "both",
  "top": "...",
  "synthesis": {
    "ran": true,
    "status": "passed | failed | skipped",
    "errors": 0,
    "warnings": 5,
    "critical_warnings": 0,
    "log": "syn.log"
  },
  "simulation": {
    "ran": true,
    "status": "passed | failed | unknown | skipped",
    "errors": 0,
    "fatals": 0,
    "pass_marker": 1,
    "fail_marker": 0,
    "log": "simulate.log"
  }
}
```

When the simulation hits its wall-clock limit, a `diagnosis` block is added under `simulation` along with a `status_override: "timeout"` field:

```json
"simulation": {
  ...,
  "status_override": "timeout",
  "timeout_after": "1h",
  "diagnosis": {
    "likely_cause": "no_finish_no_progress | long_running_simulation | sim_time_stalled | stuck_in_compile | stuck_in_elaboration | finished_but_killed_late | vivado_hung_early",
    "hint": "<actionable suggestion>",
    "log_tail": "<last 30 lines of simulate.log, escaped>"
  }
}
```

Exit codes: `0` = passed, `1` = failed, `2` = environment error (no vivado), `3` = unknown (sim ran clean but no pass/fail marker), `4` = timeout.

**Handling timeout outcomes**: read `diagnosis.likely_cause` and act on it directly rather than asking the user generic questions:

- `no_finish_no_progress` — testbench has no `$finish` or initial blocks aren't driving. Recommend adding a watchdog `initial begin #<N>; $finish; end`.
- `long_running_simulation` — sim is fine, just big. Suggest `--sim-timeout 4h` (or higher).
- `sim_time_stalled` — likely a deadlock in the DUT. Recommend `--wave` and waveform inspection.
- `stuck_in_compile` / `stuck_in_elaboration` — Vivado never finished bringing up the simulation. Read `compile.log` / `elaborate.log` for the cause.
- `finished_but_killed_late` — unusual; investigate post-`$finish` work in the TB.
- `vivado_hung_early` — Vivado problem unrelated to the design. Suggest re-running.

### Step 2 — Read the actual logs

Even if `summary.json` says passed, look at the logs to surface anything the user should know about:

**Synthesis** (`syn.log`):
```bash
grep -nE "^(ERROR|CRITICAL WARNING):" <outdir>/result/vivado_log/syn.log
# Also worth scanning: utilization summary, timing report
```

**Simulation** (`simulate.log` — xsim runtime log; falls back to `sim.log`):
```bash
grep -nE "^(Error|Fatal|Warning):|TEST_(PASSED|FAILED)|\\\$finish" \
    <outdir>/result/vivado_log/simulate.log | head -60
```

For non-trivial logs, read targeted chunks with the file viewer rather than dumping everything. The interesting bits are usually near the end of the log and around any `Error:` lines.

### Step 3 — Report to the user

- **passed**: confirm what passed, mention notable warnings (especially CRITICAL WARNINGs in synthesis — those often indicate latches, multi-driven nets, or timing issues).
- **failed**: pinpoint the failure — which file, which line, which error message. Quote the relevant log line. Don't just relay "synthesis failed".
- **unknown** (simulation only): explain that the sim ran cleanly but produced no `TEST PASSED` / `TEST FAILED` marker. Show whatever `$display` output is in `simulate.log` so the user can judge. Suggest the testbench convention below.

## Recommended testbench convention

For reliable pass/fail detection, encourage testbenches to print one of these markers before `$finish`:

```verilog
if (errors == 0)
    $display("TEST PASSED");
else
    $display("TEST FAILED: %0d errors", errors);
$finish;
```

Recognized markers (case-sensitive):
- Pass: `TEST PASSED`, `TEST_PASSED`, `SIMULATION PASSED`, `ALL TESTS PASSED`
- Fail: `TEST FAILED`, `TEST_FAILED`, `SIMULATION FAILED`, `ASSERTION FAILED`

Any of `Error:`, `Fatal:`, or `$fatal called` in the log also marks it as failed regardless of markers.

## Common situations

- **Flat directory of `.v` files.** Glob them into a file list — `ls rtl/*.v > rtl_files.f` then edit as needed.
- **Synthesis-only check (no testbench yet).** Use `--mode syn`; no `--tb` needed.
- **Long simulation.** Bump `--sim-timeout 4h` (or whatever fits).
- **Non-default part.** Pass `--part xc7a100tcsg324-1` (Artix-7), `--part xczu7ev-ffvc1156-2-e` (Zynq UltraScale+), etc.
- **Multiple synthesis attempts at different settings.** Use `--archive` so each run is preserved with a timestamp.
- **Vivado version matters for the user.** Check `vivado -version` if uncertain — the script doesn't enforce a version, but TCL APIs occasionally shift.

## Result directory layout

```
<outdir>/result/vivado_log/
├── summary.json          # read this first
├── syn.log               # vivado's main synthesis log
├── syn.tcl               # generated synthesis script (for inspection)
├── utilization.rpt       # synthesis resource usage (after successful synth)
├── timing.rpt            # synthesis timing summary (after successful synth)
├── sim.log               # vivado's main simulation log
├── sim.tcl               # generated simulation script
├── simulate.log          # xsim runtime log (the one with $display output)
├── elaborate.log         # xsim elaboration
├── compile.log           # xsim compile (xvlog/xvhdl)
├── *.wdb                 # waveform (only with --wave)
└── project/              # vivado project files (large; safe to ignore)
```
