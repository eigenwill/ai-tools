# Testbench Template

Testbenches written by this skill are **self-checking** and emit
**machine-readable pass/fail markers**. The vivado-runner skill greps for
these markers to grade the simulation; a TB that runs cleanly without a
marker is graded `unknown`, which is treated as a failure of the testbench.

This file contains the standard skeleton plus guidance on the parts that
vary by DUT.

## Skeleton

Copy this skeleton, then replace the `<...>` placeholders. Every part is
present for a reason — see notes below the code.

```systemverilog
// =============================================================================
// <module>_tb.sv — testbench for <module>
// =============================================================================
`timescale 1ns/1ps

module <module>_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int  CLK_PERIOD_NS = 10;        // 100 MHz default
    localparam int  TIMEOUT_NS    = 1_000_000; // 1 ms; bump for long sims
    localparam int  RESET_CYCLES  = 5;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    // <other DUT ports — declare each at module-scope, drive from initial>

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    int errors    = 0;
    int checks    = 0;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    <module> dut (
        .clk   (clk),
        .rst_n (rst_n)
        // <other connections>
    );

    // -------------------------------------------------------------------------
    // Watchdog: kill the run before vivado-runner's wall-clock kills us.
    // Without this, a hung sim gets killed without a clean failure marker.
    // -------------------------------------------------------------------------
    initial begin
        #(TIMEOUT_NS);
        $display("TEST FAILED: watchdog timeout at %0t", $time);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Self-check task: compare actual to expected, increment errors on mismatch.
    // Use for every check rather than ad-hoc if/$display so the count is
    // accurate and the failure messages are uniform.
    // -------------------------------------------------------------------------
    task automatic check(input string label,
                         input logic [63:0] actual,
                         input logic [63:0] expected);
        checks++;
        if (actual !== expected) begin
            errors++;
            $display("CHECK FAILED [%s] at %0t: got 0x%0h, expected 0x%0h",
                     label, $time, actual, expected);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Initialize all DUT inputs to known values
        rst_n = 1'b0;
        // <other inputs = 0>

        // Hold reset for a few cycles
        repeat (RESET_CYCLES) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ----- Test cases -----
        // <stimulus + check() calls go here>

        // ----- Final verdict -----
        @(posedge clk);
        if (errors == 0) begin
            $display("TEST PASSED (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: %0d errors out of %0d checks", errors, checks);
        end
        $finish;
    end

endmodule
```

## Why each part is there

### `timescale`

Explicit `\`timescale 1ns/1ps` keeps simulation timing predictable across
files. xsim picks a default if none is set, and that default isn't
guaranteed to be the same across versions.

### Watchdog

vivado-runner enforces a wall-clock limit (default 1 hour). A testbench
that hangs without calling `$finish` gets killed by `timeout(1)` —
vivado-runner's diagnose-timeout logic will guess at the cause, but the
diagnosis is much weaker than a clean `TEST FAILED: watchdog timeout`
message from the TB itself.

Set `TIMEOUT_NS` to roughly 10× the expected legitimate runtime. Too tight
and you'll get false trips on slow stimulus; too loose and a true hang
wastes simulator time.

### `errors` counter and `check` task

The verdict at the end is decided by `errors == 0`, not by a human reading
output. This is the difference between a TB that's part of a regression
and one that requires expert review every time.

Using a single `check` task instead of ad-hoc `if (a !== b) $display(...)`
keeps the message format uniform (easier to grep) and ensures every
mismatch increments `errors`. The `===` / `!==` operators (case-equality)
treat X and Z as distinct values — for hardware checks that's almost
always what you want.

The `string label` argument is the test-step name. Use it; "CHECK FAILED
[reset_value]" tells you immediately where to look, "CHECK FAILED" alone
doesn't.

### Pass/fail markers

Print exactly one of:

- `TEST PASSED (<N> checks)` — clean run.
- `TEST FAILED: <N> errors out of <M> checks` — at least one mismatch.
- `TEST FAILED: watchdog timeout at <time>` — TB watchdog tripped.

vivado-runner recognizes any of `TEST PASSED`, `TEST_PASSED`, `SIMULATION
PASSED`, `ALL TESTS PASSED` for pass, and the equivalents for fail. Stick
with `TEST PASSED` / `TEST FAILED` for consistency.

### Reset sequence

Hold `rst_n` low for several cycles (default 5) before deasserting. The
project default is **synchronous, active-low** reset: the DUT samples
`rst_n` on the rising clock edge, so reset must be held across at least
one full clock period to take effect. Holding for several cycles costs
nothing and makes the reset behavior unambiguous in waveforms.

Deassert `rst_n` on a clock edge (`@(posedge clk)` then
`rst_n = 1'b1`) to avoid simulator race conditions where the
deassertion lands inside a setup window.

If the DUT uses a different reset style (async, active-high, etc.),
match the DUT — the default in this template is the project default,
not the only legal choice.

## Stimulus patterns

### Directed test

For modules with a small, well-defined behavior space (an adder, a small
FSM), enumerate the interesting cases by hand:

```systemverilog
// Test: add zero
a = 8'd0; b = 8'd0;
@(posedge clk);
check("zero_plus_zero", sum, 8'd0);

// Test: add with carry
a = 8'd255; b = 8'd1;
@(posedge clk);
check("overflow_to_zero", sum, 8'd0);
check("carry_out", cout, 1'b1);
```

### Random stimulus

For wider behaviors (ALUs, datapaths), constrained random with a reference
model:

```systemverilog
logic [31:0] a_rand, b_rand, expected;
for (int i = 0; i < 1000; i++) begin
    a_rand = $urandom();
    b_rand = $urandom();
    expected = a_rand + b_rand;     // reference model

    a = a_rand; b = b_rand;
    @(posedge clk);
    check($sformatf("rand_%0d", i), sum, expected);
end
```

`$urandom` is reproducible if you set a seed; SystemVerilog's `$urandom` is
seeded from the simulator command line. xsim accepts `-sv_seed <N>` —
record the seed in the log if reproducibility matters.

### Handshake / valid-ready

When the DUT uses a `valid`/`ready` handshake, drive `valid` high until
`ready` is sampled, then drop it:

```systemverilog
task automatic send(input logic [31:0] data);
    in_data  = data;
    in_valid = 1'b1;
    do begin
        @(posedge clk);
    end while (!in_ready);
    in_valid = 1'b0;
endtask
```

## Anti-patterns

- **Eyeball-checking.** A TB that runs to completion and dumps a waveform
  without printing pass/fail isn't a regression test. Even a one-shot
  exploration TB should print *something* the user can grep.
- **Forgetting the watchdog.** "It'll finish quickly" is famous last
  words. Add the watchdog every time.
- **Multi-line `$display` with the marker buried.** vivado-runner greps
  per line; "TEST PASSED" needs to be on its own line. Don't:
  `$display("Done. TEST PASSED. Have a nice day.");` — works for grep but
  hard to read in log. Just keep the marker on its own line.
- **Logging the marker conditionally inside a deeper if-block.** It's easy
  to put the verdict inside a branch that's never taken, leaving a clean
  run with no marker. Always print the verdict at the top level of the
  stimulus block, just before `$finish`.
- **`$stop` instead of `$finish`.** `$stop` returns to the simulator
  prompt; in batch mode this hangs. Always use `$finish`.

## Header for the TB file

Same standard header as RTL files, but the "Assumptions" section becomes
"Coverage" — a brief list of what the TB exercises. This helps the user
(and Claude on a later turn) understand at a glance what this TB does and
doesn't test.

```systemverilog
// =============================================================================
// adder_tb.sv — testbench for adder.sv
//
// Coverage:
//   - Reset values
//   - Zero + zero
//   - Maximum + 1 (overflow)
//   - 1000 random pairs vs reference model
//
// =============================================================================
```
