# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
預設回答使用中文

## Project Overview

This is NYCU DCS 2026 HW05 — a single-file SystemVerilog CPU implementation (`CPU.sv`). The spec is in `2026_DCS_HW05.pdf`.

## Architecture

### Module Interface

```
CPU(clk, rst_n, in_valid, instruction[31:0],
    in_ready, out_valid, bad_ins[1:0],
    out_0..out_5[15:0])
```

- `in_ready` is 1'b1 when the output is steady to recieve next input
- `out_valid` goes high one cycle after a valid instruction is accepted
- `bad_ins = 2'b01` → invalid opcode or register address; `2'b10` → divide-by-zero

### Register File

6 registers, each 16-bit, mapped to **non-sequential 5-bit addresses**:

| Name | 5-bit addr | Output port |
|------|-----------|-------------|
| r0   | `10001`   | out_0       |
| r1   | `10010`   | out_1       |
| r2   | `01000`   | out_2       |
| r3   | `10111`   | out_3       |
| r4   | `11111`   | out_4       |
| r5   | `10000`   | out_5       |

Any register address not in this set is invalid and triggers `bad_ins = 2'b01`.

### Instruction Encoding (MIPS-like)

- **R-type** (`opcode = 6'b000000`): `[31:26]=opcode [25:21]=rs [20:16]=rt [15:11]=rd [10:6]=shamt [5:0]=funct`
- **I-type**: `[31:26]=opcode [25:21]=rs [20:16]=rt [15:0]=imm`; writes to `rt`

Supported instructions:

| Mnemonic | Type   | opcode     | funct      | Operation |
|----------|--------|-----------|-----------|-----------|
| ADD      | R      | `000000`  | `100000`  | rd = rs + rt |
| MULT     | R      | `000000`  | `011000`  | rd = (rs*rt)[30:15] (Q1.15 signed) |
| OR       | R      | `000000`  | `011001`  | rd = rs \| rt |
| SLA      | R      | `000000`  | `000000`  | rd = rt << shamt |
| SRA      | R      | `000000`  | `000010`  | rd = rt >>> shamt (arithmetic) |
| DIV      | R      | `000000`  | `110001`  | rd = floor((rs>>>n)/rt) in Q1.15 |
| ADDI     | I      | `001000`  | —         | rt = rs + imm |
| ORI      | I      | `001101`  | —         | rt = rs \| imm |

### Pipeline (2-stage)

**Stage 1 – Fetch** (posedge): latch `instruction → ins_r`, set `has_ins ← in_valid`.

**Stage 2 – Execute** (posedge, when `has_ins`): decode combinationally from `ins_r`, compute ALU result, write register file, drive `out_*` outputs.

All combinational decode/ALU logic operates on `ins_r` (the latched instruction). Outputs update one cycle after the instruction is presented.

### DIV Algorithm

Division computes `floor(rs_shifted / rt)` in Q1.15 format:
1. Compute `n = pos_a - pos_b + 1` only when `|rs| >= |rt|`, else `n = 0`.
2. Arithmetic right-shift `rs` by `n` → `a_shifted` (now `|a_shifted| < |rt|`).
3. 15-iteration restoring binary divider on `|a_shifted| / |rt|` → 15-bit magnitude.
4. Apply sign: XOR of `a_shifted[15]` and `rt[15]`.

Division by zero (`rt == 0`) suppresses the write and asserts `bad_ins = 2'b10`.

### Data Representation

All register values are **signed 16-bit Q1.15 fixed-point**. MULT shifts the 32-bit product right by 15 (`product[30:15]`). SLA/SRA use `shamt` from the instruction field.
