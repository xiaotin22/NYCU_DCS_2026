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

    typedef enum logic [2:0] {
        S_IDLE,
        S_FAST_RUN,
        S_ATT_PARAM,
        S_ATT_READ,
        S_ATT_ISSUE,
        S_ATT_WAIT
    } state_t;

    // QKV / score / context all share one issue+wait skeleton; att_stage_q says
    // which matmul stage S_ATT_ISSUE/S_ATT_WAIT are currently running.
    typedef enum logic [1:0] {
        ST_QKV,
        ST_SV,
        ST_FINAL
    } att_stage_t;

    state_t      state_q;
    att_stage_t  att_stage_q;
    logic        att_param_phase_q;
    logic [1:0]  rd_req_cnt_q;
    logic [1:0]  att_rd_word_cnt_q;
    logic [7:0]  wr_cmd_cnt_q;
    logic [7:0]  out_cnt_q;
    logic [9:0]  wr_pre_pipe_q;
    logic [7:0]  att_group_base_q;
    logic [3:0]  att_phase_cnt_q;
    logic [13:0] att_wr_pipe_q;
    logic        att_prefetch_pending_q;
    logic [1:0]  att_pf_word_q;
    logic        att_pf_done_q;

    logic        job_start;
    logic        attention_start;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        rd_cmd_fire;
    logic        att_read_fire;
    logic        att_prefetch_fire;
    logic        att_pf_capture;
    logic        result_last;
    logic        att_final_start;
    logic        att_wr_fire;
    logic [7:0]  att_next_group_base;
    logic [3:0]  att_phase_last;

    assign job_start              = (state_q == S_IDLE) && mem_set && in_valid;
    assign attention_start        = job_start && ((op == 2'b10) || (op == 2'b11));
    assign result_last            = datapath_result_valid && (out_cnt_q == 8'd255);
    assign wr_pre_fire            = wr_pre_pipe_q[9];
    assign wr_cmd_fire            = (state_q == S_FAST_RUN) && wr_pre_fire;
    assign rd_cmd_fire            = (state_q == S_FAST_RUN) && (rd_req_cnt_q < 2'd2) && rd_ready;
    assign att_read_fire          = (state_q == S_ATT_READ) &&
                                    !att_prefetch_pending_q &&
                                    !att_pf_done_q &&
                                    (rd_req_cnt_q == 2'd0) &&
                                    rd_ready;
    // x_buf is released once QKV has issued, so the one-group-ahead prefetch can
    // fire as early as the QKV issue (rd_ready permitting); the 50-cycle data
    // return still lands well after QKV has finished reading x_buf.
    assign att_prefetch_fire      = ((state_q == S_ATT_ISSUE) ||
                                     (state_q == S_ATT_WAIT)) &&
                                    (att_stage_q == ST_QKV) &&
                                    !att_prefetch_pending_q &&
                                    !att_pf_done_q &&
                                    (att_group_base_q != 8'd252) &&
                                    rd_ready;
    // Prefetched words land in x_buf as soon as they arrive: x_buf is free once
    // the QKV issue is done (only QKV reads it), so capture is decoupled from the
    // FSM state and the fixed 50-cycle read latency hides behind the current group.
    assign att_pf_capture         = att_prefetch_pending_q && !att_pf_done_q && rd_valid;
    assign att_final_start        = (state_q == S_ATT_ISSUE) && (att_stage_q == ST_FINAL) &&
                                    (att_phase_cnt_q == 4'd0);
    assign att_wr_fire            = (exec_op == 2'b11) ? att_wr_pipe_q[13] : att_wr_pipe_q[9];
    assign att_next_group_base    = att_group_base_q + 8'd4;
    // Issue-phase upper bound: QKV always issues 12 phases (4 rows × Q/K/V);
    // SV/FINAL issue 8 for MHA (2 heads × 4 rows) or 4 for SHA.
    assign att_phase_last         = (att_stage_q == ST_QKV) ? 4'd11 :
                                    (exec_op == 2'b11)      ? 4'd7  : 4'd3;

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
                if (!att_prefetch_pending_q && !att_pf_done_q && rd_valid) begin
                    datapath_capture_valid = 1'b1;
                    datapath_capture_idx   = att_rd_word_cnt_q;
                end
            end

            S_ATT_ISSUE: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_idx   = att_phase_cnt_q;
                case (att_stage_q)
                    ST_QKV:  datapath_issue_mode = IM_QKV;
                    ST_SV:   datapath_issue_mode = IM_SV;
                    default: datapath_issue_mode = IM_FINAL;
                endcase
            end

            default: begin
            end
        endcase

        // Prefetched words are captured wherever they arrive (x_buf is already
        // free), independent of FSM state. Takes priority over the in-state read.
        if (att_pf_capture) begin
            datapath_capture_valid = 1'b1;
            datapath_capture_idx   = att_pf_word_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q                <= S_IDLE;
            att_stage_q            <= ST_QKV;
            att_param_phase_q      <= 1'b0;
            rd_req_cnt_q           <= 2'd0;
            att_rd_word_cnt_q      <= 2'd0;
            wr_cmd_cnt_q           <= 8'd0;
            out_cnt_q              <= 8'd0;
            wr_pre_pipe_q          <= 10'd0;
            att_group_base_q       <= 8'd0;
            att_phase_cnt_q        <= 4'd0;
            att_wr_pipe_q          <= 14'd0;
            att_prefetch_pending_q <= 1'b0;
            att_pf_word_q          <= 2'd0;
            att_pf_done_q          <= 1'b0;
        end
        else begin
            att_wr_pipe_q <= {att_wr_pipe_q[12:0], att_final_start};

            // Prefetched burst lands while the current group is still computing;
            // collect the 4 words then flag the next group's x_buf ready.
            if (att_pf_capture) begin
                if (att_pf_word_q == 2'd3) begin
                    att_pf_done_q          <= 1'b1;
                    att_prefetch_pending_q <= 1'b0;
                end
                else begin
                    att_pf_word_q <= att_pf_word_q + 1'b1;
                end
            end

            // One-group-ahead prefetch (fires while att_stage_q == ST_QKV, see wire).
            // rd_addr/rd_en/rd_burst for this read are driven in the RAM-read block.
            if (att_prefetch_fire) begin
                att_prefetch_pending_q <= 1'b1;
                att_pf_word_q          <= 2'd0;
            end

            case (state_q)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op   <= op;
                        exec_act  <= act;
                        exec_param <= param;

                        // FAST_RUN counters only; attention-specific state is
                        // initialised in S_ATT_PARAM right before S_ATT_READ.
                        rd_req_cnt_q  <= 2'd0;
                        wr_cmd_cnt_q  <= 8'd0;
                        out_cnt_q     <= 8'd0;
                        wr_pre_pipe_q <= 10'd0;

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
                    wr_pre_pipe_q <= {wr_pre_pipe_q[8:0], datapath_issue_valid};

                    if (rd_cmd_fire) begin
                        rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
                    end

                    // wr_en/wr_addr/wr_burst for this write are driven in the
                    // RAM-write block; here we only advance the command counter.
                    if (wr_cmd_fire) begin
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
                            att_wr_pipe_q          <= 14'd0;
                            att_prefetch_pending_q <= 1'b0;
                            att_pf_word_q          <= 2'd0;
                            att_pf_done_q          <= 1'b0;
                            state_q                <= S_ATT_READ;
                        end
                    end
                end

                S_ATT_READ: begin
                    if (att_read_fire) begin
                        rd_req_cnt_q <= 2'd1;
                    end

                    if (att_pf_done_q) begin
                        // Next group's input was already prefetched into x_buf.
                        att_pf_done_q   <= 1'b0;
                        att_phase_cnt_q <= 4'd0;
                        att_stage_q     <= ST_QKV;
                        state_q         <= S_ATT_ISSUE;
                    end
                    else if (!att_prefetch_pending_q && rd_valid) begin
                        // First group (no prefetch yet): capture the burst here.
                        if (att_rd_word_cnt_q == 2'd3) begin
                            att_rd_word_cnt_q <= 2'd0;
                            att_phase_cnt_q   <= 4'd0;
                            att_stage_q       <= ST_QKV;
                            state_q           <= S_ATT_ISSUE;
                        end
                        else begin
                            att_rd_word_cnt_q <= att_rd_word_cnt_q + 1'b1;
                        end
                    end
                end

                S_ATT_ISSUE: begin
                    if (att_phase_cnt_q == att_phase_last) begin
                        state_q <= S_ATT_WAIT;
                    end
                    else begin
                        att_phase_cnt_q <= att_phase_cnt_q + 1'b1;
                    end
                end

                S_ATT_WAIT: begin
                    case (att_stage_q)
                        ST_QKV: begin
                            if (datapath_qkv_ready) begin
                                att_phase_cnt_q <= 4'd0;
                                att_stage_q     <= ST_SV;
                                state_q         <= S_ATT_ISSUE;
                            end
                        end

                        ST_SV: begin
                            if (datapath_sv_ready) begin
                                att_phase_cnt_q <= 4'd0;
                                att_wr_pipe_q   <= 14'd0;
                                att_stage_q     <= ST_FINAL;
                                state_q         <= S_ATT_ISSUE;
                            end
                        end

                        default: begin  // ST_FINAL: write back, advance group / finish.
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
                    endcase
                end

                default: begin
                    state_q <= S_IDLE;
                end
            endcase
        end
    end

    // All RAM-read command outputs (rd_en/rd_burst/rd_addr) live here. The three
    // fire conditions are mutually exclusive (each gated on a distinct state), so
    // the if/else-if chain matches the original parallel assignments.
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
                rd_addr  <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
            end
            else if (att_read_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_4;
                rd_addr  <= att_group_base_q[ADDR_W-1:0];
            end
            else if (att_prefetch_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_4;
                rd_addr  <= att_next_group_base[ADDR_W-1:0];
            end
        end
    end

    // All RAM-write command outputs (wr_en/wr_burst/wr_addr) live here. The two
    // write paths never overlap (attention write-back only fires in attention
    // states; the FAST_RUN write only in S_FAST_RUN), so the separate ifs keep
    // the original "last assignment wins" tie-break while staying mutually
    // exclusive in practice. Counters (wr_cmd_cnt_q, att_wr_pipe_q) stay in the
    // main FSM block and are only read here.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en    <= 1'b0;
            wr_burst <= '0;
        end
        else begin
            wr_en    <= 1'b0;
            wr_burst <= '0;

            // Attention: one BURST_4 per group, timed by att_wr_pipe_q.
            if (att_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= att_group_base_q[ADDR_W-1:0];
                wr_burst <= BURST_4;
            end

            // FAST_RUN: a single BURST_128 covering all 256 results.
            if (wr_cmd_fire && (wr_cmd_cnt_q[6:0] == 7'd0)) begin
                wr_en    <= 1'b1;
                wr_addr  <= wr_cmd_cnt_q[ADDR_W-1:0];
                wr_burst <= BURST_128;
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

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

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
    logic          act_in_valid_q;
    logic [1:0]    act_in_mode_q;
    logic [1023:0] act_in_data_q;
    pipe_tag_t     act_in_tag_q;
    logic [2:0]    act_in_idx_q;
    logic          act_valid;
    logic [1023:0] act_data;
    pipe_tag_t     act_tag_q [0:4];
    logic [2:0]    act_idx_q [0:4];

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
                            (mult_tag_out == MT_SCORE) ||
                            ((mult_tag_out == MT_FINAL) && (op != 2'b11))));
    assign act_in_data  = mha_comb_valid ? mha_comb_data : mult_data;
    assign act_in_idx   = mha_comb_valid                       ? mha_comb_idx :
                          ((mult_tag_out == MT_FINAL) ||
                           (mult_tag_out == MT_SCORE))         ? mult_idx_out :
                                                                 3'd0;

    always_comb begin
        act_in_tag  = PT_NONE;
        act_in_mode = ACT_USER;

        case (mult_tag_out)
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

    logic use_act_for_pot;
    assign use_act_for_pot = act_valid &&
                             ((act_tag_q[4] == PT_NORM) || (act_tag_q[4] == PT_FINAL));

    assign pot_in_valid = use_act_for_pot ||
                          (mult_valid && ((mult_tag_out == MT_Q) ||
                                          (mult_tag_out == MT_K) ||
                                          (mult_tag_out == MT_V)));
    assign pot_in_data  = use_act_for_pot ? act_data       : mult_data;
    assign pot_in_idx   = use_act_for_pot ? act_idx_q[4]   : mult_idx_out;

    always_comb begin
        if (use_act_for_pot) begin
            pot_in_tag = act_tag_q[4];
        end
        else begin
            case (mult_tag_out)
                MT_Q:    pot_in_tag = PT_Q;
                MT_K:    pot_in_tag = PT_K;
                MT_V:    pot_in_tag = PT_V;
                default: pot_in_tag = PT_NONE;
            endcase
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
        .in_valid  (act_in_valid_q),
        .act       (act),
        .act_mode  (act_in_mode_q),
        .in_data   (act_in_data_q),
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
            q_ready_q     <= 4'd0;
            k_ready_q     <= 4'd0;
            v_ready_q     <= 4'd0;
            score_ready_q <= 8'd0;
            out_valid     <= 1'b0;
            out_data      <= 32'd0;
            act_in_valid_q <= 1'b0;
            act_in_mode_q  <= ACT_USER;
            act_in_data_q  <= 1024'd0;
            act_in_tag_q   <= PT_NONE;
            act_in_idx_q   <= 3'd0;
        end
        else begin
            out_valid <= result_valid;

            act_in_valid_q <= act_in_valid;
            act_in_mode_q  <= act_in_mode;
            act_in_data_q  <= act_in_data;
            act_in_tag_q   <= act_in_valid ? act_in_tag : PT_NONE;
            act_in_idx_q   <= act_in_idx;

            // Clear the per-group ready flags at the first QKV issue (decoupled
            // from x_buf capture, which now happens early via prefetch while the
            // previous group still needs these flags in SV/FINAL).
            if (issue_valid_q && (issue_mode_q == IM_QKV) && (issue_idx_q == 4'd0)) begin
                q_ready_q     <= 4'd0;
                k_ready_q     <= 4'd0;
                v_ready_q     <= 4'd0;
                score_ready_q <= 8'd0;
            end

            if (capture_valid_q) begin
                x_buf_q[capture_idx_q] <= rd_data_q[255:0];
            end

            act_tag_q[0] <= act_in_tag_q;
            act_idx_q[0] <= act_in_idx_q;
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

    // Stage 0 = registered operands (issue-time selection mux is now off the
    // multiplier critical path); Stage 1/2 = multiplier internal pipeline.
    localparam int MULT_STAGES = 3;

    logic          mult_issue_valid;
    logic          mult_issue_b_transpose;
    logic          mult_issue_a_wide;
    logic          mult_issue_head_mask;
    logic          mult_issue_head_sel;
    logic [255:0]  mult_issue_A;
    logic [SCORE_PACK_W-1:0] mult_issue_score;
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
        mult_issue_score       = '0;
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
                    mult_issue_score  = score_buf[mult_issue_idx];
                    mult_issue_B      = v_buf[issue_idx[1:0]];
                    mult_issue_tag    = MT_FINAL;
                end

                default: begin
                    mult_issue_valid = 1'b0;
                end
            endcase
        end
    end

    // ---- Stage 0: operand pipeline register --------------------------------
    // The issue-time selection (mode/idx muxing of x/q/k/v/score buffers) used
    // to sit in series with the multiplier, costing ~1.4ns. Latch the selected
    // operands so the multiplier starts each cycle from stable registers.
    logic                    op_valid_q;
    logic                    op_btr_q;
    logic                    op_awide_q;
    logic                    op_hmask_q;
    logic                    op_hsel_q;
    logic [1:0]              op_op_q;
    logic [255:0]            op_A_q;
    logic [255:0]            op_B_q;
    logic [SCORE_PACK_W-1:0] op_score_q;
    logic [1023:0]           op_A_wide;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_valid_q <= 1'b0;
        end
        else begin
            op_valid_q <= mult_issue_valid;
            op_btr_q   <= mult_issue_b_transpose;
            op_awide_q <= mult_issue_a_wide;
            op_hmask_q <= mult_issue_head_mask;
            op_hsel_q  <= mult_issue_head_sel;
            op_op_q    <= op;
            op_A_q     <= mult_issue_A;
            op_B_q     <= mult_issue_B;
            op_score_q <= mult_issue_score;
        end
    end

    // Sign-extension unpack is pure wiring; doing it after the register keeps
    // the 8:1 score_buf mux off the multiplier path and saves 320 flops vs.
    // registering the full 1024-bit unpacked form.
    assign op_A_wide = unpack_score(op_score_q);

    Mult_2Stage_Parallel u_mult (
        .clk            (clk),
        .rst_n          (rst_n),
        .op             (op_op_q),
        .b_transpose    (op_btr_q),
        .a_wide         (op_awide_q),
        .head_mask      (op_hmask_q),
        .head_sel       (op_hsel_q),
        .in_valid       (op_valid_q),
        .in_data_A      (op_A_q),
        .in_data_A_wide (op_A_wide),
        .in_data_B      (op_B_q),
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

module Mult_2Stage_Parallel (
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

    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int DOT_SIZE = 9;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

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
        input integer        row_idx,
        input integer        lane,
        input integer        tap
    );
        integer idx;
        integer row;
        integer col;
        begin
            if (op_sel == 2'b01) begin
                idx   = (row_idx * ROW_ELEM) + lane;
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
                sel_a = get_s16(mat_A_wide, (row_idx * ROW_ELEM) + tap);
            end
            else begin
                sel_a = get_s4(mat_A, (row_idx * ROW_ELEM) + tap);
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

    // Stage 1 = all 64*9 = 576 partial products combinational, then register.
    // Stage 2 = per-lane 9-input add tree combinational, then register.
    logic stage1_valid_q;
    logic stage2_valid_q;
    s16_t prod_q   [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s16_t sum_q    [0:MAT_SIZE-1];

    s16_t prod_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s16_t sum_next  [0:MAT_SIZE-1];

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_next[(row * ROW_ELEM) + lane][tap] =
                        $signed(sel_a(in_data_A, in_data_A_wide, op,
                                      a_wide, head_mask, head_sel,
                                      row, lane, tap)) *
                        $signed(sel_b(in_data_B, op, b_transpose,
                                      head_mask, head_sel,
                                      lane, tap));
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_next[i] = ((prod_q[i][0] + prod_q[i][1]) + (prod_q[i][2] + prod_q[i][3])) +
                          ((prod_q[i][4] + prod_q[i][5]) + (prod_q[i][6] + prod_q[i][7]) +
                           prod_q[i][8]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid_q <= 1'b0;
            stage2_valid_q <= 1'b0;
        end
        else begin
            stage1_valid_q <= in_valid;
            stage2_valid_q <= stage1_valid_q;
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int t = 0; t < DOT_SIZE; t++) begin
                    prod_q[i][t] <= prod_next[i][t];
                end
            end
            for (int i = 0; i < MAT_SIZE; i++) begin
                sum_q[i] <= sum_next[i];
            end
        end
    end

    assign out_valid = stage2_valid_q;

    always_comb begin
        out_data = 1024'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            out_data[1023 - (i * 16) -: 16] = sum_q[i];
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
    output logic [1023:0] out_data
);

    localparam int MAT_SIZE   = 64;
    localparam int ROW_ELEM   = 8;
    localparam int CHUNK_SIZE = 16;
    localparam int ACT_STAGES = 5;

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [19:0] s20_t;

    logic          valid_q  [0:ACT_STAGES-1];
    logic [1:0]    act_q    [0:ACT_STAGES-1];
    logic [1:0]    mode_q   [0:ACT_STAGES-1];
    logic [1023:0] matrix_q [0:ACT_STAGES-1];
    // thr_*_q only feeds stages 1..4 (each stage uses prev stage's threshold).
    // Stage 4 is the last apply_chunk consumer, so we only need indices 0..3.
    s20_t          thr_a_q  [0:ACT_STAGES-2];
    s20_t          thr_b_q  [0:ACT_STAGES-2];

    logic [39:0]   thr0_pair;
    logic [39:0]   thr1_pair;
    logic [39:0]   thr2_pair;
    logic [39:0]   thr3_pair;

    assign out_valid = valid_q[ACT_STAGES-1];
    assign out_data  = matrix_q[ACT_STAGES-1];

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s20_t ext20(input s16_t value);
        ext20 = {{4{value[15]}}, value};
    endfunction

    // Balanced adder trees: depth log2(N) instead of serial accumulation.
    function automatic s20_t reduce8(input s20_t a [0:7]);
        s20_t l1 [0:3];
        s20_t l2 [0:1];
        begin
            l1[0] = a[0] + a[1];
            l1[1] = a[2] + a[3];
            l1[2] = a[4] + a[5];
            l1[3] = a[6] + a[7];
            l2[0] = l1[0] + l1[1];
            l2[1] = l1[2] + l1[3];
            reduce8 = l2[0] + l2[1];
        end
    endfunction

    function automatic s20_t reduce16(input s20_t a [0:15]);
        s20_t l1 [0:7];
        begin
            for (int i = 0; i < 8; i++) l1[i] = a[2*i] + a[2*i+1];
            reduce16 = reduce8(l1);
        end
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
        s20_t  terms_a  [0:7];
        s20_t  terms_b  [0:7];
        s20_t  terms16  [0:15];
        s20_t  thr_a;
        s20_t  thr_b;
        begin
            thr_a = 20'sd0;
            thr_b = 20'sd0;
            for (int i = 0; i < 8;  i++) begin
                terms_a[i] = 20'sd0;
                terms_b[i] = 20'sd0;
            end
            for (int i = 0; i < 16; i++) terms16[i] = 20'sd0;

            case (act_sel)
                2'b01: begin
                    row0 = chunk * 2;
                    row1 = row0 + 1;
                    for (int c = 0; c < ROW_ELEM; c++) begin
                        terms_a[c] = ext20(get_s16(matrix, (row0 * ROW_ELEM) + c));
                        terms_b[c] = ext20(get_s16(matrix, (row1 * ROW_ELEM) + c));
                    end
                    thr_a = reduce8(terms_a) >>> 3;
                    thr_b = reduce8(terms_b) >>> 3;
                end

                2'b10: begin
                    col0 = chunk * 2;
                    col1 = col0 + 1;
                    for (int r = 0; r < ROW_ELEM; r++) begin
                        terms_a[r] = ext20(get_s16(matrix, (r * ROW_ELEM) + col0));
                        terms_b[r] = ext20(get_s16(matrix, (r * ROW_ELEM) + col1));
                    end
                    thr_a = reduce8(terms_a) >>> 3;
                    thr_b = reduce8(terms_b) >>> 3;
                end

                2'b11: begin
                    base_row = (chunk / 2) * 4;
                    base_col = (chunk % 2) * 4;
                    for (int r = 0; r < 4; r++) begin
                        for (int c = 0; c < 4; c++) begin
                            terms16[(r * 4) + c] =
                                ext20(get_s16(matrix,
                                              ((base_row + r) * ROW_ELEM) +
                                              (base_col + c)));
                        end
                    end
                    thr_a = reduce16(terms16) >>> 4;
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
                    activate_value(get_s16(src_matrix, idx), act_sel, mode_sel, threshold);
            end
        end
    endfunction

    always_comb begin
        thr0_pair = calc_threshold_pair(in_data,     act,      0);
        thr1_pair = calc_threshold_pair(matrix_q[0], act_q[0], 1);
        thr2_pair = calc_threshold_pair(matrix_q[1], act_q[1], 2);
        thr3_pair = calc_threshold_pair(matrix_q[2], act_q[2], 3);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ACT_STAGES; i++) begin
                valid_q[i]  <= 1'b0;
                act_q[i]    <= 2'd0;
                mode_q[i]   <= ACT_USER;
                matrix_q[i] <= 1024'd0;
            end
            for (int i = 0; i < ACT_STAGES - 1; i++) begin
                thr_a_q[i] <= 20'sd0;
                thr_b_q[i] <= 20'sd0;
            end
        end
        else begin
            valid_q[0]  <= in_valid;
            act_q[0]    <= act;
            mode_q[0]   <= act_mode;
            matrix_q[0] <= in_data;
            thr_a_q[0]  <= $signed(thr0_pair[39:20]);
            thr_b_q[0]  <= $signed(thr0_pair[19:0]);

            valid_q[1]  <= valid_q[0];
            act_q[1]    <= act_q[0];
            mode_q[1]   <= mode_q[0];
            matrix_q[1] <= apply_chunk(matrix_q[0], matrix_q[0], act_q[0], mode_q[0],
                                       0, thr_a_q[0], thr_b_q[0]);
            thr_a_q[1]  <= $signed(thr1_pair[39:20]);
            thr_b_q[1]  <= $signed(thr1_pair[19:0]);

            valid_q[2]  <= valid_q[1];
            act_q[2]    <= act_q[1];
            mode_q[2]   <= mode_q[1];
            matrix_q[2] <= apply_chunk(matrix_q[1], matrix_q[1], act_q[1], mode_q[1],
                                       1, thr_a_q[1], thr_b_q[1]);
            thr_a_q[2]  <= $signed(thr2_pair[39:20]);
            thr_b_q[2]  <= $signed(thr2_pair[19:0]);

            valid_q[3]  <= valid_q[2];
            act_q[3]    <= act_q[2];
            mode_q[3]   <= mode_q[2];
            matrix_q[3] <= apply_chunk(matrix_q[2], matrix_q[2], act_q[2], mode_q[2],
                                       2, thr_a_q[2], thr_b_q[2]);
            thr_a_q[3]  <= $signed(thr3_pair[39:20]);
            thr_b_q[3]  <= $signed(thr3_pair[19:0]);

            valid_q[4]  <= valid_q[3];
            act_q[4]    <= act_q[3];
            mode_q[4]   <= mode_q[3];
            matrix_q[4] <= apply_chunk(matrix_q[3], matrix_q[3], act_q[3], mode_q[3],
                                       3, thr_a_q[3], thr_b_q[3]);
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
