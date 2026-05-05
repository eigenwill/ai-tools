---
name: sv-author
description: Author SystemVerilog RTL and testbenches that follow strict team conventions for synthesizability, file structure, naming, CDC, and verification output. Use this skill whenever the user asks Claude to write, generate, refactor, or scaffold SystemVerilog (.sv) or Verilog (.v) modules — including FPGA designs, RTL components, ALUs, FSMs, AXI/handshake interfaces, memory controllers, peripherals, clock-domain crossings, or testbenches. Use it even when the user doesn't explicitly say "follow the convention" — generated SV must follow the team coding standard unless the user says otherwise. Pair this with the vivado-runner skill: testbenches produced here are designed to be graded by vivado-runner's pass/fail markers.
---

# SystemVerilog Author

Produce SystemVerilog that complies with the team coding standard, is
synthesizable by Vivado, and is verifiable by automation. This skill exists
because LLM-generated HDL otherwise drifts: simulation-only constructs leak
into RTL, signal naming is inconsistent across files, testbenches print
free-form `$display` that nobody can grade, and modules sprawl without a
clear top/sub split.

The two outputs this skill governs are **RTL** (must be synthesizable) and
**testbenches** (must be self-checking with machine-readable pass/fail
markers). Both follow the file structure and naming rules below.

## Pairing with vivado-runner

If the `vivado-runner` skill is available, the user will likely run the
generated code through it. That sets two hard requirements on testbenches
produced here:

1. **Print a pass/fail marker before `$finish`.** vivado-runner greps for
   `TEST PASSED` / `TEST FAILED`. A testbench that ends without a marker
   is graded `unknown` — which is a failure of the testbench, not the DUT.
2. **Always include a watchdog timeout.** vivado-runner kills sims that
   hang past its wall-clock limit. A testbench without a `$finish`-bearing
   watchdog risks getting killed mid-run with no useful diagnosis.

Both of these are handled by the testbench template in
`references/tb-template.md`.

## Workflow

When asked to write SystemVerilog:

1. **Clarify intent before coding.** Get clear on: what the module does,
   its interface (ports/protocols), clock/reset scheme, target part if
   specified, and whether a testbench is wanted. If something material is
   ambiguous (e.g., AXI-Lite vs custom handshake, signed vs unsigned
   arithmetic, single-clock vs CDC), ask once before writing.
2. **Read the relevant reference.** Load `references/rtl-conventions.md`
   for RTL work or `references/tb-template.md` for testbench work. For
   mixed tasks, load both. The conventions document is the authoritative
   ruleset; this SKILL.md only sketches the highlights.
3. **Write to the file structure described below.** One module per file,
   filename matches module name.
4. **Self-review against `references/synthesizability-checklist.md`**
   before declaring done. The checklist catches the LLM-typical mistakes:
   `initial` blocks in RTL, `#delays`, blocking assignments in sequential
   logic, missing case defaults, etc.
5. **If the user has vivado-runner available, suggest running it.** Don't
   run it automatically — let the user decide when to spend simulator
   time.

## File structure

One module, one file. The filename matches the module name exactly
(`adder.sv` defines `module adder`). This is non-negotiable — Vivado's
project-mode flow uses filename-based file ordering, and humans use file
search.

For a typical project, the recommended layout is:

```
project/
├── rtl/
│   ├── <top>.sv              # top-level module
│   ├── <submodule_a>.sv
│   ├── <submodule_b>.sv
│   └── <project>_pkg.sv      # shared types, params, localparams
├── tb/
│   ├── <top>_tb.sv           # top-level testbench
│   └── <submodule_a>_tb.sv   # unit testbenches (optional but encouraged)
├── constraints/
│   └── <board>.xdc           # pin/timing constraints
└── docs/
    └── README.md             # what this module does, interface, status
```

If the user's existing project doesn't use this layout, follow theirs —
don't reorganize files unprompted. But for new projects, this layout slots
cleanly into vivado-runner: `--rtl-list rtl/files.f --tb-list tb/files.f
--xdc constraints/*.xdc`.

## High-level conventions

These are the rules that shape every decision; the references hold the
detail.

### Defaults

- **Clock**: positive-edge triggered, single-clock per module, named `clk`
  (or `<domain>_clk` for multi-domain projects).
- **Reset**: **synchronous, active-low**, named `rst_n`. Used as
  `always_ff @(posedge clk)` ... `if (!rst_n)`. The reset is sampled on
  the clock edge, so `rst_n` only needs to be valid in the cycle the
  flop is meant to reset.
- **Procedural blocks**: `always_ff` for sequential, `always_comb` for
  combinational. **`always_latch` is forbidden** — if latch behavior is
  truly needed, instantiate a vendor primitive.
- **Types**: `logic` everywhere (not `wire`/`reg`). `int` for loop
  counters, `genvar` for generate iterators.
- **FSM**: `typedef enum logic [N-1:0] {...} state_e` with explicit
  one-hot values for complex FSMs; two-process style (separate state
  register and next-state combinational).

### Naming highlights

| Thing | Convention | Example |
|-------|-----------|---------|
| Module / file | `lower_snake_case` | `dma_controller.sv` |
| Signal | `lower_snake_case`, ≤30 chars | `data_valid` |
| Inter-module signal | `xx2yy_<name>` prefix | `core2cache_addr` |
| Active-low | `_n` suffix | `rst_n`, `cs_n` |
| Clock | `_clk` (or just `clk`) | `axi_clk` |
| First-stage CDC sync | `_asyn` suffix | `req_asyn` |
| Parameter / macro | `UPPER_SNAKE_CASE` | `DATA_WIDTH` |
| Localparam (incl. FSM states) | `UPPER_SNAKE_CASE` | `ST_IDLE` |
| Bus declaration | descending `[N-1:0]` | `logic [31:0] dat` |
| Memory declaration | bus desc, depth asc | `logic [W-1:0] mem [0:D-1]` |
| Instance name | `u_<name>` (or `u0_`, `u1_`) | `u_module_xx` |

The full abbreviation table (`addr`, `cnt`, `req`, `vld`, `wr`, `rd`,
etc.) and suffix table (`_en`, `_dis`, `_sel`, `_flg`, `_dly`, etc.) are
in `references/rtl-conventions.md` §2.3 and §2.4.

### File header

Every file opens with a header block giving filename, author, creation
date, description, and revision history. The full template is in
`references/rtl-conventions.md` §1.

### Module declaration style

ANSI-style port declaration: direction and type written inside the port
list. Parameters use `#(...)`, internal-only constants use `localparam`
after the port list:

```systemverilog
module module_example #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 20
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic [DATA_WIDTH-1:0]      xx2yy_din,
    input  logic [ADDR_WIDTH-1:0]      xx2yy_addr,
    output logic [DATA_WIDTH-1:0]      xx2yy_dout
);

    localparam int LCDW = 32;
    // ...
endmodule
```

### Module instantiation style

Named port mapping only, all ports listed (even unconnected outputs use
empty parens), no expressions in port connections, `u_` instance prefix:

```systemverilog
module_xx u_module_xx (
    .clk         (clk),
    .rst_n       (rst_n),
    .xx2yy_din   (xx2yy_din),
    .xx2yy_addr  (xx2yy_addr),
    .xx2yy_dout0 (xx2yy_dout),
    .xx2yy_dout1 ()             // intentionally unconnected
);
```

### Testbench rules

The full testbench template is in `references/tb-template.md`. The
high-level rules:

- **Self-checking, not eyeball-checking.** Compare DUT output against
  expected, increment an `errors` counter on mismatch.
- **End with `TEST PASSED` or `TEST FAILED` before `$finish`.**
- **Always include a watchdog timeout.**
- **Testbench top is `<module>_tb`** by default.
- **No assertions in synthesis paths.** SVA-as-checker belongs in the TB.

## CDC (clock-domain crossing)

CDC bugs simulate fine and fail in hardware. Treat every async crossing
as a deliberate design decision documented in the spec.

The full CDC ruleset is in `references/rtl-conventions.md` §15.

## Reference files

This skill loads supporting documents on demand. Load them before
generating code in the matching domain.

| File | When to read |
|------|-------------|
| `references/rtl-conventions.md` | Before writing or modifying any RTL. The full ruleset — naming, formatting, always-block discipline, reset, clocking, FSM, CDC, module partitioning, forbidden constructs. Has a TOC. |
| `references/tb-template.md` | Before writing or modifying any testbench. Includes the copy-paste skeleton with watchdog and pass/fail markers. |
| `references/synthesizability-checklist.md` | Run through before declaring RTL done. Catches the typical LLM and human mistakes. |

## Common situations

- **User asks for "just a quick module" with no clarification.** Ask the
  minimum needed (interface, clock/reset polarity if they want to
  override the default, target part if relevant) and write it. Don't
  skip the file header or the synthesizability checklist — the cost is
  low and the value is high.
- **User pastes existing code and asks for changes.** Match their
  existing style for naming, reset polarity, and indentation, even if
  it differs from this skill's defaults. Note any deviations from
  synthesizable-RTL rules that you're preserving — they may not be
  aware.
- **User wants a testbench for an existing module.** Read the module
  first to extract its interface. Generate stimulus that exercises
  typical paths plus at least one corner case. Always include the
  pass/fail marker and watchdog.
- **Module has no clock (pure combinational).** That's fine — use
  `always_comb` and skip the reset discussion. Don't invent a clock
  just for consistency.
- **User says "I'll run vivado-runner on this".** Make sure the
  testbench prints `TEST PASSED` / `TEST FAILED` and has a watchdog.
  Mention briefly which top module names to pass to `--top` and
  `--tb_top`.

## What this skill won't do

- **Won't write SystemVerilog targeting ASIC backend flows.** The team
  coding standard has rules for ASIC backend (scan-chain bypass, clock
  cell selection, feedthrough cells) that aren't captured here because
  the target is FPGA. If the user is doing ASIC work, surface that and
  ask for the missing rules.
- **Won't write UVM testbenches** unless the user asks. UVM is its own
  world with heavy infrastructure costs; the default TB style here is
  simple Verilog-style self-checking, which is right-sized for the
  directed tests most users want.
- **Won't run the simulation.** That's vivado-runner's job. This skill
  produces files; the runner produces results.
