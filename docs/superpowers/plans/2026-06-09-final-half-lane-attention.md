# Final Half-Lane Attention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evaluate whether halving the attention final-stage lanes can reduce area enough to improve `area * clk * cycles` toward `3.0E+11`.

**Architecture:** Keep FAST mode on the existing `BURST_128` flow. For ATT mode, issue RAM reads and writes as single-word commands at a two-cycle cadence so the final stage can use 32 physical lanes to compute low and high output columns in two successive cycles without adding a large FIFO.

**Result:** The experiment reached RTL correctness after fixing the low/high output capture alignment, but the single-word RAM read cadence is not performance-viable. Official RTL VCS passed with `execution cycles = 128400`, far beyond the roughly `10000` cycle budget. At `3.0 ns`, hitting `3.0E+11` with 128400 cycles would require area under about `778,816`, which is impossible for this design. Do not run DC for this variant unless the read path is redesigned around burst reads plus buffering.

**Tech Stack:** SystemVerilog RTL in `DCS_FINAL/CA.sv`, remote VCS/DC runs on `dcs_mimi`.

---

### Task 1: Throttle Attention RAM Cadence

**Files:**
- Modify: `DCS_FINAL/CA.sv`

- [x] Add `BURST_1 = 3'd0` in `CA_Control`.
- [x] Add attention read command counter and one-cycle gap state.
- [x] In ATT mode, issue one read command per RAM word and use `rd_burst = BURST_1`.
- [x] In ATT mode, issue one write command per result-pre-valid word and use `wr_burst = BURST_1`.
- [x] Preserve FAST mode `BURST_128` behavior.

### Task 2: Replace 64 Final Lanes With 32 Reused Lanes

**Files:**
- Modify: `DCS_FINAL/CA.sv`

- [x] Instantiate 8 rows by 4 lanes in `ATT_Final_Booth_Acc`.
- [x] Capture score/V on `in_valid`.
- [x] Run low columns first, then high columns on the following cycle.
- [x] Capture low-half lane outputs one cycle before high-half commit.
- [x] Assert one `out_valid` per input word and assemble the full 64-element vector from stored low columns plus current high columns.

### Task 3: Verify

**Files:**
- Modify: remote `Final/01_RTL/CA.sv`

- [x] Run local static checks: `git diff --check -- DCS_FINAL/CA.sv` and module/endmodule count.
- [x] Sync RTL to `dcs_mimi`.
- [x] Run remote RTL VCS.
- [x] If RTL passes and cycles stay near 10000, run remote DC at 3.0 ns. Skipped because cycles are `128400`.
- [x] Compare area, slack, cycles, and performance against opstage and directfinal experiments.
