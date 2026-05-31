module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    // ============================================= //
    //                    PATTERN                    //
    // ============================================= //
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    output logic                            out_valid,
    output logic [31:0]                     out_data,

    // ============================================= //
    //                      RAM                      //
    // ============================================= //
    // READ
    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

    // WRITE
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst,
    output logic [RAM_WIDTH-1:0]            wr_data,
    input  logic                            wr_valid,
    input  logic                            wr_ready
);
    localparam int ADDR_W = $clog2(RAM_DEPTH);
    localparam logic [BURST_BIT-1:0] BURST_4   = 3'd2;
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;
    localparam int MAT_ELEMS = 64;
    localparam int ACC_W = 16;
    localparam int ACC_VEC_W = MAT_ELEMS * ACC_W;
    localparam int SCORE_ELEM_W = 11;
    localparam int SCORE_VEC_W = MAT_ELEMS * SCORE_ELEM_W;
    localparam int MHA_OUT_ELEM_W = 15;
    localparam int MHA_OUT_LANES = 32;
    localparam int MHA_OUT_VEC_W = MHA_OUT_ELEM_W * MHA_OUT_LANES;
    localparam int MULT_CTRL_LATENCY = 4; // u_mult now exposes sum_q directly; no extra registered out_data stage
    localparam int ATT_SHA_FINAL_ISSUE_OFFSET = 8;  // 4 words * first two score-nibble rounds
    localparam int ATT_MHA_FINAL_ISSUE_OFFSET = 20; // head1 nibble-2 word0..3 stays consecutive
    localparam int ACT_IN_PIPE_LATENCY = 1;
    localparam int ACT_LATENCY = 3;
    localparam int ACT_LAST = ACT_LATENCY - 1;
    localparam int POT_IN_PIPE_LATENCY = 0; // u_pot now directly receives pot_in_*; no CA-top POT input register
    localparam int POT_LATENCY = 5;
    localparam int POT_LAST = POT_LATENCY - 1;
    localparam int POT_EXTRA_LATENCY = 2;
    localparam int WR_PRE_LATENCY = MULT_CTRL_LATENCY + ACT_IN_PIPE_LATENCY + POT_IN_PIPE_LATENCY + POT_EXTRA_LATENCY;
    localparam int WR_PRE_LAST = WR_PRE_LATENCY - 1;
    localparam int ATT_WR_PIPE_W = WR_PRE_LATENCY + ATT_MHA_FINAL_ISSUE_OFFSET;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RUN,
        S_ATT_PARAM,
        S_ATT_READ,
        S_ATT_ISSUE_QKV,
        S_ATT_WAIT_QKV,
        S_ATT_ISSUE_SV,
        S_ATT_WAIT_SV,
        S_ATT_ISSUE_FINAL,
        S_ATT_WAIT_FINAL
    } state_t;

    typedef enum logic [2:0] {
        MT_NONE,
        MT_NORM,
        MT_Q,
        MT_K,
        MT_V,
        MT_SCORE,
        MT_VALIGN,
        MT_FINAL
    } mult_tag_t;

    typedef enum logic [2:0] {
        PT_NONE,
        PT_NORM,
        PT_Q,
        PT_K,
        PT_V,
        PT_FINAL
    } pot_tag_t;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic [SCORE_VEC_W-1:0] score_vec_t;
    typedef logic [MHA_OUT_VEC_W-1:0] mha_vec_t;

    state_t              state_q;
    logic [1:0]          op_q;
    logic [1:0]          act_q;
    logic [255:0]        param1_q;
    logic [255:0]        param2_q;
    logic [255:0]        param3_q;
    logic [1:0]          att_param_cnt_q;
    logic [1:0]          rd_req_cnt_q;
    logic [8:0]          rd_word_cnt_q;
    logic [8:0]          wr_cmd_cnt_q;
    logic [7:0]          out_cnt_q;
    logic [WR_PRE_LATENCY-1:0] wr_pre_pipe_q;

    logic [255:0]        x_buf_q      [0:3];
    logic [255:0]        q_buf_q      [0:3];
    logic [255:0]        k_buf_q      [0:3];
    logic [255:0]        v_buf_q      [0:3];
    score_vec_t          score_buf_q  [0:7];
    logic [255:0]        valign_buf_q [0:3];
    logic [3:0]          q_ready_q;
    logic [3:0]          k_ready_q;
    logic [3:0]          v_ready_q;
    logic [7:0]          score_ready_q;
    logic [3:0]          valign_ready_q;
    logic [7:0]          att_group_base_q;
    logic [3:0]          att_issue_cnt_q;
    logic [2:0]          att_sv_issue_cnt_q;
    logic [4:0]          att_final_issue_cnt_q;
    logic [1:0]          att_final_recv_cnt_q;
    logic [ATT_WR_PIPE_W-1:0] att_wr_pipe_q;
    logic                att_prefetch_req_q;
    logic                att_prefetch_ready_q;
    logic [1:0]          att_prefetch_cnt_q;

    logic                mult_issue_valid;
    logic [1:0]          mult_issue_op;
    logic                mult_issue_b_transpose;
    logic                mult_issue_a_wide;
    logic                mult_issue_head_mask;
    logic                mult_issue_head_sel;
    logic [255:0]        mult_issue_A;
    score_vec_t          mult_issue_A_wide;
    logic [255:0]        mult_issue_B;
    mult_tag_t           mult_issue_tag;
    logic [2:0]          mult_issue_idx;
    logic [1:0]          mult_issue_wide_nib;
    logic                mult_valid;
    acc_vec_t            mult_data;
    mult_tag_t           mult_out_tag;
    logic [2:0]          mult_out_idx;

    logic                act_in_valid;
    acc_vec_t            act_in_data;
    pot_tag_t            act_in_tag;
    logic [1:0]          act_in_idx;
    logic                act_valid;
    acc_vec_t            act_data;
    logic [2:0]          act_out_tag;
    logic [1:0]          act_out_idx;

    logic                pot_in_valid;
    acc_vec_t            pot_in_data;
    pot_tag_t            pot_in_tag;
    logic [1:0]          pot_in_idx;
    logic                pot_valid;
    logic [255:0]        pot_data;
    logic [2:0]          pot_out_tag;
    logic [1:0]          pot_out_idx;
    logic                wr_pre_fire;
    logic                att_wr_fire;
    logic                att_final_start;
    logic                mha_comb_valid;
    acc_vec_t            mha_comb_data;
    mha_vec_t            mha_head0_data;

    assign wr_pre_fire    = wr_pre_pipe_q[WR_PRE_LAST];
    assign att_final_start = (state_q == S_ATT_ISSUE_FINAL) && (att_final_issue_cnt_q == 3'd0);
    assign att_wr_fire    = (op_q == 2'b11) ? att_wr_pipe_q[WR_PRE_LAST + ATT_MHA_FINAL_ISSUE_OFFSET] :
                                                att_wr_pipe_q[WR_PRE_LAST + ATT_SHA_FINAL_ISSUE_OFFSET];

    function automatic logic [255:0] identity_matrix();
        begin
            identity_matrix = 256'd0;
            for (int i = 0; i < 8; i++) begin
                identity_matrix[255 - (((i * 8) + i) * 4) -: 4] = 4'sd1;
            end
        end
    endfunction

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic s4_t clamp_s4(input acc_t value);
        begin
            if (value > acc_t'(7)) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < acc_t'(-8)) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic acc_t att_act_value(input acc_t value);
        begin
            att_act_value = (value < 0) ? (value >>> 2) : value;
        end
    endfunction

    function automatic logic [255:0] pack_s4(input acc_vec_t src_data);
        begin
            pack_s4 = 256'd0;
            for (int i = 0; i < MAT_ELEMS; i++) begin
                pack_s4[255 - (i * 4) -: 4] = clamp_s4(get_acc(src_data, i));
            end
        end
    endfunction

    function automatic score_vec_t pack_attention_score(input acc_vec_t src_data);
        acc_t act_score;
        begin
            pack_attention_score = '0;
            for (int i = 0; i < MAT_ELEMS; i++) begin
                act_score = att_act_value(get_acc(src_data, i));
                // Score after Q*K^T and attention activation fits in signed 11-bit.
                // Store only bits [10:0] and recover the sign in the final 3-pass path.
                pack_attention_score[SCORE_VEC_W - 1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W] =
                    act_score[SCORE_ELEM_W-1:0];
            end
        end
    endfunction

    function automatic logic [1:0] mha_final_word(input logic [4:0] cnt);
        begin
            case (cnt)
                5'd0,  5'd1,  5'd2,
                5'd12, 5'd16, 5'd20: mha_final_word = 2'd0;
                5'd3,  5'd4,  5'd5,
                5'd13, 5'd17, 5'd21: mha_final_word = 2'd1;
                5'd6,  5'd7,  5'd8,
                5'd14, 5'd18, 5'd22: mha_final_word = 2'd2;
                default:              mha_final_word = 2'd3;
            endcase
        end
    endfunction

    function automatic logic [1:0] mha_final_nib(input logic [4:0] cnt);
        begin
            case (cnt)
                5'd0, 5'd3, 5'd6, 5'd9,
                5'd12, 5'd13, 5'd14, 5'd15: mha_final_nib = 2'd0;
                5'd1, 5'd4, 5'd7, 5'd10,
                5'd16, 5'd17, 5'd18, 5'd19: mha_final_nib = 2'd1;
                default:                     mha_final_nib = 2'd2;
            endcase
        end
    endfunction

    function automatic logic mha_final_head(input logic [4:0] cnt);
        mha_final_head = cnt[4] || (cnt[3] && cnt[2]);
    endfunction

    function automatic mha_vec_t pack_mha_head0(input acc_vec_t src_data);
        integer full_idx;
        acc_t lane;
        begin
            pack_mha_head0 = '0;
            for (int s = 0; s < MHA_OUT_LANES; s++) begin
                full_idx = ((s / 4) * 8) + (s % 4); // row s/4, col 0..3 only
                lane = get_acc(src_data, full_idx);
                pack_mha_head0[MHA_OUT_VEC_W - 1 - (s * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W] =
                    lane[MHA_OUT_ELEM_W-1:0];
            end
        end
    endfunction

    function automatic acc_vec_t combine_mha_heads(
        input mha_vec_t head0,
        input acc_vec_t head1
    );
        logic [MHA_OUT_ELEM_W-1:0] h0_lane;
        integer s;
        begin
            combine_mha_heads = '0;
            for (int i = 0; i < MAT_ELEMS; i++) begin
                if ((i % 8) < 4) begin
                    s = (i / 8) * 4 + (i % 4);
                    h0_lane = head0[MHA_OUT_VEC_W - 1 - (s * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W];
                    combine_mha_heads[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] =
                        {{(ACC_W-MHA_OUT_ELEM_W){h0_lane[MHA_OUT_ELEM_W-1]}}, h0_lane};
                end
                else begin
                    combine_mha_heads[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] =
                        head1[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W];
                end
            end
        end
    endfunction

    always_comb begin
        mult_issue_valid       = 1'b0;
        mult_issue_op          = 2'b00;
        mult_issue_b_transpose = 1'b0;
        mult_issue_a_wide      = 1'b0;
        mult_issue_head_mask   = 1'b0;
        mult_issue_head_sel    = 1'b0;
        mult_issue_A           = 256'd0;
        mult_issue_A_wide      = '0;
        mult_issue_B           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_idx         = 3'd0;
        mult_issue_wide_nib    = 2'd0;

        case (state_q)
            S_RUN: begin
                if (rd_valid && (rd_word_cnt_q < 9'd256)) begin
                    mult_issue_valid = 1'b1;
                    mult_issue_op    = op_q;
                    mult_issue_A     = rd_data;
                    mult_issue_B     = param1_q;
                    mult_issue_tag   = MT_NORM;
                end
            end

            S_ATT_ISSUE_QKV: begin
                mult_issue_valid = 1'b1;
                mult_issue_idx   = att_issue_cnt_q / 3;
                mult_issue_A     = x_buf_q[mult_issue_idx];

                case (att_issue_cnt_q % 3)
                    0: begin
                        mult_issue_B   = param1_q;
                        mult_issue_tag = MT_Q;
                    end
                    1: begin
                        mult_issue_B   = param2_q;
                        mult_issue_tag = MT_K;
                    end
                    default: begin
                        mult_issue_B   = param3_q;
                        mult_issue_tag = MT_V;
                    end
                endcase
            end

            S_ATT_ISSUE_SV: begin
                mult_issue_valid = 1'b1;

                if (op_q == 2'b11) begin
                    mult_issue_idx         = {att_sv_issue_cnt_q[2], att_sv_issue_cnt_q[1:0]};
                    mult_issue_A           = q_buf_q[att_sv_issue_cnt_q[1:0]];
                    mult_issue_B           = k_buf_q[att_sv_issue_cnt_q[1:0]];
                    mult_issue_b_transpose = 1'b1;
                    mult_issue_head_mask   = 1'b1;
                    mult_issue_head_sel    = att_sv_issue_cnt_q[2];
                    mult_issue_tag         = MT_SCORE;
                end
                else begin
                    mult_issue_idx = {1'b0, att_sv_issue_cnt_q[2:1]};

                    if (!att_sv_issue_cnt_q[0]) begin
                        mult_issue_A           = q_buf_q[att_sv_issue_cnt_q[2:1]];
                        mult_issue_B           = k_buf_q[att_sv_issue_cnt_q[2:1]];
                        mult_issue_b_transpose = 1'b1;
                        mult_issue_tag         = MT_SCORE;
                    end
                    else begin
                        mult_issue_A   = v_buf_q[att_sv_issue_cnt_q[2:1]];
                        mult_issue_B   = identity_matrix();
                        mult_issue_tag = MT_VALIGN;
                    end
                end
            end

            S_ATT_ISSUE_FINAL: begin
                mult_issue_valid = 1'b1;
                mult_issue_a_wide = 1'b1;
                mult_issue_tag    = MT_FINAL;

                if (op_q == 2'b11) begin
                    // Head0 finishes one word at a time; head1 keeps nibble-2
                    // word0..3 consecutive for the existing burst-write timing.
                    mult_issue_wide_nib = mha_final_nib(att_final_issue_cnt_q);
                    mult_issue_idx      = {mha_final_head(att_final_issue_cnt_q),
                                           mha_final_word(att_final_issue_cnt_q)};
                    mult_issue_A_wide   = score_buf_q[mult_issue_idx];
                    mult_issue_B        = v_buf_q[mult_issue_idx[1:0]];
                end
                else begin
                    // SHA final uses 4 words per nibble round:
                    //   cnt 0..3   : nibble 0 for word0..3
                    //   cnt 4..7   : nibble 1 for word0..3
                    //   cnt 8..11  : nibble 2 for word0..3
                    mult_issue_wide_nib = att_final_issue_cnt_q[3:2];
                    mult_issue_idx      = {1'b0, att_final_issue_cnt_q[1:0]};
                    mult_issue_A_wide   = score_buf_q[mult_issue_idx];
                    mult_issue_B        = valign_buf_q[mult_issue_idx[1:0]];
                end
            end

            default: begin
            end
        endcase
    end

    // u_mult now accumulates Score*V nibble partials internally and only asserts
    // MT_FINAL on the completed nibble-2 result.  The CA top no longer needs a
    // full 8-entry final_acc_buf_q scratchpad.
    assign mha_comb_valid = mult_valid && (mult_out_tag == MT_FINAL) &&
                            (op_q == 2'b11) && mult_out_idx[2];
    assign mha_comb_data  = combine_mha_heads({q_buf_q[mult_out_idx[1:0]],
                                               k_buf_q[mult_out_idx[1:0]][255:32]},
                                              mult_data);
    assign mha_head0_data = pack_mha_head0(mult_data);

    assign act_in_valid = mha_comb_valid ||
                          (mult_valid && (mult_out_tag == MT_NORM)) ||
                          (mult_valid && (mult_out_tag == MT_FINAL) && (op_q != 2'b11));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = (mult_valid && (mult_out_tag == MT_FINAL)) ? mult_out_idx[1:0] : 2'd0;

    always_comb begin
        case (mult_out_tag)
            MT_NORM:  act_in_tag = PT_NORM;
            MT_FINAL: act_in_tag = (mult_valid && (mult_out_tag == MT_FINAL)) ? PT_FINAL : PT_NONE;
            default:  act_in_tag = PT_NONE;
        endcase
    end

    assign pot_in_valid = act_valid ||
                          (mult_valid && ((mult_out_tag == MT_Q) ||
                                          (mult_out_tag == MT_K) ||
                                          (mult_out_tag == MT_V)));
    assign pot_in_data  = act_valid ? act_data : mult_data;
    assign pot_in_idx   = act_valid ? act_out_idx : mult_out_idx[1:0];

    always_comb begin
        pot_in_tag = PT_NONE;

        if (act_valid) begin
            // ACT stage now owns tag/index alignment internally, so the CA top
            // forwards the aligned ACT output tag directly into POT.
            pot_in_tag = pot_tag_t'(act_out_tag);
        end
        else begin
            case (mult_out_tag)
                MT_Q: pot_in_tag = PT_Q;
                MT_K: pot_in_tag = PT_K;
                MT_V: pot_in_tag = PT_V;
                default: pot_in_tag = PT_NONE;
            endcase
        end
    end

    mult_4x4_shared_score3 #(
        .ACC_W       (ACC_W),
        .MAT_SIZE    (MAT_ELEMS),
        .SCORE_ELEM_W(SCORE_ELEM_W)
    ) u_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (mult_issue_op),
        .b_transpose (mult_issue_b_transpose),
        .a_wide      (mult_issue_a_wide),
        .head_mask   (mult_issue_head_mask),
        .head_sel    (mult_issue_head_sel),
        .in_valid    (mult_issue_valid),
        .in_data_A   (mult_issue_A),
        .in_data_A_wide(mult_issue_A_wide),
        .in_data_B   (mult_issue_B),
        .in_tag      (mult_issue_valid ? mult_issue_tag : MT_NONE),
        .in_idx      (mult_issue_idx),
        .in_wide_nib (mult_issue_wide_nib),
        .out_valid   (mult_valid),
        .out_data    (mult_data),
        .out_tag     (mult_out_tag),
        .out_idx     (mult_out_idx)
    );

    act_2stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act_q),
        .in_data   (act_in_data),
        .in_tag    (act_in_tag),
        .in_idx    (act_in_idx),
        .out_valid (act_valid),
        .out_data  (act_data),
        .out_tag   (act_out_tag),
        .out_idx   (act_out_idx)
    );

    pot_3stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),
        .in_data   (pot_in_data),
        .in_tag    (pot_in_tag),
        .in_idx    (pot_in_idx),
        .out_valid (pot_valid),
        .out_data  (pot_data),
        .out_tag   (pot_out_tag),
        .out_idx   (pot_out_idx)
    );


    // ==============================================================
    // Control-path sequential registers
    // - FSM, RAM protocol, output valid/data, counters, ready flags,
    //   and attention scratch buffers.
    // ==============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ==========================================================
            // Output / RAM interface registers
            // ==========================================================
            rd_en                 <= 1'b0;
            rd_addr               <= '0;
            rd_burst              <= '0;
            wr_en                 <= 1'b0;
            wr_addr               <= '0;
            wr_burst              <= '0;
            wr_data               <= 256'd0;
            out_valid             <= 1'b0;
            out_data              <= 32'd0;

            // ==========================================================
            // Top-level FSM / operation control
            // ==========================================================
            state_q               <= S_IDLE;
            op_q                  <= 2'd0;
            act_q                 <= 2'd0;
            att_param_cnt_q       <= 2'd0;

            // ==========================================================
            // Normal read / write / output counters
            // ==========================================================
            rd_req_cnt_q          <= 2'd0;
            rd_word_cnt_q         <= 9'd0;
            wr_cmd_cnt_q          <= 9'd0;
            out_cnt_q             <= 8'd0;
            wr_pre_pipe_q         <= '0;

            // ==========================================================
            // Attention control counters / flags
            // ==========================================================
            q_ready_q             <= 4'd0;
            k_ready_q             <= 4'd0;
            v_ready_q             <= 4'd0;
            score_ready_q         <= 8'd0;
            valign_ready_q        <= 4'd0;
            att_group_base_q      <= 8'd0;
            att_issue_cnt_q       <= 4'd0;
            att_sv_issue_cnt_q    <= 3'd0;
            att_final_issue_cnt_q <= 5'd0;
            att_final_recv_cnt_q  <= 2'd0;
            att_wr_pipe_q         <= '0;
            att_prefetch_req_q    <= 1'b0;
            att_prefetch_ready_q  <= 1'b0;
            att_prefetch_cnt_q    <= 2'd0;

        end
        else begin
            rd_en     <= 1'b0;
            wr_en     <= 1'b0;
            out_valid <= 1'b0;
            rd_burst  <= '0;
            wr_burst  <= '0;

            att_wr_pipe_q <= {att_wr_pipe_q[ATT_WR_PIPE_W-2:0], att_final_start};

            if (att_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= att_group_base_q[ADDR_W-1:0];
                wr_burst <= BURST_4;
            end

            if ((state_q != S_IDLE) && (state_q != S_RUN) &&
                (state_q != S_ATT_PARAM) && (state_q != S_ATT_READ) &&
                (att_group_base_q != 8'd252) &&
                !att_prefetch_req_q && !att_prefetch_ready_q && rd_ready) begin
                rd_en                <= 1'b1;
                rd_addr              <= att_group_base_q[ADDR_W-1:0] + 8'd4;
                rd_burst             <= BURST_4;
                att_prefetch_req_q   <= 1'b1;
                att_prefetch_cnt_q   <= 2'd0;
            end

            if (rd_valid && att_prefetch_req_q) begin
                x_buf_q[att_prefetch_cnt_q[1:0]] <= rd_data;

                if (att_prefetch_cnt_q == 2'd3) begin
                    att_prefetch_req_q   <= 1'b0;
                    att_prefetch_ready_q <= 1'b1;
                end
                else begin
                    att_prefetch_cnt_q <= att_prefetch_cnt_q + 1'b1;
                end
            end
            if (pot_valid) begin
                case (pot_out_tag)
                    PT_NORM: begin
                        wr_data   <= pot_data;
                        out_valid <= 1'b1;
                        out_data  <= pot_data[31:0];

                        if (out_cnt_q == 8'd255) begin
                            state_q <= S_IDLE;
                        end
                        else begin
                            out_cnt_q <= out_cnt_q + 1'b1;
                        end
                    end
                    PT_Q: begin
                        q_buf_q[pot_out_idx[1:0]] <= pot_data;
                        q_ready_q[pot_out_idx[1:0]] <= 1'b1;
                    end
                    PT_K: begin
                        k_buf_q[pot_out_idx[1:0]] <= pot_data;
                        k_ready_q[pot_out_idx[1:0]] <= 1'b1;
                    end
                    PT_V: begin
                        v_buf_q[pot_out_idx[1:0]] <= pot_data;
                        v_ready_q[pot_out_idx[1:0]] <= 1'b1;
                    end
                    PT_FINAL: begin
                        wr_data   <= pot_data;
                        out_valid <= 1'b1;
                        out_data  <= pot_data[31:0];
                        att_final_recv_cnt_q <= att_final_recv_cnt_q + 1'b1;
                    end
                    default: begin
                    end
                endcase
            end

            if (mult_valid) begin
                case (mult_out_tag)
                    MT_SCORE: begin
                        score_buf_q[mult_out_idx] <= pack_attention_score(mult_data);
                        score_ready_q[mult_out_idx] <= 1'b1;
                    end
                    MT_VALIGN: begin
                        valign_buf_q[mult_out_idx[1:0]] <= pack_s4(mult_data);
                        valign_ready_q[mult_out_idx[1:0]] <= 1'b1;
                    end
                    MT_FINAL: begin
                        // MT_FINAL is visible only after u_mult has accumulated
                        // score nibble 0/1/2.  For MHA, keep only the head0
                        // columns that survive the final head-combine step.
                        // Q/K storage is dead by this point, so reuse it for
                        // the 480-bit head0 scratch instead of a separate buffer.
                        if ((op_q == 2'b11) && !mult_out_idx[2]) begin
                            q_buf_q[mult_out_idx[1:0]] <=
                                mha_head0_data[MHA_OUT_VEC_W - 1 -: 256];
                            k_buf_q[mult_out_idx[1:0]] <=
                                {mha_head0_data[MHA_OUT_VEC_W - 257:0], 32'd0};
                        end
                    end
                    default: begin
                    end
                endcase
            end

            case (state_q)
                S_IDLE: begin
                    if (mem_set && in_valid) begin
                        op_q    <= op;
                        act_q   <= act;
                        param1_q <= param;

                        if ((op == 2'b00) || (op == 2'b01)) begin
                            rd_req_cnt_q  <= 2'd0;
                            rd_word_cnt_q <= 9'd0;
                            wr_cmd_cnt_q  <= 9'd0;
                            out_cnt_q     <= 8'd0;
                            wr_pre_pipe_q <= '0;
                            att_prefetch_req_q   <= 1'b0;
                            att_prefetch_ready_q <= 1'b0;
                            att_prefetch_cnt_q   <= 2'd0;
                            state_q       <= S_RUN;
                        end
                        else begin
                            att_param_cnt_q <= 2'd1;
                            att_prefetch_req_q   <= 1'b0;
                            att_prefetch_ready_q <= 1'b0;
                            att_prefetch_cnt_q   <= 2'd0;
                            state_q         <= S_ATT_PARAM;
                        end
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (att_param_cnt_q == 2'd1) begin
                            param2_q        <= param;
                            att_param_cnt_q <= 2'd2;
                        end
                        else begin
                            param3_q         <= param;
                            att_group_base_q <= 8'd0;
                            rd_req_cnt_q     <= 2'd0;
                            rd_word_cnt_q    <= 9'd0;
                            out_cnt_q        <= 8'd0;
                            att_wr_pipe_q    <= '0;
                            att_prefetch_req_q   <= 1'b0;
                            att_prefetch_ready_q <= 1'b0;
                            att_prefetch_cnt_q   <= 2'd0;
                            state_q          <= S_ATT_READ;
                        end
                    end
                end

                S_RUN: begin
                    wr_burst <= BURST_128;
                    wr_pre_pipe_q <= {wr_pre_pipe_q[WR_PRE_LATENCY-2:0], mult_issue_valid};

                    if ((rd_req_cnt_q < 2'd2) && rd_ready) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
                        rd_burst     <= BURST_128;
                        rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
                    end

                    if (mult_issue_valid) begin
                        rd_word_cnt_q <= rd_word_cnt_q + 1'b1;
                    end

                    if (wr_pre_fire) begin
                        if (wr_cmd_cnt_q[6:0] == 7'd0) begin
                            wr_en    <= 1'b1;
                            wr_addr  <= wr_cmd_cnt_q[ADDR_W-1:0];
                            wr_burst <= BURST_128;
                        end

                        wr_cmd_cnt_q <= wr_cmd_cnt_q + 1'b1;
                    end
                end

                S_ATT_READ: begin
                    if (att_prefetch_ready_q) begin
                        q_ready_q             <= 4'd0;
                        k_ready_q             <= 4'd0;
                        v_ready_q             <= 4'd0;
                        score_ready_q         <= 8'd0;
                        valign_ready_q        <= 4'd0;
                        att_issue_cnt_q       <= 4'd0;
                        rd_req_cnt_q          <= 2'd1;
                        rd_word_cnt_q         <= 9'd4;
                        att_prefetch_ready_q  <= 1'b0;
                        att_prefetch_cnt_q    <= 2'd0;
                        state_q               <= S_ATT_ISSUE_QKV;
                    end
                    else if ((rd_req_cnt_q == 2'd0) && !att_prefetch_req_q && rd_ready) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= att_group_base_q[ADDR_W-1:0];
                        rd_burst     <= BURST_4;
                        rd_req_cnt_q <= 2'd1;
                    end

                    if (rd_valid && (rd_word_cnt_q < 9'd4)) begin
                        x_buf_q[rd_word_cnt_q[1:0]] <= rd_data;
                        rd_word_cnt_q <= rd_word_cnt_q + 1'b1;

                        if (rd_word_cnt_q == 9'd3) begin
                            q_ready_q          <= 4'd0;
                            k_ready_q          <= 4'd0;
                            v_ready_q          <= 4'd0;
                            score_ready_q      <= 8'd0;
                            valign_ready_q     <= 4'd0;
                            att_issue_cnt_q    <= 4'd0;
                            state_q            <= S_ATT_ISSUE_QKV;
                            if ((att_group_base_q != 8'd252) &&
                                !att_prefetch_req_q && !att_prefetch_ready_q && rd_ready) begin
                                rd_en              <= 1'b1;
                                rd_addr            <= att_group_base_q[ADDR_W-1:0] + 8'd4;
                                rd_burst           <= BURST_4;
                                att_prefetch_req_q <= 1'b1;
                                att_prefetch_cnt_q <= 2'd0;
                            end
                        end
                    end
                end

                S_ATT_ISSUE_QKV: begin
                    if (att_issue_cnt_q == 4'd11) begin
                        state_q <= S_ATT_WAIT_QKV;
                    end
                    else begin
                        att_issue_cnt_q <= att_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_QKV: begin
                    if (&q_ready_q && &k_ready_q && &v_ready_q) begin
                        score_ready_q      <= 8'd0;
                        valign_ready_q     <= 4'd0;
                        att_sv_issue_cnt_q <= 3'd0;
                        state_q            <= S_ATT_ISSUE_SV;
                    end
                end

                S_ATT_ISSUE_SV: begin
                    if (att_sv_issue_cnt_q == 3'd7) begin
                        state_q <= S_ATT_WAIT_SV;
                    end
                    else begin
                        att_sv_issue_cnt_q <= att_sv_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_SV: begin
                    if (((op_q == 2'b11) && (&score_ready_q)) ||
                        ((op_q != 2'b11) && (&score_ready_q[3:0]) && (&valign_ready_q))) begin
                        att_final_issue_cnt_q <= 5'd0;
                        att_final_recv_cnt_q  <= 2'd0;
                        att_wr_pipe_q         <= '0;
                        state_q               <= S_ATT_ISSUE_FINAL;
                    end
                end

                S_ATT_ISSUE_FINAL: begin
                    if (((op_q == 2'b11) && (att_final_issue_cnt_q == 5'd23)) ||
                        ((op_q != 2'b11) && (att_final_issue_cnt_q == 5'd11))) begin
                        state_q <= S_ATT_WAIT_FINAL;
                    end
                    else begin
                        att_final_issue_cnt_q <= att_final_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_FINAL: begin
                    if (pot_valid && (pot_out_tag == PT_FINAL) &&
                        (att_final_recv_cnt_q == 2'd3)) begin
                        if (att_group_base_q == 8'd252) begin
                            state_q <= S_IDLE;
                        end
                        else begin
                            att_group_base_q <= att_group_base_q + 8'd4;
                            if (att_prefetch_ready_q) begin
                                q_ready_q             <= 4'd0;
                                k_ready_q             <= 4'd0;
                                v_ready_q             <= 4'd0;
                                score_ready_q         <= 8'd0;
                                valign_ready_q        <= 4'd0;
                                att_issue_cnt_q       <= 4'd0;
                                rd_req_cnt_q          <= 2'd1;
                                rd_word_cnt_q         <= 9'd4;
                                att_prefetch_ready_q  <= 1'b0;
                                att_prefetch_cnt_q    <= 2'd0;
                                state_q               <= S_ATT_ISSUE_QKV;
                            end
                            else begin
                                rd_req_cnt_q  <= att_prefetch_req_q ? 2'd1 : 2'd0;
                                rd_word_cnt_q <= att_prefetch_req_q ? 9'd4 : 9'd0;
                                state_q       <= S_ATT_READ;
                            end
                        end
                    end
                end

                default: begin
                    state_q <= S_IDLE;
                end
            endcase
        end
    end

endmodule



module mult_4x4_shared_score3 #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 11
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic                 b_transpose,
    input  logic                 a_wide,
    input  logic                 head_mask,
    input  logic                 head_sel,
    input  logic                 in_valid,
    input  logic [255:0]         in_data_A,
    input  logic [(MAT_SIZE*SCORE_ELEM_W)-1:0] in_data_A_wide,
    input  logic [255:0]         in_data_B,
    input  logic [2:0]           in_tag,
    input  logic [2:0]           in_idx,
    input  logic [1:0]           in_wide_nib,
    output logic                 out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data,
    output logic [2:0]           out_tag,
    output logic [2:0]           out_idx
);

    localparam int ROW_ELEM = 8;
    localparam int DOT_SIZE = 9;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SCORE_VEC_W = MAT_SIZE * SCORE_ELEM_W;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [4:0]  s5_t;
    typedef logic signed [8:0]  prod_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic [SCORE_VEC_W-1:0] score_vec_t;

    // Area-optimized shared 4x4 datapath.
    // Compared with the previous version, this removes:
    //   1. 64*9 operand registers a_sel_q / b_sel_q
    //   2. 64*9 unsigned-correction registers
    //   3. 64*3 partial-sum registers
    // and keeps only:
    //   input matrix/control buffer -> 9-bit products -> one 16-bit sum per lane.
    //
    // Pipeline:
    //   issue cycle
    //   +1 input buffer visible to product logic
    //   +2 product registers
    //   +3 lane sum registers / externally visible output
    // The old full 1024-bit out_data register is removed.  out_data is now
    // combinationally packed from sum_q or from the internal Score*V accumulator.
    logic         buf_valid_q;
    logic         prod_valid_q;
    logic         sum_valid_q;

    logic [1:0]   op_q;
    logic         b_transpose_q;
    logic         a_wide_q;
    logic         head_mask_q;
    logic         head_sel_q;
    logic [255:0] in_data_A_q;
    score_vec_t   in_data_A_wide_q;
    logic [255:0] in_data_B_q;

    logic [2:0] tag0_q, tag1_q;
    logic [2:0] idx0_q, idx1_q;
    logic [1:0] nib0_q, nib1_q;
    logic       wide0_q, wide1_q;

    prod_t prod_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    acc_t  sum_q  [0:MAT_SIZE-1];
    acc_vec_t scorev_acc_q [0:3];
    logic out_wide_q;
    logic [1:0] out_wide_nib;

    prod_t prod_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    acc_t  sum_next  [0:MAT_SIZE-1];
    acc_vec_t sum_shifted_q;
    acc_vec_t out_data_comb;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic s4_t get_pad_s4(input logic [255:0] vec, input integer row, input integer col);
        if ((row < 0) || (row >= ROW_ELEM) || (col < 0) || (col >= ROW_ELEM)) begin
            get_pad_s4 = 4'sd0;
        end
        else begin
            get_pad_s4 = get_s4(vec, (row * ROW_ELEM) + col);
        end
    endfunction

    function automatic s5_t sel_a5(
        input logic [255:0] mat_A,
        input score_vec_t   score_mat,
        input logic [1:0]   op_sel,
        input logic         wide_sel,
        input logic [1:0]   nib_sel,
        input logic         head_mask_sel,
        input logic         head_sel_sel,
        input integer       out_idx,
        input integer       tap
    );
        integer row;
        integer col;
        logic [SCORE_ELEM_W-1:0] score11;
        logic [3:0] raw4;
        begin
            row = out_idx / ROW_ELEM;
            col = out_idx % ROW_ELEM;

            if (wide_sel) begin
                if (tap == 8) begin
                    sel_a5 = 5'sd0;
                end
                else begin
                    score11 = score_mat[SCORE_VEC_W - 1 - (((row * ROW_ELEM) + tap) * SCORE_ELEM_W) -: SCORE_ELEM_W];
                    case (nib_sel)
                        // Low/middle nibbles of two's-complement score are unsigned.
                        2'd0: begin
                            raw4   = score11[3:0];
                            sel_a5 = {1'b0, raw4};
                        end
                        2'd1: begin
                            raw4   = score11[7:4];
                            sel_a5 = {1'b0, raw4};
                        end
                        // High group is score[10:8], sign-extended to a 4-bit signed nibble.
                        default: begin
                            raw4   = {score11[10], score11[10:8]};
                            sel_a5 = s5_t'($signed(raw4));
                        end
                    endcase
                end
            end
            else if (op_sel == 2'b01) begin
                sel_a5 = s5_t'(get_pad_s4(mat_A, row + (tap / 3) - 1, col + (tap % 3) - 1));
            end
            else if (tap == 8) begin
                sel_a5 = 5'sd0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_a5 = 5'sd0;
            end
            else begin
                sel_a5 = s5_t'(get_s4(mat_A, (row * ROW_ELEM) + tap));
            end
        end
    endfunction

    function automatic s4_t sel_b4(
        input logic [255:0] mat_B,
        input logic [1:0]   op_sel,
        input logic         wide_sel,
        input logic         b_transpose_sel,
        input logic         head_mask_sel,
        input logic         head_sel_sel,
        input integer       lane,
        input integer       tap
    );
        begin
            if (op_sel == 2'b01) begin
                sel_b4 = get_s4(mat_B, tap);
            end
            else if (tap == 8) begin
                sel_b4 = 4'sd0;
            end
            else if (!wide_sel && head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_b4 = 4'sd0;
            end
            else if (!wide_sel && b_transpose_sel) begin
                sel_b4 = get_s4(mat_B, (lane * ROW_ELEM) + tap);
            end
            else begin
                sel_b4 = get_s4(mat_B, (tap * ROW_ELEM) + lane);
            end
        end
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_next[(row * ROW_ELEM) + lane][tap] = prod_t'(
                        $signed(sel_a5(in_data_A_q, in_data_A_wide_q, op_q, a_wide_q,
                                       nib0_q, head_mask_q, head_sel_q,
                                       (row * ROW_ELEM) + lane, tap)) *
                        $signed(sel_b4(in_data_B_q, op_q, a_wide_q, b_transpose_q,
                                       head_mask_q, head_sel_q, lane, tap)));
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_next[i] =
                (acc_t'(prod_q[i][0]) + acc_t'(prod_q[i][1]) +
                 acc_t'(prod_q[i][2]) + acc_t'(prod_q[i][3])) +
                (acc_t'(prod_q[i][4]) + acc_t'(prod_q[i][5]) +
                 acc_t'(prod_q[i][6]) + acc_t'(prod_q[i][7]) +
                 acc_t'(prod_q[i][8]));
        end
    end
    function automatic acc_vec_t pack_sum_shift(
        input acc_t lanes [0:MAT_SIZE-1],
        input logic [1:0] nib_sel,
        input logic       wide_sel
    );
        begin
            pack_sum_shift = '0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                if (wide_sel) begin
                    case (nib_sel)
                        2'd0: pack_sum_shift[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = lanes[i];
                        2'd1: pack_sum_shift[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = acc_t'(lanes[i] <<< 4);
                        default: pack_sum_shift[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = acc_t'(lanes[i] <<< 8);
                    endcase
                end
                else begin
                    pack_sum_shift[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = lanes[i];
                end
            end
        end
    endfunction

    function automatic acc_vec_t add_vec(input acc_vec_t lhs, input acc_vec_t rhs);
        acc_t a;
        acc_t b;
        begin
            add_vec = '0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                a = $signed(lhs[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W]);
                b = $signed(rhs[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W]);
                add_vec[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = acc_t'(a + b);
            end
        end
    endfunction

    always_comb begin
        sum_shifted_q = pack_sum_shift(sum_q, out_wide_nib, out_wide_q);
    end

    always_comb begin
        if (out_wide_q && (out_wide_nib == 2'd2)) begin
            out_data_comb = add_vec(scorev_acc_q[out_idx[1:0]],
                                    sum_shifted_q);
        end
        else begin
            out_data_comb = sum_shifted_q;
        end
    end

    always_comb begin
        out_data = out_data_comb;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid_q  <= 1'b0;
            prod_valid_q <= 1'b0;
            sum_valid_q  <= 1'b0;
            out_valid    <= 1'b0;
            out_tag      <= 3'd0;
            out_idx      <= 3'd0;
            out_wide_nib <= 2'd0;
            out_wide_q   <= 1'b0;
        end
        else begin
            // Stage 0: register whole matrix operands instead of 64*9 selected operands.
            buf_valid_q      <= in_valid;
            op_q             <= op;
            b_transpose_q    <= b_transpose;
            a_wide_q         <= a_wide;
            head_mask_q      <= head_mask;
            head_sel_q       <= head_sel;
            in_data_A_q      <= in_data_A;
            in_data_A_wide_q <= in_data_A_wide;
            in_data_B_q      <= in_data_B;

            tag0_q  <= in_tag;
            idx0_q  <= in_idx;
            nib0_q  <= in_wide_nib;
            wide0_q <= a_wide;

            // Stage 1 valid/metadata.
            prod_valid_q <= buf_valid_q;
            sum_valid_q  <= prod_valid_q;
            tag1_q       <= tag0_q;
            idx1_q       <= idx0_q;
            nib1_q       <= nib0_q;
            wide1_q      <= wide0_q;

            // Stage 2 output metadata.  Wide Score*V nibble 0/1 are internal
            // partials only; only nibble 2 is visible to the CA top.
            out_valid <= prod_valid_q && (!wide1_q || (nib1_q == 2'd2));
            if (prod_valid_q) begin
                out_tag      <= tag1_q;
                out_idx      <= idx1_q;
                out_wide_nib <= nib1_q;
                out_wide_q   <= wide1_q;
            end
        end
    end

    always_ff @(posedge clk) begin
        // Stage 1: one shared 4x4 multiplier array.  Since A is 5-bit signed
        // in the low/mid score nibbles, synthesis should infer a smaller
        // s5*s4 multiplier rather than the old s16*s4 datapath.
        if (buf_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_q[i][tap] <= prod_next[i][tap];
                end
            end
        end

        // Stage 2: directly reduce nine products into one 16-bit lane sum.
        // The full out_data register has been removed; out_data is packed
        // combinationally from sum_q.  For Score*V, nibble 0/1 are accumulated
        // inside this multiplier and nibble 2 is the only externally visible result.
        if (prod_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                sum_q[i] <= sum_next[i];
            end

            if (sum_valid_q && out_wide_q) begin
                if (out_wide_nib == 2'd0) begin
                    scorev_acc_q[out_idx[1:0]] <= sum_shifted_q;
                end
                else if (out_wide_nib == 2'd1) begin
                    scorev_acc_q[out_idx[1:0]] <= add_vec(scorev_acc_q[out_idx[1:0]],
                                                           sum_shifted_q);
                end
            end
        end
    end

endmodule


module act_2stage_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    input  logic [2:0]    in_tag,
    input  logic [1:0]    in_idx,
    output logic          out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data,
    output logic [2:0]    out_tag,
    output logic [1:0]    out_idx
);

    localparam int ROW_ELEM   = 8;
    localparam int AVG_GROUPS = 8;
    localparam int PSUM_CNT   = 4;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;
    localparam int PSUM_W     = ACC_W + 2;
    localparam int AVG_SUM_W  = ACC_W + 4;

    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic signed [PSUM_W-1:0] psum_t;
    typedef logic signed [AVG_SUM_W-1:0] avg_sum_t;
    typedef logic signed [ACC_W-1:0] avg_t;

    logic          s0_valid_q;
    logic [1:0]    s0_act_q;
    acc_vec_t      s0_data_q;
    logic [2:0]    s0_tag_q;
    logic [1:0]    s0_idx_q;

    logic          psum_valid_q;
    logic [1:0]    psum_act_q;
    acc_vec_t      psum_data_q;
    logic [2:0]    psum_tag_q;
    logic [1:0]    psum_idx_q;
    psum_t         psum_q [0:AVG_GROUPS-1][0:PSUM_CNT-1];

    logic          avg_valid_q;
    logic [1:0]    avg_act_q;
    acc_vec_t      avg_data_q;
    logic [2:0]    avg_tag_q;
    logic [1:0]    avg_idx_q;
    avg_t          avg_q [0:AVG_GROUPS-1];

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic psum_t ext_psum(input acc_t value);
        ext_psum = psum_t'(value);
    endfunction

    function automatic psum_t calc_rat_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        begin
            calc_rat_psum = ext_psum(get_acc(matrix, (group * ROW_ELEM) + (part * 2) + 0)) +
                            ext_psum(get_acc(matrix, (group * ROW_ELEM) + (part * 2) + 1));
        end
    endfunction

    function automatic psum_t calc_cat_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        begin
            calc_cat_psum = ext_psum(get_acc(matrix, (((part * 2) + 0) * ROW_ELEM) + group)) +
                            ext_psum(get_acc(matrix, (((part * 2) + 1) * ROW_ELEM) + group));
        end
    endfunction

    function automatic psum_t calc_bat_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        integer row_base;
        integer col_base;
        integer row;
        integer col;
        begin
            if (group < 4) begin
                row_base = (group / 2) * 4;
                col_base = (group % 2) * 4;
                row = row_base + part;

                calc_bat_psum = '0;
                for (int k = 0; k < 4; k++) begin
                    col = col_base + k;
                    calc_bat_psum += ext_psum(get_acc(matrix, (row * ROW_ELEM) + col));
                end
            end
            else begin
                calc_bat_psum = '0;
            end
        end
    endfunction

    function automatic avg_t calc_final_avg(
        input logic [1:0] act_sel,
        input psum_t      p0,
        input psum_t      p1,
        input psum_t      p2,
        input psum_t      p3
    );
        avg_sum_t sum;
        begin
            sum = avg_sum_t'(p0) + avg_sum_t'(p1) +
                  avg_sum_t'(p2) + avg_sum_t'(p3);

            case (act_sel)
                2'b01,
                2'b10: calc_final_avg = avg_t'(sum >>> 3);
                2'b11: calc_final_avg = avg_t'(sum >>> 4);
                default: calc_final_avg = '0;
            endcase
        end
    endfunction

    function automatic integer value_group(input logic [1:0] act_sel, input integer idx);
        integer row;
        integer col;
        begin
            row = idx / ROW_ELEM;
            col = idx % ROW_ELEM;

            case (act_sel)
                2'b01: value_group = row;
                2'b10: value_group = col;
                2'b11: value_group = ((row / 4) * 2) + (col / 4);
                default: value_group = 0;
            endcase
        end
    endfunction

    function automatic acc_t activate(
        input acc_t        value,
        input logic [1:0]  act_sel,
        input avg_t        threshold
    );
        begin
            if (act_sel == 2'b00) begin
                activate = (value < 0) ? '0 : value;
            end
            else begin
                activate = (value < threshold) ? (value >>> 3) : value;
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid_q   <= 1'b0;
            psum_valid_q <= 1'b0;
            avg_valid_q  <= 1'b0;
            out_valid    <= 1'b0;
        end
        else begin
            s0_valid_q   <= in_valid;
            psum_valid_q <= s0_valid_q;
            avg_valid_q  <= psum_valid_q;
            out_valid    <= avg_valid_q;
        end
    end

    always_ff @(posedge clk) begin
        // Stage 0: input register moved from CA top into ACT.
        if (in_valid) begin
            s0_act_q  <= act;
            s0_data_q <= in_data;
            s0_tag_q  <= in_tag;
            s0_idx_q  <= in_idx;
        end

        // Stage 1: partial sums.
        // RAT/CAT: 8 inputs -> four 2-input partial sums.
        // BAT:     16 inputs -> four row-wise 4-input partial sums.
        if (s0_valid_q) begin
            psum_act_q  <= s0_act_q;
            psum_data_q <= s0_data_q;
            psum_tag_q  <= s0_tag_q;
            psum_idx_q  <= s0_idx_q;

            for (int g = 0; g < AVG_GROUPS; g++) begin
                for (int p = 0; p < PSUM_CNT; p++) begin
                    unique case (s0_act_q)
                        2'b01: begin
                            psum_q[g][p] <= calc_rat_psum(s0_data_q, g, p);
                        end
                        2'b10: begin
                            psum_q[g][p] <= calc_cat_psum(s0_data_q, g, p);
                        end
                        2'b11: begin
                            psum_q[g][p] <= calc_bat_psum(s0_data_q, g, p);
                        end
                        default: begin
                            psum_q[g][p] <= '0;
                        end
                    endcase
                end
            end
        end

        // Stage 2: final average threshold from four partial sums.
        if (psum_valid_q) begin
            avg_act_q  <= psum_act_q;
            avg_data_q <= psum_data_q;
            avg_tag_q  <= psum_tag_q;
            avg_idx_q  <= psum_idx_q;

            for (int g = 0; g < AVG_GROUPS; g++) begin
                avg_q[g] <= calc_final_avg(psum_act_q,
                                           psum_q[g][0], psum_q[g][1],
                                           psum_q[g][2], psum_q[g][3]);
            end
        end

        // Stage 3: activation using the registered threshold.
        if (avg_valid_q) begin
            out_tag <= avg_tag_q;
            out_idx <= avg_idx_q;
            for (int i = 0; i < MAT_SIZE; i++) begin
                out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                    activate(get_acc(avg_data_q, i), avg_act_q,
                             avg_q[value_group(avg_act_q, i)]);
            end
        end
    end

endmodule

module pot_3stage_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    input  logic [2:0]    in_tag,
    input  logic [1:0]    in_idx,
    output logic          out_valid,
    output logic [255:0]  out_data,
    output logic [2:0]    out_tag,
    output logic [1:0]    out_idx
);

    localparam int MAX_L0    = 16;  // 64 values -> 16 max4 results
    localparam int MAX_L1    = 4;   // 16 values -> 4 max4 results
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_W-1:0] mag_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    logic          abs_valid_q;
    logic          max0_valid_q;
    logic          max1_valid_q;
    logic          max2_valid_q;
    acc_vec_t      abs_data_q;
    acc_vec_t      max0_data_q;
    acc_vec_t      max1_data_q;
    acc_vec_t      max2_data_q;
    logic [2:0]    tag0_q, tag1_q, tag2_q, tag3_q;
    logic [1:0]    idx0_q, idx1_q, idx2_q, idx3_q;
    mag_t          abs_q  [0:MAT_SIZE-1];
    mag_t          max0_q [0:MAX_L0-1];
    mag_t          max1_q [0:MAX_L1-1];
    mag_t          max2_q;

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic mag_t abs_acc(input acc_t value);
        abs_acc = (value[ACC_W - 1]) ? -value : value;
    endfunction

    function automatic mag_t max4(
        input mag_t a,
        input mag_t b,
        input mag_t c,
        input mag_t d
    );
        mag_t l1_0;
        mag_t l1_1;
        begin
            l1_0 = (a > b) ? a : b;
            l1_1 = (c > d) ? c : d;
            max4 = (l1_0 > l1_1) ? l1_0 : l1_1;
        end
    endfunction

    function automatic logic [SHIFT_W-1:0] pot_shift(input mag_t max_abs);
        logic [SHIFT_W-1:0] msb;
        begin
            msb = '0;
            for (int b = 0; b < ACC_W; b++) begin
                if (max_abs[b]) begin
                    msb = b[SHIFT_W-1:0];
                end
            end
            pot_shift = (msb > SHIFT_TWO) ? (msb - SHIFT_TWO) : '0;
        end
    endfunction

    function automatic s4_t clamp_s4(input acc_t value);
        begin
            if (value > acc_t'(7)) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < acc_t'(-8)) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic logic [255:0] quant_all(
        input acc_vec_t             src_data,
        input logic [SHIFT_W-1:0]   shift
    );
        acc_t   scaled;
        begin
            quant_all = 256'd0;

            for (int i = 0; i < MAT_SIZE; i++) begin
                scaled = get_acc(src_data, i) >>> shift;
                quant_all[255 - (i * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            abs_valid_q  <= 1'b0;
            max0_valid_q <= 1'b0;
            max1_valid_q <= 1'b0;
            max2_valid_q <= 1'b0;
            out_valid    <= 1'b0;
            out_tag      <= 3'd0;
            out_idx      <= 2'd0;
        end
        else begin
            abs_valid_q  <= in_valid;
            max0_valid_q <= abs_valid_q;
            max1_valid_q <= max0_valid_q;
            max2_valid_q <= max1_valid_q;
            out_valid    <= max2_valid_q;

            tag0_q <= in_tag;
            idx0_q <= in_idx;
            tag1_q <= tag0_q;
            idx1_q <= idx0_q;
            tag2_q <= tag1_q;
            idx2_q <= idx1_q;
            tag3_q <= tag2_q;
            idx3_q <= idx2_q;

            // Stage 0: register absolute values only.
            // This cuts the previous in_data -> abs + max4 -> max0_q path.
            if (in_valid) begin
                abs_data_q <= in_data;

                for (int i = 0; i < MAT_SIZE; i++) begin
                    abs_q[i] <= abs_acc(get_acc(in_data, i));
                end
            end

            // Stage 1: 64 absolute values -> 16 partial max4 values.
            if (abs_valid_q) begin
                max0_data_q <= abs_data_q;

                for (int g = 0; g < MAX_L0; g++) begin
                    max0_q[g] <= max4(abs_q[(g * 4) + 0],
                                    abs_q[(g * 4) + 1],
                                    abs_q[(g * 4) + 2],
                                    abs_q[(g * 4) + 3]);
                end
            end

            // Stage 2: 16 partial max4 values -> 4 partial max4 values.
            if (max0_valid_q) begin
                max1_data_q <= max0_data_q;

                for (int g = 0; g < MAX_L1; g++) begin
                    max1_q[g] <= max4(max0_q[(g * 4) + 0],
                                    max0_q[(g * 4) + 1],
                                    max0_q[(g * 4) + 2],
                                    max0_q[(g * 4) + 3]);
                end
            end

            // Stage 3: 4 partial max4 values -> 1 global maximum.
            if (max1_valid_q) begin
                max2_data_q <= max1_data_q;
                max2_q      <= max4(max1_q[0], max1_q[1], max1_q[2], max1_q[3]);
            end

            // Stage 4: compute PoT shift and quantize all 64 elements to signed 4-bit.
            if (max2_valid_q) begin
                out_data <= quant_all(max2_data_q, pot_shift(max2_q));
                out_tag  <= tag3_q;
                out_idx  <= idx3_q;
            end
        end
    end
endmodule
