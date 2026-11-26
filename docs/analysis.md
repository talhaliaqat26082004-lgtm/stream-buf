# stream_buf: Analysis (one page)

## 1. Architecture summary
Single clock, synchronous active-low reset. Storage is a flop array (one write port, one asynchronous read port) with `wr_ptr`, `rd_ptr` and one total-occupancy register `cnt`. `s_ready = (cnt != DEPTH)` and never depends on `m_ready`. Registered `almost_full`/`almost_empty` flags are loaded from `cnt_nxt`, and sticky `overflow`/`underflow` warnings are cleared by `err_clr`. DEPTH >= 2, non-power-of-2 supported. `OUT_REG` selects the read side:

| | OUT_REG=0 | OUT_REG=1 |
|---|---|---|
| Read side | first-word-fall-through, `m_data = mem[rd_ptr]` | one-word output register |
| Read latency (write edge N, earliest consumer transfer) | 1 cycle (edge N+1) | 2 cycles (edge N+2) |
| Core memory | DEPTH words | DEPTH-1 words + output register |
| `count` / full | total words held, full at `count == DEPTH` | same |

Rule 4 (stable `m_data` under stall) holds because the read pointer or output register only changes on a real transfer.

## 2. Area (Yosys generic gates, DATA_W=32; flops and cells, not LUTs)
| Config | Total cells | Storage flops | Control flops | 2:1 mux cells |
|---|---|---|---|---|
| DEPTH 16, OUT_REG=0 | 1139 | 512 | 21 | 488 |
| DEPTH 16, OUT_REG=1 | 1106 | 512 | 18 | 454 |
| DEPTH 64, OUT_REG=0 | 4377 | 2048 | 29 | 2028 |
| DEPTH 64, OUT_REG=1 | 4347 | 2048 | 24 | 1990 |

Storage is DEPTH x DATA_W flops in both modes (OUT_REG=1 uses (DEPTH-1) x DATA_W core flops plus DATA_W output flops). Control logic is under 3% of cells, so area is dominated by storage and the read mux. Memory bits: 0 (all flops, no RAM inferred).

## 3. Timing (by reasoning; Fmax was not measured)
- **OUT_REG=0 critical path:** `rd_ptr` flops to the DEPTH:1 read mux (about log2(DEPTH) mux levels) to `m_data`. This path breaks first as DEPTH grows.
- **OUT_REG=1 critical path:** `m_ready` to `rd_en`/`core_rd_en` (includes the `cnt == out_valid` compare) to `rd_ptr`, `out_data` enables and `cnt_nxt`, then to the flag compares.
- **Next to break as DEPTH grows:** the write enable and pointer decode fanning out to DEPTH x DATA_W flops, and the `cnt_nxt` up/down counter feeding the flag comparators.
- **Fixes:** pipeline or tree the read mux; one-hot pointers; duplicate/registered enables to cut fan-out; precompute flags incrementally instead of comparing `cnt_nxt`; move large DEPTH to LUTRAM/BRAM with a registered read.

## 4. Cost and trade-off
`OUT_REG` trades one cycle of read latency for taking the wide read mux off the output path. Area is essentially unchanged (storage is the same DEPTH words; cell count was 3% lower in generic gates). It adds a limitation: no sustained 100% throughput at DEPTH=2 (see decision log D14). Other trade-offs: `s_ready` ignoring `m_ready` costs one transfer slot when full, but avoids a consumer-to-producer combinational path.

## 5. Verification
See `verification_plan.md`. Self-checking testbench with a reference model; directed and random tests; regressions at DEPTH 16, 5, 3, 2 (`OUT_REG=0`) and DEPTH 16, 7, 5, 4, 3, 2 (`OUT_REG=1`), all passing under Icarus 12 (`-Wall -g2001`).
