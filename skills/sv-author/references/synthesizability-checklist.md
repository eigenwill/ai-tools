# Synthesizability and Convention Checklist

Run through this list before declaring an RTL module done. The items here
catch the mistakes that LLM-generated and human-generated HDL tends to make:
code that simulates correctly but fails synthesis, infers latches
accidentally, or behaves differently in hardware than in simulation.

This is a self-review pass, not a substitute for actually running synthesis
through vivado-runner — but catching these issues here saves a synthesis
round-trip.

The checklist is organized by topic. For each item, verify the file complies
or has a documented intentional violation.

## Headers and naming

- [ ] File has a header with filename, author, date, description, history.
- [ ] Filename matches module name exactly.
- [ ] Module name is `lower_snake_case`.
- [ ] All signal names are `lower_snake_case`, ≤30 characters.
- [ ] Multi-bit buses use descending range: `[N-1:0]`.
- [ ] Memory arrays use descending bus, ascending depth: `[W-1:0] mem [0:D-1]`.
- [ ] Active-low signals end in `_n` (`rst_n`, `cs_n`).
- [ ] Inter-module signals use `xx2yy_` prefix.
- [ ] First-stage CDC sync registers end in `_asyn`.
- [ ] Parameters and macros are `UPPER_SNAKE_CASE`.
- [ ] One declaration per line (no `logic [7:0] sig1, sig2;`).

## Module structure

- [ ] One module per file.
- [ ] Verilog-2001 ANSI port style: direction and type in the port list.
- [ ] Overridable constants are `parameter`; internal-only are `localparam`.
- [ ] All instantiations use named port mapping (`.port (signal)`).
- [ ] Instance names use `u_` (or `u0_`, `u1_`) prefix.
- [ ] All ports listed in instantiations, even unconnected outputs (use
      empty parens).
- [ ] No expressions in port connections at instantiation.
- [ ] No parameter overrides on hardened modules or vendor IPs.

## Constructs that don't synthesize

The file contains none of the following (outside of `` `ifdef SIMULATION ``
guarded blocks):

- [ ] `initial` blocks. Exception: ROM/RAM init via `$readmemh`/`$readmemb`
      with explicit user approval.
- [ ] `final` blocks.
- [ ] `#delay` of any kind (`#5`, `#1ns`, `#(PERIOD)`).
- [ ] `force` / `release`.
- [ ] `wait` statements.
- [ ] `event` declarations.
- [ ] `fork` / `join` / `join_any` / `join_none`.
- [ ] `disable` statements.
- [ ] `repeat`, `while`, `forever` loops.
- [ ] `task` declarations.
- [ ] `real`, `realtime`, `time`, `shortreal` types.
- [ ] `$display`, `$monitor`, `$write`, `$strobe`, `$finish`, `$stop`.
- [ ] `assert` / `assume` / `cover`.
- [ ] `===` or `!==` (case-equality with X/Z).
- [ ] Hierarchical references (`top.sub.signal`).
- [ ] `/` or `%` on non-constant variables.
- [ ] Variable shift amounts (flag for review; small known widths may be OK).
- [ ] Both edges of the same signal in a sensitivity list.
- [ ] `assign` or `deassign` inside an `always` block.
- [ ] Embedded EDA-tool pragmas, except `translate_off` / `translate_on`.
- [ ] `casex` statements.
- [ ] `casez` statements (discouraged, flag for review).

If any debug/sim logic needs to live in an RTL file, it must be wrapped:

```systemverilog
`ifdef SIMULATION
    always_ff @(posedge clk) begin   // sequential, not combinational
        if (a_hit && b_hit)
            $display("Error: conflict at %0t", $time);
    end
`endif
```

Combinational triggering of sim checkers (`always @(*)`) can fire on
glitches that don't represent real hardware behavior — always use a
clocked trigger.

## Procedural block discipline

- [ ] All sequential logic uses `always_ff @(posedge clk)`.
- [ ] All combinational logic uses `always_comb`.
- [ ] No bare `always @(...)` anywhere.
- [ ] No `always_latch` anywhere.
- [ ] Sequential blocks use non-blocking (`<=`) only.
- [ ] Combinational blocks use blocking (`=`) only.
- [ ] No mixed blocking/non-blocking in any block.
- [ ] Each register is assigned in exactly one `always_ff` block.
- [ ] Unrelated signals are not assigned in the same `always_ff`.

## Sequential logic specifics

- [ ] Reset uses `if (!rst_n)` (low-active polarity matches the signal).
- [ ] Reset values are constants, never variables.
- [ ] When multiple registers share an `always_ff`, every one of them has
      a reset value.
- [ ] One reset signal per `always_ff` block.
- [ ] Conditional assignment used to enable clock-gate inference (no
      unconditional `else` writing the same data each cycle).
- [ ] No self-to-self assignment in `else` branches.
- [ ] Sequential `if` chains use `else if`, not consecutive bare `if`s
      ("覆盖式赋值" antipattern).

## Combinational logic specifics

- [ ] Every signal driven in `always_comb` has a default at the top of
      the block, OR every `if` has a matching `else` and every `case`
      has all values covered.
- [ ] Every `case` has a `default` arm on the last line.
- [ ] No combinational feedback loops (signal depending on its own
      current value).
- [ ] No latches with constant inputs.

## Reset

- [ ] Reset is synchronous and active-low (project default).
- [ ] `rst_n` is checked inside `always_ff`, not in the sensitivity list.
- [ ] No combinational logic generates reset signals.
- [ ] No `if (!rst_n)` followed by another bare `if` (use `else if`).
- [ ] No reset on combinational logic (`always_comb` does not check
      `rst_n`).
- [ ] No mixing different reset signals in one expression.
- [ ] CDC reset goes through a reset synchronizer.

## Clocking

- [ ] Each module's clock comes through a port (no internal clock
      generation, except vendor clock-gate primitives).
- [ ] No combinational logic generates clocks.
- [ ] All flops triggered on `posedge` (negedge requires spec entry).
- [ ] One clock per `always_ff` block.
- [ ] Clock signals only connect to clock pins (never sampled as data,
      never assigned to data signals).
- [ ] No clock pin tied to a constant.

## FSM coding

- [ ] States declared as `typedef enum logic [N-1:0] {...} state_e`.
- [ ] Two-process style: separate sequential and combinational blocks.
- [ ] Default state assignment at top of `always_comb` (next_state =
      cur_state).
- [ ] `case` includes a `default` arm.
- [ ] FSM has ≤40 states.
- [ ] FSM logic separated from unrelated combinational logic (different
      `always_comb` blocks at minimum).

## Bit widths and types

- [ ] Operand widths match in comparisons and arithmetic.
- [ ] Constants have explicit width and base (`8'd5`, not `5`).
- [ ] Signed/unsigned not mixed without explicit cast.
- [ ] Derived widths use `$clog2()`.
- [ ] All signals declared explicitly (no implicit wires).
- [ ] No initialization in declarations (`logic temp = 1` is wrong).
- [ ] No `'X'` or `'Z'` in assignments or comparisons.
- [ ] Single driver per signal (tri-state allowed only at chip top/IO).

## Conditionals and expressions

- [ ] No expressions in `if` conditions (precompute and use the result).
- [ ] Complex Boolean expressions wrapped in parentheses for clarity.
- [ ] Long `||` or `&&` chains split into named intermediate signals.
- [ ] No always-false / always-true conditions (dead branches).
- [ ] No `?` as a constant match (`A == 4'b1???` is forbidden).
- [ ] Multi-bit "is zero" tests use `(r == '0)` or `~|r`, not `!r`.
- [ ] No multi-bit edge triggers.
- [ ] No expressions used to index arrays directly.
- [ ] No multiple statements per line.

## case statements

- [ ] `default` is on the last line.
- [ ] Case labels are constants, not expressions.
- [ ] No constant case selector (`case (1)`-style is unclear).
- [ ] Used in preference to nested `if`/`else if` when there's no
      priority requirement.

## for loops

- [ ] Initial value is constant.
- [ ] Bound is constant (no `i != a` where `a` is a signal).
- [ ] Step is constant (no variable-bit step).
- [ ] Loop index not modified inside the body.
- [ ] Loop variable is `int` (or `genvar` for generate loops).
- [ ] All generate blocks named (`begin : g_name`).

## Functions

- [ ] Declared `function automatic`.
- [ ] No non-blocking assignment.
- [ ] No `assign` statement.
- [ ] No sequential logic, no `@(...)`.
- [ ] All inputs and locals declared inside the function.
- [ ] All output bits assigned on every code path.
- [ ] Conditional assignments cover all paths (`if`/`else` complete).

## CDC

- [ ] Every async crossing uses a vetted synchronizer module from a
      common library (no inline 2-FF chains written by hand).
- [ ] First-stage sync register named with `_asyn` suffix.
- [ ] Multi-bit data uses gray code or async FIFO, not parallel
      sync flops.
- [ ] No combinational signals cross clock domains directly (always go
      through a flop in the source domain first).
- [ ] Time-aligned signals combined in source domain before crossing.
- [ ] No multiple async FIFOs concatenated to form a wider FIFO.
- [ ] Async FIFO reset reaches both clock domains.
- [ ] Each CDC point documented in the design spec.

## Module partitioning

- [ ] Each module operates in a single clock domain (CDC at the
      boundary, in dedicated synchronizer modules).
- [ ] Top-level module does instantiation and wiring only — no
      `always` blocks, no `assign` other than trivial pass-throughs.
- [ ] Module outputs are registered (recommended for hardening targets).
- [ ] No expression-based glue logic at the top level.

## When something is intentionally violated

Document it. A single-line comment next to the violation is enough:

```systemverilog
// Negedge flop intentional: crossing power domain (see spec §3.4)
always_ff @(negedge clk_pd_b) begin
    if (!rst_n) ...
    else        ...
end
```

This isn't busywork — six months later, the comment is what tells the
next reader (or Claude on a future turn) "yes, this is supposed to be
like that, don't 'fix' it."
