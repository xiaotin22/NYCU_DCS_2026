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
    localparam int MULT_CTRL_LATENCY = 3;
    localparam int MULT_CTRL_LAST = MULT_CTRL_LATENCY - 1;
    localparam int ACT_IN_PIPE_LATENCY = 1;
    localparam int WR_PRE_LATENCY = MULT_CTRL_LATENCY + ACT_IN_PIPE_LATENCY;
    localparam int WR_PRE_LAST = WR_PRE_LATENCY - 1;
    localparam int ATT_WR_PIPE_W = 8;

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
    acc_vec_t            score_buf_q  [0:7];
    acc_vec_t            mha_out0_buf_q [0:3];
    logic [255:0]        valign_buf_q [0:3];
    logic [3:0]          q_ready_q;
    logic [3:0]          k_ready_q;
    logic [3:0]          v_ready_q;
    logic [7:0]          score_ready_q;
    logic [3:0]          valign_ready_q;
    logic [7:0]          att_group_base_q;
    logic [3:0]          att_issue_cnt_q;
    logic [2:0]          att_sv_issue_cnt_q;
    logic [2:0]          att_final_issue_cnt_q;
    logic [2:0]          att_final_recv_cnt_q;
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
    acc_vec_t            mult_issue_A_wide;
    logic [255:0]        mult_issue_B;
    mult_tag_t           mult_issue_tag;
    logic [2:0]          mult_issue_idx;
    logic                mult_in_valid_q;
    logic [1:0]          mult_in_op_q;
    logic                mult_in_b_transpose_q;
    logic                mult_in_a_wide_q;
    logic                mult_in_head_mask_q;
    logic                mult_in_head_sel_q;
    logic [255:0]        mult_in_A_q;
    acc_vec_t            mult_in_A_wide_q;
    logic [255:0]        mult_in_B_q;
    logic                mult_valid;
    acc_vec_t            mult_data;
    mult_tag_t           mult_tag_q [0:MULT_CTRL_LAST];
    logic [2:0]          mult_idx_q [0:MULT_CTRL_LAST];

    logic                act_in_valid;
    acc_vec_t            act_in_data;
    pot_tag_t            act_in_tag;
    logic [1:0]          act_in_idx;
    logic                act_pipe_valid_q;
    acc_vec_t            act_pipe_data_q;
    pot_tag_t            act_pipe_tag_q;
    logic [1:0]          act_pipe_idx_q;
    logic                act_valid;
    acc_vec_t            act_data;
    pot_tag_t            act_tag_q [0:1];
    logic [1:0]          act_idx_q [0:1];

    logic                pot_in_valid;
    acc_vec_t            pot_in_data;
    pot_tag_t            pot_in_tag;
    logic [1:0]          pot_in_idx;
    logic                pot_valid;
    logic [255:0]        pot_data;
    pot_tag_t            pot_tag_q [0:2];
    logic [1:0]          pot_idx_q [0:2];
    logic                wr_pre_fire;
    logic                att_wr_fire;
    logic                att_final_start;
    logic                mha_comb_valid;
    acc_vec_t            mha_comb_data;

    assign wr_pre_fire    = wr_pre_pipe_q[WR_PRE_LAST];
    assign att_final_start = (state_q == S_ATT_ISSUE_FINAL) && (att_final_issue_cnt_q == 3'd0);
    assign att_wr_fire    = (op_q == 2'b11) ? att_wr_pipe_q[ATT_WR_PIPE_W-1] :
                                                att_wr_pipe_q[WR_PRE_LAST];

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

    function automatic acc_vec_t attention_score_act(input acc_vec_t src_data);
        begin
            attention_score_act = '0;
            for (int i = 0; i < MAT_ELEMS; i++) begin
                attention_score_act[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] =
                    att_act_value(get_acc(src_data, i));
            end
        end
    endfunction

    function automatic acc_vec_t combine_mha_heads(
        input acc_vec_t head0,
        input acc_vec_t head1
    );
        begin
            combine_mha_heads = '0;
            for (int i = 0; i < MAT_ELEMS; i++) begin
                combine_mha_heads[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] =
                    ((i % 8) < 4) ? head0[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] :
                                    head1[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W];
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
                mult_issue_idx   = (op_q == 2'b11) ?
                                   {att_final_issue_cnt_q[2], att_final_issue_cnt_q[1:0]} :
                                   {1'b0, att_final_issue_cnt_q[1:0]};
                mult_issue_a_wide = 1'b1;
                mult_issue_A_wide = score_buf_q[mult_issue_idx];
                mult_issue_B     = (op_q == 2'b11) ?
                                   v_buf_q[att_final_issue_cnt_q[1:0]] :
                                   valign_buf_q[att_final_issue_cnt_q[1:0]];
                mult_issue_tag   = MT_FINAL;
            end

            default: begin
            end
        endcase
    end

    assign mha_comb_valid = mult_valid && (op_q == 2'b11) &&
                            (mult_tag_q[MULT_CTRL_LAST] == MT_FINAL) &&
                            mult_idx_q[MULT_CTRL_LAST][2];
    assign mha_comb_data  = combine_mha_heads(mha_out0_buf_q[mult_idx_q[MULT_CTRL_LAST][1:0]], mult_data);

    assign act_in_valid = mha_comb_valid ||
                          (mult_valid &&
                           ((mult_tag_q[MULT_CTRL_LAST] == MT_NORM) ||
                            ((mult_tag_q[MULT_CTRL_LAST] == MT_FINAL) && (op_q != 2'b11))));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = (mult_tag_q[MULT_CTRL_LAST] == MT_FINAL) ?
                          mult_idx_q[MULT_CTRL_LAST][1:0] : 2'd0;

    always_comb begin
        case (mult_tag_q[MULT_CTRL_LAST])
            MT_NORM:  act_in_tag = PT_NORM;
            MT_FINAL: act_in_tag = ((op_q == 2'b11) && !mha_comb_valid) ? PT_NONE : PT_FINAL;
            default:  act_in_tag = PT_NONE;
        endcase
    end

    assign pot_in_valid = act_valid ||
                          (mult_valid && ((mult_tag_q[MULT_CTRL_LAST] == MT_Q) ||
                                          (mult_tag_q[MULT_CTRL_LAST] == MT_K) ||
                                          (mult_tag_q[MULT_CTRL_LAST] == MT_V)));
    assign pot_in_data  = act_valid ? act_data : mult_data;
    assign pot_in_idx   = act_valid ? act_idx_q[1] : mult_idx_q[MULT_CTRL_LAST][1:0];

    always_comb begin
        pot_in_tag = PT_NONE;

        if (act_valid) begin
            pot_in_tag = act_tag_q[1];
        end
        else begin
            case (mult_tag_q[MULT_CTRL_LAST])
                MT_Q: pot_in_tag = PT_Q;
                MT_K: pot_in_tag = PT_K;
                MT_V: pot_in_tag = PT_V;
                default: pot_in_tag = PT_NONE;
            endcase
        end
    end

    mult_1stage #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (mult_in_op_q),
        .b_transpose (mult_in_b_transpose_q),
        .a_wide      (mult_in_a_wide_q),
        .head_mask   (mult_in_head_mask_q),
        .head_sel    (mult_in_head_sel_q),
        .in_valid    (mult_in_valid_q),
        .in_data_A   (mult_in_A_q),
        .in_data_A_wide(mult_in_A_wide_q),
        .in_data_B   (mult_in_B_q),
        .out_valid   (mult_valid),
        .out_data    (mult_data)
    );

    act_2stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_pipe_valid_q),
        .act       (act_q),
        .in_data   (act_pipe_data_q),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    pot_3stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),
        .in_data   (pot_in_data),
        .out_valid (pot_valid),
        .out_data  (pot_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q               <= S_IDLE;
            op_q                  <= 2'b00;
            act_q                 <= 2'b00;
            param1_q              <= 256'd0;
            param2_q              <= 256'd0;
            param3_q              <= 256'd0;
            att_param_cnt_q       <= 2'd0;
            rd_req_cnt_q          <= 2'd0;
            rd_word_cnt_q         <= 9'd0;
            wr_cmd_cnt_q          <= 9'd0;
            out_cnt_q             <= 8'd0;
            wr_pre_pipe_q         <= '0;
            mult_in_valid_q       <= 1'b0;
            mult_in_op_q          <= 2'b00;
            mult_in_b_transpose_q <= 1'b0;
            mult_in_a_wide_q      <= 1'b0;
            mult_in_head_mask_q   <= 1'b0;
            mult_in_head_sel_q    <= 1'b0;
            mult_in_A_q           <= 256'd0;
            mult_in_A_wide_q      <= '0;
            mult_in_B_q           <= 256'd0;
            q_ready_q             <= 4'd0;
            k_ready_q             <= 4'd0;
            v_ready_q             <= 4'd0;
            score_ready_q         <= 8'd0;
            valign_ready_q        <= 4'd0;
            att_group_base_q      <= 8'd0;
            att_issue_cnt_q       <= 4'd0;
            att_sv_issue_cnt_q    <= 3'd0;
            att_final_issue_cnt_q <= 3'd0;
            att_final_recv_cnt_q  <= 3'd0;
            att_wr_pipe_q         <= '0;
            att_prefetch_req_q    <= 1'b0;
            att_prefetch_ready_q  <= 1'b0;
            att_prefetch_cnt_q    <= 2'd0;
            act_pipe_valid_q      <= 1'b0;
            act_pipe_data_q       <= '0;
            act_pipe_tag_q        <= PT_NONE;
            act_pipe_idx_q        <= 2'd0;
            act_tag_q[0]          <= PT_NONE;
            act_tag_q[1]          <= PT_NONE;
            act_idx_q[0]          <= 2'd0;
            act_idx_q[1]          <= 2'd0;
            rd_en                 <= 1'b0;
            rd_addr               <= '0;
            rd_burst              <= '0;
            wr_en                 <= 1'b0;
            wr_addr               <= '0;
            wr_burst              <= '0;
            wr_data               <= 256'd0;
            out_valid             <= 1'b0;
            out_data              <= 32'd0;

            for (int i = 0; i < 4; i++) begin
                x_buf_q[i]      <= 256'd0;
                q_buf_q[i]      <= 256'd0;
                k_buf_q[i]      <= 256'd0;
                v_buf_q[i]      <= 256'd0;
                mha_out0_buf_q[i] <= '0;
                valign_buf_q[i] <= 256'd0;
            end

            for (int i = 0; i < 8; i++) begin
                score_buf_q[i] <= '0;
            end

            for (int i = 0; i < MULT_CTRL_LATENCY; i++) begin
                mult_tag_q[i] <= MT_NONE;
                mult_idx_q[i] <= 3'd0;
            end

            for (int i = 0; i < 3; i++) begin
                pot_tag_q[i] <= PT_NONE;
                pot_idx_q[i] <= 2'd0;
            end
        end
        else begin
            rd_en     <= 1'b0;
            wr_en     <= 1'b0;
            out_valid <= 1'b0;
            rd_burst  <= '0;
            wr_burst  <= '0;

            mult_in_valid_q       <= mult_issue_valid;
            mult_in_op_q          <= mult_issue_op;
            mult_in_b_transpose_q <= mult_issue_b_transpose;
            mult_in_a_wide_q      <= mult_issue_a_wide;
            mult_in_head_mask_q   <= mult_issue_head_mask;
            mult_in_head_sel_q    <= mult_issue_head_sel;
            mult_in_A_q           <= mult_issue_A;
            mult_in_A_wide_q      <= mult_issue_A_wide;
            mult_in_B_q           <= mult_issue_B;

            mult_tag_q[0] <= mult_issue_valid ? mult_issue_tag : MT_NONE;
            mult_idx_q[0] <= mult_issue_idx;
            for (int i = 1; i < MULT_CTRL_LATENCY; i++) begin
                mult_tag_q[i] <= mult_tag_q[i - 1];
                mult_idx_q[i] <= mult_idx_q[i - 1];
            end

            pot_tag_q[0] <= pot_in_valid ? pot_in_tag : PT_NONE;
            pot_idx_q[0] <= pot_in_idx;
            for (int i = 1; i < 3; i++) begin
                pot_tag_q[i] <= pot_tag_q[i - 1];
                pot_idx_q[i] <= pot_idx_q[i - 1];
            end

            act_pipe_valid_q <= act_in_valid;
            act_pipe_data_q  <= act_in_data;
            act_pipe_tag_q   <= act_in_tag;
            act_pipe_idx_q   <= act_in_idx;

            act_tag_q[0] <= act_pipe_valid_q ? act_pipe_tag_q : PT_NONE;
            act_tag_q[1] <= act_tag_q[0];
            act_idx_q[0] <= act_pipe_idx_q;
            act_idx_q[1] <= act_idx_q[0];

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
                case (pot_tag_q[2])
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
                        q_buf_q[pot_idx_q[2][1:0]] <= pot_data;
                        q_ready_q[pot_idx_q[2][1:0]] <= 1'b1;
                    end
                    PT_K: begin
                        k_buf_q[pot_idx_q[2][1:0]] <= pot_data;
                        k_ready_q[pot_idx_q[2][1:0]] <= 1'b1;
                    end
                    PT_V: begin
                        v_buf_q[pot_idx_q[2][1:0]] <= pot_data;
                        v_ready_q[pot_idx_q[2][1:0]] <= 1'b1;
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
                case (mult_tag_q[MULT_CTRL_LAST])
                    MT_SCORE: begin
                        score_buf_q[mult_idx_q[MULT_CTRL_LAST]] <= attention_score_act(mult_data);
                        score_ready_q[mult_idx_q[MULT_CTRL_LAST]] <= 1'b1;
                    end
                    MT_VALIGN: begin
                        valign_buf_q[mult_idx_q[MULT_CTRL_LAST][1:0]] <= pack_s4(mult_data);
                        valign_ready_q[mult_idx_q[MULT_CTRL_LAST][1:0]] <= 1'b1;
                    end
                    MT_FINAL: begin
                        if ((op_q == 2'b11) && !mult_idx_q[MULT_CTRL_LAST][2]) begin
                            mha_out0_buf_q[mult_idx_q[MULT_CTRL_LAST][1:0]] <= mult_data;
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
                        att_final_issue_cnt_q <= 3'd0;
                        att_final_recv_cnt_q  <= 3'd0;
                        att_wr_pipe_q         <= '0;
                        state_q               <= S_ATT_ISSUE_FINAL;
                    end
                end

                S_ATT_ISSUE_FINAL: begin
                    if (((op_q == 2'b11) && (att_final_issue_cnt_q == 3'd7)) ||
                        ((op_q != 2'b11) && (att_final_issue_cnt_q == 3'd3))) begin
                        state_q <= S_ATT_WAIT_FINAL;
                    end
                    else begin
                        att_final_issue_cnt_q <= att_final_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_FINAL: begin
                    if (pot_valid && (pot_tag_q[2] == PT_FINAL) &&
                        (att_final_recv_cnt_q == 3'd3)) begin
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

module mult_1stage #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
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
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data_A_wide,
    input  logic [255:0]         in_data_B,
    output logic                 out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data
);

    localparam int ROW_ELEM = 8;
    localparam int DOT_SIZE = 9;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int PROD_W = ACC_W + 4;
    localparam int SUM_W = PROD_W + 3;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic signed [PROD_W-1:0] prod_t;
    typedef logic signed [SUM_W-1:0] sum_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    logic  prod_valid_q;
    prod_t prod_q [0:MAT_SIZE-1][0:DOT_SIZE-1];

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

    function automatic acc_t sel_a(
        input logic [255:0]  mat_A,
        input acc_vec_t      mat_A_wide,
        input logic [1:0]    op_sel,
        input logic          a_wide_sel,
        input logic          head_mask_sel,
        input logic          head_sel_sel,
        input integer        out_idx,
        input integer        tap
    );
        integer row;
        integer col;
        begin
            row = out_idx / ROW_ELEM;
            col = out_idx % ROW_ELEM;

            if (op_sel == 2'b01) begin
                sel_a = get_pad_s4(mat_A, row + (tap / 3) - 1, col + (tap % 3) - 1);
            end
            else if (tap == 8) begin
                sel_a = '0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_a = '0;
            end
            else if (a_wide_sel) begin
                sel_a = get_acc(mat_A_wide, (row * ROW_ELEM) + tap);
            end
            else begin
                sel_a = get_s4(mat_A, (row * ROW_ELEM) + tap);
            end
        end
    endfunction

    function automatic s4_t sel_b(
        input logic [255:0] mat_B,
        input logic [1:0]   op_sel,
        input logic         b_transpose_sel,
        input logic         head_mask_sel,
        input logic         head_sel_sel,
        input integer       lane,
        input integer       tap
    );
        begin
            if (op_sel == 2'b01) begin
                sel_b = get_s4(mat_B, tap);
            end
            else if (tap == 8) begin
                sel_b = 4'sd0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_b = 4'sd0;
            end
            else if (b_transpose_sel) begin
                sel_b = get_s4(mat_B, (lane * ROW_ELEM) + tap);
            end
            else begin
                sel_b = get_s4(mat_B, (tap * ROW_ELEM) + lane);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_valid_q <= 1'b0;
            out_valid    <= 1'b0;
            out_data     <= '0;

            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_q[i][tap] <= '0;
                end
            end
        end
        else begin
            prod_valid_q <= in_valid;
            out_valid    <= prod_valid_q;

            if (in_valid) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        prod_q[i][tap] <= prod_t'(
                            $signed(sel_a(in_data_A, in_data_A_wide, op, a_wide,
                                           head_mask, head_sel, i, tap)) *
                            $signed(sel_b(in_data_B, op, b_transpose, head_mask,
                                           head_sel, i % ROW_ELEM, tap))
                        );
                    end
                end
            end

            if (prod_valid_q) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    sum_t sum;
                    sum = '0;

                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        sum += sum_t'(prod_q[i][tap]);
                    end

                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <= acc_t'(sum);
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
    output logic          out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data
);

    localparam int ROW_ELEM   = 8;
    localparam int AVG_GROUPS = 8;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;
    localparam int AVG_W      = ACC_W + 4;

    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic signed [AVG_W-1:0] avg_t;

    logic          avg_valid_q;
    logic [1:0]    avg_act_q;
    acc_vec_t      avg_data_q;
    avg_t          avg_q [0:AVG_GROUPS-1];

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic avg_t ext_avg(input acc_t value);
        ext_avg = value;
    endfunction

    function automatic integer avg_src_idx(
        input logic [1:0] act_sel,
        input integer     group,
        input integer     elem
    );
        integer row;
        integer col;
        begin
            case (act_sel)
                2'b01: begin
                    avg_src_idx = (group * ROW_ELEM) + elem;
                end
                2'b10: begin
                    avg_src_idx = (elem * ROW_ELEM) + group;
                end
                2'b11: begin
                    row = ((group / 2) * 4) + (elem / 4);
                    col = ((group % 2) * 4) + (elem % 4);
                    avg_src_idx = (row * ROW_ELEM) + col;
                end
                default: begin
                    avg_src_idx = 0;
                end
            endcase
        end
    endfunction

    function automatic avg_t calc_avg(
        input acc_vec_t      matrix,
        input logic [1:0]    act_sel,
        input integer        group
    );
        avg_t sum;
        begin
            sum      = '0;
            calc_avg = '0;

            case (act_sel)
                2'b01,
                2'b10: begin
                    for (int i = 0; i < ROW_ELEM; i++) begin
                        sum += ext_avg(get_acc(matrix, avg_src_idx(act_sel, group, i)));
                    end
                    calc_avg = sum >>> 3;
                end
                2'b11: begin
                    if (group < 4) begin
                        for (int i = 0; i < 16; i++) begin
                            sum += ext_avg(get_acc(matrix, avg_src_idx(act_sel, group, i)));
                        end
                        calc_avg = sum >>> 4;
                    end
                end
                default: begin
                    calc_avg = '0;
                end
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
                activate = (ext_avg(value) < threshold) ? (value >>> 3) : value;
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg_valid_q <= 1'b0;
            avg_act_q   <= 2'b00;
            avg_data_q  <= '0;
            out_valid   <= 1'b0;
            out_data    <= '0;

            for (int i = 0; i < AVG_GROUPS; i++) begin
                avg_q[i] <= '0;
            end
        end
        else begin
            avg_valid_q <= in_valid;
            out_valid   <= avg_valid_q;

            if (in_valid) begin
                avg_act_q  <= act;
                avg_data_q <= in_data;

                for (int i = 0; i < AVG_GROUPS; i++) begin
                    avg_q[i] <= calc_avg(in_data, act, i);
                end
            end

            if (avg_valid_q) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                        activate(get_acc(avg_data_q, i), avg_act_q,
                                 avg_q[value_group(avg_act_q, i)]);
                end
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
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAX_C1   = 8;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_W-1:0] mag_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    logic          max1_valid_q;
    logic          max2_valid_q;
    acc_vec_t      max1_data_q;
    acc_vec_t      max2_data_q;
    mag_t          max1_q [0:MAX_C1-1];
    mag_t          max2_q;

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic mag_t abs_acc(input acc_t value);
        abs_acc = (value[ACC_W - 1]) ? -value : value;
    endfunction

    function automatic mag_t max8(
        input mag_t a,
        input mag_t b,
        input mag_t c,
        input mag_t d,
        input mag_t e,
        input mag_t f,
        input mag_t g,
        input mag_t h
    );
        mag_t l1_0;
        mag_t l1_1;
        mag_t l1_2;
        mag_t l1_3;
        mag_t l2_0;
        mag_t l2_1;
        begin
            l1_0 = (a > b) ? a : b;
            l1_1 = (c > d) ? c : d;
            l1_2 = (e > f) ? e : f;
            l1_3 = (g > h) ? g : h;
            l2_0 = (l1_0 > l1_1) ? l1_0 : l1_1;
            l2_1 = (l1_2 > l1_3) ? l1_2 : l1_3;
            max8 = (l2_0 > l2_1) ? l2_0 : l2_1;
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
            max1_valid_q <= 1'b0;
            max2_valid_q <= 1'b0;
            max1_data_q  <= '0;
            max2_data_q  <= '0;
            max2_q       <= '0;
            out_valid    <= 1'b0;
            out_data     <= 256'd0;

            for (int i = 0; i < MAX_C1; i++) begin
                max1_q[i] <= '0;
            end
        end
        else begin
            max1_valid_q <= in_valid;
            max2_valid_q <= max1_valid_q;
            out_valid    <= max2_valid_q;

            if (in_valid) begin
                max1_data_q <= in_data;

                for (int i = 0; i < MAX_C1; i++) begin
                    max1_q[i] <= max8(abs_acc(get_acc(in_data, (i * 8) + 0)),
                                      abs_acc(get_acc(in_data, (i * 8) + 1)),
                                      abs_acc(get_acc(in_data, (i * 8) + 2)),
                                      abs_acc(get_acc(in_data, (i * 8) + 3)),
                                      abs_acc(get_acc(in_data, (i * 8) + 4)),
                                      abs_acc(get_acc(in_data, (i * 8) + 5)),
                                      abs_acc(get_acc(in_data, (i * 8) + 6)),
                                      abs_acc(get_acc(in_data, (i * 8) + 7)));
                end
            end

            if (max1_valid_q) begin
                max2_data_q <= max1_data_q;
                max2_q      <= max8(max1_q[0], max1_q[1], max1_q[2], max1_q[3],
                                    max1_q[4], max1_q[5], max1_q[6], max1_q[7]);
            end

            if (max2_valid_q) begin
                out_data <= quant_all(max2_data_q, pot_shift(max2_q));
            end
        end
    end

endmodule