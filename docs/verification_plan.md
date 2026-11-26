# stream_buf Verification Plan

## Scope
DUT: `stream_buf` (OUT_REG=0 baseline). Testbench: `testbench.sv` (self-checking, Verilog-2001, Icarus).

## Method
- Cycle-accurate reference model in the monitor: `wr_n`/`rd_n` counters plus an expected-data array.
- Stimulus changes on negedge, DUT outputs sampled on posedge; compare first, then update the model.
- Producer holds `s_valid`/`s_data` until accepted (AXI-Stream rule). Consumer `m_ready` is random per percentage.
- Pass criterion: `TEST PASSED` printed, zero errors.

## Checks (always on)
| ID | Rule | Check |
|----|------|-------|
| C1 | Occupancy | `count == wr_n - rd_n` |
| C2 | Full | `s_ready == (occ != DEPTH)` |
| C3 | Empty | `m_valid == (occ != 0)` |
| C4 | No loss/dup/reorder | `m_data == expected[rd_n]` whenever occ != 0 |
| C5 | Stability | if `m_valid && !m_ready`, next cycle `m_valid` stays 1 and `m_data` unchanged |
| C6 | Flags | `almost_full == (occ >= AF_THRESH)`, `almost_empty == (occ <= AE_THRESH)` |
| C7 | Sticky errors | `overflow` set by `s_valid && full`, `underflow` by `m_ready && empty`, cleared by `err_clr`; a new event in the clear cycle wins |

## Directed and random tests
| ID | Scenario | Purpose |
|----|----------|---------|
| T1 | Reset, idle | Reset values: count 0, empty, flags |
| T2 | Fill, no consumer | Full, backpressure, overflow warning |
| T3 | Pulse `err_clr` | Overflow clears |
| T4 | Drain, no producer | Empty, underflow warning |
| T5 | Pulse `err_clr` while idle | Underflow clears and stays clear |
| T6 | Both sides 100% at mid occupancy | Simultaneous read+write, 100% throughput (300 transfers in 300 cycles) |
| T7 | Random stalls, 8 producer/consumer mixes x 2000 cycles | Data integrity, flags, count under traffic |
| T8 | Reset mid-traffic | Clean recovery |
| T9 | Final drain | Ends empty |

## Known behavior (not bugs)
- `overflow` sets whenever valid is held while full (normal backpressure). It is a warning.
- When full, a simultaneous write+read does not write (`s_ready` ignores `m_ready`).

## Parameter regression
Rerun with: DEPTH=16 (AF 14, AE 2), DEPTH=5 (AF 4, AE 1), DEPTH=2 (AF 1, AE 0), DEPTH=3 (AF 2, AE 1). Non-power-of-2 depths exercise pointer wrap.

## Extension ideas
- Add OUT_REG=1 and rerun everything (latency 2, same checks).
- Add functional coverage counters (full hit, empty hit, simultaneous r/w at full-1 and 1).
- Add an assertion-style check that `s_ready` never depends combinationally on `m_ready`.
