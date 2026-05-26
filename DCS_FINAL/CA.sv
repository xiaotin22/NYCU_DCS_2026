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

    logic [1:0]    exec_op;
    logic [1:0]    exec_act;
    logic [255:0]  exec_param;
    logic [255:0]  exec_weight_k;
    logic [255:0]  exec_weight_v;

    logic          datapath_issue_valid;
    logic [2:0]    datapath_issue_mode;
    logic [3:0]    datapath_issue_idx;
    logic          datapath_capture_valid;
    logic [1:0]    datapath_capture_idx;
    logic          datapath_qkv_ready;
    logic          datapath_sv_ready;
    logic          datapath_result_valid;
    logic          datapath_result_commit;

    CA_Control #(
        .RAM_DEPTH (RAM_DEPTH),
        .BURST_BIT (BURST_BIT)
    ) u_control (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .mem_set                (mem_set),
        .in_valid               (in_valid),
        .op                     (op),
        .act                    (act),
        .param                  (param),
        .rd_ready               (rd_ready),
        .rd_valid               (rd_valid),
        .datapath_qkv_ready     (datapath_qkv_ready),
        .datapath_sv_ready      (datapath_sv_ready),
        .datapath_result_valid  (datapath_result_valid),
        .exec_op                (exec_op),
        .exec_act               (exec_act),
        .exec_param             (exec_param),
        .exec_weight_k          (exec_weight_k),
        .exec_weight_v          (exec_weight_v),
        .datapath_issue_valid   (datapath_issue_valid),
        .datapath_issue_mode    (datapath_issue_mode),
        .datapath_issue_idx     (datapath_issue_idx),
        .datapath_capture_valid (datapath_capture_valid),
        .datapath_capture_idx   (datapath_capture_idx),
        .datapath_result_commit (datapath_result_commit),
        .rd_en                  (rd_en),
        .rd_addr                (rd_addr),
        .rd_burst               (rd_burst),
        .wr_en                  (wr_en),
        .wr_addr                (wr_addr),
        .wr_burst               (wr_burst)
    );

    CA_DataPath #(
        .RAM_WIDTH (RAM_WIDTH)
    ) u_datapath (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .issue_valid            (datapath_issue_valid),
        .issue_mode             (datapath_issue_mode),
        .issue_idx              (datapath_issue_idx),
        .capture_valid          (datapath_capture_valid),
        .capture_idx            (datapath_capture_idx),
        .op                     (exec_op),
        .act                    (exec_act),
        .param                  (exec_param),
        .weight_k               (exec_weight_k),
        .weight_v               (exec_weight_v),
        .rd_data                (rd_data),
        .result_commit          (datapath_result_commit),
        .qkv_ready              (datapath_qkv_ready),
        .sv_ready               (datapath_sv_ready),
        .result_valid           (datapath_result_valid),
        .wr_data                (wr_data),
        .out_valid              (out_valid),
        .out_data               (out_data)
    );

endmodule

module CA_Control #(
    parameter RAM_DEPTH = 256,
    parameter BURST_BIT = 3
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,
    input  logic                            rd_ready,
    input  logic                            rd_valid,
    input  logic                            datapath_qkv_ready,
    input  logic                            datapath_sv_ready,
    input  logic                            datapath_result_valid,

    output logic [1:0]                      exec_op,
    output logic [1:0]                      exec_act,
    output logic [255:0]                    exec_param,
    output logic [255:0]                    exec_weight_k,
    output logic [255:0]                    exec_weight_v,
    output logic                            datapath_issue_valid,
    output logic [2:0]                      datapath_issue_mode,
    output logic [3:0]                      datapath_issue_idx,
    output logic                            datapath_capture_valid,
    output logic [1:0]                      datapath_capture_idx,
    output logic                            datapath_result_commit,

    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst
);

    localparam int ADDR_W = $clog2(RAM_DEPTH);
    localparam logic [BURST_BIT-1:0] BURST_4   = 3'd2;
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;

    localparam logic [2:0] IM_NONE  = 3'd0;
    localparam logic [2:0] IM_NORM  = 3'd1;
    localparam logic [2:0] IM_QKV   = 3'd2;
    localparam logic [2:0] IM_SV    = 3'd3;
    localparam logic [2:0] IM_FINAL = 3'd4;

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

    state_t      state_q;
    logic [1:0]  att_param_cnt_q;
    logic [1:0]  rd_req_cnt_q;
    logic [2:0]  att_rd_word_cnt_q;
    logic [7:0]  wr_cmd_cnt_q;
    logic [7:0]  out_cnt_q;
    logic [9:0]  wr_pre_pipe_q;
    logic [7:0]  att_group_base_q;
    logic [3:0]  att_issue_cnt_q;
    logic [2:0]  att_sv_issue_cnt_q;
    logic [2:0]  att_final_issue_cnt_q;
    logic [1:0]  att_final_recv_cnt_q;
    logic [13:0] att_wr_pipe_q;
    logic        att_prefetch_pending_q;

    logic        job_start;
    logic        attention_start;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        rd_cmd_fire;
    logic        result_last;
    logic        att_final_start;
    logic        att_wr_fire;
    logic [7:0]  att_next_group_base;

    function automatic logic op_supported(input logic [1:0] op_sel);
        op_supported = (op_sel == 2'b00) || (op_sel == 2'b01) ||
                       (op_sel == 2'b10) || (op_sel == 2'b11);
    endfunction

    assign job_start              = (state_q == S_IDLE) && mem_set && in_valid && op_supported(op);
    assign attention_start        = job_start && ((op == 2'b10) || (op == 2'b11));
    assign datapath_result_commit = datapath_result_valid;
    assign result_last            = datapath_result_valid && (out_cnt_q == 8'd255);
    assign wr_pre_fire            = wr_pre_pipe_q[9];
    assign wr_cmd_fire            = (state_q == S_RUN) && wr_pre_fire;
    assign rd_cmd_fire            = (state_q == S_RUN) && (rd_req_cnt_q < 2'd2) && rd_ready;
    assign att_final_start        = (state_q == S_ATT_ISSUE_FINAL) && (att_final_issue_cnt_q == 3'd0);
    assign att_wr_fire            = (exec_op == 2'b11) ? att_wr_pipe_q[13] : att_wr_pipe_q[9];
    assign att_next_group_base    = att_group_base_q + 8'd4;

    always_comb begin
        datapath_issue_valid   = 1'b0;
        datapath_issue_mode    = IM_NONE;
        datapath_issue_idx     = 4'd0;
        datapath_capture_valid = 1'b0;
        datapath_capture_idx   = att_rd_word_cnt_q[1:0];

        case (state_q)
            S_RUN: begin
                if (rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_NORM;
                end
            end

            S_ATT_READ: begin
                if (rd_valid && (att_rd_word_cnt_q < 3'd4)) begin
                    datapath_capture_valid = 1'b1;
                    datapath_capture_idx   = att_rd_word_cnt_q[1:0];
                end
            end

            S_ATT_ISSUE_QKV: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_QKV;
                datapath_issue_idx   = att_issue_cnt_q;
            end

            S_ATT_ISSUE_SV: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_SV;
                datapath_issue_idx   = att_sv_issue_cnt_q;
            end

            S_ATT_ISSUE_FINAL: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_FINAL;
                datapath_issue_idx   = {1'b0, att_final_issue_cnt_q};
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q               <= S_IDLE;
            exec_op               <= 2'b00;
            exec_act              <= 2'b00;
            exec_param            <= 256'd0;
            exec_weight_k         <= 256'd0;
            exec_weight_v         <= 256'd0;
            att_param_cnt_q       <= 2'd0;
            rd_req_cnt_q          <= 2'd0;
            att_rd_word_cnt_q     <= 3'd0;
            wr_cmd_cnt_q          <= 8'd0;
            out_cnt_q             <= 8'd0;
            wr_pre_pipe_q         <= 10'd0;
            att_group_base_q      <= 8'd0;
            att_issue_cnt_q       <= 4'd0;
            att_sv_issue_cnt_q    <= 3'd0;
            att_final_issue_cnt_q <= 3'd0;
            att_final_recv_cnt_q  <= 2'd0;
            att_wr_pipe_q         <= 14'd0;
            att_prefetch_pending_q <= 1'b0;
            rd_en                 <= 1'b0;
            rd_addr               <= '0;
            rd_burst              <= '0;
            wr_en                 <= 1'b0;
            wr_addr               <= '0;
            wr_burst              <= '0;
        end
        else begin
            rd_en    <= 1'b0;
            wr_en    <= 1'b0;
            rd_burst <= '0;
            wr_burst <= '0;

            att_wr_pipe_q <= {att_wr_pipe_q[12:0], att_final_start};

            if (att_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= att_group_base_q[ADDR_W-1:0];
                wr_burst <= BURST_4;
            end

            case (state_q)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op   <= op;
                        exec_act  <= act;
                        exec_param <= param;

                        rd_req_cnt_q          <= 2'd0;
                        att_rd_word_cnt_q     <= 3'd0;
                        wr_cmd_cnt_q          <= 8'd0;
                        out_cnt_q             <= 8'd0;
                        wr_pre_pipe_q         <= 10'd0;
                        att_wr_pipe_q         <= 14'd0;
                        att_final_recv_cnt_q  <= 2'd0;
                        att_prefetch_pending_q <= 1'b0;

                        if (attention_start) begin
                            att_param_cnt_q <= 2'd1;
                            state_q         <= S_ATT_PARAM;
                        end
                        else begin
                            state_q <= S_RUN;
                        end
                    end
                end

                S_RUN: begin
                    wr_pre_pipe_q <= {wr_pre_pipe_q[8:0], datapath_issue_valid};

                    if (rd_cmd_fire) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
                        rd_burst     <= BURST_128;
                        rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
                    end

                    if (wr_cmd_fire) begin
                        if (wr_cmd_cnt_q[6:0] == 7'd0) begin
                            wr_en    <= 1'b1;
                            wr_addr  <= wr_cmd_cnt_q[ADDR_W-1:0];
                            wr_burst <= BURST_128;
                        end
                        wr_cmd_cnt_q <= wr_cmd_cnt_q + 1'b1;
                    end

                    if (datapath_result_valid) begin
                        if (result_last) begin
                            state_q <= S_IDLE;
                        end
                        else begin
                            out_cnt_q <= out_cnt_q + 1'b1;
                        end
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (att_param_cnt_q == 2'd1) begin
                            exec_weight_k   <= param;
                            att_param_cnt_q <= 2'd2;
                        end
                        else begin
                            exec_weight_v         <= param;
                            att_group_base_q       <= 8'd0;
                            rd_req_cnt_q           <= 2'd0;
                            att_rd_word_cnt_q      <= 3'd0;
                            out_cnt_q              <= 8'd0;
                            att_final_recv_cnt_q   <= 2'd0;
                            att_wr_pipe_q          <= 14'd0;
                            att_prefetch_pending_q <= 1'b0;
                            state_q                <= S_ATT_READ;
                        end
                    end
                end

                S_ATT_READ: begin
                    if (!att_prefetch_pending_q && (rd_req_cnt_q == 2'd0) && rd_ready) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= att_group_base_q[ADDR_W-1:0];
                        rd_burst     <= BURST_4;
                        rd_req_cnt_q <= 2'd1;
                    end

                    if (rd_valid && (att_rd_word_cnt_q < 3'd4)) begin
                        if (att_rd_word_cnt_q == 3'd3) begin
                            att_issue_cnt_q         <= 4'd0;
                            att_prefetch_pending_q <= 1'b0;
                            state_q                 <= S_ATT_ISSUE_QKV;
                        end
                        att_rd_word_cnt_q <= att_rd_word_cnt_q + 3'd1;
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
                    if (datapath_qkv_ready) begin
                        att_sv_issue_cnt_q <= 3'd0;
                        state_q            <= S_ATT_ISSUE_SV;
                    end
                end

                S_ATT_ISSUE_SV: begin
                    if (!att_prefetch_pending_q && (att_group_base_q != 8'd252) && rd_ready) begin
                        rd_en                    <= 1'b1;
                        rd_addr                  <= att_next_group_base[ADDR_W-1:0];
                        rd_burst                 <= BURST_4;
                        att_prefetch_pending_q  <= 1'b1;
                    end

                    if (att_sv_issue_cnt_q == 3'd7) begin
                        state_q <= S_ATT_WAIT_SV;
                    end
                    else begin
                        att_sv_issue_cnt_q <= att_sv_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_SV: begin
                    if (datapath_sv_ready) begin
                        att_final_issue_cnt_q <= 3'd0;
                        att_final_recv_cnt_q  <= 2'd0;
                        att_wr_pipe_q         <= 14'd0;
                        state_q               <= S_ATT_ISSUE_FINAL;
                    end
                end

                S_ATT_ISSUE_FINAL: begin
                    if (((exec_op == 2'b11) && (att_final_issue_cnt_q == 3'd7)) ||
                        ((exec_op != 2'b11) && (att_final_issue_cnt_q == 3'd3))) begin
                        state_q <= S_ATT_WAIT_FINAL;
                    end
                    else begin
                        att_final_issue_cnt_q <= att_final_issue_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_FINAL: begin
                    if (datapath_result_valid) begin
                        if (att_final_recv_cnt_q == 2'd3) begin
                            if (att_group_base_q == 8'd252) begin
                                state_q <= S_IDLE;
                            end
                            else begin
                                att_group_base_q     <= att_next_group_base;
                                rd_req_cnt_q         <= att_prefetch_pending_q ? 2'd1 : 2'd0;
                                att_rd_word_cnt_q    <= 3'd0;
                                att_final_recv_cnt_q <= 2'd0;
                                state_q              <= S_ATT_READ;
                            end
                        end
                        else begin
                            att_final_recv_cnt_q <= att_final_recv_cnt_q + 1'b1;
                        end

                        if (out_cnt_q != 8'd255) begin
                            out_cnt_q <= out_cnt_q + 1'b1;
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

module CA_DataPath #(
    parameter RAM_WIDTH = 256
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 issue_valid,
    input  logic [2:0]           issue_mode,
    input  logic [3:0]           issue_idx,
    input  logic                 capture_valid,
    input  logic [1:0]           capture_idx,
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [255:0]         weight_k,
    input  logic [255:0]         weight_v,
    input  logic [RAM_WIDTH-1:0] rd_data,
    input  logic                 result_commit,

    output logic                 qkv_ready,
    output logic                 sv_ready,
    output logic                 result_valid,
    output logic [RAM_WIDTH-1:0] wr_data,
    output logic                 out_valid,
    output logic [31:0]          out_data
);

    localparam logic [2:0] IM_NORM  = 3'd1;
    localparam logic [2:0] IM_QKV   = 3'd2;
    localparam logic [2:0] IM_SV    = 3'd3;
    localparam logic [2:0] IM_FINAL = 3'd4;

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_BYPASS  = 2'd1;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

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
        PT_SCORE,
        PT_FINAL
    } pipe_tag_t;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

    logic [255:0]  x_buf_q        [0:3];
    logic [255:0]  q_buf_q        [0:3];
    logic [255:0]  k_buf_q        [0:3];
    logic [255:0]  v_buf_q        [0:3];
    logic [1023:0] score_buf_q    [0:7];
    logic [1023:0] mha_out0_buf_q [0:3];
    logic [255:0]  valign_buf_q   [0:3];
    logic [3:0]    q_ready_q;
    logic [3:0]    k_ready_q;
    logic [3:0]    v_ready_q;
    logic [7:0]    score_ready_q;
    logic [3:0]    valign_ready_q;

    logic          mult_issue_valid;
    logic [1:0]    mult_issue_op;
    logic          mult_issue_b_transpose;
    logic          mult_issue_a_wide;
    logic          mult_issue_head_mask;
    logic          mult_issue_head_sel;
    logic [255:0]  mult_issue_A;
    logic [1023:0] mult_issue_A_wide;
    logic [255:0]  mult_issue_B;
    mult_tag_t     mult_issue_tag;
    logic [2:0]    mult_issue_idx;
    logic          mult_valid;
    logic [1023:0] mult_data;
    mult_tag_t     mult_tag_q [0:7];
    logic [2:0]    mult_idx_q [0:7];

    logic          act_in_valid;
    logic [1:0]    act_in_mode;
    logic [1023:0] act_in_data;
    pipe_tag_t     act_in_tag;
    logic [2:0]    act_in_idx;
    logic          act_valid;
    logic [1023:0] act_data;
    pipe_tag_t     act_tag_q [0:1];
    logic [2:0]    act_idx_q [0:1];

    logic          pot_in_valid;
    logic [1023:0] pot_in_data;
    pipe_tag_t     pot_in_tag;
    logic [2:0]    pot_in_idx;
    logic          pot_valid;
    logic [255:0]  pot_data;
    pipe_tag_t     pot_tag_q [0:4];
    logic [2:0]    pot_idx_q [0:4];

    logic          mha_comb_valid;
    logic [1023:0] mha_comb_data;
    logic [2:0]    mha_comb_idx;

    assign qkv_ready = (&q_ready_q) && (&k_ready_q) && (&v_ready_q);
    assign sv_ready  = (op == 2'b11) ? (&score_ready_q) :
                       ((&score_ready_q[3:0]) && (&valign_ready_q));
    assign result_valid = pot_valid &&
                          ((pot_tag_q[4] == PT_NORM) ||
                           (pot_tag_q[4] == PT_FINAL));

    function automatic logic [255:0] identity_matrix();
        begin
            identity_matrix = 256'd0;
            for (int i = 0; i < 8; i++) begin
                identity_matrix[255 - (((i * 8) + i) * 4) -: 4] = 4'sd1;
            end
        end
    endfunction

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s4_t clamp_s4(input s16_t value);
        begin
            if (value > 16'sd7) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < -16'sd8) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic logic [255:0] pack_s4(input logic [1023:0] src_data);
        begin
            pack_s4 = 256'd0;
            for (int i = 0; i < 64; i++) begin
                pack_s4[255 - (i * 4) -: 4] = clamp_s4(get_i16(src_data, i));
            end
        end
    endfunction

    function automatic logic [1023:0] combine_mha_heads(
        input logic [1023:0] head0,
        input logic [1023:0] head1
    );
        begin
            combine_mha_heads = 1024'd0;
            for (int i = 0; i < 64; i++) begin
                combine_mha_heads[1023 - (i * 16) -: 16] =
                    ((i % 8) < 4) ? head0[1023 - (i * 16) -: 16] :
                                    head1[1023 - (i * 16) -: 16];
            end
        end
    endfunction

    always_comb begin
        mult_issue_valid       = 1'b0;
        mult_issue_op          = op;
        mult_issue_b_transpose = 1'b0;
        mult_issue_a_wide      = 1'b0;
        mult_issue_head_mask   = 1'b0;
        mult_issue_head_sel    = 1'b0;
        mult_issue_A           = 256'd0;
        mult_issue_A_wide      = 1024'd0;
        mult_issue_B           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_idx         = 3'd0;

        if (issue_valid) begin
            mult_issue_valid = 1'b1;

            case (issue_mode)
                IM_NORM: begin
                    mult_issue_A   = rd_data[255:0];
                    mult_issue_B   = param;
                    mult_issue_tag = MT_NORM;
                end

                IM_QKV: begin
                    case (issue_idx)
                        4'd0, 4'd1, 4'd2:    mult_issue_idx = 3'd0;
                        4'd3, 4'd4, 4'd5:    mult_issue_idx = 3'd1;
                        4'd6, 4'd7, 4'd8:    mult_issue_idx = 3'd2;
                        default:             mult_issue_idx = 3'd3;
                    endcase
                    mult_issue_A   = x_buf_q[mult_issue_idx[1:0]];

                    case (issue_idx)
                        4'd0, 4'd3, 4'd6, 4'd9: begin
                            mult_issue_B   = param;
                            mult_issue_tag = MT_Q;
                        end
                        4'd1, 4'd4, 4'd7, 4'd10: begin
                            mult_issue_B   = weight_k;
                            mult_issue_tag = MT_K;
                        end
                        default: begin
                            mult_issue_B   = weight_v;
                            mult_issue_tag = MT_V;
                        end
                    endcase
                end

                IM_SV: begin
                    if (op == 2'b11) begin
                        mult_issue_idx         = {issue_idx[2], issue_idx[1:0]};
                        mult_issue_A           = q_buf_q[issue_idx[1:0]];
                        mult_issue_B           = k_buf_q[issue_idx[1:0]];
                        mult_issue_b_transpose = 1'b1;
                        mult_issue_head_mask   = 1'b1;
                        mult_issue_head_sel    = issue_idx[2];
                        mult_issue_tag         = MT_SCORE;
                    end
                    else begin
                        mult_issue_idx = {1'b0, issue_idx[2:1]};

                        if (!issue_idx[0]) begin
                            mult_issue_A           = q_buf_q[issue_idx[2:1]];
                            mult_issue_B           = k_buf_q[issue_idx[2:1]];
                            mult_issue_b_transpose = 1'b1;
                            mult_issue_tag         = MT_SCORE;
                        end
                        else begin
                            mult_issue_A   = v_buf_q[issue_idx[2:1]];
                            mult_issue_B   = identity_matrix();
                            mult_issue_tag = MT_VALIGN;
                        end
                    end
                end

                IM_FINAL: begin
                    mult_issue_idx    = (op == 2'b11) ?
                                        {issue_idx[2], issue_idx[1:0]} :
                                        {1'b0, issue_idx[1:0]};
                    mult_issue_a_wide = 1'b1;
                    mult_issue_A_wide = score_buf_q[mult_issue_idx];
                    mult_issue_B      = (op == 2'b11) ?
                                        v_buf_q[issue_idx[1:0]] :
                                        valign_buf_q[issue_idx[1:0]];
                    mult_issue_tag    = MT_FINAL;
                end

                default: begin
                    mult_issue_valid = 1'b0;
                end
            endcase
        end
    end

    assign mha_comb_valid = mult_valid && (op == 2'b11) &&
                            (mult_tag_q[7] == MT_FINAL) && mult_idx_q[7][2];
    assign mha_comb_idx   = {1'b0, mult_idx_q[7][1:0]};
    assign mha_comb_data  = combine_mha_heads(mha_out0_buf_q[mult_idx_q[7][1:0]], mult_data);

    assign act_in_valid = mha_comb_valid ||
                          (mult_valid &&
                           ((mult_tag_q[7] == MT_NORM) ||
                            (mult_tag_q[7] == MT_SCORE) ||
                            ((mult_tag_q[7] == MT_FINAL) && (op != 2'b11))));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = ((mult_tag_q[7] == MT_FINAL) || mha_comb_valid ||
                           (mult_tag_q[7] == MT_SCORE)) ?
                          (mha_comb_valid ? mha_comb_idx : mult_idx_q[7]) : 3'd0;

    always_comb begin
        act_in_tag  = PT_NONE;
        act_in_mode = ACT_USER;

        case (mult_tag_q[7])
            MT_NORM: begin
                act_in_tag  = PT_NORM;
                act_in_mode = ACT_USER;
            end
            MT_SCORE: begin
                act_in_tag  = PT_SCORE;
                act_in_mode = ACT_SPECIAL;
            end
            MT_FINAL: begin
                act_in_tag  = ((op == 2'b11) && !mha_comb_valid) ? PT_NONE : PT_FINAL;
                act_in_mode = ACT_USER;
            end
            default: begin
            end
        endcase
    end

    assign pot_in_valid = (act_valid &&
                           ((act_tag_q[1] == PT_NORM) ||
                            (act_tag_q[1] == PT_FINAL))) ||
                          (mult_valid && ((mult_tag_q[7] == MT_Q) ||
                                          (mult_tag_q[7] == MT_K) ||
                                          (mult_tag_q[7] == MT_V)));
    assign pot_in_data  = (act_valid &&
                           ((act_tag_q[1] == PT_NORM) ||
                            (act_tag_q[1] == PT_FINAL))) ? act_data : mult_data;
    assign pot_in_idx   = (act_valid &&
                           ((act_tag_q[1] == PT_NORM) ||
                            (act_tag_q[1] == PT_FINAL))) ? act_idx_q[1] : mult_idx_q[7];

    always_comb begin
        pot_in_tag = PT_NONE;

        if (act_valid && ((act_tag_q[1] == PT_NORM) ||
                          (act_tag_q[1] == PT_FINAL))) begin
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

    Mult_8Stage_Parallel u_mult (
        .clk            (clk),
        .rst_n          (rst_n),
        .op             (mult_issue_op),
        .b_transpose    (mult_issue_b_transpose),
        .a_wide         (mult_issue_a_wide),
        .head_mask      (mult_issue_head_mask),
        .head_sel       (mult_issue_head_sel),
        .in_valid       (mult_issue_valid),
        .in_data_A      (mult_issue_A),
        .in_data_A_wide (mult_issue_A_wide),
        .in_data_B      (mult_issue_B),
        .out_valid      (mult_valid),
        .out_data       (mult_data)
    );

    ACT_TwoStage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act),
        .act_mode  (act_in_mode),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    PoT_FiveStage_Parallel u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),
        .in_data   (pot_in_data),
        .out_valid (pot_valid),
        .out_data  (pot_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_ready_q      <= 4'd0;
            k_ready_q      <= 4'd0;
            v_ready_q      <= 4'd0;
            score_ready_q  <= 8'd0;
            valign_ready_q <= 4'd0;
            out_valid      <= 1'b0;
            wr_data        <= '0;
            out_data       <= 32'd0;

            for (int i = 0; i < 4; i++) begin
                x_buf_q[i]        <= 256'd0;
                q_buf_q[i]        <= 256'd0;
                k_buf_q[i]        <= 256'd0;
                v_buf_q[i]        <= 256'd0;
                mha_out0_buf_q[i] <= 1024'd0;
                valign_buf_q[i]   <= 256'd0;
            end

            for (int i = 0; i < 8; i++) begin
                score_buf_q[i] <= 1024'd0;
                mult_tag_q[i]  <= MT_NONE;
                mult_idx_q[i]  <= 3'd0;
            end

            for (int i = 0; i < 2; i++) begin
                act_tag_q[i] <= PT_NONE;
                act_idx_q[i] <= 3'd0;
            end

            for (int i = 0; i < 5; i++) begin
                pot_tag_q[i] <= PT_NONE;
                pot_idx_q[i] <= 3'd0;
            end
        end
        else begin
            out_valid <= result_commit;

            if (capture_valid && (capture_idx == 2'd0)) begin
                q_ready_q      <= 4'd0;
                k_ready_q      <= 4'd0;
                v_ready_q      <= 4'd0;
                score_ready_q  <= 8'd0;
                valign_ready_q <= 4'd0;
            end

            if (capture_valid) begin
                x_buf_q[capture_idx] <= rd_data[255:0];
            end

            mult_tag_q[0] <= mult_issue_valid ? mult_issue_tag : MT_NONE;
            mult_idx_q[0] <= mult_issue_idx;
            for (int i = 1; i < 8; i++) begin
                mult_tag_q[i] <= mult_tag_q[i - 1];
                mult_idx_q[i] <= mult_idx_q[i - 1];
            end

            act_tag_q[0] <= act_in_valid ? act_in_tag : PT_NONE;
            act_idx_q[0] <= act_in_idx;
            act_tag_q[1] <= act_tag_q[0];
            act_idx_q[1] <= act_idx_q[0];

            pot_tag_q[0] <= pot_in_valid ? pot_in_tag : PT_NONE;
            pot_idx_q[0] <= pot_in_idx;
            for (int i = 1; i < 5; i++) begin
                pot_tag_q[i] <= pot_tag_q[i - 1];
                pot_idx_q[i] <= pot_idx_q[i - 1];
            end

            if (act_valid && (act_tag_q[1] == PT_SCORE)) begin
                score_buf_q[act_idx_q[1]] <= act_data;
                score_ready_q[act_idx_q[1]] <= 1'b1;
            end

            if (mult_valid) begin
                case (mult_tag_q[7])
                    MT_VALIGN: begin
                        valign_buf_q[mult_idx_q[7][1:0]] <= pack_s4(mult_data);
                        valign_ready_q[mult_idx_q[7][1:0]] <= 1'b1;
                    end
                    MT_FINAL: begin
                        if ((op == 2'b11) && !mult_idx_q[7][2]) begin
                            mha_out0_buf_q[mult_idx_q[7][1:0]] <= mult_data;
                        end
                    end
                    default: begin
                    end
                endcase
            end

            if (pot_valid) begin
                case (pot_tag_q[4])
                    PT_Q: begin
                        q_buf_q[pot_idx_q[4][1:0]] <= pot_data;
                        q_ready_q[pot_idx_q[4][1:0]] <= 1'b1;
                    end
                    PT_K: begin
                        k_buf_q[pot_idx_q[4][1:0]] <= pot_data;
                        k_ready_q[pot_idx_q[4][1:0]] <= 1'b1;
                    end
                    PT_V: begin
                        v_buf_q[pot_idx_q[4][1:0]] <= pot_data;
                        v_ready_q[pot_idx_q[4][1:0]] <= 1'b1;
                    end
                    default: begin
                    end
                endcase
            end

            if (result_commit) begin
                wr_data  <= pot_data;
                out_data <= pot_data[31:0];
            end
        end
    end

endmodule

module Mult_8Stage_Parallel (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic                 b_transpose,
    input  logic                 a_wide,
    input  logic                 head_mask,
    input  logic                 head_sel,
    input  logic                 in_valid,
    input  logic [255:0]         in_data_A,
    input  logic [1023:0]        in_data_A_wide,
    input  logic [255:0]         in_data_B,
    output logic                 out_valid,
    output logic [1023:0]        out_data
);

    localparam int STAGES   = 8;
    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int DOT_SIZE = 9;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

    logic          valid_q      [0:STAGES-1];
    logic [1:0]    op_q         [0:STAGES-1];
    logic          b_trans_q    [0:STAGES-1];
    logic          a_wide_q     [0:STAGES-1];
    logic          head_mask_q  [0:STAGES-1];
    logic          head_sel_q   [0:STAGES-1];
    logic [255:0]  mat_A_q      [0:STAGES-1];
    logic [1023:0] mat_A_wide_q [0:STAGES-1];
    logic [255:0]  mat_B_q      [0:STAGES-1];
    s16_t          data_q       [0:STAGES-1][0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s4_t get_pad_s4(input logic [255:0] vec, input integer row, input integer col);
        if ((row < 0) || (row >= ROW_ELEM) || (col < 0) || (col >= ROW_ELEM)) begin
            get_pad_s4 = 4'sd0;
        end
        else begin
            get_pad_s4 = get_s4(vec, (row * ROW_ELEM) + col);
        end
    endfunction

    function automatic s16_t sel_a(
        input logic [255:0]  mat_A,
        input logic [1023:0] mat_A_wide,
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
                sel_a = 16'sd0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_a = 16'sd0;
            end
            else if (a_wide_sel) begin
                sel_a = get_i16(mat_A_wide, (stage * ROW_ELEM) + tap);
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

            logic [255:0]  stage_A;
            logic [1023:0] stage_A_wide;
            logic [255:0]  stage_B;
            logic          stage_valid;
            logic [1:0]    stage_op;
            logic          stage_b_trans;
            logic          stage_a_wide;
            logic          stage_head_mask;
            logic          stage_head_sel;
            s16_t          data_next [0:MAT_SIZE-1];
            s16_t          mul_a [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s4_t           mul_b [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s16_t          prod  [0:ROW_ELEM-1][0:DOT_SIZE-1];
            s16_t          value;
            integer        idx;

            always_comb begin
                stage_valid     = (st == 0) ? in_valid       : valid_q[PREV_STAGE];
                stage_op        = (st == 0) ? op             : op_q[PREV_STAGE];
                stage_b_trans   = (st == 0) ? b_transpose    : b_trans_q[PREV_STAGE];
                stage_a_wide    = (st == 0) ? a_wide         : a_wide_q[PREV_STAGE];
                stage_head_mask = (st == 0) ? head_mask      : head_mask_q[PREV_STAGE];
                stage_head_sel  = (st == 0) ? head_sel       : head_sel_q[PREV_STAGE];
                stage_A         = (st == 0) ? in_data_A      : mat_A_q[PREV_STAGE];
                stage_A_wide    = (st == 0) ? in_data_A_wide : mat_A_wide_q[PREV_STAGE];
                stage_B         = (st == 0) ? in_data_B      : mat_B_q[PREV_STAGE];

                for (int i = 0; i < MAT_SIZE; i++) begin
                    data_next[i] = (st == 0) ? 16'sd0 : data_q[PREV_STAGE][i];
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
                    valid_q[st]      <= 1'b0;
                    op_q[st]         <= 2'b00;
                    b_trans_q[st]    <= 1'b0;
                    a_wide_q[st]     <= 1'b0;
                    head_mask_q[st]  <= 1'b0;
                    head_sel_q[st]   <= 1'b0;
                    mat_A_q[st]      <= 256'd0;
                    mat_A_wide_q[st] <= 1024'd0;
                    mat_B_q[st]      <= 256'd0;
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        data_q[st][i] <= 16'sd0;
                    end
                end
                else begin
                    valid_q[st]      <= stage_valid;
                    op_q[st]         <= stage_op;
                    b_trans_q[st]    <= stage_b_trans;
                    a_wide_q[st]     <= stage_a_wide;
                    head_mask_q[st]  <= stage_head_mask;
                    head_sel_q[st]   <= stage_head_sel;
                    mat_A_q[st]      <= stage_A;
                    mat_A_wide_q[st] <= stage_A_wide;
                    mat_B_q[st]      <= stage_B;

                    for (int i = 0; i < MAT_SIZE; i++) begin
                        data_q[st][i] <= data_next[i];
                    end
                end
            end
        end
    endgenerate

    assign out_valid = valid_q[STAGES-1];

    always_comb begin
        out_data = 1024'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            out_data[1023 - (i * 16) -: 16] = data_q[STAGES-1][i];
        end
    end

endmodule

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

    localparam int MAT_SIZE  = 64;
    localparam int ROW_ELEM  = 8;
    localparam int HALF_SIZE = MAT_SIZE / 2;

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_BYPASS  = 2'd1;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [19:0] s20_t;

    logic          st1_valid;
    logic [1:0]    st1_act_q;
    logic [1:0]    st1_mode_q;
    logic [1023:0] st1_src;
    logic [1023:0] st1_matrix;
    logic [1023:0] st0_matrix_next;
    logic [1023:0] st1_matrix_next;

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s20_t ext20(input s16_t value);
        ext20 = {{4{value[15]}}, value};
    endfunction

    function automatic integer lane_idx(input logic [1:0] act_sel, input logic phase, input integer lane);
        integer block;
        integer local_idx;
        begin
            case (act_sel)
                2'b10: begin
                    lane_idx = ((lane % ROW_ELEM) * ROW_ELEM) + (phase ? 4 : 0) + (lane / ROW_ELEM);
                end
                2'b11: begin
                    block     = (phase ? 2 : 0) + (lane / 16);
                    local_idx = lane % 16;
                    lane_idx  = (((block / 2) * 4) + (local_idx / 4)) * ROW_ELEM +
                                (((block % 2) * 4) + (local_idx % 4));
                end
                default: begin
                    lane_idx = (phase ? HALF_SIZE : 0) + lane;
                end
            endcase
        end
    endfunction

    function automatic integer lane_group(input logic [1:0] act_sel, input integer lane);
        lane_group = (act_sel == 2'b11) ? (lane / 16) : (lane / ROW_ELEM);
    endfunction

    function automatic s20_t group_sum(
        input logic [1023:0] matrix,
        input logic [1:0]    act_sel,
        input logic          phase,
        input integer        group
    );
        integer lane;
        integer group_size;
        begin
            group_sum  = 20'sd0;
            group_size = (act_sel == 2'b11) ? 16 : ROW_ELEM;

            if ((act_sel != 2'b00) && !((act_sel == 2'b11) && (group > 1))) begin
                for (int i = 0; i < 16; i++) begin
                    if (i < group_size) begin
                        lane = (group * group_size) + i;
                        group_sum += ext20(get_i16(matrix, lane_idx(act_sel, phase, lane)));
                    end
                end
            end
        end
    endfunction

    function automatic s16_t activate_user(input s16_t value, input logic [1:0] act_sel, input s20_t threshold);
        begin
            if (act_sel == 2'b00) begin
                activate_user = (value < 0) ? 16'sd0 : value;
            end
            else begin
                activate_user = (ext20(value) < threshold) ? (value >>> 3) : value;
            end
        end
    endfunction

    function automatic s16_t activate_mode(
        input s16_t        value,
        input logic [1:0]  act_sel,
        input logic [1:0]  mode_sel,
        input s20_t        threshold
    );
        begin
            case (mode_sel)
                ACT_BYPASS: begin
                    activate_mode = value;
                end
                ACT_SPECIAL: begin
                    activate_mode = (value < 0) ? (value >>> 2) : value;
                end
                default: begin
                    activate_mode = activate_user(value, act_sel, threshold);
                end
            endcase
        end
    endfunction

    function automatic logic [1023:0] run_half(
        input logic [1023:0] base_matrix,
        input logic [1023:0] src_matrix,
        input logic [1:0]    act_sel,
        input logic [1:0]    mode_sel,
        input logic          phase
    );
        integer idx;
        integer group;
        s20_t  sum [0:3];
        s20_t  threshold;
        begin
            run_half = base_matrix;

            if (mode_sel == ACT_USER) begin
                for (group = 0; group < 4; group++) begin
                    sum[group] = group_sum(src_matrix, act_sel, phase, group);
                end

                for (int lane = 0; lane < HALF_SIZE; lane++) begin
                    idx       = lane_idx(act_sel, phase, lane);
                    group     = lane_group(act_sel, lane);
                    threshold = (act_sel == 2'b11) ? (sum[group] >>> 4) : (sum[group] >>> 3);
                    run_half[1023 - (idx * 16) -: 16] =
                        activate_mode(get_i16(src_matrix, idx), act_sel, mode_sel, threshold);
                end
            end
            else begin
                for (int lane = 0; lane < HALF_SIZE; lane++) begin
                    idx = (phase ? HALF_SIZE : 0) + lane;
                    run_half[1023 - (idx * 16) -: 16] =
                        activate_mode(get_i16(src_matrix, idx), act_sel, mode_sel, 20'sd0);
                end
            end
        end
    endfunction

    always_comb begin
        st0_matrix_next = run_half(in_data, in_data, act, act_mode, 1'b0);
        st1_matrix_next = run_half(st1_matrix, st1_src, st1_act_q, st1_mode_q, 1'b1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1_valid <= 1'b0;
            out_valid <= 1'b0;
        end
        else begin
            st1_valid <= in_valid;
            out_valid <= st1_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1_act_q  <= 2'd0;
            st1_mode_q <= ACT_USER;
            st1_src    <= 1024'd0;
            st1_matrix <= 1024'd0;
        end
        else if (in_valid) begin
            st1_act_q  <= act;
            st1_mode_q <= act_mode;
            st1_src    <= in_data;
            st1_matrix <= st0_matrix_next;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= 1024'd0;
        end
        else if (st1_valid) begin
            out_data <= st1_matrix_next;
        end
    end

endmodule

module PoT_FiveStage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] in_data,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAT_SIZE  = 64;
    localparam int HALF_SIZE = MAT_SIZE / 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

    logic          max_valid;
    logic [15:0]   max_abs;
    logic [1023:0] src_pipe_q [0:2];
    logic          quant_valid;
    logic [3:0]    quant_shift;
    logic [1023:0] quant_src;
    logic [255:0]  quant_data;
    logic [3:0]    shift_next;
    logic [255:0]  quant_data_next;
    logic [255:0]  out_data_next;

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic logic [3:0] pot_shift(input logic [15:0] max_abs);
        logic [3:0] msb;
        begin
            msb = 4'd0;
            for (int b = 0; b < 16; b++) begin
                if (max_abs[b]) begin
                    msb = b[3:0];
                end
            end
            pot_shift = (msb > 4'd2) ? (msb - 4'd2) : 4'd0;
        end
    endfunction

    function automatic s4_t clamp_s4(input s16_t value);
        begin
            if (value > 16'sd7) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < -16'sd8) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    function automatic logic [255:0] quant_half(
        input logic [255:0]  base_data,
        input logic [1023:0] src_data,
        input logic [3:0]    shift,
        input logic          phase
    );
        integer idx;
        s16_t   scaled;
        begin
            quant_half = base_data;

            for (int lane = 0; lane < HALF_SIZE; lane++) begin
                idx    = (phase ? HALF_SIZE : 0) + lane;
                scaled = get_i16(src_data, idx) >>> shift;
                quant_half[255 - (idx * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    always_comb begin
        shift_next      = pot_shift(max_abs);
        quant_data_next = quant_half(256'd0, src_pipe_q[2], shift_next, 1'b0);
        out_data_next   = quant_half(quant_data, quant_src, quant_shift, 1'b1);
    end

    Matrix_Max_3Stage_Parallel u_matrix_max (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_valid (max_valid),
        .out_max   (max_abs)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int stage = 0; stage < 3; stage++) begin
                src_pipe_q[stage] <= 1024'd0;
            end
        end
        else begin
            src_pipe_q[0] <= in_data;
            src_pipe_q[1] <= src_pipe_q[0];
            src_pipe_q[2] <= src_pipe_q[1];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quant_valid <= 1'b0;
            out_valid   <= 1'b0;
        end
        else begin
            quant_valid <= max_valid;
            out_valid   <= quant_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quant_shift <= 4'd0;
            quant_src   <= 1024'd0;
            quant_data  <= 256'd0;
        end
        else if (max_valid) begin
            quant_shift <= shift_next;
            quant_src   <= src_pipe_q[2];
            quant_data  <= quant_data_next;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= 256'd0;
        end
        else if (quant_valid) begin
            out_data <= out_data_next;
        end
    end

endmodule

module Matrix_Max_3Stage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] in_data,
    output logic          out_valid,
    output logic [15:0]   out_max
);

    localparam int MAT_SIZE    = 64;
    localparam int MAX16_COUNT = 16;
    localparam int MAX4_COUNT  = 4;

    typedef logic signed [15:0] s16_t;

    logic          st1_valid;
    logic          st2_valid;
    logic [15:0]   max16_next [0:MAX16_COUNT-1];
    logic [15:0]   max4_next  [0:MAX4_COUNT-1];
    logic [15:0]   max16_q    [0:MAX16_COUNT-1];
    logic [15:0]   max4_q     [0:MAX4_COUNT-1];
    logic [15:0]   out_max_next;

    function automatic s16_t get_i16(input logic [1023:0] vec, input integer idx);
        get_i16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic logic [15:0] abs16(input s16_t value);
        abs16 = (value < 0) ? -value : value;
    endfunction

    function automatic logic [15:0] max4_u16(
        input logic [15:0] a,
        input logic [15:0] b,
        input logic [15:0] c,
        input logic [15:0] d
    );
        logic [15:0] ab;
        logic [15:0] cd;
        begin
            ab       = (a > b) ? a : b;
            cd       = (c > d) ? c : d;
            max4_u16 = (ab > cd) ? ab : cd;
        end
    endfunction

    function automatic logic [15:0] max4_abs(
        input logic [1023:0] matrix,
        input integer        base_idx
    );
        begin
            max4_abs = max4_u16(abs16(get_i16(matrix, base_idx + 0)),
                                abs16(get_i16(matrix, base_idx + 1)),
                                abs16(get_i16(matrix, base_idx + 2)),
                                abs16(get_i16(matrix, base_idx + 3)));
        end
    endfunction

    always_comb begin
        for (int i = 0; i < MAX16_COUNT; i++) begin
            max16_next[i] = max4_abs(in_data, i * 4);
        end

        for (int i = 0; i < MAX4_COUNT; i++) begin
            max4_next[i] = max4_u16(max16_q[(i * 4) + 0],
                                    max16_q[(i * 4) + 1],
                                    max16_q[(i * 4) + 2],
                                    max16_q[(i * 4) + 3]);
        end

        out_max_next = max4_u16(max4_q[0], max4_q[1], max4_q[2], max4_q[3]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1_valid <= 1'b0;
            st2_valid <= 1'b0;
            out_valid <= 1'b0;
        end
        else begin
            st1_valid <= in_valid;
            st2_valid <= st1_valid;
            out_valid <= st2_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX16_COUNT; i++) begin
                max16_q[i] <= 16'd0;
            end
        end
        else if (in_valid) begin
            for (int i = 0; i < MAX16_COUNT; i++) begin
                max16_q[i] <= max16_next[i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX4_COUNT; i++) begin
                max4_q[i] <= 16'd0;
            end
        end
        else if (st1_valid) begin
            for (int i = 0; i < MAX4_COUNT; i++) begin
                max4_q[i] <= max4_next[i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_max <= 16'd0;
        end
        else if (st2_valid) begin
            out_max <= out_max_next;
        end
    end

endmodule
