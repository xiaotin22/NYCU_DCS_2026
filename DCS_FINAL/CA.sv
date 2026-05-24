module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    // ============================================= //
    //                    PATTERN                    //
    // ============================================= //
    // input signals
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    // output signals
    output logic                            out_valid,
    output logic [31:0]                     out_data,

    // ============================================= //
    //                      RAM                      //
    // ============================================= //
    // READ
    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1    :0]        rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

    // WRITE
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1    :0]        wr_burst,
    output logic [RAM_WIDTH-1:0]            wr_data,
    input  logic                            wr_valid,
    input  logic                            wr_ready
);

    // ======================================================================
    // Your Design
    // ======================================================================

    localparam int ADDR_WIDTH       = $clog2(RAM_DEPTH);
    localparam int BATCH_LEN        = 128;
    localparam int READ_WAIT_CYCLES = 50;
    localparam logic [BURST_BIT-1:0]   FULL_BURST  = 3'd7;
    localparam logic [ADDR_WIDTH-1:0]  BATCH0_ADDR = '0;
    localparam logic [ADDR_WIDTH-1:0]  BATCH1_ADDR = ADDR_WIDTH'(BATCH_LEN);

    localparam logic [1:0] OP_FFN  = 2'b00;
    localparam logic [1:0] OP_CONV = 2'b01;
    localparam logic [1:0] OP_SHA  = 2'b10;
    localparam logic [1:0] OP_MHA  = 2'b11;

    localparam logic [1:0] ACT_RELU = 2'b00;
    localparam logic [1:0] ACT_RAT  = 2'b01;
    localparam logic [1:0] ACT_CAT  = 2'b10;
    localparam logic [1:0] ACT_BAT  = 2'b11;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RECV_P1,
        S_RECV_P2,
        S_RECV_P3,
        S_RD_REQ,
        S_RD_WAIT,
        S_RD_STREAM,
        S_COMPUTE,
        S_WR_REQ,
        S_WR_STREAM,
        S_PREFETCH_STREAM,
        S_BATCH_CHK,
        S_OP_DONE
    } state_t;

    state_t state_cs, state_ns;

    logic [1:0]   op_reg,       op_reg_ns;
    logic [1:0]   act_reg,      act_reg_ns;
    logic [255:0] param_p1_reg, param_p1_reg_ns;
    logic [255:0] param_p2_reg, param_p2_reg_ns;
    logic [255:0] param_p3_reg, param_p3_reg_ns;
    logic [6:0]   mat_cnt,      mat_cnt_ns;
    logic [6:0]   wr_cnt,       wr_cnt_ns;
    logic         batch_id,     batch_id_ns;
    logic [5:0]   rd_wait_cnt,  rd_wait_cnt_ns;
    logic         out_valid_ns;
    logic [31:0]  out_data_ns;
    logic [2:0]   sha_step,     sha_step_ns;
    logic         prefetch_active, prefetch_active_ns;
    logic         prefetch_done,   prefetch_done_ns;
    logic [6:0]   prefetch_cnt,    prefetch_cnt_ns;

    // 128 x 256-bit buffers: batch0 and overlapped batch1 prefetch storage
    logic [RAM_WIDTH-1:0]   mat_buf     [0:BATCH_LEN-1];
    logic [RAM_WIDTH-1:0]   mat_buf_b   [0:BATCH_LEN-1];

    // SHA/MHA intermediate buffers (registered)
    logic signed [15:0]     q_raw_buf   [0:7][0:7];
    logic signed [15:0]     q_raw_buf_ns[0:7][0:7];
    logic signed [15:0]     k_raw_buf   [0:7][0:7];
    logic signed [15:0]     k_raw_buf_ns[0:7][0:7];
    logic signed [15:0]     v_raw_buf   [0:7][0:7];
    logic signed [15:0]     v_raw_buf_ns[0:7][0:7];
    logic signed [3:0]      q_buf       [0:7][0:7];
    logic signed [3:0]      q_buf_ns    [0:7][0:7];
    logic signed [3:0]      k_buf       [0:7][0:7];
    logic signed [3:0]      k_buf_ns    [0:7][0:7];
    logic signed [3:0]      v_buf       [0:7][0:7];
    logic signed [3:0]      v_buf_ns    [0:7][0:7];
    logic signed [11:0]     score_buf   [0:1][0:7][0:7];
    logic signed [11:0]     score_buf_ns[0:1][0:7][0:7];

    logic [ADDR_WIDTH-1:0]  batch_base_addr;
    assign batch_base_addr = batch_id ? BATCH1_ADDR : BATCH0_ADDR;

    // ------------------------------------------------------------------
    // Helper functions
    // ------------------------------------------------------------------

    // Extract signed 4-bit element idx from a 256-bit packed word (MSB-first)
    function automatic logic signed [3:0] get_seq_s4(
        input logic [255:0] word,
        input int           idx
    );
        get_seq_s4 = $signed(word[255 - 4*idx -: 4]);
    endfunction

    // Extract matrix element [row][col] from a 256-bit packed word
    function automatic logic signed [3:0] get_matrix_s4(
        input logic [255:0] word,
        input int           row,
        input int           col
    );
        get_matrix_s4 = get_seq_s4(word, 8*row + col);
    endfunction

    // Sign-extend 4-bit signed to int for arithmetic
    function automatic int signed s4_int(input logic signed [3:0] value);
        s4_int = value;
    endfunction

    // Absolute value of signed int
    function automatic int unsigned abs_int(input int signed value);
        abs_int = (value < 0) ? -value : value;
    endfunction

    // Position of most-significant set bit (0 when value==0)
    function automatic int unsigned msb_index(input int unsigned value);
        int  bit_idx;
        logic found;
        begin
            msb_index = 0;
            found     = 1'b0;
            for (bit_idx = 31; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                if (!found && value[bit_idx]) begin
                    msb_index = bit_idx;
                    found     = 1'b1;
                end
            end
        end
    endfunction

    // Compute PoT right-shift amount from max absolute value
    function automatic int unsigned pot_shift(input int unsigned max_abs);
        int unsigned msb;
        begin
            if (max_abs == 0) begin
                pot_shift = 0;
            end else begin
                msb       = msb_index(max_abs);
                pot_shift = (msb > 2) ? (msb - 2) : 0;
            end
        end
    endfunction

    // Clamp int to signed 4-bit range [-8, 7]
    function automatic logic signed [3:0] clip_s4(input int signed value);
        begin
            if      (value >  7) clip_s4 =  4'sd7;
            else if (value < -8) clip_s4 = -4'sd8;
            else                 clip_s4 = value[3:0];
        end
    endfunction

    // Fixed activation used inside SHA score: x<0 -> x>>>2
    function automatic int signed attention_score_act(input int signed value);
        attention_score_act = (value < 0) ? (value >>> 2) : value;
    endfunction

    // One element of an 8x8 matrix multiplication: sum_k x[row][k]*w[k][col]
    function automatic logic signed [15:0] matmul_raw_word(
        input logic [RAM_WIDTH-1:0] x_word,
        input logic [255:0]         w_word,
        input int                   row,
        input int                   col
    );
        int k;
        int signed sum;
        begin
            sum = 0;
            for (k = 0; k < 8; k = k + 1)
                sum = sum + s4_int(get_matrix_s4(x_word, row, k))
                          * s4_int(get_matrix_s4(w_word, k,   col));
            matmul_raw_word = sum[15:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // FFN / Conv combinational compute + act + PoT (single-cycle per matrix)
    // ------------------------------------------------------------------
    function automatic logic [RAM_WIDTH-1:0] compute_result_word(
        input logic [RAM_WIDTH-1:0] x_word
    );
        logic signed [3:0]  x_mat    [0:7][0:7];
        logic signed [3:0]  final_mat[0:7][0:7];
        int signed          raw_mat  [0:7][0:7];
        int signed          act_mat  [0:7][0:7];
        int r, c, k, kr, kc, rr, cc, br, bc;
        int signed          sum, threshold, shifted;
        int unsigned        max_abs, elem_abs, shift;
        logic [RAM_WIDTH-1:0] packed_result;
        begin
            packed_result = '0;

            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    x_mat[r][c]     = get_matrix_s4(x_word, r, c);
                    raw_mat[r][c]   = 0;
                    act_mat[r][c]   = 0;
                    final_mat[r][c] = 4'sd0;
                end

            case (op_reg)
                OP_FFN: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1) begin
                            sum = 0;
                            for (k = 0; k < 8; k = k + 1)
                                sum = sum + s4_int(x_mat[r][k])
                                          * s4_int(get_matrix_s4(param_p1_reg, k, c));
                            raw_mat[r][c] = sum;
                        end
                end

                OP_CONV: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1) begin
                            sum = 0;
                            for (kr = 0; kr < 3; kr = kr + 1)
                                for (kc = 0; kc < 3; kc = kc + 1) begin
                                    rr = r + kr - 1;
                                    cc = c + kc - 1;
                                    if (rr >= 0 && rr < 8 && cc >= 0 && cc < 8)
                                        sum = sum + s4_int(x_mat[rr][cc])
                                                  * s4_int(get_seq_s4(param_p1_reg, 3*kr + kc));
                                end
                            raw_mat[r][c] = sum;
                        end
                end

                default: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1)
                            raw_mat[r][c] = 0;
                end
            endcase

            case (act_reg)
                ACT_RELU: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = (raw_mat[r][c] < 0) ? 0 : raw_mat[r][c];
                end

                ACT_RAT: begin
                    for (r = 0; r < 8; r = r + 1) begin
                        sum = 0;
                        for (c = 0; c < 8; c = c + 1)
                            sum = sum + raw_mat[r][c];
                        threshold = sum / 8;  // truncate-toward-zero matches spec
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = (raw_mat[r][c] < threshold)
                                            ? (raw_mat[r][c] / 8)
                                            :  raw_mat[r][c];
                    end
                end

                ACT_CAT: begin
                    for (c = 0; c < 8; c = c + 1) begin
                        sum = 0;
                        for (r = 0; r < 8; r = r + 1)
                            sum = sum + raw_mat[r][c];
                        threshold = sum / 8;  // signed / truncates toward zero
                        for (r = 0; r < 8; r = r + 1)
                            act_mat[r][c] = (raw_mat[r][c] < threshold)
                                            ? (raw_mat[r][c] / 8)
                                            :  raw_mat[r][c];
                    end
                end

                ACT_BAT: begin
                    for (br = 0; br < 8; br = br + 4)
                        for (bc = 0; bc < 8; bc = bc + 4) begin
                            sum = 0;
                            for (rr = 0; rr < 4; rr = rr + 1)
                                for (cc = 0; cc < 4; cc = cc + 1)
                                    sum = sum + raw_mat[br+rr][bc+cc];
                            threshold = sum / 16;
                            for (rr = 0; rr < 4; rr = rr + 1)
                                for (cc = 0; cc < 4; cc = cc + 1)
                                    act_mat[br+rr][bc+cc] =
                                        (raw_mat[br+rr][bc+cc] < threshold)
                                        ? (raw_mat[br+rr][bc+cc] / 8)
                                        :  raw_mat[br+rr][bc+cc];
                        end
                end

                default: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = raw_mat[r][c];
                end
            endcase

            // PoT quantize act_mat -> final_mat
            max_abs = 0;
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    elem_abs = abs_int(act_mat[r][c]);
                    if (elem_abs > max_abs) max_abs = elem_abs;
                end
            shift = pot_shift(max_abs);
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    shifted = act_mat[r][c] >>> shift;
                    final_mat[r][c] = clip_s4(shifted);
                    packed_result[255 - 4*(8*r + c) -: 4] = final_mat[r][c];
                end

            compute_result_word = packed_result;
        end
    endfunction

    // ------------------------------------------------------------------
    // SHA / MHA final step: score_buf x V_buf -> act -> PoT
    // ------------------------------------------------------------------
    function automatic logic [RAM_WIDTH-1:0] compute_attention_result_word();
        logic signed [3:0]  final_mat[0:7][0:7];
        int signed          raw_mat  [0:7][0:7];
        int signed          act_mat  [0:7][0:7];
        int r, c, k, rr, cc, br, bc;
        int                 head_idx;
        int signed          sum, threshold, shifted;
        int unsigned        max_abs, elem_abs, shift;
        logic [RAM_WIDTH-1:0] packed_result;
        begin
            packed_result = '0;

            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    // MHA: col 0-3 use head 0, col 4-7 use head 1
                    head_idx = ((op_reg == OP_MHA) && (c >= 4)) ? 1 : 0;
                    sum = 0;
                    // Output column c selects the matching V half for each MHA head.
                    for (k = 0; k < 8; k = k + 1)
                        sum = sum + $signed(score_buf[head_idx][r][k])
                                  * s4_int(v_buf[k][c]);
                    raw_mat[r][c]   = sum;
                    act_mat[r][c]   = 0;
                    final_mat[r][c] = 4'sd0;
                end

            case (act_reg)
                ACT_RELU: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = (raw_mat[r][c] < 0) ? 0 : raw_mat[r][c];
                end

                ACT_RAT: begin
                    for (r = 0; r < 8; r = r + 1) begin
                        sum = 0;
                        for (c = 0; c < 8; c = c + 1)
                            sum = sum + raw_mat[r][c];
                        threshold = sum / 8;  // signed / truncates toward zero
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = (raw_mat[r][c] < threshold)
                                            ? (raw_mat[r][c] / 8)
                                            :  raw_mat[r][c];
                    end
                end

                ACT_CAT: begin
                    for (c = 0; c < 8; c = c + 1) begin
                        sum = 0;
                        for (r = 0; r < 8; r = r + 1)
                            sum = sum + raw_mat[r][c];
                        threshold = sum / 8;  // signed / truncates toward zero
                        for (r = 0; r < 8; r = r + 1)
                            act_mat[r][c] = (raw_mat[r][c] < threshold)
                                            ? (raw_mat[r][c] / 8)
                                            :  raw_mat[r][c];
                    end
                end

                ACT_BAT: begin
                    for (br = 0; br < 8; br = br + 4)
                        for (bc = 0; bc < 8; bc = bc + 4) begin
                            sum = 0;
                            for (rr = 0; rr < 4; rr = rr + 1)
                                for (cc = 0; cc < 4; cc = cc + 1)
                                    sum = sum + raw_mat[br+rr][bc+cc];
                            threshold = sum / 16;
                            for (rr = 0; rr < 4; rr = rr + 1)
                                for (cc = 0; cc < 4; cc = cc + 1)
                                    act_mat[br+rr][bc+cc] =
                                        (raw_mat[br+rr][bc+cc] < threshold)
                                        ? (raw_mat[br+rr][bc+cc] / 8)
                                        :  raw_mat[br+rr][bc+cc];
                        end
                end

                default: begin
                    for (r = 0; r < 8; r = r + 1)
                        for (c = 0; c < 8; c = c + 1)
                            act_mat[r][c] = raw_mat[r][c];
                end
            endcase

            // PoT quantize act_mat -> final_mat
            max_abs = 0;
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    elem_abs = abs_int(act_mat[r][c]);
                    if (elem_abs > max_abs) max_abs = elem_abs;
                end
            shift = pot_shift(max_abs);
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    shifted = act_mat[r][c] >>> shift;
                    final_mat[r][c] = clip_s4(shifted);
                    packed_result[255 - 4*(8*r + c) -: 4] = final_mat[r][c];
                end

            compute_attention_result_word = packed_result;
        end
    endfunction

    // ------------------------------------------------------------------
    // Sequential registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin : seq_regs
        int r, c, h;
        if (!rst_n) begin
            state_cs     <= S_IDLE;
            op_reg       <= 2'd0;
            act_reg      <= 2'd0;
            param_p1_reg <= 256'd0;
            param_p2_reg <= 256'd0;
            param_p3_reg <= 256'd0;
            mat_cnt      <= 7'd0;
            wr_cnt       <= 7'd0;
            batch_id     <= 1'b0;
            rd_wait_cnt  <= 6'd0;
            out_valid    <= 1'b0;
            out_data     <= 32'd0;
            sha_step     <= 3'd0;
            prefetch_active <= 1'b0;
            prefetch_done   <= 1'b0;
            prefetch_cnt    <= 7'd0;
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    q_raw_buf[r][c] <= '0;
                    k_raw_buf[r][c] <= '0;
                    v_raw_buf[r][c] <= '0;
                    q_buf[r][c]     <= 4'sd0;
                    k_buf[r][c]     <= 4'sd0;
                    v_buf[r][c]     <= 4'sd0;
                    for (h = 0; h < 2; h = h + 1)
                        score_buf[h][r][c] <= '0;
                end
        end else begin
            state_cs     <= state_ns;
            op_reg       <= op_reg_ns;
            act_reg      <= act_reg_ns;
            param_p1_reg <= param_p1_reg_ns;
            param_p2_reg <= param_p2_reg_ns;
            param_p3_reg <= param_p3_reg_ns;
            mat_cnt      <= mat_cnt_ns;
            wr_cnt       <= wr_cnt_ns;
            batch_id     <= batch_id_ns;
            rd_wait_cnt  <= rd_wait_cnt_ns;
            out_valid    <= out_valid_ns;
            out_data     <= out_data_ns;
            sha_step     <= sha_step_ns;
            prefetch_active <= prefetch_active_ns;
            prefetch_done   <= prefetch_done_ns;
            prefetch_cnt    <= prefetch_cnt_ns;
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    q_raw_buf[r][c] <= q_raw_buf_ns[r][c];
                    k_raw_buf[r][c] <= k_raw_buf_ns[r][c];
                    v_raw_buf[r][c] <= v_raw_buf_ns[r][c];
                    q_buf[r][c]     <= q_buf_ns[r][c];
                    k_buf[r][c]     <= k_buf_ns[r][c];
                    v_buf[r][c]     <= v_buf_ns[r][c];
                    for (h = 0; h < 2; h = h + 1)
                        score_buf[h][r][c] <= score_buf_ns[h][r][c];
                end

            // Matrix buffer write paths are selected by active batch.
            if (state_cs == S_COMPUTE &&
                    (op_reg == OP_FFN || op_reg == OP_CONV)) begin
                if (batch_id)
                    mat_buf_b[mat_cnt] <= compute_result_word(mat_buf_b[mat_cnt]);
                else
                    mat_buf[mat_cnt] <= compute_result_word(mat_buf[mat_cnt]);
            end
            else if (state_cs == S_COMPUTE &&
                    (op_reg == OP_SHA || op_reg == OP_MHA) &&
                    sha_step == 3'd6) begin
                if (batch_id)
                    mat_buf_b[mat_cnt] <= compute_attention_result_word();
                else
                    mat_buf[mat_cnt] <= compute_attention_result_word();
            end
            else if (prefetch_active && rd_valid) begin
                mat_buf_b[prefetch_cnt] <= rd_data;
            end
            else if ((state_cs == S_RD_WAIT || state_cs == S_RD_STREAM) && rd_valid) begin
                if (batch_id)
                    mat_buf_b[mat_cnt] <= rd_data;
                else
                    mat_buf[mat_cnt] <= rd_data;
            end
        end
    end

    // ------------------------------------------------------------------
    // Combinational control path
    // ------------------------------------------------------------------
    always_comb begin : comb_control
        int r, c, k, h, head_start;
        int signed          sum, shifted;
        int unsigned        max_q_abs, max_k_abs, max_v_abs;
        int unsigned        q_shift, k_shift, v_shift;
        logic [RAM_WIDTH-1:0] active_mat_word;
        logic [RAM_WIDTH-1:0] write_mat_word;
        logic                 prefetch_finishing;

        // ---- next-state defaults (hold current) ----
        state_ns        = state_cs;
        op_reg_ns       = op_reg;
        act_reg_ns      = act_reg;
        param_p1_reg_ns = param_p1_reg;
        param_p2_reg_ns = param_p2_reg;
        param_p3_reg_ns = param_p3_reg;
        mat_cnt_ns      = mat_cnt;
        wr_cnt_ns       = wr_cnt;
        batch_id_ns     = batch_id;
        rd_wait_cnt_ns  = rd_wait_cnt;
        sha_step_ns     = sha_step;
        prefetch_active_ns = prefetch_active;
        prefetch_done_ns   = prefetch_done;
        prefetch_cnt_ns    = prefetch_cnt;
        active_mat_word    = batch_id ? mat_buf_b[mat_cnt] : mat_buf[mat_cnt];
        write_mat_word     = batch_id ? mat_buf_b[wr_cnt]  : mat_buf[wr_cnt];
        prefetch_finishing = prefetch_active && rd_valid && (prefetch_cnt == BATCH_LEN - 1);
        for (r = 0; r < 8; r = r + 1)
            for (c = 0; c < 8; c = c + 1) begin
                q_raw_buf_ns[r][c] = q_raw_buf[r][c];
                k_raw_buf_ns[r][c] = k_raw_buf[r][c];
                v_raw_buf_ns[r][c] = v_raw_buf[r][c];
                q_buf_ns[r][c]     = q_buf[r][c];
                k_buf_ns[r][c]     = k_buf[r][c];
                v_buf_ns[r][c]     = v_buf[r][c];
                for (h = 0; h < 2; h = h + 1)
                    score_buf_ns[h][r][c] = score_buf[h][r][c];
            end

        // ---- output defaults (prevent latches) ----
        rd_en    = 1'b0;
        rd_addr  = '0;
        rd_burst = '0;

        wr_en    = 1'b0;
        wr_addr  = '0;
        wr_burst = '0;
        wr_data  = '0;

        out_valid_ns = 1'b0;
        out_data_ns  = 32'd0;

        if (prefetch_active && rd_valid) begin
            if (prefetch_cnt == BATCH_LEN - 1) begin
                prefetch_active_ns = 1'b0;
                prefetch_done_ns   = 1'b1;
                prefetch_cnt_ns    = 7'd0;
            end else begin
                prefetch_cnt_ns = prefetch_cnt + 7'd1;
            end
        end

        case (state_cs)
            // ---- wait for this RAM round to begin ----
            S_IDLE: begin
                batch_id_ns    = 1'b0;
                mat_cnt_ns     = 7'd0;
                wr_cnt_ns      = 7'd0;
                rd_wait_cnt_ns = 6'd0;
                sha_step_ns    = 3'd0;
                prefetch_active_ns = 1'b0;
                prefetch_done_ns   = 1'b0;
                prefetch_cnt_ns    = 7'd0;
                if (mem_set)
                    state_ns = S_RECV_P1;
            end

            // ---- capture op/act/param (1 cycle FFN/Conv, 3 cycles SHA/MHA) ----
            S_RECV_P1: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    op_reg_ns       = op;
                    act_reg_ns      = act;
                    param_p1_reg_ns = param;
                    param_p2_reg_ns = 256'd0;
                    param_p3_reg_ns = 256'd0;
                    batch_id_ns     = 1'b0;
                    mat_cnt_ns      = 7'd0;
                    wr_cnt_ns       = 7'd0;
                    rd_wait_cnt_ns  = 6'd0;
                    sha_step_ns     = 3'd0;
                    prefetch_active_ns = 1'b0;
                    prefetch_done_ns   = 1'b0;
                    prefetch_cnt_ns    = 7'd0;
                    if (op == OP_SHA || op == OP_MHA)
                        state_ns = S_RECV_P2;
                    else
                        state_ns = S_RD_REQ;
                end
            end

            S_RECV_P2: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    param_p2_reg_ns = param;  // W_K
                    state_ns        = S_RECV_P3;
                end
            end

            S_RECV_P3: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    param_p3_reg_ns = param;  // W_V
                    state_ns        = S_RD_REQ;
                end
            end

            // ---- issue burst read request ----
            S_RD_REQ: begin
                rd_addr  = batch_base_addr;
                rd_burst = FULL_BURST;
                if (rd_ready) begin
                    rd_en          = 1'b1;
                    mat_cnt_ns     = 7'd0;
                    rd_wait_cnt_ns = 6'd0;
                    state_ns       = S_RD_WAIT;
                end
            end

            // ---- wait for RAM read latency (50 cycles) ----
            // beat 0 is captured in always_ff when rd_valid first fires here
            S_RD_WAIT: begin
                if (rd_valid) begin
                    mat_cnt_ns = 7'd1;        // beat 0 at mat_buf[0], advance to 1
                    state_ns   = S_RD_STREAM;
                end else if (rd_wait_cnt == READ_WAIT_CYCLES - 1) begin
                    state_ns = S_RD_STREAM;   // rd_valid arrives in S_RD_STREAM
                end else begin
                    rd_wait_cnt_ns = rd_wait_cnt + 6'd1;
                end
            end

            // ---- receive remaining burst beats (indices 1 to 127) ----
            S_RD_STREAM: begin
                if (rd_valid) begin
                    if (mat_cnt == BATCH_LEN - 1) begin
                        mat_cnt_ns  = 7'd0;
                        sha_step_ns = 3'd0;
                        state_ns    = S_COMPUTE;
                    end else begin
                        mat_cnt_ns = mat_cnt + 7'd1;
                    end
                end
            end

            // ---- compute one matrix per cycle; SHA/MHA use 7 sub-steps ----
            S_COMPUTE: begin
                if (op_reg == OP_FFN || op_reg == OP_CONV) begin
                    // FFN/Conv: compute_result_word fires in always_ff this cycle
                    sha_step_ns = 3'd0;
                    if (mat_cnt == BATCH_LEN - 1) begin
                        mat_cnt_ns = 7'd0;
                        wr_cnt_ns  = 7'd0;
                        state_ns   = S_WR_REQ;
                    end else begin
                        mat_cnt_ns = mat_cnt + 7'd1;
                    end
                end else begin
                    // SHA / MHA: 7-step sub-FSM, mat_cnt only advances at step 6
                    case (sha_step)
                        // Step 0: Q = X * W_Q
                        3'd0: begin
                            for (r = 0; r < 8; r = r + 1)
                                for (c = 0; c < 8; c = c + 1)
                                    q_raw_buf_ns[r][c] =
                                        matmul_raw_word(active_mat_word, param_p1_reg, r, c);
                            sha_step_ns = 3'd1;
                        end

                        // Step 1: K = X * W_K
                        3'd1: begin
                            for (r = 0; r < 8; r = r + 1)
                                for (c = 0; c < 8; c = c + 1)
                                    k_raw_buf_ns[r][c] =
                                        matmul_raw_word(active_mat_word, param_p2_reg, r, c);
                            sha_step_ns = 3'd2;
                        end

                        // Step 2: V = X * W_V
                        3'd2: begin
                            for (r = 0; r < 8; r = r + 1)
                                for (c = 0; c < 8; c = c + 1)
                                    v_raw_buf_ns[r][c] =
                                        matmul_raw_word(active_mat_word, param_p3_reg, r, c);
                            sha_step_ns = 3'd3;
                        end

                        // Step 3: PoT quantize Q, K, V simultaneously
                        3'd3: begin
                            max_q_abs = 0;
                            max_k_abs = 0;
                            max_v_abs = 0;
                            for (r = 0; r < 8; r = r + 1)
                                for (c = 0; c < 8; c = c + 1) begin
                                    if (abs_int(q_raw_buf[r][c]) > max_q_abs)
                                        max_q_abs = abs_int(q_raw_buf[r][c]);
                                    if (abs_int(k_raw_buf[r][c]) > max_k_abs)
                                        max_k_abs = abs_int(k_raw_buf[r][c]);
                                    if (abs_int(v_raw_buf[r][c]) > max_v_abs)
                                        max_v_abs = abs_int(v_raw_buf[r][c]);
                                end
                            q_shift = pot_shift(max_q_abs);
                            k_shift = pot_shift(max_k_abs);
                            v_shift = pot_shift(max_v_abs);
                            for (r = 0; r < 8; r = r + 1)
                                for (c = 0; c < 8; c = c + 1) begin
                                    shifted = q_raw_buf[r][c] >>> q_shift;
                                    q_buf_ns[r][c] = clip_s4(shifted);
                                    shifted = k_raw_buf[r][c] >>> k_shift;
                                    k_buf_ns[r][c] = clip_s4(shifted);
                                    shifted = v_raw_buf[r][c] >>> v_shift;
                                    v_buf_ns[r][c] = clip_s4(shifted);
                                end
                            sha_step_ns = 3'd4;
                        end

                        // Step 4: score = Q * K^T  (SHA: 1 head; MHA: 2 heads)
                        3'd4: begin
                            if (op_reg == OP_SHA) begin
                                for (r = 0; r < 8; r = r + 1)
                                    for (c = 0; c < 8; c = c + 1) begin
                                        sum = 0;
                                        // score[r][c] = Q[r][:] . K[c][:] => Q x K^T
                                        for (k = 0; k < 8; k = k + 1)
                                            sum = sum + s4_int(q_buf[r][k])
                                                      * s4_int(k_buf[c][k]);
                                        score_buf_ns[0][r][c] = sum[11:0];
                                        score_buf_ns[1][r][c] = '0;
                                    end
                            end else begin
                                for (h = 0; h < 2; h = h + 1) begin
                                    head_start = h * 4;
                                    for (r = 0; r < 8; r = r + 1)
                                        for (c = 0; c < 8; c = c + 1) begin
                                            sum = 0;
                                            // head h uses Q/K columns head_start..head_start+3
                                            for (k = 0; k < 4; k = k + 1)
                                                sum = sum
                                                    + s4_int(q_buf[r][head_start + k])
                                                    * s4_int(k_buf[c][head_start + k]);
                                            score_buf_ns[h][r][c] = sum[11:0];
                                        end
                                end
                            end
                            sha_step_ns = 3'd5;
                        end

                        // Step 5: partial = fixed_act(score): x<0 -> x>>>2
                        3'd5: begin
                            for (h = 0; h < 2; h = h + 1)
                                for (r = 0; r < 8; r = r + 1)
                                    for (c = 0; c < 8; c = c + 1)
                                        score_buf_ns[h][r][c] =
                                            attention_score_act($signed(score_buf[h][r][c]));
                            sha_step_ns = 3'd6;
                        end

                        // Step 6: attn_ctx = partial * V -> act -> PoT -> pack
                        // compute_attention_result_word() fires in always_ff this cycle
                        3'd6: begin
                            sha_step_ns = 3'd0;
                            if (mat_cnt == BATCH_LEN - 1) begin
                                mat_cnt_ns = 7'd0;
                                wr_cnt_ns  = 7'd0;
                                state_ns   = S_WR_REQ;
                            end else begin
                                mat_cnt_ns = mat_cnt + 7'd1;
                            end
                        end

                        default: sha_step_ns = 3'd0;
                    endcase
                end
            end

            // ---- issue burst write request ----
            S_WR_REQ: begin
                wr_addr  = batch_base_addr;
                wr_burst = FULL_BURST;
                if (!batch_id && !prefetch_active && !prefetch_done && rd_ready) begin
                    rd_addr            = BATCH1_ADDR;
                    rd_burst           = FULL_BURST;
                    rd_en              = 1'b1;
                    prefetch_active_ns = 1'b1;
                    prefetch_done_ns   = 1'b0;
                    prefetch_cnt_ns    = 7'd0;
                end
                if (wr_ready) begin
                    wr_en    = 1'b1;
                    state_ns = S_WR_STREAM;
                end
            end

            // ---- stream 128 write beats; pulse out_valid per beat ----
            S_WR_STREAM: begin
                wr_data = write_mat_word;
                if (!batch_id && !prefetch_active && !prefetch_done && rd_ready) begin
                    rd_addr            = BATCH1_ADDR;
                    rd_burst           = FULL_BURST;
                    rd_en              = 1'b1;
                    prefetch_active_ns = 1'b1;
                    prefetch_done_ns   = 1'b0;
                    prefetch_cnt_ns    = 7'd0;
                end
                if (wr_valid) begin
                    out_valid_ns = 1'b1;
                    out_data_ns  = write_mat_word[31:0];  // last row (row 7)
                    if (wr_cnt == BATCH_LEN - 1) begin
                        wr_cnt_ns = 7'd0;
                        state_ns  = S_BATCH_CHK;
                    end else begin
                        wr_cnt_ns = wr_cnt + 7'd1;
                    end
                end
            end

            // ---- wait until overlapped batch1 read finishes before compute ----
            S_PREFETCH_STREAM: begin
                if (prefetch_done || prefetch_finishing) begin
                    batch_id_ns        = 1'b1;
                    mat_cnt_ns         = 7'd0;
                    wr_cnt_ns          = 7'd0;
                    rd_wait_cnt_ns     = 6'd0;
                    sha_step_ns        = 3'd0;
                    prefetch_active_ns = 1'b0;
                    prefetch_done_ns   = 1'b1;
                    prefetch_cnt_ns    = 7'd0;
                    state_ns           = S_COMPUTE;
                end else if (!prefetch_active) begin
                    batch_id_ns        = 1'b1;
                    mat_cnt_ns         = 7'd0;
                    wr_cnt_ns          = 7'd0;
                    rd_wait_cnt_ns     = 6'd0;
                    sha_step_ns        = 3'd0;
                    prefetch_done_ns   = 1'b0;
                    prefetch_cnt_ns    = 7'd0;
                    state_ns           = S_RD_REQ;
                end
            end

            // ---- after each 128-matrix batch, check if second batch needed ----
            S_BATCH_CHK: begin
                if (!batch_id) begin
                    mat_cnt_ns     = 7'd0;
                    wr_cnt_ns      = 7'd0;
                    rd_wait_cnt_ns = 6'd0;
                    sha_step_ns    = 3'd0;
                    if (prefetch_done || prefetch_finishing) begin
                        batch_id_ns        = 1'b1;
                        prefetch_active_ns = 1'b0;
                        prefetch_done_ns   = 1'b1;
                        prefetch_cnt_ns    = 7'd0;
                        state_ns           = S_COMPUTE;
                    end else if (prefetch_active) begin
                        batch_id_ns = 1'b0;
                        state_ns    = S_PREFETCH_STREAM;
                    end else begin
                        batch_id_ns        = 1'b1;
                        prefetch_active_ns = 1'b0;
                        prefetch_done_ns   = 1'b0;
                        prefetch_cnt_ns    = 7'd0;
                        state_ns           = S_RD_REQ;
                    end
                end else begin
                    batch_id_ns        = 1'b0;
                    prefetch_active_ns = 1'b0;
                    prefetch_done_ns   = 1'b0;
                    prefetch_cnt_ns    = 7'd0;
                    state_ns           = S_OP_DONE;
                end
            end

            // ---- 256 matrices done; wait for next op_set or end of RAM round ----
            S_OP_DONE: begin
                if (mem_set)
                    state_ns = S_RECV_P1;
                else
                    state_ns = S_IDLE;
            end

            default: state_ns = S_IDLE;
        endcase
    end


endmodule
