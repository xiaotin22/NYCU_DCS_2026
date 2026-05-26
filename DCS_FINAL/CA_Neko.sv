module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    output logic                            out_valid,
    output logic [31:0]                     out_data,

    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

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
    typedef logic signed [31:0] s32_t;

    state_t              state_q;
    logic [1:0]          op_q;
    logic [1:0]          act_q;
    logic [255:0]        param_q;
    logic [255:0]        wq_q;
    logic [255:0]        wk_q;
    logic [255:0]        wv_q;
    logic [1:0]          att_param_cnt_q;
    logic [1:0]          rd_req_cnt_q;
    logic [8:0]          rd_word_cnt_q;
    logic [8:0]          wr_cmd_cnt_q;
    logic [8:0]          out_cnt_q;
    logic [7:0]          wr_pre_pipe_q;

    logic [255:0]        x_buf_q      [0:3];
    logic [255:0]        q_buf_q      [0:3];
    logic [255:0]        k_buf_q      [0:3];
    logic [255:0]        v_buf_q      [0:3];
    logic [2047:0]       score_buf_q  [0:7];
    logic [2047:0]       mha_out0_buf_q [0:3];
    logic [255:0]        valign_buf_q [0:3];
    logic [3:0]          q_ready_q;
    logic [3:0]          k_ready_q;
    logic [3:0]          v_ready_q;
    logic [7:0]          score_ready_q;
    logic [3:0]          valign_ready_q;
    logic [8:0]          att_group_base_q;
    logic [3:0]          att_issue_cnt_q;
    logic [3:0]          att_sv_issue_cnt_q;
    logic [2:0]          att_final_issue_cnt_q;
    logic [2:0]          att_final_recv_cnt_q;
    logic [11:0]         att_wr_pipe_q;

    logic                mult_issue_valid;
    logic [1:0]          mult_issue_op;
    logic                mult_issue_b_transpose;
    logic                mult_issue_a_wide;
    logic                mult_issue_head_mask;
    logic                mult_issue_head_sel;
    logic [255:0]        mult_issue_A;
    logic [2047:0]       mult_issue_A_wide;
    logic [255:0]        mult_issue_B;
    mult_tag_t           mult_issue_tag;
    logic [2:0]          mult_issue_idx;
    logic                mult_valid;
    logic [2047:0]       mult_data;
    mult_tag_t           mult_tag_q [0:7];
    logic [2:0]          mult_idx_q [0:7];

    logic                act_in_valid;
    logic [2047:0]       act_in_data;
    pot_tag_t            act_in_tag;
    logic [2:0]          act_in_idx;
    logic                act_valid;
    logic [2047:0]       act_data;
    pot_tag_t            act_tag_q [0:1];
    logic [2:0]          act_idx_q [0:1];

    logic                pot_in_valid;
    logic [2047:0]       pot_in_data;
    pot_tag_t            pot_in_tag;
    logic [2:0]          pot_in_idx;
    logic                pot_valid;
    logic [255:0]        pot_data;
    pot_tag_t            pot_tag_q [0:2];
    logic [2:0]          pot_idx_q [0:2];
    logic                wr_pre_fire;
    logic                att_wr_fire;
    logic                att_final_start;
    logic                mha_comb_valid;
    logic [2047:0]       mha_comb_data;
    logic [2:0]          mha_comb_idx;

    assign wr_pre_fire    = wr_pre_pipe_q[7];
    assign att_final_start = (state_q == S_ATT_ISSUE_FINAL) && (att_final_issue_cnt_q == 3'd0);
    assign att_wr_fire    = (op_q == 2'b11) ? att_wr_pipe_q[11] : att_wr_pipe_q[7];

    function automatic logic op_supported(input logic [1:0] op_sel);
        op_supported = (op_sel == 2'b00) || (op_sel == 2'b01) ||
                       (op_sel == 2'b10) || (op_sel == 2'b11);
    endfunction

    function automatic logic [255:0] identity_matrix();
        begin
            identity_matrix = 256'd0;
            for (int i = 0; i < 8; i++) begin
                identity_matrix[255 - (((i * 8) + i) * 4) -: 4] = 4'sd1;
            end
        end
    endfunction

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic s4_t clamp_s4(input s32_t value);
        begin
            if (value > 32'sd7) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < -32'sd8) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic s32_t att_act_value(input s32_t value);
        begin
            att_act_value = (value < 0) ? (value >>> 2) : value;
        end
    endfunction

    function automatic logic [255:0] pack_s4(input logic [2047:0] src_data);
        begin
            pack_s4 = 256'd0;
            for (int i = 0; i < 64; i++) begin
                pack_s4[255 - (i * 4) -: 4] = clamp_s4(get_i32(src_data, i));
            end
        end
    endfunction

    function automatic logic [2047:0] attention_score_act(input logic [2047:0] src_data);
        begin
            attention_score_act = 2048'd0;
            for (int i = 0; i < 64; i++) begin
                attention_score_act[2047 - (i * 32) -: 32] =
                    att_act_value(get_i32(src_data, i));
            end
        end
    endfunction

    function automatic logic [2047:0] combine_mha_heads(
        input logic [2047:0] head0,
        input logic [2047:0] head1
    );
        begin
            combine_mha_heads = 2048'd0;
            for (int i = 0; i < 64; i++) begin
                combine_mha_heads[2047 - (i * 32) -: 32] =
                    ((i % 8) < 4) ? head0[2047 - (i * 32) -: 32] :
                                    head1[2047 - (i * 32) -: 32];
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
        mult_issue_A_wide      = 2048'd0;
        mult_issue_B           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_idx         = 3'd0;

        case (state_q)
            S_RUN: begin
                if (rd_valid && (rd_word_cnt_q < 9'd256)) begin
                    mult_issue_valid = 1'b1;
                    mult_issue_op    = op_q;
                    mult_issue_A     = rd_data;
                    mult_issue_B     = param_q;
                    mult_issue_tag   = MT_NORM;
                end
            end

            S_ATT_ISSUE_QKV: begin
                mult_issue_valid = 1'b1;
                mult_issue_idx   = att_issue_cnt_q / 3;
                mult_issue_A     = x_buf_q[mult_issue_idx];

                case (att_issue_cnt_q % 3)
                    0: begin
                        mult_issue_B   = wq_q;
                        mult_issue_tag = MT_Q;
                    end
                    1: begin
                        mult_issue_B   = wk_q;
                        mult_issue_tag = MT_K;
                    end
                    default: begin
                        mult_issue_B   = wv_q;
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
                            (mult_tag_q[7] == MT_FINAL) && mult_idx_q[7][2];
    assign mha_comb_idx   = {1'b0, mult_idx_q[7][1:0]};
    assign mha_comb_data  = combine_mha_heads(mha_out0_buf_q[mult_idx_q[7][1:0]], mult_data);

    assign act_in_valid = mha_comb_valid ||
                          (mult_valid &&
                           ((mult_tag_q[7] == MT_NORM) ||
                            ((mult_tag_q[7] == MT_FINAL) && (op_q != 2'b11))));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = ((mult_tag_q[7] == MT_FINAL) || mha_comb_valid) ?
                          (mha_comb_valid ? mha_comb_idx : mult_idx_q[7]) : 3'd0;

    always_comb begin
        case (mult_tag_q[7])
            MT_NORM:  act_in_tag = PT_NORM;
            MT_FINAL: act_in_tag = ((op_q == 2'b11) && !mha_comb_valid) ? PT_NONE : PT_FINAL;
            default:  act_in_tag = PT_NONE;
        endcase
    end

    assign pot_in_valid = act_valid ||
                          (mult_valid && ((mult_tag_q[7] == MT_Q) ||
                                          (mult_tag_q[7] == MT_K) ||
                                          (mult_tag_q[7] == MT_V)));
    assign pot_in_data  = act_valid ? act_data : mult_data;
    assign pot_in_idx   = act_valid ? act_idx_q[1] : mult_idx_q[7];

    always_comb begin
        pot_in_tag = PT_NONE;

        if (act_valid) begin
            pot_in_tag = act_tag_q[1];
        end
        else begin
            case (mult_tag_q[7])
                MT_Q: pot_in_tag = PT_Q;
                MT_K: pot_in_tag = PT_K;
                MT_V: pot_in_tag = PT_V;
                default: pot_in_tag = PT_NONE;
            endcase
        end
    end

    mult_8stage u_mult (
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
        .out_valid   (mult_valid),
        .out_data    (mult_data)
    );

    act_2stage_parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act_q),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    pot_3stage_parallel u_pot (
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
            param_q               <= 256'd0;
            wq_q                  <= 256'd0;
            wk_q                  <= 256'd0;
            wv_q                  <= 256'd0;
            att_param_cnt_q       <= 2'd0;
            rd_req_cnt_q          <= 2'd0;
            rd_word_cnt_q         <= 9'd0;
            wr_cmd_cnt_q          <= 9'd0;
            out_cnt_q             <= 9'd0;
            wr_pre_pipe_q         <= 8'd0;
            q_ready_q             <= 4'd0;
            k_ready_q             <= 4'd0;
            v_ready_q             <= 4'd0;
            score_ready_q         <= 8'd0;
            valign_ready_q        <= 4'd0;
            att_group_base_q      <= 9'd0;
            att_issue_cnt_q       <= 4'd0;
            att_sv_issue_cnt_q    <= 4'd0;
            att_final_issue_cnt_q <= 3'd0;
            att_final_recv_cnt_q  <= 3'd0;
            att_wr_pipe_q         <= 12'd0;
            act_tag_q[0]          <= PT_NONE;
            act_tag_q[1]          <= PT_NONE;
            act_idx_q[0]          <= 3'd0;
            act_idx_q[1]          <= 3'd0;
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
                mha_out0_buf_q[i] <= 2048'd0;
                valign_buf_q[i] <= 256'd0;
            end

            for (int i = 0; i < 8; i++) begin
                score_buf_q[i] <= 2048'd0;
            end

            for (int i = 0; i < 8; i++) begin
                mult_tag_q[i] <= MT_NONE;
                mult_idx_q[i] <= 3'd0;
            end

            for (int i = 0; i < 3; i++) begin
                pot_tag_q[i] <= PT_NONE;
                pot_idx_q[i] <= 3'd0;
            end
        end
        else begin
            rd_en     <= 1'b0;
            wr_en     <= 1'b0;
            out_valid <= 1'b0;
            rd_burst  <= '0;
            wr_burst  <= '0;

            mult_tag_q[0] <= mult_issue_valid ? mult_issue_tag : MT_NONE;
            mult_idx_q[0] <= mult_issue_idx;
            for (int i = 1; i < 8; i++) begin
                mult_tag_q[i] <= mult_tag_q[i - 1];
                mult_idx_q[i] <= mult_idx_q[i - 1];
            end

            pot_tag_q[0] <= pot_in_valid ? pot_in_tag : PT_NONE;
            pot_idx_q[0] <= pot_in_idx;
            for (int i = 1; i < 3; i++) begin
                pot_tag_q[i] <= pot_tag_q[i - 1];
                pot_idx_q[i] <= pot_idx_q[i - 1];
            end

            act_tag_q[0] <= act_in_valid ? act_in_tag : PT_NONE;
            act_tag_q[1] <= act_tag_q[0];
            act_idx_q[0] <= act_in_idx;
            act_idx_q[1] <= act_idx_q[0];

            att_wr_pipe_q <= {att_wr_pipe_q[10:0], att_final_start};

            if (att_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= att_group_base_q[ADDR_W-1:0];
                wr_burst <= BURST_4;
            end

            if (pot_valid) begin
                case (pot_tag_q[2])
                    PT_NORM: begin
                        wr_data   <= pot_data;
                        out_valid <= 1'b1;
                        out_data  <= pot_data[31:0];

                        if (out_cnt_q == 9'd255) begin
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
                case (mult_tag_q[7])
                    MT_SCORE: begin
                        score_buf_q[mult_idx_q[7]] <= attention_score_act(mult_data);
                        score_ready_q[mult_idx_q[7]] <= 1'b1;
                    end
                    MT_VALIGN: begin
                        valign_buf_q[mult_idx_q[7][1:0]] <= pack_s4(mult_data);
                        valign_ready_q[mult_idx_q[7][1:0]] <= 1'b1;
                    end
                    MT_FINAL: begin
                        if ((op_q == 2'b11) && !mult_idx_q[7][2]) begin
                            mha_out0_buf_q[mult_idx_q[7][1:0]] <= mult_data;
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
                        param_q <= param;

                        if ((op == 2'b00) || (op == 2'b01)) begin
                            rd_req_cnt_q  <= 2'd0;
                            rd_word_cnt_q <= 9'd0;
                            wr_cmd_cnt_q  <= 9'd0;
                            out_cnt_q     <= 9'd0;
                            wr_pre_pipe_q <= 8'd0;
                            state_q       <= S_RUN;
                        end
                        else if ((op == 2'b10) || (op == 2'b11)) begin
                            wq_q            <= param;
                            att_param_cnt_q <= 2'd1;
                            state_q         <= S_ATT_PARAM;
                        end
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (att_param_cnt_q == 2'd1) begin
                            wk_q            <= param;
                            att_param_cnt_q <= 2'd2;
                        end
                        else begin
                            wv_q             <= param;
                            att_group_base_q <= 9'd0;
                            rd_req_cnt_q     <= 2'd0;
                            rd_word_cnt_q    <= 9'd0;
                            out_cnt_q        <= 9'd0;
                            att_wr_pipe_q    <= 12'd0;
                            state_q          <= S_ATT_READ;
                        end
                    end
                end

                S_RUN: begin
                    wr_burst <= BURST_128;
                    wr_pre_pipe_q <= {wr_pre_pipe_q[6:0], mult_issue_valid};

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
                    if ((rd_req_cnt_q == 2'd0) && rd_ready) begin
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
                        att_sv_issue_cnt_q <= 4'd0;
                        state_q            <= S_ATT_ISSUE_SV;
                    end
                end

                S_ATT_ISSUE_SV: begin
                    if (att_sv_issue_cnt_q == 4'd7) begin
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
                        att_wr_pipe_q         <= 12'd0;
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
                        if (att_group_base_q == 9'd252) begin
                            state_q <= S_IDLE;
                        end
                        else begin
                            att_group_base_q <= att_group_base_q + 9'd4;
                            rd_req_cnt_q     <= 2'd0;
                            rd_word_cnt_q    <= 9'd0;
                            state_q          <= S_ATT_READ;
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

module mult_8stage (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic                 b_transpose,
    input  logic                 a_wide,
    input  logic                 head_mask,
    input  logic                 head_sel,
    input  logic                 in_valid,
    input  logic [255:0]         in_data_A,
    input  logic [2047:0]        in_data_A_wide,
    input  logic [255:0]         in_data_B,
    output logic                 out_valid,
    output logic [2047:0]        out_data
);

    localparam int STAGES = 8;
    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int DOT_SIZE = 9;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [31:0] s32_t;

    logic         valid_q    [0:STAGES-1];
    logic [1:0]   op_q       [0:STAGES-1];
    logic         b_trans_q  [0:STAGES-1];
    logic         a_wide_q   [0:STAGES-1];
    logic         head_mask_q[0:STAGES-1];
    logic         head_sel_q [0:STAGES-1];
    logic [255:0] mat_A_q    [0:STAGES-1];
    logic [2047:0] mat_A_wide_q [0:STAGES-1];
    logic [255:0] mat_B_q    [0:STAGES-1];
    s32_t         data_q     [0:STAGES-1][0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic s4_t get_pad_s4(input logic [255:0] vec, input integer row, input integer col);
        if ((row < 0) || (row >= ROW_ELEM) || (col < 0) || (col >= ROW_ELEM)) begin
            get_pad_s4 = 4'sd0;
        end
        else begin
            get_pad_s4 = get_s4(vec, (row * ROW_ELEM) + col);
        end
    endfunction

    function automatic s32_t sel_a(
        input logic [255:0]  mat_A,
        input logic [2047:0] mat_A_wide,
        input logic [1:0]    op_sel,
        input logic          a_wide_sel,
        input logic          head_mask_sel,
        input logic          head_sel_sel,
        input integer        stage,
        input integer        lane,
        input integer        tap
    );
        integer idx;
        integer row;
        integer col;
        begin
            if (op_sel == 2'b01) begin
                idx   = (stage * ROW_ELEM) + lane;
                row   = idx / ROW_ELEM;
                col   = idx % ROW_ELEM;
                sel_a = get_pad_s4(mat_A, row + (tap / 3) - 1, col + (tap % 3) - 1);
            end
            else if (tap == 8) begin
                sel_a = 4'sd0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_a = 4'sd0;
            end
            else if (a_wide_sel) begin
                sel_a = get_i32(mat_A_wide, (stage * ROW_ELEM) + tap);
            end
            else begin
                sel_a = get_s4(mat_A, (stage * ROW_ELEM) + tap);
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

    genvar st;
    generate
        for (st = 0; st < STAGES; st++) begin : g_stage
            localparam int PREV_STAGE = (st == 0) ? 0 : st - 1;

            logic [255:0] stage_A;
            logic [2047:0] stage_A_wide;
            logic [255:0] stage_B;
            logic         stage_valid;
            logic [1:0]   stage_op;
            logic         stage_b_trans;
            logic         stage_a_wide;
            logic         stage_head_mask;
            logic         stage_head_sel;
            s32_t         data_next [0:MAT_SIZE-1];
            s32_t         mul_a [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s4_t          mul_b [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s32_t         prod  [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s32_t         value;
            integer       idx;

            always_comb begin
                stage_valid = (st == 0) ? in_valid  : valid_q[PREV_STAGE];
                stage_op    = (st == 0) ? op        : op_q[PREV_STAGE];
                stage_b_trans = (st == 0) ? b_transpose : b_trans_q[PREV_STAGE];
                stage_a_wide = (st == 0) ? a_wide : a_wide_q[PREV_STAGE];
                stage_head_mask = (st == 0) ? head_mask : head_mask_q[PREV_STAGE];
                stage_head_sel = (st == 0) ? head_sel : head_sel_q[PREV_STAGE];
                stage_A     = (st == 0) ? in_data_A : mat_A_q[PREV_STAGE];
                stage_A_wide = (st == 0) ? in_data_A_wide : mat_A_wide_q[PREV_STAGE];
                stage_B     = (st == 0) ? in_data_B : mat_B_q[PREV_STAGE];

                for (int i = 0; i < MAT_SIZE; i++) begin
                    data_next[i] = (st == 0) ? 32'sd0 : data_q[PREV_STAGE][i];
                end

                for (int lane = 0; lane < ROW_ELEM; lane++) begin
                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        mul_a[lane][tap] = sel_a(stage_A, stage_A_wide, stage_op,
                                                 stage_a_wide, stage_head_mask,
                                                 stage_head_sel, st, lane, tap);
                        mul_b[lane][tap] = sel_b(stage_B, stage_op, stage_b_trans,
                                                 stage_head_mask, stage_head_sel,
                                                 lane, tap);
                        prod[lane][tap]  = $signed(mul_a[lane][tap]) * $signed(mul_b[lane][tap]);
                    end

                    idx   = (st * ROW_ELEM) + lane;
                    value = ((prod[lane][0] + prod[lane][1]) + (prod[lane][2] + prod[lane][3])) +
                            ((prod[lane][4] + prod[lane][5]) + (prod[lane][6] + prod[lane][7]) +
                             prod[lane][8]);

                    data_next[idx] = value;
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_q[st] <= 1'b0;
                    op_q[st]    <= 2'b00;
                    b_trans_q[st] <= 1'b0;
                    a_wide_q[st] <= 1'b0;
                    head_mask_q[st] <= 1'b0;
                    head_sel_q[st] <= 1'b0;
                    mat_A_q[st] <= 256'd0;
                    mat_A_wide_q[st] <= 2048'd0;
                    mat_B_q[st] <= 256'd0;
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        data_q[st][i] <= 32'sd0;
                    end
                end
                else begin
                    valid_q[st] <= stage_valid;
                    op_q[st]    <= stage_op;
                    b_trans_q[st] <= stage_b_trans;
                    a_wide_q[st] <= stage_a_wide;
                    head_mask_q[st] <= stage_head_mask;
                    head_sel_q[st] <= stage_head_sel;
                    mat_A_q[st] <= stage_A;
                    mat_A_wide_q[st] <= stage_A_wide;
                    mat_B_q[st] <= stage_B;

                    for (int i = 0; i < MAT_SIZE; i++) begin
                        data_q[st][i] <= data_next[i];
                    end
                end
            end
        end
    endgenerate

    assign out_valid = valid_q[STAGES-1];

    always_comb begin
        out_data = 2048'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            out_data[2047 - (i * 32) -: 32] = data_q[STAGES-1][i];
        end
    end

endmodule

module act_2stage_parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [2047:0] in_data,
    output logic          out_valid,
    output logic [2047:0] out_data
);

    localparam int MAT_SIZE   = 64;
    localparam int ROW_ELEM   = 8;
    localparam int AVG_GROUPS = 8;

    typedef logic signed [31:0] s32_t;
    typedef logic signed [39:0] s40_t;

    logic          avg_valid_q;
    logic [1:0]    avg_act_q;
    logic [2047:0] avg_data_q;
    s40_t          avg_q [0:AVG_GROUPS-1];

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic s40_t ext40(input s32_t value);
        ext40 = {{8{value[31]}}, value};
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

    function automatic s40_t calc_avg(
        input logic [2047:0] matrix,
        input logic [1:0]    act_sel,
        input integer        group
    );
        s40_t sum;
        begin
            sum      = 40'sd0;
            calc_avg = 40'sd0;

            case (act_sel)
                2'b01,
                2'b10: begin
                    for (int i = 0; i < ROW_ELEM; i++) begin
                        sum += ext40(get_i32(matrix, avg_src_idx(act_sel, group, i)));
                    end
                    calc_avg = sum >>> 3;
                end
                2'b11: begin
                    if (group < 4) begin
                        for (int i = 0; i < 16; i++) begin
                            sum += ext40(get_i32(matrix, avg_src_idx(act_sel, group, i)));
                        end
                        calc_avg = sum >>> 4;
                    end
                end
                default: begin
                    calc_avg = 40'sd0;
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

    function automatic s32_t activate(
        input s32_t        value,
        input logic [1:0]  act_sel,
        input s40_t        threshold
    );
        begin
            if (act_sel == 2'b00) begin
                activate = (value < 0) ? 32'sd0 : value;
            end
            else begin
                activate = (ext40(value) < threshold) ? (value >>> 3) : value;
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg_valid_q <= 1'b0;
            avg_act_q   <= 2'b00;
            avg_data_q  <= 2048'd0;
            out_valid   <= 1'b0;
            out_data    <= 2048'd0;

            for (int i = 0; i < AVG_GROUPS; i++) begin
                avg_q[i] <= 40'sd0;
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
                    out_data[2047 - (i * 32) -: 32] <=
                        activate(get_i32(avg_data_q, i), avg_act_q,
                                 avg_q[value_group(avg_act_q, i)]);
                end
            end
        end
    end

endmodule

module pot_3stage_parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [2047:0] in_data,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAT_SIZE = 64;
    localparam int MAX_C1   = 8;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [31:0] s32_t;

    logic          max1_valid_q;
    logic          max2_valid_q;
    logic [2047:0] max1_data_q;
    logic [2047:0] max2_data_q;
    logic [31:0]   max1_q [0:MAX_C1-1];
    logic [31:0]   max2_q;

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic logic [31:0] abs32(input s32_t value);
        abs32 = (value < 0) ? -value : value;
    endfunction

    function automatic logic [31:0] max8(
        input logic [31:0] a,
        input logic [31:0] b,
        input logic [31:0] c,
        input logic [31:0] d,
        input logic [31:0] e,
        input logic [31:0] f,
        input logic [31:0] g,
        input logic [31:0] h
    );
        logic [31:0] l1_0;
        logic [31:0] l1_1;
        logic [31:0] l1_2;
        logic [31:0] l1_3;
        logic [31:0] l2_0;
        logic [31:0] l2_1;
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

    function automatic logic [5:0] pot_shift(input logic [31:0] max_abs);
        logic [5:0] msb;
        begin
            msb = 6'd0;
            for (int b = 0; b < 32; b++) begin
                if (max_abs[b]) begin
                    msb = b[5:0];
                end
            end
            pot_shift = (msb > 6'd2) ? (msb - 6'd2) : 6'd0;
        end
    endfunction

    function automatic s4_t clamp_s4(input s32_t value);
        begin
            if (value > 32'sd7) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < -32'sd8) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic logic [255:0] quant_all(
        input logic [2047:0] src_data,
        input logic [5:0]    shift
    );
        s32_t   scaled;
        begin
            quant_all = 256'd0;

            for (int i = 0; i < MAT_SIZE; i++) begin
                scaled = get_i32(src_data, i) >>> shift;
                quant_all[255 - (i * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max1_valid_q <= 1'b0;
            max2_valid_q <= 1'b0;
            max1_data_q  <= 2048'd0;
            max2_data_q  <= 2048'd0;
            max2_q       <= 32'd0;
            out_valid    <= 1'b0;
            out_data     <= 256'd0;

            for (int i = 0; i < MAX_C1; i++) begin
                max1_q[i] <= 32'd0;
            end
        end
        else begin
            max1_valid_q <= in_valid;
            max2_valid_q <= max1_valid_q;
            out_valid    <= max2_valid_q;

            if (in_valid) begin
                max1_data_q <= in_data;

                for (int i = 0; i < MAX_C1; i++) begin
                    max1_q[i] <= max8(abs32(get_i32(in_data, (i * 8) + 0)),
                                      abs32(get_i32(in_data, (i * 8) + 1)),
                                      abs32(get_i32(in_data, (i * 8) + 2)),
                                      abs32(get_i32(in_data, (i * 8) + 3)),
                                      abs32(get_i32(in_data, (i * 8) + 4)),
                                      abs32(get_i32(in_data, (i * 8) + 5)),
                                      abs32(get_i32(in_data, (i * 8) + 6)),
                                      abs32(get_i32(in_data, (i * 8) + 7)));
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
