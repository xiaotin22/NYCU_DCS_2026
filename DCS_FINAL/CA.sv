typedef enum logic [2:0] {
    IM_NONE  = 3'd0,
    IM_NORM  = 3'd1,
    IM_QKV   = 3'd2,
    IM_SV    = 3'd3,
    IM_FINAL = 3'd4
} issue_mode_t;

typedef enum logic [2:0] {
    MT_NONE,
    MT_NORM,
    MT_Q,
    MT_K,
    MT_V,
    MT_SCORE,
    MT_FINAL
} mult_tag_t;

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
    issue_mode_t   datapath_issue_mode;
    logic [3:0]    datapath_issue_idx;
    logic          datapath_capture_valid;
    logic [1:0]    datapath_capture_idx;
    logic          datapath_qkv_ready;
    logic          datapath_sv_ready;
    logic          datapath_result_valid;

    CA_Control #(
        .RAM_DEPTH (RAM_DEPTH), .BURST_BIT (BURST_BIT)
    ) u_control (
        .clk(clk), .rst_n(rst_n),

        // From Top Module
        .mem_set(mem_set), .in_valid(in_valid),
        .op(op), .act(act), .param(param),

        // From RAM interface
        .rd_ready(rd_ready), .rd_valid(rd_valid),

        // Receive DataPath
        .datapath_qkv_ready     (datapath_qkv_ready),
        .datapath_sv_ready      (datapath_sv_ready),
        .datapath_result_valid  (datapath_result_valid),

        // Output to DataPath
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

        // Output for RAM interface
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_burst(rd_burst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_burst(wr_burst)
    );

    CA_DataPath #(
        .RAM_WIDTH (RAM_WIDTH)
    ) u_datapath (
        .clk                    (clk),
        .rst_n                  (rst_n),
        // From Control Module
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
        // Reading from RAM
        .rd_data                (rd_data),
        // Output to Control Module
        .qkv_ready              (datapath_qkv_ready),
        .sv_ready               (datapath_sv_ready),
        .result_valid           (datapath_result_valid),
        // Output to Top Module
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
    output issue_mode_t                     datapath_issue_mode,
    output logic [3:0]                      datapath_issue_idx,
    output logic                            datapath_capture_valid,
    output logic [1:0]                      datapath_capture_idx,

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

    typedef enum logic [3:0] {
        S_IDLE,
        S_FAST_RUN,
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
    logic        att_param_phase_q;
    logic [1:0]  rd_req_cnt_q;
    logic [1:0]  att_rd_word_cnt_q;
    logic [7:0]  wr_cmd_cnt_q;
    logic [7:0]  out_cnt_q;
    logic [13:0] wr_pre_pipe_q;
    logic [7:0]  att_group_base_q;
    logic [3:0]  att_phase_cnt_q;
    logic [17:0] att_wr_pipe_q;
    logic        att_prefetch_pending_q;

    logic        job_start;
    logic        attention_start;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        rd_cmd_fire;
    logic        att_read_fire;
    logic        att_prefetch_fire;
    logic        result_last;
    logic        att_final_start;
    logic        att_wr_fire;
    logic [7:0]  att_next_group_base;

    assign job_start              = (state_q == S_IDLE) && mem_set && in_valid;
    assign attention_start        = job_start && ((op == 2'b10) || (op == 2'b11));
    assign result_last            = datapath_result_valid && (out_cnt_q == 8'd255);
    assign wr_pre_fire            = wr_pre_pipe_q[13];
    assign wr_cmd_fire            = (state_q == S_FAST_RUN) && wr_pre_fire;
    assign rd_cmd_fire            = (state_q == S_FAST_RUN) && (rd_req_cnt_q < 2'd2) && rd_ready;
    assign att_read_fire          = (state_q == S_ATT_READ) &&
                                    !att_prefetch_pending_q &&
                                    (rd_req_cnt_q == 2'd0) &&
                                    rd_ready;
    assign att_prefetch_fire      = (state_q == S_ATT_ISSUE_SV) &&
                                    !att_prefetch_pending_q &&
                                    (att_group_base_q != 8'd252) &&
                                    rd_ready;
    assign att_final_start        = (state_q == S_ATT_ISSUE_FINAL) && (att_phase_cnt_q == 4'd0);
    assign att_wr_fire            = (exec_op == 2'b11) ? att_wr_pipe_q[17] : att_wr_pipe_q[13];
    assign att_next_group_base    = att_group_base_q + 8'd4;

    always_comb begin
        datapath_issue_valid   = 1'b0;
        datapath_issue_mode    = IM_NONE;
        datapath_issue_idx     = 4'd0;
        datapath_capture_valid = 1'b0;
        datapath_capture_idx   = att_rd_word_cnt_q;

        case (state_q)
            S_FAST_RUN: begin
                if (rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_NORM;
                end
            end

            S_ATT_READ: begin
                if (rd_valid) begin
                    datapath_capture_valid = 1'b1;
                    datapath_capture_idx   = att_rd_word_cnt_q;
                end
            end

            S_ATT_ISSUE_QKV: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_QKV;
                datapath_issue_idx   = att_phase_cnt_q;
            end

            S_ATT_ISSUE_SV: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_SV;
                datapath_issue_idx   = att_phase_cnt_q;
            end

            S_ATT_ISSUE_FINAL: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_mode  = IM_FINAL;
                datapath_issue_idx   = att_phase_cnt_q;
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q                <= S_IDLE;
            rd_req_cnt_q           <= 2'd0;
            att_rd_word_cnt_q      <= 2'd0;
            wr_cmd_cnt_q           <= 8'd0;
            out_cnt_q              <= 8'd0;
            wr_pre_pipe_q          <= 14'd0;
            att_group_base_q       <= 8'd0;
            att_phase_cnt_q        <= 4'd0;
            att_wr_pipe_q          <= 18'd0;
            att_prefetch_pending_q <= 1'b0;
            wr_en                  <= 1'b0;
        end
        else begin
            wr_en    <= 1'b0;
            wr_burst <= '0;

            att_wr_pipe_q <= {att_wr_pipe_q[16:0], att_final_start};

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
                        att_rd_word_cnt_q     <= 2'd0;
                        wr_cmd_cnt_q          <= 8'd0;
                        out_cnt_q             <= 8'd0;
                        wr_pre_pipe_q         <= 14'd0;
                        att_wr_pipe_q         <= 18'd0;
                        att_prefetch_pending_q <= 1'b0;

                        if (attention_start) begin
                            att_param_phase_q <= 1'b0;
                            state_q           <= S_ATT_PARAM;
                        end
                        else begin
                            state_q <= S_FAST_RUN;
                        end
                    end
                end

                S_FAST_RUN: begin
                    wr_pre_pipe_q <= {wr_pre_pipe_q[12:0], datapath_issue_valid};

                    if (rd_cmd_fire) begin
                        rd_addr      <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
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
                        if (!att_param_phase_q) begin
                            exec_weight_k     <= param;
                            att_param_phase_q <= 1'b1;
                        end
                        else begin
                            exec_weight_v          <= param;
                            att_group_base_q       <= 8'd0;
                            rd_req_cnt_q           <= 2'd0;
                            att_rd_word_cnt_q      <= 2'd0;
                            out_cnt_q              <= 8'd0;
                            att_wr_pipe_q          <= 18'd0;
                            att_prefetch_pending_q <= 1'b0;
                            state_q                <= S_ATT_READ;
                        end
                    end
                end

                S_ATT_READ: begin
                    if (att_read_fire) begin
                        rd_addr      <= att_group_base_q[ADDR_W-1:0];
                        rd_req_cnt_q <= 2'd1;
                    end

                    if (rd_valid) begin
                        if (att_rd_word_cnt_q == 2'd3) begin
                            att_phase_cnt_q        <= 4'd0;
                            att_prefetch_pending_q <= 1'b0;
                            state_q                <= S_ATT_ISSUE_QKV;
                        end
                        else begin
                            att_rd_word_cnt_q <= att_rd_word_cnt_q + 1'b1;
                        end
                    end
                end

                S_ATT_ISSUE_QKV: begin
                    if (att_phase_cnt_q == 4'd11) begin
                        state_q <= S_ATT_WAIT_QKV;
                    end
                    else begin
                        att_phase_cnt_q <= att_phase_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_QKV: begin
                    if (datapath_qkv_ready) begin
                        att_phase_cnt_q <= 4'd0;
                        state_q         <= S_ATT_ISSUE_SV;
                    end
                end

                S_ATT_ISSUE_SV: begin
                    if (att_prefetch_fire) begin
                        rd_addr                 <= att_next_group_base[ADDR_W-1:0];
                        att_prefetch_pending_q  <= 1'b1;
                    end

                    if (((exec_op == 2'b11) && (att_phase_cnt_q == 4'd7)) ||
                        ((exec_op != 2'b11) && (att_phase_cnt_q == 4'd3))) begin
                        state_q <= S_ATT_WAIT_SV;
                    end
                    else begin
                        att_phase_cnt_q <= att_phase_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_SV: begin
                    if (datapath_sv_ready) begin
                        att_phase_cnt_q <= 4'd0;
                        att_wr_pipe_q   <= 18'd0;
                        state_q         <= S_ATT_ISSUE_FINAL;
                    end
                end

                S_ATT_ISSUE_FINAL: begin
                    if (((exec_op == 2'b11) && (att_phase_cnt_q == 4'd7)) ||
                        ((exec_op != 2'b11) && (att_phase_cnt_q == 4'd3))) begin
                        state_q <= S_ATT_WAIT_FINAL;
                    end
                    else begin
                        att_phase_cnt_q <= att_phase_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT_FINAL: begin
                    if (datapath_result_valid) begin
                        if (out_cnt_q[1:0] == 2'd3) begin
                            if (att_group_base_q == 8'd252) begin
                                state_q <= S_IDLE;
                            end
                            else begin
                                att_group_base_q  <= att_next_group_base;
                                rd_req_cnt_q      <= att_prefetch_pending_q ? 2'd1 : 2'd0;
                                att_rd_word_cnt_q <= 2'd0;
                                state_q           <= S_ATT_READ;
                            end
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


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en <= 1'b0;
        end
        else begin
            rd_en    <= 1'b0;
            rd_burst <= '0;
            if (rd_cmd_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_128;
            end
            else if (att_read_fire || att_prefetch_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_4;
            end
        end
    end

endmodule

module CA_DataPath #(
    parameter RAM_WIDTH = 256
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 issue_valid,
    input  issue_mode_t          issue_mode,
    input  logic [3:0]           issue_idx,
    input  logic                 capture_valid,
    input  logic [1:0]           capture_idx,
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [255:0]         weight_k,
    input  logic [255:0]         weight_v,
    input  logic [RAM_WIDTH-1:0] rd_data,

    output logic                 qkv_ready,
    output logic                 sv_ready,
    output logic                 result_valid,
    output logic [RAM_WIDTH-1:0] wr_data,
    output logic                 out_valid,
    output logic [31:0]          out_data
);

    localparam logic [1:0] ACT_USER     = 2'd0;
    localparam logic [1:0] ACT_IDENTITY = 2'd1;
    localparam logic [1:0] ACT_SPECIAL  = 2'd2;

    typedef enum logic [2:0] {
        PT_NONE,
        PT_NORM,
        PT_Q,
        PT_K,
        PT_V,
        PT_SCORE,
        PT_FINAL
    } pipe_tag_t;

    localparam int SCORE_ELEM_W   = 11;
    localparam int SCORE_PACK_W   = SCORE_ELEM_W * 64;
    localparam int MHA_OUT_ELEM_W = 15;
    localparam int MHA_OUT_PACK_W = MHA_OUT_ELEM_W * 64;

    // Attention scores are activated before buffering: SHA fits in signed 11 bits.
    // MHA head0 FINAL partial output can reach -16384, so it keeps 15-bit lanes.
    logic [255:0]  x_buf_q        [0:3];
    logic [255:0]  q_buf_q        [0:3];
    logic [255:0]  k_buf_q        [0:3];
    logic [255:0]  v_buf_q        [0:3];
    logic [SCORE_PACK_W-1:0]   score_buf_q    [0:7];
    logic [MHA_OUT_PACK_W-1:0] mha_out0_buf_q [0:3];
    logic [3:0]    q_ready_q;
    logic [3:0]    k_ready_q;
    logic [3:0]    v_ready_q;
    logic [7:0]    score_ready_q;

    logic          mult_valid;
    logic [1023:0] mult_data;
    mult_tag_t     mult_tag_out;
    logic [2:0]    mult_idx_out;

    logic          act_in_valid;
    logic [1:0]    act_in_mode;
    logic [1023:0] act_in_data;
    pipe_tag_t     act_in_tag;
    logic [2:0]    act_in_idx;
    logic          act_valid;
    logic [1023:0] act_data;
    logic [15:0]   act_max_abs;
    pipe_tag_t     act_tag_q [0:4];
    logic [2:0]    act_idx_q [0:4];

    logic          pot_in_valid;
    logic [1023:0] pot_in_data;
    logic [15:0]   pot_in_max_abs;
    pipe_tag_t     pot_in_tag;
    logic [2:0]    pot_in_idx;
    logic          pot_valid;
    logic [255:0]  pot_data;
    pipe_tag_t     pot_tag_q [0:4];
    logic [2:0]    pot_idx_q [0:4];

    logic          mha_comb_valid;
    logic [1023:0] mha_comb_data;
    logic [2:0]    mha_comb_idx;

    logic                 issue_valid_q;
    issue_mode_t          issue_mode_q;
    logic [3:0]           issue_idx_q;
    logic                 capture_valid_q;
    logic [1:0]           capture_idx_q;
    logic [RAM_WIDTH-1:0] rd_data_q;

    assign qkv_ready = (&q_ready_q) && (&k_ready_q) && (&v_ready_q);
    assign sv_ready  = (op == 2'b11) ? (&score_ready_q) : (&score_ready_q[3:0]);
    assign result_valid = pot_valid &&
                          ((pot_tag_q[4] == PT_NORM) ||
                           (pot_tag_q[4] == PT_FINAL));

    function automatic logic [1023:0] combine_mha_heads(
        input logic [1023:0] head0,
        input logic [1023:0] head1
    );
        logic [1023:0] result;
        begin
            result = 1024'd0;
            for (int r = 0; r < 8; r++) begin
                result[1023 -  r*128       -: 64] = head0[1023 -  r*128       -: 64];
                result[1023 - (r*128 + 64) -: 64] = head1[1023 - (r*128 + 64) -: 64];
            end
            combine_mha_heads = result;
        end
    endfunction

    function automatic logic [SCORE_PACK_W-1:0] pack_score(input logic [1023:0] src);
        begin
            for (int i = 0; i < 64; i++) begin
                pack_score[SCORE_PACK_W-1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W] =
                    src[1023 - (i * 16) - (16 - SCORE_ELEM_W) -: SCORE_ELEM_W];
            end
        end
    endfunction

    function automatic logic [MHA_OUT_PACK_W-1:0] pack_mha_out(input logic [1023:0] src);
        begin
            for (int i = 0; i < 64; i++) begin
                pack_mha_out[MHA_OUT_PACK_W-1 - (i * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W] =
                    src[1023 - (i * 16) - (16 - MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W];
            end
        end
    endfunction

    function automatic logic [1023:0] unpack_mha_out(input logic [MHA_OUT_PACK_W-1:0] src);
        logic [MHA_OUT_ELEM_W-1:0] lane;
        begin
            unpack_mha_out = 1024'd0;
            for (int i = 0; i < 64; i++) begin
                lane = src[MHA_OUT_PACK_W-1 - (i * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W];
                unpack_mha_out[1023 - (i * 16) -: 16] =
                    {{(16-MHA_OUT_ELEM_W){lane[MHA_OUT_ELEM_W-1]}}, lane};
            end
        end
    endfunction

    assign mha_comb_valid = mult_valid && (op == 2'b11) &&
                            (mult_tag_out == MT_FINAL) && mult_idx_out[2];
    assign mha_comb_idx   = {1'b0, mult_idx_out[1:0]};
    assign mha_comb_data  = combine_mha_heads(unpack_mha_out(mha_out0_buf_q[mult_idx_out[1:0]]),
                                              mult_data);

    assign act_in_valid = mha_comb_valid ||
                          (mult_valid &&
                           ((mult_tag_out == MT_NORM) ||
                            (mult_tag_out == MT_Q) ||
                            (mult_tag_out == MT_K) ||
                            (mult_tag_out == MT_V) ||
                            (mult_tag_out == MT_SCORE) ||
                            ((mult_tag_out == MT_FINAL) && (op != 2'b11))));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = mha_comb_valid                       ? mha_comb_idx :
                          ((mult_tag_out == MT_FINAL) ||
                           (mult_tag_out == MT_SCORE) ||
                           (mult_tag_out == MT_Q) ||
                           (mult_tag_out == MT_K) ||
                           (mult_tag_out == MT_V))             ? mult_idx_out :
                                                                  3'd0;

    always_comb begin
        act_in_tag  = PT_NONE;
        act_in_mode = ACT_USER;

        case (mult_tag_out)
            MT_NORM: begin
                act_in_tag  = PT_NORM;
                act_in_mode = ACT_USER;
            end
            MT_Q: begin
                act_in_tag  = PT_Q;
                act_in_mode = ACT_IDENTITY;
            end
            MT_K: begin
                act_in_tag  = PT_K;
                act_in_mode = ACT_IDENTITY;
            end
            MT_V: begin
                act_in_tag  = PT_V;
                act_in_mode = ACT_IDENTITY;
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

    logic use_act_for_pot;
    assign use_act_for_pot = act_valid &&
                             ((act_tag_q[4] == PT_NORM) ||
                              (act_tag_q[4] == PT_Q) ||
                              (act_tag_q[4] == PT_K) ||
                              (act_tag_q[4] == PT_V) ||
                              (act_tag_q[4] == PT_FINAL));

    assign pot_in_valid   = use_act_for_pot;
    assign pot_in_data    = act_data;
    assign pot_in_max_abs = act_max_abs;
    assign pot_in_idx     = act_idx_q[4];

    always_comb begin
        if (use_act_for_pot) begin
            pot_in_tag = act_tag_q[4];
        end
        else begin
            pot_in_tag = PT_NONE;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_valid_q   <= 1'b0;
            capture_valid_q <= 1'b0;
        end
        else begin
            issue_valid_q   <= issue_valid;
            issue_mode_q    <= issue_valid ? issue_mode : IM_NONE;
            issue_idx_q     <= issue_valid ? issue_idx : 4'd0;
            capture_valid_q <= capture_valid;
            capture_idx_q   <= capture_idx;
            rd_data_q       <= rd_data;
        end
    end

    Multiple_Processor #(
        .SCORE_ELEM_W (SCORE_ELEM_W),
        .SCORE_PACK_W (SCORE_PACK_W)
    ) u_mult_proc (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue_valid  (issue_valid_q),
        .issue_mode   (issue_mode_q),
        .issue_idx    (issue_idx_q),
        .op           (op),
        .param        (param),
        .weight_k     (weight_k),
        .weight_v     (weight_v),
        .rd_data      (rd_data_q),
        .x_buf        (x_buf_q),
        .q_buf        (q_buf_q),
        .k_buf        (k_buf_q),
        .v_buf        (v_buf_q),
        .score_buf    (score_buf_q),
        .mult_valid   (mult_valid),
        .mult_data    (mult_data),
        .mult_tag_out (mult_tag_out),
        .mult_idx_out (mult_idx_out)
    );

    ACT_FiveStage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act),
        .act_mode  (act_in_mode),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data),
        .out_max_abs (act_max_abs)
    );

    PoT_FiveStage_Parallel u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),
        .in_data   (pot_in_data),
        .in_max_abs (pot_in_max_abs),
        .out_valid (pot_valid),
        .out_data  (pot_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_ready_q     <= 4'd0;
            k_ready_q     <= 4'd0;
            v_ready_q     <= 4'd0;
            score_ready_q <= 8'd0;
            out_valid     <= 1'b0;
            out_data      <= 32'd0;
        end
        else begin
            out_valid <= result_valid;

            if (capture_valid_q && (capture_idx_q == 2'd0)) begin
                q_ready_q     <= 4'd0;
                k_ready_q     <= 4'd0;
                v_ready_q     <= 4'd0;
                score_ready_q <= 8'd0;
            end

            if (capture_valid_q) begin
                x_buf_q[capture_idx_q] <= rd_data_q[255:0];
            end

            act_tag_q[0] <= act_in_valid ? act_in_tag : PT_NONE;
            act_idx_q[0] <= act_in_idx;
            for (int i = 1; i < 5; i++) begin
                act_tag_q[i] <= act_tag_q[i - 1];
                act_idx_q[i] <= act_idx_q[i - 1];
            end

            pot_tag_q[0] <= pot_in_valid ? pot_in_tag : PT_NONE;
            pot_idx_q[0] <= pot_in_idx;
            for (int i = 1; i < 5; i++) begin
                pot_tag_q[i] <= pot_tag_q[i - 1];
                pot_idx_q[i] <= pot_idx_q[i - 1];
            end

            if (act_valid && (act_tag_q[4] == PT_SCORE)) begin
                score_buf_q[act_idx_q[4]] <= pack_score(act_data);
                score_ready_q[act_idx_q[4]] <= 1'b1;
            end

            if (mult_valid && (mult_tag_out == MT_FINAL) &&
                (op == 2'b11) && !mult_idx_out[2]) begin
                mha_out0_buf_q[mult_idx_out[1:0]] <= pack_mha_out(mult_data);
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

            if (result_valid) begin
                wr_data  <= pot_data;
                out_data <= pot_data[31:0];
            end
        end
    end

endmodule

module Multiple_Processor #(
    parameter int SCORE_ELEM_W = 11,
    parameter int SCORE_PACK_W = SCORE_ELEM_W * 64
)(
    input  logic           clk,
    input  logic           rst_n,

    input  logic           issue_valid,
    input  issue_mode_t    issue_mode,
    input  logic [3:0]     issue_idx,

    input  logic [1:0]     op,
    input  logic [255:0]   param,
    input  logic [255:0]   weight_k,
    input  logic [255:0]   weight_v,
    input  logic [255:0]   rd_data,

    input  logic [255:0]   x_buf       [0:3],
    input  logic [255:0]   q_buf       [0:3],
    input  logic [255:0]   k_buf       [0:3],
    input  logic [255:0]   v_buf       [0:3],
    input  logic [SCORE_PACK_W-1:0] score_buf [0:7],

    output logic           mult_valid,
    output logic [1023:0]  mult_data,
    output mult_tag_t      mult_tag_out,
    output logic [2:0]     mult_idx_out
);

    localparam int MULT_STAGES = 8;

    logic          mult_issue_valid;
    logic          mult_issue_b_transpose;
    logic          mult_issue_a_wide;
    logic          mult_issue_head_mask;
    logic          mult_issue_head_sel;
    logic [255:0]  mult_issue_A;
    logic [1023:0] mult_issue_A_wide;
    logic [255:0]  mult_issue_B;
    mult_tag_t     mult_issue_tag;
    logic [2:0]    mult_issue_idx;

    mult_tag_t  mult_tag_q [0:MULT_STAGES-1];
    logic [2:0] mult_idx_q [0:MULT_STAGES-1];

    function automatic logic [1023:0] unpack_score(input logic [SCORE_PACK_W-1:0] src);
        logic [SCORE_ELEM_W-1:0] lane;
        begin
            unpack_score = 1024'd0;
            for (int i = 0; i < 64; i++) begin
                lane = src[SCORE_PACK_W-1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W];
                unpack_score[1023 - (i * 16) -: 16] =
                    {{(16-SCORE_ELEM_W){lane[SCORE_ELEM_W-1]}}, lane};
            end
        end
    endfunction

    always_comb begin
        mult_issue_valid       = 1'b0;
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
                    mult_issue_A   = rd_data;
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
                    mult_issue_A = x_buf[mult_issue_idx[1:0]];

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
                        mult_issue_idx       = {issue_idx[2], issue_idx[1:0]};
                        mult_issue_head_mask = 1'b1;
                        mult_issue_head_sel  = issue_idx[2];
                    end
                    else begin
                        mult_issue_idx = {1'b0, issue_idx[1:0]};
                    end
                    mult_issue_A           = q_buf[issue_idx[1:0]];
                    mult_issue_B           = k_buf[issue_idx[1:0]];
                    mult_issue_b_transpose = 1'b1;
                    mult_issue_tag         = MT_SCORE;
                end

                IM_FINAL: begin
                    mult_issue_idx    = (op == 2'b11) ?
                                        {issue_idx[2], issue_idx[1:0]} :
                                        {1'b0, issue_idx[1:0]};
                    mult_issue_a_wide = 1'b1;
                    mult_issue_A_wide = unpack_score(score_buf[mult_issue_idx]);
                    mult_issue_B      = v_buf[issue_idx[1:0]];
                    mult_issue_tag    = MT_FINAL;
                end

                default: begin
                    mult_issue_valid = 1'b0;
                end
            endcase
        end
    end

    Mult_8Stage_Parallel u_mult (
        .clk            (clk),
        .rst_n          (rst_n),
        .op             (op),
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

    always_ff @(posedge clk) begin
        mult_tag_q[0] <= mult_issue_valid ? mult_issue_tag : MT_NONE;
        mult_idx_q[0] <= mult_issue_idx;
        for (int i = 1; i < MULT_STAGES; i++) begin
            mult_tag_q[i] <= mult_tag_q[i - 1];
            mult_idx_q[i] <= mult_idx_q[i - 1];
        end
    end

    assign mult_tag_out = mult_tag_q[MULT_STAGES-1];
    assign mult_idx_out = mult_idx_q[MULT_STAGES-1];

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

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
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
                sel_a = get_s16(mat_A_wide, (stage * ROW_ELEM) + tap);
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
                stage_op        = op;
                stage_b_trans   = (st == 0) ? b_transpose    : b_trans_q[PREV_STAGE];
                stage_a_wide    = (st == 0) ? a_wide         : a_wide_q[PREV_STAGE];
                stage_head_mask = (st == 0) ? head_mask      : head_mask_q[PREV_STAGE];
                stage_head_sel  = (st == 0) ? head_sel       : head_sel_q[PREV_STAGE];
                stage_A         = (st == 0) ? in_data_A      : mat_A_q[PREV_STAGE];
                stage_A_wide    = (st == 0) ? in_data_A_wide : mat_A_wide_q[PREV_STAGE];
                stage_B         = (st == 0) ? in_data_B      : mat_B_q[PREV_STAGE];

                for (int i = 0; i < MAT_SIZE; i++) begin
                    if ((st != 0) && (i < st * ROW_ELEM)) begin
                        data_next[i] = data_q[PREV_STAGE][i];
                    end
                    else begin
                        data_next[i] = 16'sd0;
                    end
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
                end
                else begin
                    valid_q[st]      <= stage_valid;
                    

                    if (st < STAGES - 1) begin
                        b_trans_q[st]    <= stage_b_trans;
                        a_wide_q[st]     <= stage_a_wide;
                        head_mask_q[st]  <= stage_head_mask;
                        head_sel_q[st]   <= stage_head_sel;
                        for (int r = 0; r < ROW_ELEM; r++) begin
                            // mat_A_q[st] must carry rows {st..7} forward: Conv stage
                            // st+1 reads rows {st, st+1, st+2}, and subsequent stages
                            // need the rest propagated through this register.
                            if (r >= st) begin
                                mat_A_q[st][255 - r*32 -: 32] <= stage_A[255 - r*32 -: 32];
                            end
                            else begin
                                mat_A_q[st][255 - r*32 -: 32] <= 32'd0;
                            end
                            // mat_A_wide_q[st] must carry rows {st+1..7} forward.
                            if (r > st) begin
                                mat_A_wide_q[st][1023 - r*128 -: 128] <= stage_A_wide[1023 - r*128 -: 128];
                            end
                            else begin
                                mat_A_wide_q[st][1023 - r*128 -: 128] <= 128'd0;
                            end
                        end
                        mat_B_q[st] <= stage_B;
                    end
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        if (i < (st + 1) * ROW_ELEM) begin
                            data_q[st][i] <= data_next[i];
                        end
                        else begin
                            data_q[st][i] <= 16'sd0;
                        end
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

module ACT_FiveStage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [1:0]    act_mode,
    input  logic [1023:0] in_data,
    output logic          out_valid,
    output logic [1023:0] out_data,
    output logic [15:0]   out_max_abs
);

    localparam int MAT_SIZE   = 64;
    localparam int ROW_ELEM   = 8;
    localparam int CHUNK_SIZE = 16;
    localparam int ACT_STAGES = 5;

    localparam logic [1:0] ACT_USER     = 2'd0;
    localparam logic [1:0] ACT_IDENTITY = 2'd1;
    localparam logic [1:0] ACT_SPECIAL  = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [19:0] s20_t;

    logic          valid_q  [0:ACT_STAGES-1];
    logic [1:0]    act_q    [0:ACT_STAGES-1];
    logic [1:0]    mode_q   [0:ACT_STAGES-1];
    logic [1023:0] matrix_q [0:ACT_STAGES-1];
    logic [15:0]   max_q    [0:ACT_STAGES-1];
    // thr_*_q only feeds stages 1..4 (each stage uses prev stage's threshold).
    // Stage 4 is the last apply_chunk consumer, so we only need indices 0..3.
    s20_t          thr_a_q  [0:ACT_STAGES-2];
    s20_t          thr_b_q  [0:ACT_STAGES-2];

    logic [39:0]   thr0_pair;
    logic [39:0]   thr1_pair;
    logic [39:0]   thr2_pair;
    logic [39:0]   thr3_pair;
    logic [1039:0] chunk0_result;
    logic [1039:0] chunk1_result;
    logic [1039:0] chunk2_result;
    logic [1039:0] chunk3_result;

    assign out_valid = valid_q[ACT_STAGES-1];
    assign out_data  = matrix_q[ACT_STAGES-1];
    assign out_max_abs = max_q[ACT_STAGES-1];

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s20_t ext20(input s16_t value);
        ext20 = {{4{value[15]}}, value};
    endfunction

    function automatic logic [15:0] abs16(input s16_t value);
        abs16 = (value < 0) ? -value : value;
    endfunction

    function automatic logic [15:0] max_u16(
        input logic [15:0] a,
        input logic [15:0] b
    );
        max_u16 = (a > b) ? a : b;
    endfunction

    function automatic logic [39:0] calc_threshold_pair(
        input logic [1023:0] matrix,
        input logic [1:0]    act_sel,
        input logic [1:0]    mode_sel,
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

            if ((mode_sel == ACT_USER) && (act_sel != 2'b00)) begin
                case (act_sel)
                    2'b01: begin
                        row0 = chunk * 2;
                        row1 = row0 + 1;
                        for (int c = 0; c < ROW_ELEM; c++) begin
                            sum_a += ext20(get_s16(matrix, (row0 * ROW_ELEM) + c));
                            sum_b += ext20(get_s16(matrix, (row1 * ROW_ELEM) + c));
                        end
                        thr_a = sum_a >>> 3;
                        thr_b = sum_b >>> 3;
                    end

                    2'b10: begin
                        col0 = chunk * 2;
                        col1 = col0 + 1;
                        for (int r = 0; r < ROW_ELEM; r++) begin
                            sum_a += ext20(get_s16(matrix, (r * ROW_ELEM) + col0));
                            sum_b += ext20(get_s16(matrix, (r * ROW_ELEM) + col1));
                        end
                        thr_a = sum_a >>> 3;
                        thr_b = sum_b >>> 3;
                    end

                    2'b11: begin
                        base_row = (chunk / 2) * 4;
                        base_col = (chunk % 2) * 4;
                        for (int r = 0; r < 4; r++) begin
                            for (int c = 0; c < 4; c++) begin
                                sum_a += ext20(get_s16(matrix,
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
            end

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
                ACT_IDENTITY: begin
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

    function automatic logic [1039:0] apply_chunk_with_max(
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
        s16_t  activated;
        logic [1023:0] matrix;
        logic [15:0]   chunk_max;
        begin
            matrix    = base_matrix;
            chunk_max = 16'd0;

            for (int lane = 0; lane < CHUNK_SIZE; lane++) begin
                idx       = chunk_idx(act_sel, mode_sel, chunk, lane);
                threshold = select_threshold(act_sel, lane, threshold_a, threshold_b);
                activated = activate_value(get_s16(src_matrix, idx), act_sel,
                                           mode_sel, threshold);
                matrix[1023 - (idx * 16) -: 16] = activated;
                chunk_max = max_u16(chunk_max, abs16(activated));
            end

            apply_chunk_with_max = {chunk_max, matrix};
        end
    endfunction

    always_comb begin
        thr0_pair = calc_threshold_pair(in_data,     act,      act_mode,  0);
        thr1_pair = calc_threshold_pair(matrix_q[0], act_q[0], mode_q[0], 1);
        thr2_pair = calc_threshold_pair(matrix_q[1], act_q[1], mode_q[1], 2);
        thr3_pair = calc_threshold_pair(matrix_q[2], act_q[2], mode_q[2], 3);

        chunk0_result = apply_chunk_with_max(matrix_q[0], matrix_q[0], act_q[0], mode_q[0],
                                             0, thr_a_q[0], thr_b_q[0]);
        chunk1_result = apply_chunk_with_max(matrix_q[1], matrix_q[1], act_q[1], mode_q[1],
                                             1, thr_a_q[1], thr_b_q[1]);
        chunk2_result = apply_chunk_with_max(matrix_q[2], matrix_q[2], act_q[2], mode_q[2],
                                             2, thr_a_q[2], thr_b_q[2]);
        chunk3_result = apply_chunk_with_max(matrix_q[3], matrix_q[3], act_q[3], mode_q[3],
                                             3, thr_a_q[3], thr_b_q[3]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ACT_STAGES; i++) begin
                valid_q[i] <= 1'b0;
            end
        end
        else begin
            valid_q[0]  <= in_valid;
            act_q[0]    <= act;
            mode_q[0]   <= act_mode;
            matrix_q[0] <= in_data;
            max_q[0]    <= 16'd0;
            thr_a_q[0]  <= $signed(thr0_pair[39:20]);
            thr_b_q[0]  <= $signed(thr0_pair[19:0]);

            valid_q[1]  <= valid_q[0];
            act_q[1]    <= act_q[0];
            mode_q[1]   <= mode_q[0];
            matrix_q[1] <= chunk0_result[1023:0];
            max_q[1]    <= max_u16(max_q[0], chunk0_result[1039:1024]);
            thr_a_q[1]  <= $signed(thr1_pair[39:20]);
            thr_b_q[1]  <= $signed(thr1_pair[19:0]);

            valid_q[2]  <= valid_q[1];
            act_q[2]    <= act_q[1];
            mode_q[2]   <= mode_q[1];
            matrix_q[2] <= chunk1_result[1023:0];
            max_q[2]    <= max_u16(max_q[1], chunk1_result[1039:1024]);
            thr_a_q[2]  <= $signed(thr2_pair[39:20]);
            thr_b_q[2]  <= $signed(thr2_pair[19:0]);

            valid_q[3]  <= valid_q[2];
            act_q[3]    <= act_q[2];
            mode_q[3]   <= mode_q[2];
            matrix_q[3] <= chunk2_result[1023:0];
            max_q[3]    <= max_u16(max_q[2], chunk2_result[1039:1024]);
            thr_a_q[3]  <= $signed(thr3_pair[39:20]);
            thr_b_q[3]  <= $signed(thr3_pair[19:0]);

            valid_q[4]  <= valid_q[3];
            act_q[4]    <= act_q[3];
            mode_q[4]   <= mode_q[3];
            matrix_q[4] <= chunk3_result[1023:0];
            max_q[4]    <= max_u16(max_q[3], chunk3_result[1039:1024]);
        end
    end

endmodule

module PoT_FiveStage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] in_data,
    input  logic [15:0]   in_max_abs,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAT_SIZE  = 64;
    localparam int HALF_SIZE = MAT_SIZE / 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

    logic          quant_valid;
    logic [3:0]    quant_shift;
    logic [1023:0] quant_src;
    logic [255:0]  quant_data;
    logic [2:0]    result_valid_q;
    logic [255:0]  result_data_q [0:2];
    logic [3:0]    shift_next;
    logic [255:0]  quant_data_next;
    logic [255:0]  out_data_next;

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic logic [3:0] pot_shift(input logic [15:0] max_abs);
        logic [3:0] msb;
        begin
            casez (max_abs)
                16'b1???????????????: msb = 4'd15;
                16'b01??????????????: msb = 4'd14;
                16'b001?????????????: msb = 4'd13;
                16'b0001????????????: msb = 4'd12;
                16'b00001???????????: msb = 4'd11;
                16'b000001??????????: msb = 4'd10;
                16'b0000001?????????: msb = 4'd9;
                16'b00000001????????: msb = 4'd8;
                16'b000000001???????: msb = 4'd7;
                16'b0000000001??????: msb = 4'd6;
                16'b00000000001?????: msb = 4'd5;
                16'b000000000001????: msb = 4'd4;
                16'b0000000000001???: msb = 4'd3;
                16'b00000000000001??: msb = 4'd2;
                16'b000000000000001?: msb = 4'd1;
                16'b0000000000000001: msb = 4'd0;
                default:              msb = 4'd0;
            endcase
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
                scaled = get_s16(src_data, idx) >>> shift;
                quant_half[255 - (idx * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    always_comb begin
        shift_next      = pot_shift(in_max_abs);
        quant_data_next = quant_half(256'd0, in_data, shift_next, 1'b0);
        out_data_next   = quant_half(quant_data, quant_src, quant_shift, 1'b1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quant_valid   <= 1'b0;
            result_valid_q <= 3'd0;
            out_valid     <= 1'b0;
        end
        else begin
            quant_valid      <= in_valid;
            result_valid_q[0] <= quant_valid;
            result_valid_q[1] <= result_valid_q[0];
            result_valid_q[2] <= result_valid_q[1];
            out_valid        <= result_valid_q[2];
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid) begin
            quant_shift <= shift_next;
            quant_src   <= in_data;
            quant_data  <= quant_data_next;
        end

        if (quant_valid) begin
            result_data_q[0] <= out_data_next;
        end
        if (result_valid_q[0]) begin
            result_data_q[1] <= result_data_q[0];
        end
        if (result_valid_q[1]) begin
            result_data_q[2] <= result_data_q[1];
        end
    end

    always_ff @(posedge clk) begin
        if (result_valid_q[2]) begin
            out_data <= result_data_q[2];
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

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
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
            max4_abs = max4_u16(abs16(get_s16(matrix, base_idx + 0)),
                                abs16(get_s16(matrix, base_idx + 1)),
                                abs16(get_s16(matrix, base_idx + 2)),
                                abs16(get_s16(matrix, base_idx + 3)));
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
