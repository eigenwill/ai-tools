# RTL Conventions

This document is the full ruleset for writing the RTL portion of a project. It
is adapted from a Verilog-targeted team coding standard, translated to
SystemVerilog where the SV form is strictly better (e.g. `always_ff` instead
of bare `always`, `logic` instead of `wire`/`reg`). Conventions concerning
ASIC backend flow (post-PD netlist checks, scan-chain bypass, feedthrough
cells) are omitted because the target here is FPGA synthesis via Vivado.

A companion testbench guide lives at `tb-template.md`. A self-review checklist
is at `synthesizability-checklist.md`.

## Table of Contents

1. [File header](#1-file-header)
2. [Naming](#2-naming)
3. [Module declaration](#3-module-declaration)
4. [Module instantiation](#4-module-instantiation)
5. [Comments](#5-comments)
6. [Formatting](#6-formatting)
7. [Always block discipline](#7-always-block-discipline)
8. [Reset](#8-reset)
9. [Clocking](#9-clocking)
10. [FSM coding](#10-fsm-coding)
11. [Expressions and types](#11-expressions-and-types)
12. [case statements](#12-case-statements)
13. [for loops](#13-for-loops)
14. [Functions](#14-functions)
15. [Clock-domain crossing](#15-clock-domain-crossing)
16. [Module partitioning](#16-module-partitioning)
17. [Forbidden constructs](#17-forbidden-constructs)

---

## 1. File header

Every file begins with a header giving filename, author, creation date, a
short description, and a revision history. Future readers (often the user
six months later) need this to know what a file is for and who to ask.

```systemverilog
//-----------------------------------------------------------------------------
//
//              (C) COPYRIGHT <year>-<year> <Company>
//                          ALL RIGHTS RESERVED
//
//-----------------------------------------------------------------------------
// Filename     : <module_name>.sv
// Author       : <author> (<email>)
// Created      : <YYYY.MM.DD>
// Description  :
//                1) <one-line purpose>
//                2) <key external connections, if not obvious from ports>
//                3) <non-obvious assumptions: clock, reset, handshake protocol>
//
// History      :
//                <YYYY.MM.DD>, <author>, initial version
//                <YYYY.MM.DD>, <author>, <what changed and why>
//
//-----------------------------------------------------------------------------
```

The Description tracks the module's contract, not its implementation. A
header that has to be updated for every code change rots; one that just
sketches the contract stays useful.

## 2. Naming

### 2.1 Modules and files

- One module per file. Filename matches the module name exactly: `module foo`
  lives in `foo.sv`.
- Module names are lowercase. Vendor IP names may keep their original case
  (don't rewrite a vendor's `XPM_FIFO_ASYNC` to `xpm_fifo_async`).
- Use `lower_snake_case`. No camelCase, no PascalCase.

### 2.2 Signals

- Lowercase, `lower_snake_case`, segments separated by `_`.
- Names must start with a letter. Allowed characters: letters, digits, `_`.
- Maximum 30 characters — beyond that, names become hard to scan.
- No reserved words. No relying on case for distinction (`foo` and `Foo`
  must not coexist as different signals).
- Buses use descending range: `logic [N-1:0] data`. Never `[0:N-1]` for
  buses. (Memories are different — see §11.)
- Inter-module port signals use `xx2yy_` prefix to indicate direction:
  `core2cache_addr`, `cpu2bus_req`. This makes it obvious from the name
  alone where a signal originates and where it's going. Apply at the port
  list level; internal wires don't need it.
- Use abbreviations from §2.3 to keep names short and consistent.
- Add suffixes from §2.4 to mark special roles (`_n`, `_clk`, `_en`, etc.).

### 2.3 Standard abbreviations

Use these in signal names. Consistent abbreviations make code searchable
and reduce the cognitive load of cross-module reading.

| Full word | Abbrev | Meaning |
|-----------|--------|---------|
| acknowledge | `ack` | acknowledgement |
| address | `addr` | address |
| arbiter | `arb` | arbiter |
| check | `chk` | check (e.g. CRC) |
| clock | `clk` | clock |
| clear | `clr` | clear |
| configuration | `cfg` | configuration |
| control | `ctrl` | control |
| count | `cnt` | counter |
| current | `cur` | current value |
| data in | `din` | data input |
| data out | `dout` | data output |
| decode | `dec` | decode |
| delay | `dly` | delay |
| disable | `dis` | disable |
| error | `err` | error |
| enable | `en` | enable |
| frame | `frm` | frame |
| generate | `gen` | generate (e.g. CRC) |
| grant | `gnt` | grant |
| increase | `inc` | increment |
| interrupt | `intr` | interrupt |
| length | `len` | length |
| memory | `mem` | memory |
| output | `out` | output |
| priority | `pri` | priority |
| pointer | `ptr` | pointer |
| read | `rd` | read |
| read enable | `ren` | read enable |
| ready | `rdy` | ready |
| receive | `rx` | receive |
| register | `reg` | register |
| request | `req` | request |
| reset | `rst` | reset |
| segment | `seg` | segment |
| source | `src` | source |
| timer | `tmr` | timer |
| temporary | `tmp` | temporary |
| transmit | `tx` | transmit |
| valid | `vld` | valid |
| write | `wr` | write |
| write enable | `wen` | write enable |

### 2.4 Standard suffixes

| Role | Suffix | Example |
|------|--------|---------|
| active-low | `_n` | `rst_n`, `cs_n` |
| clock | `_clk` | `axi_clk`, `pixel_clk` |
| enable | `_en` | `wr_en`, `dat_en` |
| disable | `_dis` | `intr_dis` |
| select | `_sel` | `mux_sel` |
| flag | `_flg` | `done_flg` |
| delay (registered version) | `_dly` | `req_dly` |
| receive direction | `_rx` | `uart_rx` |
| transmit direction | `_tx` | `uart_tx` |
| async-domain first sync stage | `_asyn` | `req_asyn` (see §15) |

### 2.5 Parameters and macros

- Parameters: `UPPER_SNAKE_CASE` — `DATA_WIDTH`, `FIFO_DEPTH`,
  `ADDR_BITS`.
- Localparams: same style — `IDLE`, `MAX_BURST`. (FSM state names are
  localparams or enum members; same convention.)
- Macros: `UPPER_SNAKE_CASE`, all caps. Macros with arguments wrap each
  argument in parentheses inside the body to avoid precedence bugs:

  ```systemverilog
  `define BYTE_IDX(x)  (((x)+1)*(8)-1):((x)*(8))
  ```

- Reserved simulation-only macros (these must never be defined for
  synthesis):
  - `SIMULATION` — generic sim-only switch
  - `BEHAVIORAL` — behavioral model
  - `FAST_SIM` — fast-simulation alternative model

  Use these to gate `$display`, `$monitor`, and any debug-only logic in
  RTL files (see §17).

## 3. Module declaration

Use ANSI-style port declaration: direction and type written inside the
port list (a Verilog-2001 feature inherited by SystemVerilog). The
older non-ANSI style — port names in the list, types declared
separately in the body — is forbidden.

```systemverilog
module module_example #(
    parameter int DATA_WIDTH = 32,    // overridable from instantiation
    parameter int ADDR_WIDTH = 20
) (
    input  logic                       clk,         // 500 MHz
    input  logic                       rst_n,       // sync, active low
    input  logic [DATA_WIDTH-1:0]      xx2yy_din,   // data in from xx
    input  logic [ADDR_WIDTH-1:0]      xx2yy_addr,  // address
    output logic [DATA_WIDTH-1:0]      xx2yy_dout0, // data out to yy
    output logic [DATA_WIDTH-1:0]      xx2zz_dout1  // data out to zz
);

    localparam int LCDW = 32;          // internal, not overridable

    // ... module body ...

endmodule
```

Rules:

- **Constants get parameter or localparam.** Don't bury magic numbers in
  the body. Anything an instantiator might want to override is a
  `parameter`. Anything internal-only is a `localparam`.
- **Group ports** by direction (all `input`, then all `output`) or by
  function (all clocks/resets, then per-interface). Pick one style per
  module and stick with it.
- **Registered outputs are still declared `output logic`** — `logic` works
  in both contexts in SystemVerilog. (In Verilog-2001 you'd write
  `output reg`; in SV the `reg`/`wire` distinction is obsolete.)
- **`inout` is permitted only at the chip top level and in IO modules.**
  Don't use `inout` in internal modules — it makes verification much
  harder and Vivado's FPGA fabric doesn't have internal tri-states anyway.

## 4. Module instantiation

```systemverilog
module_xx #(
    .DATA_WIDTH (64),
    .ADDR_WIDTH (20)
) u_module_xx (
    .clk        (clk),
    .rst_n      (rst_n),
    .xx2yy_din  (xx2yy_din),
    .xx2yy_addr (xx2yy_addr),
    .xx2yy_dout (xx2yy_dout)
);
```

Rules:

- **Instance name prefix `u_`** (or `u0_`, `u1_`, ... for multiple
  instances of the same module). The prefix marks instances apart from
  variables in tool reports and waveforms.
- **Use named port mapping** (`.port (signal)`). Positional mapping is
  forbidden — when someone reorders the port list later, positional
  instantiations break silently.
- **Don't rename ports at the boundary.** When the connecting signal
  exists, use the same name as the port. This makes hierarchical search
  trivial: grep `xx2yy_addr` and find every place it's used.
- **All ports must be listed**, even if unconnected. Unused outputs are
  shown explicitly with empty parentheses:

  ```systemverilog
  module_xx u_module_xx (
      .clk         (clk),
      .rst_n       (rst_n),
      .xx2yy_dout0 (xx2yy_dout),  // used
      .xx2yy_dout1 (),            // intentionally unconnected
      .xx2yy_dout2 ()             // intentionally unconnected
  );
  ```

  Inputs MUST be connected — leaving an input unconnected is a synthesis
  bug.

- **No expressions in port connections.** Wrong:
  `.eg_ctrl (eg_ctrl & eg_en)`. Right: assign the expression to an
  intermediate signal first, then connect. Expressions in port maps
  create implicit glue logic at module boundaries, which complicates
  debug and prevents clean module hardening.
- **Don't pass parameters to externally hardened modules or IPs.** A
  hardened block's parameters are baked in; overriding them at the
  instance has no effect and creates inconsistency between the
  instantiation and the actual netlist.

## 5. Comments

- Comment every parameter and every port at declaration. Inline (same line)
  is preferred; if the comment is too long, put it on the line above.
- Use `//` for both single- and multi-line comments. Don't use `/* */` —
  it's easy to delete a `*/` accidentally and silently extend the comment
  past where you intended.
- Document important variables, instantiations, and FSM states with
  functional comments — what does this signal mean, what does this
  instance do.
- Document any synthesis directive (e.g., synthesis pragmas) at the point
  of use, with a note explaining why and which tool it targets. Same for
  compiler directives like `` `ifdef ``/`` `else ``/`` `endif `` —
  comment what the switch does and where it's expected to be defined.

## 6. Formatting

- **Indent with 4 spaces.** No tabs (different editors render tabs at
  different widths, breaking alignment).
- **Lines ≤120 characters.** Wrap longer lines logically.
- **Align signal declarations** in port lists and internal declarations:
  put the type, name, and trailing comment in vertically-aligned columns.
- **Align instantiation port maps** the same way.
- **Files ≤2000 lines.** A file beyond that almost always wants to be
  split into smaller modules.
- **One declaration per line.** Wrong: `logic [7:0] sig1, sig2, sig3;`.
  Right:

  ```systemverilog
  logic [7:0] sig1;
  logic [7:0] sig2;
  logic [7:0] sig3;
  ```

  Per-line declarations make diffs cleaner and let each signal carry its
  own comment.

## 7. Always block discipline

SystemVerilog provides three procedural blocks. Use exactly two of them:

- **`always_ff @(posedge clk)`** for sequential logic.
  Use non-blocking assignment (`<=`).
- **`always_comb`** for combinational logic. Use blocking assignment
  (`=`).
- **`always_latch` is forbidden.** If you need latch behavior, instantiate
  a vendor latch primitive explicitly and document why. The
  `always_latch` form makes accidental latches look intentional, which
  is exactly the wrong default.

Bare `always @(...)` is also forbidden. Always use the role-specific form
so the synthesis tool can catch mistakes (`always_ff` errors on
combinational drives; `always_comb` errors on incomplete sensitivity).

### Sequential blocks (`always_ff`)

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n) begin
        dat_r <= '0;
    end else if (din_vld) begin
        dat_r <= din;
    end
end
```

Rules:

- Non-blocking (`<=`) only.
- One register per `always_ff` block (or a small group of related
  registers — see below). Don't mix unrelated registers in the same
  block; it tangles the dependencies and prevents useful synthesis
  optimizations.
- **A given register is assigned in only one `always_ff` block.** Multiple
  drivers create undefined behavior in simulation and a multi-driver net
  in synthesis.
- **Use conditional assignment** (`if`/`else if`) for enabled flops, not
  unconditional reassignment. The conditional form lets the synthesis
  tool infer a clock gate and save dynamic power:

  ```systemverilog
  // Good — synth can insert clock gate
  always_ff @(posedge clk) begin
      if (!rst_n)         dat_r <= '0;
      else if (din_vld)   dat_r <= din;
  end

  // Bad — no enable, no gate possible
  always_ff @(posedge clk) begin
      if (!rst_n)         dat_r <= '0;
      else                dat_r <= din;  // always loads, even when !din_vld
  end
  ```

- **Don't assign self-to-self in `else`.** Wrong:

  ```systemverilog
  if      (!rst_n) dat_r <= '0;
  else if (cond)   dat_r <= data_a;
  else             dat_r <= dat_r;       // unnecessary; flop already holds
  ```

  An `always_ff` block omitting the else for a register naturally holds
  the previous value. The explicit self-assignment adds noise and
  defeats clock-gating inference on some tools.

- **Sequential `if` chains: use `else if`, not consecutive bare `if`s.**
  Wrong:

  ```systemverilog
  if (!rst_n) dat_r <= '0;
  if (sel0)   dat_r <= in0;       // each `if` overwrites the prior
  if (sel1)   dat_r <= in1;       // synth produces a priority chain
  if (sel2)   dat_r <= in2;       // intent unclear
  ```

  Right:

  ```systemverilog
  if      (!rst_n) dat_r <= '0;
  else if (sel0)   dat_r <= in0;
  else if (sel1)   dat_r <= in1;
  else if (sel2)   dat_r <= in2;
  ```

- **All variables in a multi-variable `always_ff` need a reset.** When
  several registers share a block, every one of them must have a reset
  branch — otherwise the reset signal can leak into the unreset
  register's clock-gate enable and produce surprising behavior.

### Combinational blocks (`always_comb`)

```systemverilog
always_comb begin
    next_state = state;          // default: hold
    out_valid  = 1'b0;           // default: inactive
    out_data   = '0;             // default: zero
    case (state)
        ACTIVE: begin
            out_valid = 1'b1;
            out_data  = computed;
            if (done) next_state = IDLE;
        end
        // ... other states ...
        default: next_state = IDLE;
    endcase
end
```

Rules:

- Blocking (`=`) only.
- **Default at top of block.** Assign every signal a default value at the
  top of the block, then write the case/if to override. This style makes
  it impossible to accidentally infer a latch and produces clean,
  reviewable code.
- **`if` without `else` is fine** if the signal has a default at the top.
  Otherwise, every `if` needs a matching `else`.
- **Every `case` either covers all values or has a `default`.** Always
  include `default` in case statements to handle unreachable encodings
  (which can occur due to X-propagation or glitch transitions in
  hardware).
- **No combinational feedback loops.** A signal cannot depend on its own
  current value in `always_comb` — that creates a 0-delay loop.
  Exception: process-monitor or test-only loops, which must be guarded
  by `` `ifdef SIMULATION `` and include a `#delay` to prevent the
  simulator from hanging.
- **No latches with constant inputs.** Wrong: `if (cond) test_d = 1'b1;`
  with no else and no default. This both infers a latch and gives it a
  meaningless input.

## 8. Reset

**Default convention: synchronous, active-low reset (`rst_n`).** Every
reset port and signal in the project follows this unless explicitly
overridden. The reset signal is sampled on the rising clock edge —
`rst_n` does not appear in the sensitivity list.

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n) dat_r <= '0;
    else        dat_r <= dat_in;
end
```

Rules:

- **Sync low-active is the default.** If a different style is required
  (async reset, active-high), it must be documented in the design spec
  and applied consistently across the module. Synchronous reset matches
  Xilinx 7-series and later FPGA fabric preferences (better timing
  closure on reset deassertion, no risk of recovery/removal violations
  feeding back into the clock tree).
- **Reset is sampled, not edge-triggered.** Therefore `rst_n` does not
  appear in the `always_ff` sensitivity list. Wrong:
  `always_ff @(posedge clk or negedge rst_n)` — that's the async form.
  Right: `always_ff @(posedge clk)` with `if (!rst_n)` inside.
- **Reset polarity in `if` must match the signal's polarity.** Wrong:
  `if (rst_n) ...` for an active-low reset. Right: `if (!rst_n) ...`.
- **Reset must be held for at least one full clock period** to guarantee
  the rising edge sees `rst_n` low. This matters for testbenches and
  for any externally-driven reset.
- **Reset structure should be simple.** Internal resets are generated in
  a single dedicated reset module, not scattered across the design.
- **No combinational logic on reset paths.** A reset that goes through
  AND/OR gates can glitch, leading to spurious resets. If you need to
  combine reset sources, do it in the dedicated reset module with
  explicit synchronization.
- **No mixing different reset signals in the same combinational
  expression.** Different resets have different timing assumptions and
  shouldn't be ORed/ANDed together.
- **CDC of reset requires synchronization.** When a reset crosses clock
  domains, run it through a reset synchronizer in the destination
  domain so the deassertion edge aligns with the destination clock.
- **One reset per `always_ff` block.** If two resets must combine, do
  that in a dedicated module first.
- **Reset values must be constants.** Wrong: `dat_r <= data_init;` where
  `data_init` is a variable. Reset must produce a known, constant state.
- **Combinational logic doesn't get reset.** Reset is for state
  elements. Wrong:

  ```systemverilog
  always_comb begin
      if (!rst_n)  test_d = 8'd0;     // pointless — comb has no state
      else if (...)
          ...
  end
  ```

- **Reset `if` is followed by `else`, not another `if`.** Wrong:

  ```systemverilog
  always_ff @(...) begin
      if (!rst_n) test_d <= 1'b0;
      if (clr)    test_d <= 1'b0;   // bare 'if', creates priority chain
      else if (vld) test_d <= datin;
  end
  ```

  Right: `else if (clr) ...`.

## 9. Clocking

- **Internal clocks live in a dedicated clock-generation module.** Don't
  scatter clock derivation across the design.
- **Each module receives its clock through a port.** A module shouldn't
  derive its own clock from internal logic. The exception is using a
  vendor clock-gate primitive (e.g. `BUFGCE`) inside the module.
- **No combinational logic generating clocks.** Wrong:
  `clk2 = clk1 & a;`. Combinational clocks glitch and produce timing
  closure nightmares. Use a clock gate primitive instead.
- **Use `posedge` triggering by default.** `negedge` is permitted only
  with explicit spec documentation (and corresponding constraints). One
  legitimate use: when crossing a power domain, the source can clock
  out on `negedge` and the destination samples on `posedge` — but this
  needs the spec entry.
- **A clock signal connects only to clock pins.** Wrong:
  `test_r <= clk;`. The clock is for clocking, not for sampling.
- **Don't tie a clock pin to a constant.** Wrong: `.CP (1'b0)` on a flop
  instance.
- **One clock per `always_ff` block.** Wrong:
  `always_ff @(posedge clk1 or posedge clk2)`.
- **Manually inserted clock gates** must be documented in the spec —
  they affect the clock tree synthesis plan.

## 10. FSM coding

Use a two-process style: one combinational block for next-state and
outputs, one sequential block for the state register. State is a
SystemVerilog `typedef enum`, not a raw `localparam`. The enum form lets
waveform viewers display the symbolic name and lets synthesis pick a
sensible encoding.

```systemverilog
typedef enum logic [2:0] {
    ST_IDLE    = 3'b001,
    ST_PROCESS = 3'b010,
    ST_END     = 3'b100
} state_e;

state_e cur_state, nxt_state;

// Sequential: state register
always_ff @(posedge clk) begin
    if (!rst_n) cur_state <= ST_IDLE;
    else        cur_state <= nxt_state;
end

// Combinational: next state and outputs
always_comb begin
    nxt_state = cur_state;            // default: hold
    case (cur_state)
        ST_IDLE: begin
            if (start) nxt_state = ST_PROCESS;
        end
        ST_PROCESS: nxt_state = ST_END;
        ST_END:     nxt_state = ST_IDLE;
        default:    nxt_state = ST_IDLE;
    endcase
end
```

Rules:

- **Two-process style** (separate sequential and combinational blocks)
  for state transitions and outputs. A single block mixing both is
  harder to read and error-prone.
- **Default state required.** The `default` arm catches X-propagation
  and unreachable encodings, which is especially important with
  one-hot encoding where invalid states can occur from glitches.
- **`typedef enum` for states.** The explicit value assignments
  (e.g. `3'b001`, `3'b010`, `3'b100`) request one-hot encoding for
  complex FSMs. For simpler FSMs, omit the values and let the synthesis
  tool choose:

  ```systemverilog
  typedef enum logic [1:0] { IDLE, BUSY, DONE } state_e;
  ```

- **At most ~40 states** per FSM. Beyond that, refactor into multiple
  cooperating FSMs.
- **Separate FSM logic from non-FSM logic.** When an FSM coexists with
  unrelated combinational logic in the same module, split them into
  separate `always_comb` blocks at minimum, ideally separate submodules.
  This lets the synthesis tool optimize the FSM independently.

## 11. Expressions and types

### Types

- **Use `logic` as the universal default.** SystemVerilog's `logic`
  works in both `wire` and `reg` contexts. Avoid bare `wire` and `reg`
  unless you specifically need their semantics (`wire` for multi-driver
  buses, which should be rare in RTL).
- **Use `int` (or `int unsigned`) for loop counters and array indices**
  in elaboration-time code (generate loops, parameter calculations).
- **Use `genvar` for generate-loop variables.**
- **All signals must be declared explicitly.** Implicit `wire`
  declaration (a signal first used without declaration becomes a 1-bit
  wire) silently truncates multi-bit values. Vivado's `default_nettype
  none` mode catches this; turning it on at the file top is a safe
  habit:

  ```systemverilog
  `default_nettype none
  module foo (...);
      // ... module body ...
  endmodule
  `default_nettype wire   // restore for files that follow
  ```

- **Don't initialize signals in the declaration.** Wrong: `logic temp = 1;`.
  Reset values come through reset logic in `always_ff`, not declarations.

### Bit widths

- **Match operand widths in comparisons and arithmetic.** Mismatched
  widths trigger implicit zero/sign extension that can hide bugs.
- **Specify width and base for constants.** Wrong: `5`. Right: `4'd5`,
  `8'h2A`, `16'b1010_1010_0000_1111`.
- **Use `$clog2` for derived widths.** Wrong: hard-coded `3` for the
  width of an 8-deep counter. Right: `$clog2(DEPTH)`.
- **Don't mix signed and unsigned in one operation.** If you need
  to, use `$signed()` or `$unsigned()` casts to make the conversion
  explicit at the boundary.

### Memories (arrays of vectors)

```systemverilog
logic [DATA_WIDTH-1:0] mem_array [0:DEPTH-1];
```

Bus dimension descending (`[N-1:0]`), depth dimension ascending
(`[0:M-1]`). The depth-ascending convention matters for verification:
when initializing memory from a text file, line 1 maps to `mem_array[0]`,
which is the natural reading order.

### Conditionals

- **No expressions in `if` conditions.** Wrong: `if (a-1 == b)`. Compute
  the expression separately and use the named result.
- **Wrap complex Boolean expressions with parentheses.** A long chain
  like `if (&a==1'b1 && !flag==1'b1 || b==1'b1)` is ambiguous to
  readers. Parens force clarity:
  `if (((&a == 1'b1) && (!flag == 1'b1)) || (b == 1'b1))`.
- **Simplify long `||` chains by grouping.** Wrong:
  `if (a||b||c||d||e||f||g||h)`. Right:

  ```systemverilog
  assign a_grp1 = a || b || c || d;
  assign a_grp2 = e || f || g || h;
  assign a_grp3 = a_grp1 || a_grp2;
  if (a_grp3) ...
  ```

  This isn't (just) cosmetic — coverage tools record per-term coverage,
  and breaking long chains makes the gaps visible.

- **Conditions must be reachable.** Wrong: `if (P1 < P2)` where both are
  parameters and `P1 >= P2`. Dead branches indicate a bug or stale code.
- **No `X` or `Z` in comparisons.** Wrong: `if (in == 1'bx)`. The `==`
  operator on `x`/`z` returns `x`, which is rarely what's intended.
  (And `===`/`!==` are forbidden in synthesis — see §17.)
- **No `?` as a constant match.** Wrong: `if (A == 4'b1???)`. Don't use
  this style; if bit-match logic is needed, write the mask explicitly:
  `if ((A & 4'b1000) == 4'b1000)`.

### Indexing and selects

- **Don't use expressions to index arrays.** Wrong:
  `mux_d = array[idx + 1]`. Compute the index separately:

  ```systemverilog
  assign idx_plus = idx + 1;
  assign mux_d    = array[idx_plus];
  ```

  Inline index arithmetic creates bus-select hardware that's hard to
  optimize and confusing to debug.

### Other

- **Use logical reduction, not negation, for "is bus zero".** Wrong:
  `s = !r;` where `r` is multi-bit (the result depends on bit 0 only,
  which is rarely intended). Right: `s = (r == '0);` or `s = ~(|r);`.
- **No multi-bit edge triggers.** Wrong: `always_ff @(posedge bus)`.
  Edge sensitivity applies to single-bit signals only.
- **Don't put multiple statements on one line.** Wrong:
  `assign a = b+1; assign c = d; assign dout = a&e;`.
- **Extract common subexpressions** when used multiple times. Easier to
  read, and lets synthesis share the hardware. Wrong:

  ```systemverilog
  assign x = a + b + c;
  assign y = d + a + b;
  ```

  Right:

  ```systemverilog
  assign sum_ab = a + b;
  assign x = sum_ab + c;
  assign y = d + sum_ab;
  ```

- **Decode tables should cover the full input space.** When using
  `assign match[i] = ...` style decoders, the last entry should be
  written to absorb the "everything else" case rather than as a precise
  range — this both simplifies the logic and adds fault tolerance.

## 12. case statements

- **`casex` is forbidden.** Its handling of don't-care is unsafe:
  unintended `x` values in the input match arbitrary patterns and cause
  silent wrong behavior. There is no acceptable use in synthesis.
- **`casez` is discouraged.** Same reasons, slightly less severe.
  Prefer explicit comparison with masks if "don't care" matching is
  truly needed.
- **`default` is on the last line.** Always include it.
- **`case` selectors and labels should be constants.** Wrong: a label
  like `c+d` (an expression).
- **Don't use a constant case-selector** (like `case (1)` to switch on
  whichever input is set). It works, but produces a priority encoder
  that's confusing in waveforms; an explicit `if`/`else if` chain reads
  better.
- **`default` can collapse multiple branches** to improve coverage. If
  six of eight cases produce the same output, write the unique two
  explicitly and put the common output in `default`:

  ```systemverilog
  // Better — clearer intent, better coverage report
  case (cond)
      3'b000: dout = 1'b0;
      3'b001: dout = 1'b0;
      3'b010: dout = 1'b0;
      3'b100: dout = 1'b0;
      default: dout = 1'b1;
  endcase
  ```

- **Use `case` instead of nested `if`/`else if`** when there's no
  priority requirement. The case form is clearer and usually generates
  better hardware.

## 13. for loops

`for` loops in RTL are unrolled at elaboration time. They must therefore
have bounds the elaborator can compute at static time.

- **Initial value must be constant.** Wrong: `for (i = a; i < 10; ...)`
  where `a` is a runtime signal.
- **Bound must be constant.** Wrong: `for (i = 0; i != a; ...)`.
- **Step must be constant.** Wrong: `for (r = 0; r < 10; r[2:0] = r+1)`
  (variable-bit step).
- **Don't modify the loop index in the body.** Wrong:
  `for (i = 0; i < 8; i = i+1) begin i = i + 2; ... end`.
- **Use `genvar` for generate loops**, `int` (or similar) for
  always-block iteration loops.
- **Generate blocks must be named.** `for (genvar i = 0; ...) begin :
  g_bit ... end`. The name is required for hierarchical paths,
  constraint targets, and tool-stable instance names.

## 14. Functions

Functions in RTL describe combinational logic only.

- **No non-blocking assignment** in a function. NBA semantics require a
  time step; functions are zero-time.
- **No `assign`** inside a function — use direct assignments to the
  function output.
- **No sequential logic** (no `always_ff`, no `@(...)`).
- **All inputs and locals declared inside the function.** Don't refer
  to variables from the enclosing module — that creates implicit
  dependencies invisible at the call site.
- **Every output bit must be assigned** on every path. Wrong:

  ```systemverilog
  function logic [15:0] f_val (input logic [7:0] inp);
      f_val[7:0] = inp;            // upper 8 bits never written
  endfunction
  ```

- **Conditional assignment must cover all paths.** Wrong: a function
  with `if (sel) func = 1'b0;` and no `else`. Right: include the `else`.
- **Use `function automatic`** in SystemVerilog. The `automatic` keyword
  prevents accidental sharing of locals across simultaneous calls,
  which can occur with `task`-style state. (Recall: `task` is forbidden
  in modules — see §17 — but functions are fine.)

## 15. Clock-domain crossing

CDC is the easiest place to introduce bugs that simulate fine and fail
in hardware. Treat every async crossing as a deliberate design decision,
and document each CDC point in the design spec — separate section, with
a block diagram and a waveform showing the expected relationship.

The common CDC patterns each have a standard implementation:

- Single-bit level synchronizer (2-FF synchronizer)
- Reset synchronizer (async-assert, sync-deassert)
- Pulse synchronizer (cross a single-cycle pulse)
- Async FIFO (multi-bit data with full/empty handshake)
- Clock multiplexer (glitch-free clock switching)

### 15.1 Single-bit control signals

Two-flop synchronizer at minimum:

```
  clk_a domain               clk_b domain
  ┌────┐                  ┌────┐    ┌────┐
  │ FF │── d_a ────┬────► │ FF │ ──►│ FF │── d_b ──►
  └────┘           │      └────┘    └────┘
   ▲               │       ▲          ▲
   │               │       │          │
  clk_a            │      clk_b      clk_b
                                       (d_b1_asyn)  (d_b2)
```

Naming convention: the first flop in the destination domain has suffix
`_asyn` (or `_async`). This both signals "this flop captures
metastability" to readers and makes constraint-writing easier
(false-path or set_max_delay can target the `*_asyn` register
specifically).

The 2-FF synchronizer eliminates metastability propagation but does
**not** guarantee correct value transmission. The source must hold
the value long enough for the destination to sample it cleanly.

### 15.2 Multi-bit data signals

Multi-bit signals can change non-atomically — different bits cross at
different cycles, leaving the destination momentarily reading garbage.
Three valid approaches:

1. **Sample-when-stable handshake.** Source asserts a "valid" toggle,
   destination synchronizes the toggle, then samples the data. The
   source must not change the data until the handshake completes.
2. **Gray-coded counter.** A counter encoded in Gray code changes one
   bit at a time, so a sample at any moment is at most one count off
   — bounded and acceptable for pointer crossings (e.g. async FIFO
   pointers).
3. **Async FIFO.** Use the library async FIFO. Don't compose multiple
   narrower async FIFOs into a wider one — the data on each FIFO
   crosses with independent timing and reassembly produces garbage.

### 15.3 Other CDC rules

- **No combinational output to a CDC.** The signal crossing must come
  directly from a flop in the source domain. A combinational output
  can glitch, and the destination flop will sample the glitch.
- **Time-aligned operations happen before the CDC.** If two signals
  must align in the destination domain, combine them in the source
  domain and cross the combined result. Crossing them separately and
  recombining post-crossing produces misaligned signals.
- **Async FIFO reset must reach both clock domains.** A common bug is
  software-resetting only one side, leaving the other side's pointers
  out of sync. Both read and write domains must reset together.

## 16. Module partitioning

- **One clock domain per module.** When a module needs to operate in
  multiple domains, split it into per-domain submodules.
- **CDC logic in its own module.** Putting all CDC at module
  boundaries makes it visible in the hierarchy and simplifies review.
- **Clock generation and reset generation in separate, dedicated
  modules.** No clock or reset derivation buried in random submodules.
- **Related combinational logic stays together.** Don't split a single
  logical computation across module boundaries — synthesis can't
  optimize across hierarchy as effectively, and time budgets get
  fragmented.
- **Top-level modules do wiring only — no glue logic.** The top
  instantiates submodules and connects them. It contains no `assign`
  statements (other than trivial pass-throughs), no `always` blocks.
  Glue logic at the top makes hardened block integration much harder.
- **Module outputs should be registered** when the module is large
  enough to be a hardening unit. This gives downstream consumers a
  clean timing boundary.
- **Critical-path logic separated from non-critical.** When a module
  contains both speed-critical and area-bounded logic, split them so
  synthesis can optimize each appropriately.
- **IO PAD logic in its own module** at the chip top level.
- **Module size bounded.** When targeting hardening, keep individual
  modules under ~1 million instances post-synthesis. For pure FPGA
  flows the bound is looser, but excessively large modules slow down
  synthesis turnaround.

## 17. Forbidden constructs

These constructs either don't synthesize, synthesize unpredictably, or
indicate a verification artifact that escaped into RTL. Code review
should treat any of these as a defect unless the file is clearly
labeled as a testbench or sim-only model.

### Not synthesizable
- `initial` blocks (exception: ROM/RAM initialization via `$readmemh`/
  `$readmemb`, with explicit user approval)
- `final` blocks
- `#delay` of any kind (`#5`, `#1ns`, `#(PERIOD)`)
- `force` / `release`
- `wait` statements
- `event` declarations
- `fork` / `join` / `join_any` / `join_none`
- `disable` statements
- `repeat`, `while`, `forever` loops
- `task` declarations in RTL modules
- `real`, `realtime`, `time`, `shortreal` types
- `$display`, `$monitor`, `$write`, `$strobe`, `$finish`, `$stop`
- `assert` / `assume` / `cover` outside guarded simulation-only blocks
- `===` and `!==` (case-equality with X/Z) — synthesis ignores the
  X/Z handling, so simulation and hardware diverge
- Hierarchical references (`top.sub.signal`)
- Direct division (`/`) or modulo (`%`) on non-constant variables —
  synthesis produces enormous, slow combinational logic; use a
  divider IP if needed
- Variable shift amounts in shift operators (`a << b` where `b` is a
  signal) — the synthesized barrel shifter is large; if width is
  small and known, this may be acceptable, but flag it
- Both edges of the same signal in a sensitivity list:
  `always @(posedge clk or negedge clk)`
- `assign` / `deassign` inside an `always` block
- Embedded EDA-tool commands in source code (e.g.,
  `// synopsys async_set_reset "rst"`). Exception: `translate_off` /
  `translate_on` to wrap simulation-only sections.
- Any `inout` port outside the chip top or IO modules
- Three-state buffers in chip internals (FPGA fabric doesn't have
  internal tri-states; use multiplexers)

### Sim-only constructs in RTL files

When sim-only logic must live in an RTL file (e.g., a checker for an
internal protocol), wrap it:

```systemverilog
`ifdef SIMULATION
    // checker that prints a $display on bad behavior
    always_ff @(posedge clk) begin    // sequential, not combinational —
                                      //   avoid glitches triggering false errors
        if (a_hit && b_hit)
            $display("Error: mem access conflict at %0t", $time);
    end
`endif
```

Two notes:

- The sim-side filelist defines `SIMULATION`; the synthesis filelist
  does not. (See §2.5 for the standard sim-only macros.)
- Use **sequential** triggering (`@(posedge clk)`) for checkers, not
  combinational (`always @(*)`). Combinational checkers can fire on
  glitches that don't actually occur in the synthesized hardware,
  producing false bugs.

### Constructs that aren't forbidden but warrant care

- `casez` — discouraged but not banned (`casex` is banned outright).
  Prefer explicit comparison with masks.
- Manually-instantiated clock gates — allowed but require spec
  documentation.
- Negative-edge flops — allowed only with documented justification
  (e.g., crossing a power domain).
