# Regression Results (OUT_REG=0 baseline)

Tool: EDA Playground, Icarus Verilog 12.0, compile options `-Wall -g2001`.
Testbench: `tb/testbench.sv` (same directed + random tests, only parameters changed).

| DEPTH | AF_THRESH | AE_THRESH | Wrap type | Result |
|-------|-----------|-----------|-----------|--------|
| 16 | 14 | 2 | power of 2 | TEST PASSED |
| 5  | 4  | 1 | non-power-of-2 | TEST PASSED |
| 3  | 2  | 1 | non-power-of-2 | TEST PASSED |
| 2  | 1  | 0 | minimum depth | TEST PASSED |

Notes:
- Transfer counts at the end differ per run because they are counted after the mid-run reset, with different random streams; they are not a comparison metric.
- Non-power-of-2 depths exercise the `ptr == DEPTH-1` wrap branch.
- DEPTH=2 is the minimum supported depth (documented assumption: DEPTH >= 2).
- AF_THRESH must be >= 1 (documented assumption: `almost_full` resets to 0).
