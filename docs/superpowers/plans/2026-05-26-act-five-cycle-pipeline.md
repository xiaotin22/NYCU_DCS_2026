# ACT Five-Cycle Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ACT_TwoStage_Parallel` with a fixed five-stage, II=1 activation pipeline and keep downstream metadata aligned.

**Architecture:** The ACT block will carry the original matrix and a partially activated matrix through five pipeline stages. Stage 0 computes threshold chunk 0, stages 1 through 3 each apply the previous chunk while computing the next threshold chunk, and stage 4 applies chunk 3 and exposes the final output. `CA_DataPath` will extend the ACT tag/index metadata pipe from two stages to five stages.

**Tech Stack:** SystemVerilog RTL in `DCS_FINAL/CA.sv`; local inspection with PowerShell, `rg`, and `git diff --check`. Do not run local simulation, synthesis, or gate-level commands for this project.

---

## File Structure

- Modify: `DCS_FINAL/CA.sv`
  - Replace the internals of `ACT_TwoStage_Parallel`.
  - Extend `act_tag_q` and `act_idx_q` from `[0:1]` to `[0:4]`.
  - Update all ACT-output consumers from stage 1 metadata to stage 4 metadata.
- Reference: `docs/superpowers/specs/2026-05-26-act-five-cycle-pipeline-design.md`
  - Keep the implementation aligned with the approved schedule and chunk mapping.

`DCS_FINAL/CA.sv` is already modified before this plan starts. Preserve those existing edits. Do not run broad revert commands or format the whole file.

---

### Task 1: Replace ACT Pipeline Internals

**Files:**
- Modify: `DCS_FINAL/CA.sv:1176-1371`
- Reference: `docs/superpowers/specs/2026-05-26-act-five-cycle-pipeline-design.md`

- [ ] **Step 1: Inspect the current ACT module boundary**

Run:

```powershell
rg -n "module ACT_TwoStage_Parallel|endmodule|ACT_TwoStage_Parallel u_act" DCS_FINAL\CA.sv
```

Expected:

```text
1176:module ACT_TwoStage_Parallel (
1371:endmodule
818:    ACT_TwoStage_Parallel u_act (
```

- [ ] **Step 2: Replace the whole `ACT_TwoStage_Parallel` module**

Replace the existing module from `module ACT_TwoStage_Parallel (` through its matching `endmodule` with this code:

```systemverilog
module ACT_TwoStage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [1:0]    act_mode,
    input  logic [1023:0] in_data,
    output logic          out_valid,
    output logic [1023:0] out_data
);

    localparam int MAT_SIZE     = 64;
    localparam int ROW_ELEM     = 8;
    localparam int CHUNK_SIZE   = 16;
    localparam int ACT_STAGES   = 5;
    localparam int NUM_CHUNKS   = 4;

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_BYPASS  = 2'd1;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [19:0] s20_t;

    logic          valid_q  [0:ACT_STAGES-1];
    logic [1:0]    act_q    [0:ACT_STAGES-1];
    logic [1:0]    mode_q   [0:ACT_STAGES-1];
    logic [1023:0] src_q    [0:ACT_STAGES-1];
    logic [1023:0] matrix_q [0:ACT_STAGES-1];
    s20_t          thr_a_q  [0:ACT_STAGES-1];
    s20_t          thr_b_q  [0:ACT_STAGES-1];

    logic [39:0]   thr0_pair;
    logic [39:0]   thr1_pair;
    logic [39:0]   thr2_pair;
    logic [39:0]   thr3_pair;

    assign out_valid = valid_q[ACT_STAGES-1];
    assign out_data  = matrix_q[ACT_STAGES-1];

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s20_t ext20(input s16_t value);
        ext20 = {{4{value[15]}}, value};
    endfunction

    function automatic logic [39:0] calc_threshold_pair(
        input logic [1023:0] matrix,
        input logic [1:0]    act_sel,
        input integer        chunk
    );
        integer row0;
        integer row1;
        integer col0;
        integer col1;
        integer base_row;
        integer base_col;
        s20_t  sum_a;
        s20_t  sum_b;
        s20_t  thr_a;
        s20_t  thr_b;
        begin
            sum_a = 20'sd0;
            sum_b = 20'sd0;
            thr_a = 20'sd0;
            thr_b = 20'sd0;

            case (act_sel)
                2'b01: begin
                    row0 = chunk * 2;
                    row1 = row0 + 1;
                    for (int c = 0; c < ROW_ELEM; c++) begin
                        sum_a += ext20(get_i16(matrix, (row0 * ROW_ELEM) + c));
                        sum_b += ext20(get_i16(matrix, (row1 * ROW_ELEM) + c));
                    end
                    thr_a = sum_a >>> 3;
                    thr_b = sum_b >>> 3;
                end

                2'b10: begin
                    col0 = chunk * 2;
                    col1 = col0 + 1;
                    for (int r = 0; r < ROW_ELEM; r++) begin
                        sum_a += ext20(get_i16(matrix, (r * ROW_ELEM) + col0));
                        sum_b += ext20(get_i16(matrix, (r * ROW_ELEM) + col1));
                    end
                    thr_a = sum_a >>> 3;
                    thr_b = sum_b >>> 3;
                end

                2'b11: begin
                    base_row = (chunk / 2) * 4;
                    base_col = (chunk % 2) * 4;
                    for (int r = 0; r < 4; r++) begin
                        for (int c = 0; c < 4; c++) begin
                            sum_a += ext20(get_i16(matrix,
                                                   ((base_row + r) * ROW_ELEM) +
                                                   (base_col + c)));
                        end
                    end
                    thr_a = sum_a >>> 4;
                    thr_b = thr_a;
                end

                default: begin
                    thr_a = 20'sd0;
                    thr_b = 20'sd0;
                end
            endcase

            calc_threshold_pair = {thr_a, thr_b};
        end
    endfunction

    function automatic integer chunk_idx(
        input logic [1:0] act_sel,
        input logic [1:0] mode_sel,
        input integer     chunk,
        input integer     lane
    );
        integer row;
        integer col;
        begin
            if (mode_sel != ACT_USER) begin
                chunk_idx = (chunk * CHUNK_SIZE) + lane;
            end
            else begin
                case (act_sel)
                    2'b10: begin
                        row       = lane / 2;
                        col       = (chunk * 2) + (lane % 2);
                        chunk_idx = (row * ROW_ELEM) + col;
                    end

                    2'b11: begin
                        row       = ((chunk / 2) * 4) + (lane / 4);
                        col       = ((chunk % 2) * 4) + (lane % 4);
                        chunk_idx = (row * ROW_ELEM) + col;
                    end

                    default: begin
                        chunk_idx = (chunk * CHUNK_SIZE) + lane;
                    end
                endcase
            end
        end
    endfunction

    function automatic s20_t select_threshold(
        input logic [1:0] act_sel,
        input integer     lane,
        input s20_t       threshold_a,
        input s20_t       threshold_b
    );
        begin
            case (act_sel)
                2'b01: begin
                    select_threshold = (lane < ROW_ELEM) ? threshold_a : threshold_b;
                end

                2'b10: begin
                    select_threshold = ((lane % 2) == 0) ? threshold_a : threshold_b;
                end

                2'b11: begin
                    select_threshold = threshold_a;
                end

                default: begin
                    select_threshold = 20'sd0;
                end
            endcase
        end
    endfunction

    function automatic s16_t activate_value(
        input s16_t       value,
        input logic [1:0] act_sel,
        input logic [1:0] mode_sel,
        input s20_t       threshold
    );
        begin
            case (mode_sel)
                ACT_BYPASS: begin
                    activate_value = value;
                end

                ACT_SPECIAL: begin
                    activate_value = (value < 0) ? (value >>> 2) : value;
                end

                default: begin
                    if (act_sel == 2'b00) begin
                        activate_value = (value < 0) ? 16'sd0 : value;
                    end
                    else begin
                        activate_value = (ext20(value) < threshold) ? (value >>> 3) : value;
                    end
                end
            endcase
        end
    endfunction

    function automatic logic [1023:0] apply_chunk(
        input logic [1023:0] base_matrix,
        input logic [1023:0] src_matrix,
        input logic [1:0]    act_sel,
        input logic [1:0]    mode_sel,
        input integer        chunk,
        input s20_t          threshold_a,
        input s20_t          threshold_b
    );
        integer idx;
        s20_t  threshold;
        begin
            apply_chunk = base_matrix;

            for (int lane = 0; lane < CHUNK_SIZE; lane++) begin
                idx       = chunk_idx(act_sel, mode_sel, chunk, lane);
                threshold = select_threshold(act_sel, lane, threshold_a, threshold_b);
                apply_chunk[1023 - (idx * 16) -: 16] =
                    activate_value(get_i16(src_matrix, idx), act_sel, mode_sel, threshold);
            end
        end
    endfunction

    always_comb begin
        thr0_pair = calc_threshold_pair(in_data,  act,      0);
        thr1_pair = calc_threshold_pair(src_q[0], act_q[0], 1);
        thr2_pair = calc_threshold_pair(src_q[1], act_q[1], 2);
        thr3_pair = calc_threshold_pair(src_q[2], act_q[2], 3);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ACT_STAGES; i++) begin
                valid_q[i]  <= 1'b0;
                act_q[i]    <= 2'd0;
                mode_q[i]   <= ACT_USER;
                src_q[i]    <= 1024'd0;
                matrix_q[i] <= 1024'd0;
                thr_a_q[i]  <= 20'sd0;
                thr_b_q[i]  <= 20'sd0;
            end
        end
        else begin
            valid_q[0]  <= in_valid;
            act_q[0]    <= act;
            mode_q[0]   <= act_mode;
            src_q[0]    <= in_data;
            matrix_q[0] <= in_data;
            thr_a_q[0]  <= $signed(thr0_pair[39:20]);
            thr_b_q[0]  <= $signed(thr0_pair[19:0]);

            valid_q[1]  <= valid_q[0];
            act_q[1]    <= act_q[0];
            mode_q[1]   <= mode_q[0];
            src_q[1]    <= src_q[0];
            matrix_q[1] <= apply_chunk(matrix_q[0], src_q[0], act_q[0], mode_q[0],
                                       0, thr_a_q[0], thr_b_q[0]);
            thr_a_q[1]  <= $signed(thr1_pair[39:20]);
            thr_b_q[1]  <= $signed(thr1_pair[19:0]);

            valid_q[2]  <= valid_q[1];
            act_q[2]    <= act_q[1];
            mode_q[2]   <= mode_q[1];
            src_q[2]    <= src_q[1];
            matrix_q[2] <= apply_chunk(matrix_q[1], src_q[1], act_q[1], mode_q[1],
                                       1, thr_a_q[1], thr_b_q[1]);
            thr_a_q[2]  <= $signed(thr2_pair[39:20]);
            thr_b_q[2]  <= $signed(thr2_pair[19:0]);

            valid_q[3]  <= valid_q[2];
            act_q[3]    <= act_q[2];
            mode_q[3]   <= mode_q[2];
            src_q[3]    <= src_q[2];
            matrix_q[3] <= apply_chunk(matrix_q[2], src_q[2], act_q[2], mode_q[2],
                                       2, thr_a_q[2], thr_b_q[2]);
            thr_a_q[3]  <= $signed(thr3_pair[39:20]);
            thr_b_q[3]  <= $signed(thr3_pair[19:0]);

            valid_q[4]  <= valid_q[3];
            act_q[4]    <= act_q[3];
            mode_q[4]   <= mode_q[3];
            src_q[4]    <= src_q[3];
            matrix_q[4] <= apply_chunk(matrix_q[3], src_q[3], act_q[3], mode_q[3],
                                       3, thr_a_q[3], thr_b_q[3]);
            thr_a_q[4]  <= 20'sd0;
            thr_b_q[4]  <= 20'sd0;
        end
    end

endmodule
```

- [ ] **Step 3: Inspect the replacement for accidental old helper leftovers**

Run:

```powershell
rg -n "HALF_SIZE|lane_idx|lane_group|group_sum|run_half|st1_valid|st1_matrix" DCS_FINAL\CA.sv
```

Expected:

```text
```

No output means the old two-stage helper structure has been removed from `ACT_TwoStage_Parallel`.

---

### Task 2: Align ACT Metadata Pipeline

**Files:**
- Modify: `DCS_FINAL/CA.sv:568-569`
- Modify: `DCS_FINAL/CA.sv:865-899`
- Modify: `DCS_FINAL/CA.sv:772-790`
- Modify: `DCS_FINAL/CA.sv:908-910`

- [ ] **Step 1: Extend the ACT tag and index arrays**

Replace:

```systemverilog
    pipe_tag_t     act_tag_q [0:1];
    logic [2:0]    act_idx_q [0:1];
```

with:

```systemverilog
    pipe_tag_t     act_tag_q [0:4];
    logic [2:0]    act_idx_q [0:4];
```

- [ ] **Step 2: Extend the reset loop for ACT metadata**

Replace:

```systemverilog
            for (int i = 0; i < 2; i++) begin
                act_tag_q[i] <= PT_NONE;
                act_idx_q[i] <= 3'd0;
            end
```

with:

```systemverilog
            for (int i = 0; i < 5; i++) begin
                act_tag_q[i] <= PT_NONE;
                act_idx_q[i] <= 3'd0;
            end
```

- [ ] **Step 3: Extend the ACT metadata shift register**

Replace:

```systemverilog
            act_tag_q[0] <= act_in_valid ? act_in_tag : PT_NONE;
            act_idx_q[0] <= act_in_idx;
            act_tag_q[1] <= act_tag_q[0];
            act_idx_q[1] <= act_idx_q[0];
```

with:

```systemverilog
            act_tag_q[0] <= act_in_valid ? act_in_tag : PT_NONE;
            act_idx_q[0] <= act_in_idx;
            for (int i = 1; i < 5; i++) begin
                act_tag_q[i] <= act_tag_q[i - 1];
                act_idx_q[i] <= act_idx_q[i - 1];
            end
```

- [ ] **Step 4: Retarget ACT consumers from stage 1 to stage 4**

Replace every ACT-output metadata reference in `CA_DataPath`:

```systemverilog
act_tag_q[1]
act_idx_q[1]
```

with:

```systemverilog
act_tag_q[4]
act_idx_q[4]
```

This affects the `pot_in_valid`, `pot_in_data`, `pot_in_idx`, `pot_in_tag`, and `score_buf_q` capture logic.

- [ ] **Step 5: Verify no old stage-1 ACT consumer remains**

Run:

```powershell
rg -n "act_tag_q\\[1\\]|act_idx_q\\[1\\]" DCS_FINAL\CA.sv
```

Expected:

```text
```

No output means ACT output metadata consumers have been moved to stage 4.

---

### Task 3: RTL Inspection Checks

**Files:**
- Inspect: `DCS_FINAL/CA.sv`

- [ ] **Step 1: Confirm the new ACT latency and metadata depth**

Run:

```powershell
rg -n "ACT_STAGES|valid_q\\[4\\]|act_tag_q \\[0:4\\]|act_idx_q \\[0:4\\]|act_tag_q\\[4\\]|act_idx_q\\[4\\]" DCS_FINAL\CA.sv
```

Expected output includes:

```text
localparam int ACT_STAGES   = 5;
assign out_valid = valid_q[ACT_STAGES-1];
pipe_tag_t     act_tag_q [0:4];
logic [2:0]    act_idx_q [0:4];
```

- [ ] **Step 2: Check for whitespace or patch formatting issues**

Run:

```powershell
git diff --check
```

Expected:

```text
```

No output means Git found no whitespace issues.

- [ ] **Step 3: Review the ACT chunk mapping by inspection**

Run:

```powershell
Get-Content -Path .\DCS_FINAL\CA.sv | Select-Object -Skip 1176 -First 260
```

Inspect these conditions:

- RAT threshold chunk uses two consecutive rows and shifts each row sum by 3.
- CAT threshold chunk uses two consecutive columns and shifts each column sum by 3.
- BAT threshold chunk uses one 4x4 block and shifts the block sum by 4.
- `apply_chunk` updates exactly 16 lanes per stage.
- `chunk_idx` ignores `act_sel` when `mode_sel != ACT_USER`, so `ACT_SPECIAL` is applied over consecutive 16-lane chunks.

- [ ] **Step 4: Review the pipeline data dependencies by inspection**

Run:

```powershell
rg -n "thr0_pair|thr1_pair|thr2_pair|thr3_pair|matrix_q\\[1\\]|matrix_q\\[2\\]|matrix_q\\[3\\]|matrix_q\\[4\\]" DCS_FINAL\CA.sv
```

Confirm:

- `thr0_pair` is computed from `in_data`.
- `thr1_pair` is computed from `src_q[0]`.
- `thr2_pair` is computed from `src_q[1]`.
- `thr3_pair` is computed from `src_q[2]`.
- `matrix_q[1]` applies chunk 0.
- `matrix_q[2]` applies chunk 1.
- `matrix_q[3]` applies chunk 2.
- `matrix_q[4]` applies chunk 3.

---

### Task 4: Final Review And Handoff

**Files:**
- Inspect: `DCS_FINAL/CA.sv`
- Inspect: `docs/superpowers/specs/2026-05-26-act-five-cycle-pipeline-design.md`

- [ ] **Step 1: Show the resulting diff**

Run:

```powershell
git diff -- DCS_FINAL/CA.sv
```

Expected:

```text
```

The diff should show only the ACT module replacement and ACT metadata pipe alignment. Existing unrelated local edits must remain intact.

- [ ] **Step 2: Summarize verification limits**

In the final implementation response, state:

```text
I performed RTL inspection and `git diff --check`. I did not run local simulation, synthesis, or gate-level checks because this project's local rules say those toolchains are expected to be unreliable on this machine.
```

- [ ] **Step 3: Decide whether to commit**

If `git status --short` shows only files changed by this implementation, commit with:

```powershell
git add DCS_FINAL\CA.sv
git commit -m "refactor: pipeline act over five stages"
```

If `git status --short` shows pre-existing local edits mixed into `DCS_FINAL/CA.sv`, do not commit. Report the changed file and leave the working tree for the user to review.
