# Decision Log: stream_buf

DRAFT: rewrite each entry in your own words before submitting. Add entries as you go (OUT_REG, regressions, synthesis).

## D1. Synchronous active-low reset
- **Chosen:** sync reset, control state only (pointers, count, flags, error bits). Storage array is not reset.
- **Alternatives:** async reset; reset every storage word.
- **Why:** sync reset maps onto FPGA flops with no recovery/removal analysis and no reset synchronizer. Not resetting storage saves area and reset fan-out; stale data is never visible because `m_valid` is low when empty.
- **Cost:** reset must be held for at least one clock edge.

## D2. Flop/reg array storage
- **Chosen:** `reg` array, one write port, asynchronous read port.
- **Alternatives:** inferred block RAM (synchronous read).
- **Why:** gives first-word-fall-through output and 100% throughput with no extra latency or bypass logic. Block RAM would force a registered read.
- **Cost:** more flops at large DEPTH. Crossover to RAM is a scaling note in the write-up.

## D3. Separate pointers plus a count register
- **Chosen:** `wr_ptr`, `rd_ptr`, `cnt`. Full is `cnt == DEPTH`, empty is `cnt == 0`.
- **Alternatives:** wrap-bit pointers with `count` computed by subtraction.
- **Why:** `count` is a required output; a register avoids a subtractor on the output path and makes full/empty trivial.
- **Cost:** one extra counter (CNT_W flops) and an up/down update.

## D4. Non-power-of-2 DEPTH supported (DEPTH >= 2)
- **Chosen:** explicit wrap `ptr == DEPTH-1 ? 0 : ptr + 1`.
- **Alternatives:** restrict to powers of 2.
- **Why:** more general. For powers of 2 synthesis reduces it to a plain counter, so it is free there.
- **Cost:** a comparator in the pointer path for non-power-of-2 depths. Verified with DEPTH 5, 3, 2 (see regression results).

## D5. First-word-fall-through read side, latency 1
- **Chosen:** `m_data = mem[rd_ptr]`, `m_valid = (cnt != 0)`. A word written at edge N is readable after edge N.
- **Alternatives:** registered output (planned as OUT_REG=1).
- **Why:** lowest latency; `m_data` is stable under stall because `rd_ptr` only advances on a real transfer.
- **Cost:** critical path is `rd_ptr` to DEPTH:1 mux to `m_data`, which grows with DEPTH.

## D6. `s_ready` depends only on occupancy
- **Chosen:** `s_ready = ~full`, never a function of `m_ready`.
- **Alternatives:** `s_ready = ~full | m_ready` (accept a write when full if a read happens the same cycle).
- **Why:** avoids a combinational path from consumer to producer (timing and loop risk).
- **Cost:** when full, simultaneous read+write loses one cycle of throughput. Allowed by rule 1 (100% only when not full or empty). This is the corner case for the video.

## D7. Optional features
- **Chosen:** almost-full/almost-empty flags, sticky overflow/underflow warnings, OUT_REG option.
- **Alternatives:** packet mode, parity/ECC, CDC, width conversion.
- **Why:** small, well-verified features with measurable cost beat large untested ones. OUT_REG gives a real latency vs Fmax trade-off to measure.

## D8. Overflow/underflow are protocol-misuse warnings
- **Chosen:** `overflow` sets on `s_valid && full`, `underflow` on `m_ready && empty`. Sticky, cleared by `err_clr`. A new event in the same cycle as `err_clr` wins.
- **Alternatives:** flag only true AXI-Stream violations (valid dropped or data changed while stalled).
- **Why:** simple and cheap. AXI-Stream allows valid held while not ready, so these are warnings, not data-loss flags. Data is never corrupted because a rejected write is not a transfer.
- **Cost:** `overflow` sets during normal backpressure; the testbench models this on purpose.

## D9. Flags registered from `cnt_nxt`
- **Chosen:** `almost_full`/`almost_empty` are flops loaded from the next count value.
- **Alternatives:** combinational compare on `cnt`.
- **Why:** registered outputs for timing, and using `cnt_nxt` keeps them aligned with `count` (no one-cycle lag).
- **Cost:** two flops and two comparators. Assumes `AF_THRESH >= 1` because `almost_full` resets to 0.

## D10. `count` includes the output register word (for OUT_REG=1)
- **Chosen:** `count` is always the total words held; full is `count == DEPTH` in both modes.
- **Alternatives:** count only the core FIFO.
- **Why:** capacity and `count` mean the same thing in both modes.
- **Cost:** core usable depth is DEPTH-1 plus the register when OUT_REG=1.

## D11. File naming vs language
- **Chosen:** file named `stream_buf.sv` per the assignment layout, written in plain Verilog-2001 style (`reg`/`wire`, non-ANSI ports, own `clog2`, no `$clog2`).
- **Why:** assignment says Verilog-2001 but names a `.sv` file. Verified it compiles under Icarus 12 with `-Wall -g2001`.

## D12. Testbench architecture
- **Chosen:** reference model in the monitor (`wr_n`/`rd_n`, expected-data array); drive on negedge, sample on posedge; producer holds valid/data until accepted; random stall percentages plus directed tests.
- **Alternatives:** waveform-only inspection; per-test hand-checked expectations.
- **Why:** self-checking against an independent model catches loss, duplication and reordering without manual review.
- **Practical note:** waveform dump limited to top-level and DUT signals and stopped after the directed tests (`$dumpoff`), because EPWave truncated the full dump.
