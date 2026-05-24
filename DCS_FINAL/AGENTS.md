# DCS_FINAL Agent Context

Use this file as the first project-context reminder before answering questions or editing code under `DCS_FINAL`.

## Response Language

- Reply in Traditional Chinese by default.
- Keep explanations focused on this final project and its RTL constraints.

## Project Goal

Implement `CA.sv`, the `CA` top module for a Conformer Accelerator.

High-level flow:

1. Receive `op`, `act`, and packed `param` from PATTERN.
2. Read 4-bit signed 8x8 input matrices from RAM.
3. Run the selected computation.
4. Apply activation.
5. Run PoT quantization to signed 4-bit range.
6. Write the result back to RAM.
7. Output the last token through `out_valid` and `out_data`.

Performance metric: minimize `execution_cycles * cycle_time * area`.

## Local Execution Rules

- Do not run local Verilog simulation, synthesis, or gate-level tool commands; this machine is expected to fail on those toolchains.
- After code review or RTL edits, perform syntax and logic inspection only.
- Do not modify `DCS_FINAL/00_TESTBED/RAM.sv` or `DCS_FINAL/00_TESTBED/PATTERN.sv`.
- Treat `RAM.sv` and `PATTERN.sv` as protected testbench files. Avoid reading them unless the user explicitly asks.

## Top Interface Summary

PATTERN inputs:

- `clk`
- `rst_n`: asynchronous active-low reset
- `mem_set`: RAM/op-set availability indicator
- `in_valid`: 1 cycle for FFN/Conv, 3 cycles for SHA/MHA
- `op[1:0]`: `00` FFN, `01` Conv, `10` SHA, `11` MHA
- `act[1:0]`: `00` ReLU, `01` RAT, `10` CAT, `11` BAT
- `param[255:0]`: signed 4-bit packed weights, MSB-to-LSB raster order

PATTERN outputs:

- `out_valid`: must reset to 0
- `out_data[31:0]`: last row of the result matrix, eight signed 4-bit values, must reset to 0

RAM interface:

- Read request: assert `rd_en` with `rd_addr` and `rd_burst` only when `rd_ready` is high.
- Read data: sample `rd_data` only when `rd_valid` is high.
- Write request: assert `wr_en` with `wr_addr` and `wr_burst` only when `wr_ready` is high.
- Write data: drive `wr_data` during `wr_valid`; update each beat for bursts.
- RAM is negative-edge triggered.
- Burst length is `2 ** burst`.

## Computation Rules

- FFN (`op == 2'b00`): 8x8 matrix multiplication, using 64 signed 4-bit weights.
- Conv (`op == 2'b01`): 3x3 kernel, zero padding 1, stride 1, using 9 signed 4-bit weights.
- SHA (`op == 2'b10`):
  - Capture `W_Q`, `W_K`, `W_V` over 3 `in_valid` cycles.
  - Compute `Q`, `K`, `V`.
  - PoT-quantize `Q`, `K`, `V` to signed 4-bit.
  - Compute `score = Q * K^T`.
  - Apply attention activation: keep nonnegative values; negative values become `x >> 2`.
  - Compute context with `V`.
- MHA (`op == 2'b11`):
  - Same broad flow as SHA.
  - Split Q/K columns into two heads: columns 0-3 and columns 4-7.
  - Compute each head separately, then combine with the corresponding V columns.

## Activation And Quantization

Activation is applied after the main computation result:

- ReLU: negative values become 0.
- RAT: row-average threshold; values below threshold are divided by 8.
- CAT: column-average threshold; values below threshold are divided by 8.
- BAT: 4x4 block-average threshold; values below threshold are divided by 8.

PoT quantization:

- Find max absolute value across the matrix.
- Compute right-shift amount from the MSB position so values fit signed 4-bit.
- Arithmetic-right-shift each element.
- Clamp to `[-8, 7]`.

## RTL Design Priorities

- Prefer smaller area, fewer execution cycles, and timing-clean RTL.
- Reuse MAC hardware where practical across FFN, Conv, SHA, and MHA.
- Pipeline around RAM latency when the design becomes performance-focused.
- Avoid latches: give defaults in combinational logic and complete all case/if branches.
- Use signed types and explicit `$signed(...)` where 4-bit values enter arithmetic.
- Reset all externally visible outputs and control signals to safe values.
- Do not use identifiers containing `error`, `latch`, `congratulation`, or `fail`.

## Packing Convention

Packed 256-bit words hold 64 signed 4-bit values in MSB-to-LSB raster order:

- `word[255:252]` maps to matrix `[0][0]`.
- `word[251:248]` maps to matrix `[0][1]`.
- `word[3:0]` maps to matrix `[7][7]`.

The output `out_data[31:0]` is the final row of the result matrix, packed as eight signed 4-bit values.

## Before Answering Or Editing

Check:

1. Is the question about architecture, RTL implementation, verification, or report writing?
2. Are protected files involved? If yes, avoid touching them unless explicitly requested.
3. Would a proposed edit improve correctness without hurting area/cycles/timing too much?
4. Are reset behavior, handshakes, signed arithmetic, and pack/unpack order preserved?
5. If code was edited, explain the syntax/logic checks performed instead of claiming local Verilog simulation passed.
