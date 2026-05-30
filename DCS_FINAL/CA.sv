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
    logic [4:0]    datapath_issue_idx;
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
    output logic [4:0]                      datapath_issue_idx,
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
        S_HA_PARAM,
        S_HA_READ,
        S_HA_ISSUE,
        S_HA_WAIT
    } state_t;

    // QKV / score / context all share one issue+wait skeleton; ha_stage_cs says
    // which matmul stage S_HA_ISSUE/S_HA_WAIT are currently running.
    typedef enum logic [1:0] {
        ST_QKV,
        ST_SV,
        ST_FINAL
    } ha_stage_t;

    state_t      state_cs;
    ha_stage_t  ha_stage_cs;
    logic        ha_param_phase_cs;
    logic [1:0]  rd_req_cnt_cs;
    logic [1:0]  ha_rd_word_cnt_cs;
    logic [7:0]  wr_cmd_cnt_cs;
    logic [7:0]  out_cnt_cs;
    logic [7:0]  wr_pre_pipe_cs;
    logic [7:0]  ha_group_base_cs;
    logic [4:0]  ha_phase_cnt_cs;
    // 把原本 28-bit shift register 換成 5-bit counter + run flag：
    // ha_final_start 每組只 fire 一次，shift reg 同時最多只有 1 bit 為 1，
    // 用 counter 等效但省 ~22 flops。
    logic [4:0]  ha_wr_cnt_cs;
    logic        ha_wr_run_cs;
    logic        ha_prefetch_pending_cs;
    logic [1:0]  ha_pf_word_cs;
    logic        ha_pf_done_cs;

    logic        job_start;
    logic        ha_start;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        rd_cmd_fire;
    logic        ha_read_fire;
    logic        ha_prefetch_fire;
    logic        ha_pf_capture;
    logic        result_last;
    logic        ha_final_start;
    logic        ha_wr_fire;
    logic [7:0]  ha_next_group_base;
    logic [4:0]  ha_phase_last;

    assign job_start              = (state_cs == S_IDLE) && mem_set && in_valid;
    assign ha_start        = job_start && ((op == 2'b10) || (op == 2'b11));
    assign result_last            = datapath_result_valid && (out_cnt_cs == 8'd255);
    assign wr_pre_fire            = wr_pre_pipe_cs[7];
    assign wr_cmd_fire            = (state_cs == S_FAST_RUN) && wr_pre_fire;
    assign rd_cmd_fire            = (state_cs == S_FAST_RUN) && (rd_req_cnt_cs < 2'd2) && rd_ready;
    assign ha_read_fire          = (state_cs == S_HA_READ) &&
                                    !ha_prefetch_pending_cs &&
                                    !ha_pf_done_cs &&
                                    (rd_req_cnt_cs == 2'd0) &&
                                    rd_ready;
    // x_mem is released once QKV has issued, so the one-group-ahead prefetch can
    // fire as early as the QKV issue (rd_ready permitting); the 50-cycle data
    // return still lands well after QKV has finished reading x_mem.
    assign ha_prefetch_fire      = ((state_cs == S_HA_ISSUE) ||
                                     (state_cs == S_HA_WAIT)) &&
                                    (ha_stage_cs == ST_QKV) &&
                                    !ha_prefetch_pending_cs &&
                                    !ha_pf_done_cs &&
                                    (ha_group_base_cs != 8'd252) &&
                                    rd_ready;
    // Prefetched words land in x_mem as soon as they arrive: x_mem is free once
    // the QKV issue is done (only QKV reads it), so capture is decoupled from the
    // FSM state and the fixed 50-cycle read latency hides behind the current group.
    assign ha_pf_capture         = ha_prefetch_pending_cs && !ha_pf_done_cs && rd_valid;
    assign ha_final_start        = (state_cs == S_HA_ISSUE) && (ha_stage_cs == ST_FINAL) &&
                                    (ha_phase_cnt_cs == 5'd0);
    // FINAL nibble-accumulation triples the issue count: 4→12 (SHA), 8→24 (MHA).
    // Interleaved order pushes the first of the 4 consecutive finals to phase 8
    // (SHA) / 20 (MHA), i.e. +8 / +16 vs the original phase-0/4 single-issue
    // design, so the write-command tap shifts by the same amount: [7]→[15],
    // [11]→[27]. (Empirical alignment — re-verify on gate sim.)
    // Counter equivalent of original ha_wr_pipe_cs[15]/[27]: ha_final_start
    // sets run=1 + cnt=0; cnt increments per cycle; fire when cnt hits target.
    // PoT 為 5-stage（abs 已搬到上游做，內部還是 abs + 3-stage max + 1 final），
    // wr_data 出現時點與原版一致 → tap 維持 27 (MHA) / 15 (SHA)。
    assign ha_wr_fire            = ha_wr_run_cs &&
                                    (ha_wr_cnt_cs == ((exec_op == 2'b11) ? 5'd27 : 5'd15));
    assign ha_next_group_base    = ha_group_base_cs + 8'd4;
    // Issue-phase upper bound:
    //   QKV: 12 phases (4 rows × Q/K/V)
    //   SV:  SHA=4, MHA=8  (rows × heads)
    //   FINAL: SHA=12, MHA=24 (× 3 nibble phases per row)
    assign ha_phase_last         = (ha_stage_cs == ST_QKV)  ? 5'd11 :
                                    (ha_stage_cs == ST_SV)   ? ((exec_op == 2'b11) ? 5'd7  : 5'd3) :
                                    /* ST_FINAL */              ((exec_op == 2'b11) ? 5'd23 : 5'd11);

    always_comb begin
        datapath_issue_valid   = 1'b0;
        datapath_issue_mode    = IM_NONE;
        datapath_issue_idx     = 5'd0;
        datapath_capture_valid = 1'b0;
        datapath_capture_idx   = ha_rd_word_cnt_cs;

        case (state_cs)
            S_FAST_RUN: begin
                if (rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_NORM;
                end
            end

            S_HA_READ: begin
                if (!ha_prefetch_pending_cs && !ha_pf_done_cs && rd_valid) begin
                    datapath_capture_valid = 1'b1;
                    datapath_capture_idx   = ha_rd_word_cnt_cs;
                end
            end

            S_HA_ISSUE: begin
                datapath_issue_valid = 1'b1;
                datapath_issue_idx   = ha_phase_cnt_cs;
                case (ha_stage_cs)
                    ST_QKV:  datapath_issue_mode = IM_QKV;
                    ST_SV:   datapath_issue_mode = IM_SV;
                    default: datapath_issue_mode = IM_FINAL;
                endcase
            end

            default: begin
            end
        endcase

        // Prefetched words are captured wherever they arrive (x_mem is already
        // free), independent of FSM state. Takes priority over the in-state read.
        if (ha_pf_capture) begin
            datapath_capture_valid = 1'b1;
            datapath_capture_idx   = ha_pf_word_cs;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_cs               <= S_IDLE;
            ha_stage_cs            <= ST_QKV;
            ha_param_phase_cs      <= 1'b0;
            rd_req_cnt_cs          <= 2'd0;
            ha_rd_word_cnt_cs      <= 2'd0;
            wr_cmd_cnt_cs          <= 8'd0;
            out_cnt_cs             <= 8'd0;
            wr_pre_pipe_cs         <= 8'd0;
            ha_group_base_cs       <= 8'd0;
            ha_phase_cnt_cs        <= 5'd0;
            ha_wr_cnt_cs           <= 5'd0;
            ha_wr_run_cs           <= 1'b0;
            ha_prefetch_pending_cs <= 1'b0;
            ha_pf_word_cs          <= 2'd0;
            ha_pf_done_cs          <= 1'b0;
        end
        else begin
            // Counter update (replaces ha_wr_pipe shift register).
            // 優先級：ha_final_start > ha_wr_fire > 計數中。state-based 清零
            // 在 case block 內以後寫覆蓋 (SV "last assignment wins")。
            if (ha_final_start) begin
                ha_wr_run_cs <= 1'b1;
                ha_wr_cnt_cs <= 5'd0;
            end
            else if (ha_wr_fire) begin
                ha_wr_run_cs <= 1'b0;
            end
            else if (ha_wr_run_cs) begin
                ha_wr_cnt_cs <= ha_wr_cnt_cs + 1'b1;
            end

            // Prefetched burst lands while the current group is still computing;
            // collect the 4 words then flag the next group's x_mem ready.
            if (ha_pf_capture) begin
                if (ha_pf_word_cs == 2'd3) begin
                    ha_pf_done_cs          <= 1'b1;
                    ha_prefetch_pending_cs <= 1'b0;
                end
                else begin
                    ha_pf_word_cs <= ha_pf_word_cs + 1'b1;
                end
            end

            // One-group-ahead prefetch (fires while ha_stage_cs == ST_QKV, see wire).
            // rd_addr/rd_en/rd_burst for this read are driven in the RAM-read block.
            if (ha_prefetch_fire) begin
                ha_prefetch_pending_cs <= 1'b1;
                ha_pf_word_cs          <= 2'd0;
            end

            case (state_cs)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op   <= op;
                        exec_act  <= act;
                        exec_param <= param;

                        // FAST_RUN counters only; attention-specific state is
                        // initialised in S_HA_PARAM right before S_HA_READ.
                        rd_req_cnt_cs  <= 2'd0;
                        wr_cmd_cnt_cs  <= 8'd0;
                        out_cnt_cs     <= 8'd0;
                        wr_pre_pipe_cs <= 8'd0;

                        if (ha_start) begin
                            ha_param_phase_cs <= 1'b0;
                            state_cs           <= S_HA_PARAM;
                        end
                        else begin
                            state_cs <= S_FAST_RUN;
                        end
                    end
                end

                S_FAST_RUN: begin
                    wr_pre_pipe_cs <= {wr_pre_pipe_cs[6:0], datapath_issue_valid};

                    if (rd_cmd_fire) begin
                        rd_req_cnt_cs <= rd_req_cnt_cs + 1'b1;
                    end

                    // wr_en/wr_addr/wr_burst for this write are driven in the
                    // RAM-write block; here we only advance the command counter.
                    if (wr_cmd_fire) begin
                        wr_cmd_cnt_cs <= wr_cmd_cnt_cs + 1'b1;
                    end

                    if (datapath_result_valid) begin
                        if (result_last) begin
                            state_cs <= S_IDLE;
                        end
                        else begin
                            out_cnt_cs <= out_cnt_cs + 1'b1;
                        end
                    end
                end

                S_HA_PARAM: begin
                    if (in_valid) begin
                        if (!ha_param_phase_cs) begin
                            exec_weight_k     <= param;
                            ha_param_phase_cs <= 1'b1;
                        end
                        else begin
                            exec_weight_v          <= param;
                            ha_group_base_cs       <= 8'd0;
                            rd_req_cnt_cs           <= 2'd0;
                            ha_rd_word_cnt_cs      <= 2'd0;
                            out_cnt_cs              <= 8'd0;
                            ha_wr_cnt_cs           <= 5'd0;
                            ha_wr_run_cs           <= 1'b0;
                            ha_prefetch_pending_cs <= 1'b0;
                            ha_pf_word_cs          <= 2'd0;
                            ha_pf_done_cs          <= 1'b0;
                            state_cs                <= S_HA_READ;
                        end
                    end
                end

                S_HA_READ: begin
                    if (ha_read_fire) begin
                        rd_req_cnt_cs <= 2'd1;
                    end

                    if (ha_pf_done_cs) begin
                        // Next group's input was already prefetched into x_mem.
                        ha_pf_done_cs   <= 1'b0;
                        ha_phase_cnt_cs <= 5'd0;
                        ha_stage_cs     <= ST_QKV;
                        state_cs        <= S_HA_ISSUE;
                    end
                    else if (!ha_prefetch_pending_cs && rd_valid) begin
                        // First group (no prefetch yet): capture the burst here.
                        if (ha_rd_word_cnt_cs == 2'd3) begin
                            ha_rd_word_cnt_cs <= 2'd0;
                            ha_phase_cnt_cs   <= 5'd0;
                            ha_stage_cs       <= ST_QKV;
                            state_cs           <= S_HA_ISSUE;
                        end
                        else begin
                            ha_rd_word_cnt_cs <= ha_rd_word_cnt_cs + 1'b1;
                        end
                    end
                end

                S_HA_ISSUE: begin
                    if (ha_phase_cnt_cs == ha_phase_last) begin
                        state_cs <= S_HA_WAIT;
                    end
                    else begin
                        ha_phase_cnt_cs <= ha_phase_cnt_cs + 1'b1;
                    end
                end

                S_HA_WAIT: begin
                    case (ha_stage_cs)
                        ST_QKV: begin
                            if (datapath_qkv_ready) begin
                                ha_phase_cnt_cs <= 5'd0;
                                ha_stage_cs     <= ST_SV;
                                state_cs         <= S_HA_ISSUE;
                            end
                        end

                        ST_SV: begin
                            if (datapath_sv_ready) begin
                                ha_phase_cnt_cs <= 5'd0;
                                ha_wr_cnt_cs    <= 5'd0;
                                ha_wr_run_cs    <= 1'b0;
                                ha_stage_cs     <= ST_FINAL;
                                state_cs         <= S_HA_ISSUE;
                            end
                        end

                        default: begin  // ST_FINAL: write back, advance group / finish.
                            if (datapath_result_valid) begin
                                if (out_cnt_cs[1:0] == 2'd3) begin
                                    if (ha_group_base_cs == 8'd252) begin
                                        state_cs <= S_IDLE;
                                    end
                                    else begin
                                        ha_group_base_cs  <= ha_next_group_base;
                                        rd_req_cnt_cs      <= ha_prefetch_pending_cs ? 2'd1 : 2'd0;
                                        ha_rd_word_cnt_cs <= 2'd0;
                                        state_cs           <= S_HA_READ;
                                    end
                                end

                                if (out_cnt_cs != 8'd255) begin
                                    out_cnt_cs <= out_cnt_cs + 1'b1;
                                end
                            end
                        end
                    endcase
                end

                default: begin
                    state_cs <= S_IDLE;
                end
            endcase
        end
    end

    // All RAM-read command outputs (rd_en/rd_burst/rd_addr) live here. The three
    // fire conditions are mutually exclusive (each gated on a distinct state), so
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
                rd_addr  <= rd_req_cnt_cs[0] ? HALF_ADDR : '0;
            end
            else if (ha_read_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_4;
                rd_addr  <= ha_group_base_cs[ADDR_W-1:0];
            end
            else if (ha_prefetch_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_4;
                rd_addr  <= ha_next_group_base[ADDR_W-1:0];
            end
        end
    end

    // All RAM-write command outputs (wr_en/wr_burst/wr_addr) live here. The two
    // write paths never overlap (attention write-back only fires in attention
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en    <= 1'b0;
            wr_burst <= '0;
        end
        else begin
            wr_en    <= 1'b0;
            wr_burst <= '0;

            // Attention: one BURST_4 per group, timed by ha_wr_cnt_cs.
            if (ha_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= ha_group_base_cs[ADDR_W-1:0];
                wr_burst <= BURST_4;
            end

            // FAST_RUN: a single BURST_128 covering all 256 results.
            if (wr_cmd_fire && (wr_cmd_cnt_cs[6:0] == 7'd0)) begin
                wr_en    <= 1'b1;
                wr_addr  <= wr_cmd_cnt_cs[ADDR_W-1:0];
                wr_burst <= BURST_128;
            end
        end
    end

endmodule

// ============================================================================
// CA_DataPath
// 角色：純路由 + 中間儲存 + 三個 compute submodule 的 dispatch / collect
//
// Pipeline 全圖（從 issue/capture 進來算起）：
//   Multiple_Processor: in→[1 issue buf]→[3 mult stages]            → mult_valid  (cycle 4)
//   ACT_4Stage_Parallel: in→[1 input buf]→[3 act stages]            → act_valid   (cycle 4)
//   PoT_5Stage_Parallel: in+abs→[1 input buf]→[3 max stages]→[1 final] → pot_valid (cycle 5)
//
// Sideband (tag/idx) pipeline 長度跟著走：
//   act_*_cs[0..3]  → 4 級 (對齊 ACT 4-stage)
//   pot_*_cs[0..4]  → 5 級 (對齊 PoT 5-stage)
//
// FF 分配原則：
//   * Multiple_Processor / ACT / PoT 自己的 input buffer 已搬進各自模組
//   * DataPath 只留：①跨 issue 的中間儲存  ②sideband pipeline  ③output buffer
// ============================================================================
module CA_DataPath #(
    parameter RAM_WIDTH = 256
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 issue_valid,
    input  issue_mode_t          issue_mode,
    input  logic [4:0]           issue_idx,
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

    // ------------------------------------------------------------------------
    // 區塊 1：型別 / 常數
    // ------------------------------------------------------------------------
    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    // Use top-level mult_tag_t for the whole DataPath sideband; values pass
    // through unchanged from Multiple_Processor into ACT / PoT tag pipelines.

    localparam int SCORE_ELEM_W   = 11;
    localparam int SCORE_PACK_W   = SCORE_ELEM_W * 64;
    localparam int MHA_OUT_ELEM_W = 15;
    // combine_mha_heads 只取 head0 每 row 的 col 0-3，所以 FINAL head0 buffer
    // 只存 32 lanes（col 4-7 計算後丟棄）。
    localparam int MHA_OUT_LANES  = 32;
    localparam int MHA_OUT_PACK_W = MHA_OUT_ELEM_W * MHA_OUT_LANES;

    // ------------------------------------------------------------------------
    // 區塊 2：跨 issue 的中間儲存（這些是 DataPath 的「狀態」，必須留在這層）
    // ------------------------------------------------------------------------
    // x/q/k/v_mem: 4 個 256-bit slot；score_mem: 8 個 (11-bit × 64) slot。
    // mha_out0_mem: MHA head0 FINAL 部份積，等 head1 算完再 combine。
    logic [255:0]              x_mem        [0:3];
    logic [255:0]              q_mem        [0:3];
    logic [255:0]              k_mem        [0:3];
    logic [255:0]              v_mem        [0:3];
    logic [SCORE_PACK_W-1:0]   score_mem    [0:7];
    logic [MHA_OUT_PACK_W-1:0] mha_out0_mem [0:3];

    logic [3:0]                q_ready_cs;
    logic [3:0]                k_ready_cs;
    logic [3:0]                v_ready_cs;
    logic [7:0]                score_ready_cs;

    // ------------------------------------------------------------------------
    // 區塊 3：Submodule output 線（comb，從各 submodule 出來的訊號）
    // ------------------------------------------------------------------------
    logic          mult_valid;
    logic [1023:0] mult_data;
    mult_tag_t     mult_tag_out;
    logic [2:0]    mult_idx_out;

    logic          act_valid;
    logic [1023:0] act_data;

    logic          pot_valid;
    logic [255:0]  pot_data;

    // ------------------------------------------------------------------------
    // 區塊 4：Issue / capture 入口 buffer
    //   * issue path 給 Multiple_Processor，先打一拍切短上游 mux
    //   * rd_data_cs 同時服務 capture (寫 x_mem) 和 IM_NORM (送進 MP)，
    //     兩者互斥，所以共享一個 register 不衝突
    // ------------------------------------------------------------------------
    logic                 issue_valid_cs;
    issue_mode_t          issue_mode_cs;
    logic [4:0]           issue_idx_cs;
    logic                 capture_valid_cs;
    logic [1:0]           capture_idx_cs;
    logic [RAM_WIDTH-1:0] rd_data_cs;

    // ------------------------------------------------------------------------
    // 區塊 5：Dispatch comb 線（mult → ACT / PoT 的分流）
    // ------------------------------------------------------------------------
    logic          act_in_valid;
    logic [1:0]    act_in_mode;
    logic [1023:0] act_in_data;
    mult_tag_t     act_in_tag;
    logic [2:0]    act_in_idx;

    logic          pot_in_valid;
    logic [1023:0] pot_in_data;
    mult_tag_t     pot_in_tag;
    logic [2:0]    pot_in_idx;

    logic          mha_comb_valid;
    logic [1023:0] mha_comb_data;
    logic [2:0]    mha_comb_idx;

    logic          use_act_for_pot;

    // ------------------------------------------------------------------------
    // 區塊 6：Sideband pipeline (跟 ACT/PoT 的延遲對齊)
    //   act_*_cs: 4 級 (input buf + 3 stages)
    //   pot_*_cs: 5 級 (input buf + Matrix_Max 3 stages + final 1 stage)
    // ------------------------------------------------------------------------
    mult_tag_t     act_tag_cs [0:3];
    logic [2:0]    act_idx_cs [0:3];
    mult_tag_t     pot_tag_cs [0:4];
    logic [2:0]    pot_idx_cs [0:4];

    // ========================================================================
    // 函式：MHA head 合併 / score 壓縮 / mha_out0 壓縮解壓
    // ========================================================================
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

    // Storage slot s in [0,31] maps to full 8x8 lane (row=s/4, col=s%4); only
    // head0 cols 0-3 of each row survive into combine_mha_heads.
    function automatic logic [MHA_OUT_PACK_W-1:0] pack_mha_out(input logic [1023:0] src);
        integer full_lane;
        begin
            for (int s = 0; s < MHA_OUT_LANES; s++) begin
                full_lane = ((s / 4) * 8) + (s % 4);
                pack_mha_out[MHA_OUT_PACK_W-1 - (s * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W] =
                    src[1023 - (full_lane * 16) - (16 - MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W];
            end
        end
    endfunction

    function automatic logic [1023:0] unpack_mha_out(input logic [MHA_OUT_PACK_W-1:0] src);
        logic [MHA_OUT_ELEM_W-1:0] lane;
        integer full_lane;
        begin
            unpack_mha_out = 1024'd0;
            for (int s = 0; s < MHA_OUT_LANES; s++) begin
                full_lane = ((s / 4) * 8) + (s % 4);
                lane = src[MHA_OUT_PACK_W-1 - (s * MHA_OUT_ELEM_W) -: MHA_OUT_ELEM_W];
                unpack_mha_out[1023 - (full_lane * 16) -: 16] =
                    {{(16-MHA_OUT_ELEM_W){lane[MHA_OUT_ELEM_W-1]}}, lane};
            end
        end
    endfunction

    // ========================================================================
    // 區塊 7：Ready / result_valid 給 Control 看的回報訊號
    // ========================================================================
    assign qkv_ready    = (&q_ready_cs) && (&k_ready_cs) && (&v_ready_cs);
    assign sv_ready     = (op == 2'b11) ? (&score_ready_cs) : (&score_ready_cs[3:0]);
    assign result_valid = pot_valid &&
                          ((pot_tag_cs[4] == MT_NORM) ||
                           (pot_tag_cs[4] == MT_FINAL));

    // ========================================================================
    // 區塊 8：Mult-output dispatch (mult → ACT 或 PoT 或 mha_out0_mem)
    //
    //   MT_NORM            → ACT (USER mode, tag=MT_NORM)
    //   MT_SCORE           → ACT (SPECIAL mode, tag=MT_SCORE)
    //   MT_FINAL (SHA)     → ACT (USER mode, tag=MT_FINAL)
    //   MT_FINAL (MHA h0)  → 存進 mha_out0_mem，不送 ACT
    //   MT_FINAL (MHA h1)  → 跟 mha_out0_mem combine 後送 ACT (tag=MT_FINAL)
    //   MT_Q/K/V           → PoT (直接，不過 ACT)
    // ========================================================================
    assign mha_comb_valid = mult_valid && (op == 2'b11) &&
                            (mult_tag_out == MT_FINAL) && mult_idx_out[2];
    assign mha_comb_idx   = {1'b0, mult_idx_out[1:0]};
    assign mha_comb_data  = combine_mha_heads(unpack_mha_out(mha_out0_mem[mult_idx_out[1:0]]),
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
        // For NORM/SCORE the tag passes through; for FINAL we suppress head0
        // of MHA (it's only stored, not sent to ACT). act_in_tag value is
        // ignored when act_in_valid=0 (Q/K/V path), so default is harmless.
        act_in_mode = (mult_tag_out == MT_SCORE) ? ACT_SPECIAL : ACT_USER;
        act_in_tag  = ((mult_tag_out == MT_FINAL) && (op == 2'b11) && !mha_comb_valid)
                      ? MT_NONE : mult_tag_out;
    end

    // ========================================================================
    // 區塊 9：ACT-output / Mult-Q/K/V dispatch (→ PoT)
    //
    //   MT_NORM/MT_FINAL (after ACT) → PoT (走 ACT→PoT 路徑)
    //   MT_Q/K/V (from mult, bypass ACT) → PoT 直接
    //   MT_SCORE (after ACT) → score_mem (不走 PoT)
    // ========================================================================
    assign use_act_for_pot = act_valid &&
                             ((act_tag_cs[3] == MT_NORM) || (act_tag_cs[3] == MT_FINAL));

    assign pot_in_valid = use_act_for_pot ||
                          (mult_valid && ((mult_tag_out == MT_Q) ||
                                          (mult_tag_out == MT_K) ||
                                          (mult_tag_out == MT_V)));
    assign pot_in_data  = use_act_for_pot ? act_data       : mult_data;
    assign pot_in_idx   = use_act_for_pot ? act_idx_cs[3]  : mult_idx_out;

    // tags pass through; Q/K/V branch gated by pot_in_valid downstream
    assign pot_in_tag   = use_act_for_pot ? act_tag_cs[3]  : mult_tag_out;

    // ========================================================================
    // 區塊 10：Submodule 例化（純連線，沒有額外邏輯）
    // ========================================================================
    Multiple_Processor u_mult_proc (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue_valid  (issue_valid_cs),
        .issue_mode   (issue_mode_cs),
        .issue_idx    (issue_idx_cs),
        .op           (op),
        .param        (param),
        .weight_k     (weight_k),
        .weight_v     (weight_v),
        .rd_data      (rd_data_cs),
        .x_mem        (x_mem),
        .q_mem        (q_mem),
        .k_mem        (k_mem),
        .v_mem        (v_mem),
        .score_mem    (score_mem),
        .mult_valid   (mult_valid),
        .mult_data    (mult_data),
        .mult_tag_out (mult_tag_out),
        .mult_idx_out (mult_idx_out)
    );

    ACT_4Stage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),   // comb 直接進，input buffer 在 ACT 內
        .act       (act),
        .act_mode  (act_in_mode),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    PoT_5Stage_Parallel u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),   // comb 直接進，input buffer 在 PoT 內
        .in_data   (pot_in_data),
        .out_valid (pot_valid),
        .out_data  (pot_data)
    );

    // ========================================================================
    // 區塊 11：所有狀態更新 (always_ff)
    //   1. Issue / capture 入口 buffer
    //   2. Sideband pipeline (act_*_cs / pot_*_cs)
    //   3. Memory writes (x/q/k/v/score/mha_out0_mem + ready flags)
    //   4. Output buffer (wr_data / out_valid / out_data)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // (1) issue / capture buffer
            issue_valid_cs   <= 1'b0;
            issue_mode_cs    <= IM_NONE;
            issue_idx_cs     <= 5'd0;
            capture_valid_cs <= 1'b0;
            capture_idx_cs   <= 2'd0;
            rd_data_cs       <= '0;

            // (2) sideband
            for (int i = 0; i < 4; i++) begin
                act_tag_cs[i] <= MT_NONE;
                act_idx_cs[i] <= 3'd0;
            end
            for (int i = 0; i < 5; i++) begin
                pot_tag_cs[i] <= MT_NONE;
                pot_idx_cs[i] <= 3'd0;
            end

            // (3) ready flags
            q_ready_cs     <= 4'd0;
            k_ready_cs     <= 4'd0;
            v_ready_cs     <= 4'd0;
            score_ready_cs <= 8'd0;

            // (4) output buffer
            out_valid <= 1'b0;
            out_data  <= 32'd0;
        end
        else begin
            // ---------------- (1) Issue / capture buffer --------------------
            issue_valid_cs   <= issue_valid;
            issue_mode_cs    <= issue_valid ? issue_mode : IM_NONE;
            issue_idx_cs     <= issue_valid ? issue_idx  : 5'd0;
            capture_valid_cs <= capture_valid;
            capture_idx_cs   <= capture_idx;
            rd_data_cs       <= rd_data;

            // ---------------- (2) Sideband pipeline -------------------------
            // ACT path: 4 級 (input buf + 3 stages)
            act_tag_cs[0] <= act_in_valid ? act_in_tag : MT_NONE;
            act_idx_cs[0] <= act_in_idx;
            for (int i = 1; i < 4; i++) begin
                act_tag_cs[i] <= act_tag_cs[i - 1];
                act_idx_cs[i] <= act_idx_cs[i - 1];
            end

            // PoT path: 5 級 (input buf + 3 max + 1 final)
            pot_tag_cs[0] <= pot_in_valid ? pot_in_tag : MT_NONE;
            pot_idx_cs[0] <= pot_in_idx;
            for (int i = 1; i < 5; i++) begin
                pot_tag_cs[i] <= pot_tag_cs[i - 1];
                pot_idx_cs[i] <= pot_idx_cs[i - 1];
            end

            // ---------------- (3) Memory writes -----------------------------
            // x_mem capture (from RAM)
            if (capture_valid_cs) begin
                x_mem[capture_idx_cs] <= rd_data_cs[255:0];
            end

            // 新 QKV 組開始：清掉前一組的 ready flags
            if (issue_valid_cs && (issue_mode_cs == IM_QKV) && (issue_idx_cs == 5'd0)) begin
                q_ready_cs     <= 4'd0;
                k_ready_cs     <= 4'd0;
                v_ready_cs     <= 4'd0;
                score_ready_cs <= 8'd0;
            end

            // score_mem ← ACT (MT_SCORE)
            if (act_valid && (act_tag_cs[3] == MT_SCORE)) begin
                score_mem[act_idx_cs[3]]      <= pack_score(act_data);
                score_ready_cs[act_idx_cs[3]] <= 1'b1;
            end

            // mha_out0_mem ← Mult (MHA FINAL head0)
            if (mult_valid && (mult_tag_out == MT_FINAL) &&
                (op == 2'b11) && !mult_idx_out[2]) begin
                mha_out0_mem[mult_idx_out[1:0]] <= pack_mha_out(mult_data);
            end

            // q/k/v_mem ← PoT
            if (pot_valid) begin
                case (pot_tag_cs[4])
                    MT_Q: begin
                        q_mem[pot_idx_cs[4][1:0]]      <= pot_data;
                        q_ready_cs[pot_idx_cs[4][1:0]] <= 1'b1;
                    end
                    MT_K: begin
                        k_mem[pot_idx_cs[4][1:0]]      <= pot_data;
                        k_ready_cs[pot_idx_cs[4][1:0]] <= 1'b1;
                    end
                    MT_V: begin
                        v_mem[pot_idx_cs[4][1:0]]      <= pot_data;
                        v_ready_cs[pot_idx_cs[4][1:0]] <= 1'b1;
                    end
                    default: begin end
                endcase
            end

            // ---------------- (4) Output buffer -----------------------------
            out_valid <= result_valid;
            if (result_valid) begin
                wr_data  <= pot_data;
                out_data <= pot_data[31:0];
            end
        end
    end

endmodule

module Multiple_Processor (
    input  logic           clk,
    input  logic           rst_n,

    input  logic           issue_valid,
    input  issue_mode_t    issue_mode,
    input  logic [4:0]     issue_idx,

    input  logic [1:0]     op,
    input  logic [255:0]   param,
    input  logic [255:0]   weight_k,
    input  logic [255:0]   weight_v,
    input  logic [255:0]   rd_data,

    input  logic [255:0]   x_mem       [0:3],
    input  logic [255:0]   q_mem       [0:3],
    input  logic [255:0]   k_mem       [0:3],
    input  logic [255:0]   v_mem       [0:3],
    input  logic [703:0]   score_mem   [0:7],  // 11-bit × 64 lanes

    output logic           mult_valid,
    output logic [1023:0]  mult_data,
    output mult_tag_t      mult_tag_out,
    output logic [2:0]     mult_idx_out
);

    // Matches Mult_3Stage_Parallel's internal depth (input buffer + 2 mult stages).
    localparam int MULT_STAGES = 3;

    logic          mult_issue_valid;
    logic          mult_issue_b_transpose;
    logic          mult_issue_a_unsigned;  // 1 = lo/mid nibble (zero-extend A)
    logic          mult_issue_head_mask;
    logic          mult_issue_head_sel;
    logic [255:0]  mult_issue_A;
    logic [255:0]  mult_issue_B;
    mult_tag_t     mult_issue_tag;
    logic [2:0]    mult_issue_idx;
    logic [1:0]    mult_issue_nibble;      // FINAL nibble phase 0/1/2

    mult_tag_t  mult_tag_cs    [0:MULT_STAGES-1];
    logic [2:0] mult_idx_cs    [0:MULT_STAGES-1];
    logic [1:0] mult_nibble_cs [0:MULT_STAGES-1]; // nibble phase through pipeline

    // FINAL counters (registered, valid for the current issue cycle). Issue order
    // is INTERLEAVED so the 4 matrices' final results emerge on consecutive cycles
    // (needed for the burst-4 write to stream wr_data correctly):
    //   loop nesting = head (outer) > nibble (mid) > matrix (inner)
    //   SHA: 4 mat × 3 nibble          = 12 issues
    //   MHA: 2 head × 3 nibble × 4 mat = 24 issues
    logic [1:0] fin_mat_cs;    // matrix within group 0..3 (innermost)
    logic [1:0] fin_nibble_cs; // 0=lo, 1=mid, 2=hi (middle)
    logic       fin_head_cs;   // MHA head 0/1 (outermost; SHA stays 0)

    // Extract one packed-4-bit nibble vector (64 lanes × 4 bit) from score_mem row.
    // phase 0: bits[3:0]  (unsigned nibble)
    // phase 1: bits[7:4]  (unsigned nibble)
    // phase 2: sign_extend(bits[10:8] from 3-bit to 4-bit)  (signed nibble)
    function automatic logic [255:0] extract_score_nibble(
        input logic [703:0] src,
        input logic [1:0]   phase
    );
        logic [10:0] ls;
        begin
            for (int s = 0; s < 64; s++) begin
                ls = src[703 - (s * 11) -: 11];
                case (phase)
                    2'd0:    extract_score_nibble[255 - (s * 4) -: 4] = ls[3:0];
                    2'd1:    extract_score_nibble[255 - (s * 4) -: 4] = ls[7:4];
                    default: extract_score_nibble[255 - (s * 4) -: 4] = {ls[10], ls[10:8]};
                endcase
            end
        end
    endfunction

    always_comb begin
        mult_issue_valid       = 1'b0;
        mult_issue_b_transpose = 1'b0;
        mult_issue_a_unsigned  = 1'b0;
        mult_issue_head_mask   = 1'b0;
        mult_issue_head_sel    = 1'b0;
        mult_issue_A           = 256'd0;
        mult_issue_B           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_idx         = 3'd0;
        mult_issue_nibble      = 2'd0;

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
                        5'd0, 5'd1, 5'd2:    mult_issue_idx = 3'd0;
                        5'd3, 5'd4, 5'd5:    mult_issue_idx = 3'd1;
                        5'd6, 5'd7, 5'd8:    mult_issue_idx = 3'd2;
                        default:             mult_issue_idx = 3'd3;
                    endcase
                    mult_issue_A = x_mem[mult_issue_idx[1:0]];

                    case (issue_idx)
                        5'd0, 5'd3, 5'd6, 5'd9: begin
                            mult_issue_B   = param;
                            mult_issue_tag = MT_Q;
                        end
                        5'd1, 5'd4, 5'd7, 5'd10: begin
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
                    mult_issue_A           = q_mem[issue_idx[1:0]];
                    mult_issue_B           = k_mem[issue_idx[1:0]];
                    mult_issue_b_transpose = 1'b1;
                    mult_issue_tag         = MT_SCORE;
                end

                IM_FINAL: begin
                    // head/nibble/matrix from registered counters (interleaved order).
                    mult_issue_idx        = (op == 2'b11) ?
                                            {fin_head_cs, fin_mat_cs} :
                                            {1'b0, fin_mat_cs};
                    mult_issue_a_unsigned = (fin_nibble_cs != 2'd2); // lo/mid unsigned
                    mult_issue_nibble     = fin_nibble_cs;
                    mult_issue_A          = extract_score_nibble(
                                               score_mem[mult_issue_idx], fin_nibble_cs);
                    mult_issue_B          = v_mem[fin_mat_cs];
                    // No head_mask in FINAL: MHA does a full 8-tap score×V dot;
                    // the per-head column split happens later in combine_mha_heads.
                    mult_issue_tag = MT_FINAL;
                end

                default: begin
                    mult_issue_valid = 1'b0;
                end
            endcase
        end
    end

    // ---- FINAL interleaved counters ----------------------------------------
    // Nesting: matrix (inner) wraps into nibble (mid) wraps into head (outer).
    // This emits matrix 0..3 back-to-back within each nibble round, so the
    // nibble-2 round yields 4 consecutive final results.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fin_mat_cs    <= 2'd0;
            fin_nibble_cs <= 2'd0;
            fin_head_cs   <= 1'b0;
        end
        else if (issue_valid) begin
            if (issue_mode == IM_FINAL) begin
                if (fin_mat_cs == 2'd3) begin
                    fin_mat_cs <= 2'd0;
                    if (fin_nibble_cs == 2'd2) begin
                        fin_nibble_cs <= 2'd0;
                        fin_head_cs   <= fin_head_cs + 1'b1; // MHA: head0→head1
                    end else begin
                        fin_nibble_cs <= fin_nibble_cs + 1'b1;
                    end
                end else begin
                    fin_mat_cs <= fin_mat_cs + 1'b1;
                end
            end else begin
                // Reset at start of any non-FINAL issue (QKV / SV)
                fin_mat_cs    <= 2'd0;
                fin_nibble_cs <= 2'd0;
                fin_head_cs   <= 1'b0;
            end
        end
    end

    // Raw multiplier outputs (before nibble accumulation)
    logic          mult_raw_valid;
    logic [1023:0] mult_raw_data;

    Mult_3Stage_Parallel u_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (mult_issue_b_transpose),
        .a_unsigned  (mult_issue_a_unsigned),
        .head_mask   (mult_issue_head_mask),
        .head_sel    (mult_issue_head_sel),
        .in_valid    (mult_issue_valid),
        .in_data_A   (mult_issue_A),
        .in_data_B   (mult_issue_B),
        .out_valid   (mult_raw_valid),
        .out_data    (mult_raw_data)
    );

    // Tag / nibble phase pipeline (mirrors Mult_3Stage_Parallel's 3-stage depth)
    always_ff @(posedge clk) begin
        mult_tag_cs[0]    <= mult_issue_valid ? mult_issue_tag    : MT_NONE;
        mult_idx_cs[0]    <= mult_issue_idx;
        mult_nibble_cs[0] <= mult_issue_nibble;
        for (int i = 1; i < MULT_STAGES; i++) begin
            mult_tag_cs[i]    <= mult_tag_cs[i - 1];
            mult_idx_cs[i]    <= mult_idx_cs[i - 1];
            mult_nibble_cs[i] <= mult_nibble_cs[i - 1];
        end
    end

    // ---- Nibble accumulator (FINAL stage only) ------------------------------
    // Interleaved: each matrix m has its own running accumulator. A matrix sees
    // its 3 nibbles spaced 4 issues apart (lo ×1 → mid ×16 → hi ×256). The hi
    // round (nibble 2) yields the 4 finals on consecutive cycles.
    logic [1023:0] nibb_acc_cs [0:3];
    logic [1023:0] nibb_final_data;
    logic [1:0]    fin_mat_out; // matrix index of the result currently emerging

    assign fin_mat_out = mult_idx_cs[MULT_STAGES-1][1:0];

    // Per-lane shift-accumulate: each 16-bit slot does acc + (prod << sh)
    // INDEPENDENTLY, truncated to 16 bits. Doing one 1024-bit add would let a
    // lane overflow carry into the neighbouring lane (off-by-one corruption).
    function automatic logic [1023:0] lane_shift_add(
        input logic [1023:0] acc,
        input logic [1023:0] prod,
        input int            sh
    );
        logic signed [15:0] a;
        logic signed [15:0] p;
        begin
            for (int i = 0; i < 64; i++) begin
                a = acc [1023 - (i * 16) -: 16];
                p = prod[1023 - (i * 16) -: 16];
                lane_shift_add[1023 - (i * 16) -: 16] = a + (p <<< sh);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) nibb_acc_cs[i] <= 1024'd0;
        end else if (mult_raw_valid && (mult_tag_cs[MULT_STAGES-1] == MT_FINAL)) begin
            case (mult_nibble_cs[MULT_STAGES-1])
                2'd0: nibb_acc_cs[fin_mat_out] <= mult_raw_data;
                2'd1: nibb_acc_cs[fin_mat_out] <=
                          lane_shift_add(nibb_acc_cs[fin_mat_out], mult_raw_data, 4);
                default: ; // phase 2 handled combinationally; acc not updated
            endcase
        end
    end

    // Combinational: phase 2 final per-lane accumulation for this matrix
    assign nibb_final_data = lane_shift_add(nibb_acc_cs[fin_mat_out], mult_raw_data, 8);

    // Public outputs: non-FINAL passes through; FINAL only fires on phase 2.
    assign mult_valid   = mult_raw_valid &&
                          ((mult_tag_cs[MULT_STAGES-1] != MT_FINAL) ||
                           (mult_nibble_cs[MULT_STAGES-1] == 2'd2));
    assign mult_data    = (mult_tag_cs[MULT_STAGES-1] == MT_FINAL) ?
                          nibb_final_data : mult_raw_data;
    assign mult_tag_out = mult_tag_cs[MULT_STAGES-1];
    assign mult_idx_out = mult_idx_cs[MULT_STAGES-1];

endmodule

module Mult_3Stage_Parallel (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [1:0]   op,
    input  logic         b_transpose,
    input  logic         a_unsigned,  // 1 = zero-extend A nibble (FINAL lo/mid phases)
    input  logic         head_mask,
    input  logic         head_sel,
    input  logic         in_valid,
    input  logic [255:0] in_data_A,
    input  logic [255:0] in_data_B,
    output logic         out_valid,
    output logic [1023:0] out_data
);

    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int DOT_SIZE = 9;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [4:0]  s5_t;  // A operand: sign- or zero-extended 4-bit
    // 範圍分析: sel_a ∈ [-8, 15], sel_b ∈ [-8, 7]
    //   → product ∈ [15×-8, 15×7] = [-120, 105]，落在 s8 [-128, 127] 內
    // 比 s9 多省 64×9 = 576 flops（prod_cs），比原 s16 共省 4608 flops。
    typedef logic signed [7:0]  s8_t;  // product: s5 × s4 → s8 (max ±120 fits)
    typedef logic signed [15:0] s16_t;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s4_t get_pad_s4(
        input logic [255:0] vec, input integer row, input integer col
    );
        if ((row < 0) || (row >= ROW_ELEM) || (col < 0) || (col >= ROW_ELEM))
            get_pad_s4 = 4'sd0;
        else
            get_pad_s4 = get_s4(vec, (row * ROW_ELEM) + col);
    endfunction

    // Returns 5-bit signed A element.
    //   Conv:        sign-extend padded 4-bit element
    //   tap==8:      zero (bias slot)
    //   head-masked: zero
    //   a_unsigned:  zero-extend nibble {0, bits[3:0]} (FINAL lo/mid)
    //   normal:      sign-extend 4-bit element
    function automatic s5_t sel_a(
        input logic [255:0] mat_A,
        input logic [1:0]   op_sel,
        input logic         a_unsigned_sel,
        input logic         head_mask_sel,
        input logic         head_sel_sel,
        input integer       row_idx,
        input integer       lane,
        input integer       tap
    );
        integer idx;
        integer row;
        integer col;
        logic [3:0] raw4;
        begin
            if (op_sel == 2'b01) begin
                idx   = (row_idx * ROW_ELEM) + lane;
                row   = idx / ROW_ELEM;
                col   = idx % ROW_ELEM;
                sel_a = s5_t'(get_pad_s4(mat_A, row + (tap / 3) - 1, col + (tap % 3) - 1));
            end
            else if (tap == 8) begin
                sel_a = 5'sd0;
            end
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4)))) begin
                sel_a = 5'sd0;
            end
            else begin
                raw4  = mat_A[255 - ((row_idx * ROW_ELEM + tap) * 4) -: 4];
                sel_a = a_unsigned_sel ? {1'b0, raw4} : s5_t'($signed(raw4));
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
            if (op_sel == 2'b01)
                sel_b = get_s4(mat_B, tap);
            else if (tap == 8)
                sel_b = 4'sd0;
            else if (head_mask_sel &&
                     ((!head_sel_sel && (tap >= 4)) || (head_sel_sel && (tap < 4))))
                sel_b = 4'sd0;
            else if (b_transpose_sel)
                sel_b = get_s4(mat_B, (lane * ROW_ELEM) + tap);
            else
                sel_b = get_s4(mat_B, (tap * ROW_ELEM) + lane);
        end
    endfunction

    // Stage 0: input buffer (operands + control). Decouples the upstream issue mux
    //          from the partial-product combinational cone.
    // Stage 1: 576 partial products s5×s4 truncated to s8, then register
    //          (4608 fewer flops vs s16, 576 fewer vs s9; range fits [-120, 105]).
    // Stage 2: per-lane 9-input add tree → s16 sum, then register.
    logic         in_valid_cs;
    // op 在一個 job 內為常數（exec_op 已 latch 在 Control），不需要 input register。
    logic         b_transpose_cs;
    logic         a_unsigned_cs;
    logic         head_mask_cs;
    logic         head_sel_cs;
    logic [255:0] in_data_A_cs;
    logic [255:0] in_data_B_cs;

    logic stage1_valid_cs;
    logic stage2_valid_cs;
    s8_t  prod_cs   [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s16_t sum_cs    [0:MAT_SIZE-1];

    s8_t  prod_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s16_t sum_next  [0:MAT_SIZE-1];

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_next[(row * ROW_ELEM) + lane][tap] = s8_t'(
                        $signed(sel_a(in_data_A_cs, op, a_unsigned_cs,
                                      head_mask_cs, head_sel_cs, row, lane, tap)) *
                        $signed(sel_b(in_data_B_cs, op, b_transpose_cs,
                                      head_mask_cs, head_sel_cs, lane, tap)));
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_next[i] =
                (s16_t'(prod_cs[i][0]) + s16_t'(prod_cs[i][1]) +
                 s16_t'(prod_cs[i][2]) + s16_t'(prod_cs[i][3])) +
                (s16_t'(prod_cs[i][4]) + s16_t'(prod_cs[i][5]) +
                 s16_t'(prod_cs[i][6]) + s16_t'(prod_cs[i][7]) +
                 s16_t'(prod_cs[i][8]));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_cs     <= 1'b0;
            stage1_valid_cs <= 1'b0;
            stage2_valid_cs <= 1'b0;
        end
        else begin
            in_valid_cs     <= in_valid;
            b_transpose_cs  <= b_transpose;
            a_unsigned_cs   <= a_unsigned;
            head_mask_cs    <= head_mask;
            head_sel_cs     <= head_sel;
            in_data_A_cs    <= in_data_A;
            in_data_B_cs    <= in_data_B;

            stage1_valid_cs <= in_valid_cs;
            stage2_valid_cs <= stage1_valid_cs;
            for (int i = 0; i < MAT_SIZE; i++)
                for (int t = 0; t < DOT_SIZE; t++)
                    prod_cs[i][t] <= prod_next[i][t];
            for (int i = 0; i < MAT_SIZE; i++)
                sum_cs[i] <= sum_next[i];
        end
    end

    assign out_valid = stage2_valid_cs;

    always_comb begin
        out_data = 1024'd0;
        for (int i = 0; i < MAT_SIZE; i++)
            out_data[1023 - (i * 16) -: 16] = sum_cs[i];
    end
endmodule

module ACT_4Stage_Parallel (
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
    localparam int NUM_CHUNK  = 4;
    localparam int ACT_STAGES = 3;

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [17:0] s18_t;  // psum: 4×s16 → range ±131K, fits s18
    typedef logic signed [19:0] s20_t;  // 留給 stage-1 中間 (part_sum01/23, BAT 和)

    // Input buffer (decouples upstream dispatch mux from psum tree; ACT 從外面
    // 看是 4-stage：input_buf → psum → threshold → apply)。
    logic          in_valid_buf;
    logic [1:0]    act_buf;
    logic [1:0]    mode_buf;
    logic [1023:0] in_data_buf;

    logic          valid_cs  [0:ACT_STAGES-1];
    logic [1:0]    act_cs    [0:ACT_STAGES-1];
    logic [1:0]    mode_cs   [0:ACT_STAGES-1];
    logic [1023:0] matrix_cs [0:ACT_STAGES-1];

    // Stage 0 registers 4 partial sums per chunk (16 total); stage 1 combines
    // them into per-chunk thresholds. Splitting the BAT 16-element sum into a
    // partial + combine keeps every adder tree at depth 2, so BAT no longer has
    // a longer path than RAT/CAT.
    // psum 用 s18（4×s16 的最大累加 ±131K）；thr 經 >>>3 或 >>>4 後 range ±32K，s16 即可。
    s18_t          psum_cs   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_cs  [0:NUM_CHUNK-1];
    s16_t          thr_b_cs  [0:NUM_CHUNK-1];

    s18_t          psum_ns   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_ns  [0:NUM_CHUNK-1];
    s16_t          thr_b_ns  [0:NUM_CHUNK-1];
    logic [1023:0] apply_ns;

    s20_t          part_sum01;
    s20_t          part_sum23;
    integer        apply_idx;
    s16_t          apply_thr;

    assign out_valid = valid_cs[ACT_STAGES-1];
    assign out_data  = matrix_cs[ACT_STAGES-1];

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s18_t ext18(input s16_t value);
        ext18 = {{2{value[15]}}, value};
    endfunction

    // One partial sum = 4 elements: a half-row (RAT), a half-column (CAT), or a
    // block row (BAT). p in 0..3 selects which group within the chunk. Depth-2
    // adder tree; the stage-1 combine adds the partials back together.
    function automatic s18_t chunk_partial_sum(
        input logic [1023:0] matrix,
        input logic [1:0]    act_sel,
        input integer        chunk,
        input integer        p
    );
        integer row;
        integer col;
        integer base_row;
        integer base_col;
        integer blk_row;
        s18_t   e0;
        s18_t   e1;
        s18_t   e2;
        s18_t   e3;
        begin
            e0 = 18'sd0;
            e1 = 18'sd0;
            e2 = 18'sd0;
            e3 = 18'sd0;

            case (act_sel)
                2'b01: begin  // RAT: row = 2*chunk + (p>>1), cols = (p&1)*4 + 0..3
                    row = (chunk * 2) + (p / 2);
                    col = (p % 2) * 4;
                    e0  = ext18(get_s16(matrix, (row * ROW_ELEM) + col + 0));
                    e1  = ext18(get_s16(matrix, (row * ROW_ELEM) + col + 1));
                    e2  = ext18(get_s16(matrix, (row * ROW_ELEM) + col + 2));
                    e3  = ext18(get_s16(matrix, (row * ROW_ELEM) + col + 3));
                end

                2'b10: begin  // CAT: col = 2*chunk + (p>>1), rows = (p&1)*4 + 0..3
                    col = (chunk * 2) + (p / 2);
                    row = (p % 2) * 4;
                    e0  = ext18(get_s16(matrix, ((row + 0) * ROW_ELEM) + col));
                    e1  = ext18(get_s16(matrix, ((row + 1) * ROW_ELEM) + col));
                    e2  = ext18(get_s16(matrix, ((row + 2) * ROW_ELEM) + col));
                    e3  = ext18(get_s16(matrix, ((row + 3) * ROW_ELEM) + col));
                end

                2'b11: begin  // BAT: 4x4 block, p selects the block row (4 elements)
                    base_row = (chunk / 2) * 4;
                    base_col = (chunk % 2) * 4;
                    blk_row  = base_row + p;
                    e0 = ext18(get_s16(matrix, (blk_row * ROW_ELEM) + base_col + 0));
                    e1 = ext18(get_s16(matrix, (blk_row * ROW_ELEM) + base_col + 1));
                    e2 = ext18(get_s16(matrix, (blk_row * ROW_ELEM) + base_col + 2));
                    e3 = ext18(get_s16(matrix, (blk_row * ROW_ELEM) + base_col + 3));
                end

                default: begin
                    e0 = 18'sd0;
                    e1 = 18'sd0;
                    e2 = 18'sd0;
                    e3 = 18'sd0;
                end
            endcase

            chunk_partial_sum = (e0 + e1) + (e2 + e3);
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

    function automatic s16_t select_threshold(
        input logic [1:0] act_sel,
        input integer     lane,
        input s16_t       threshold_a,
        input s16_t       threshold_b
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
                    select_threshold = 16'sd0;
                end
            endcase
        end
    endfunction

    function automatic s16_t activate_value(
        input s16_t       value,
        input logic [1:0] act_sel,
        input logic [1:0] mode_sel,
        input s16_t       threshold
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
                        activate_value = (value < threshold) ? (value >>> 3) : value;
                    end
                end
            endcase
        end
    endfunction

    // Stage 0 combinational: 4 partial sums per chunk, straight from the buffered input.
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int p = 0; p < 4; p++) begin
                psum_ns[chunk][p] = chunk_partial_sum(in_data_buf, act_buf, chunk, p);
            end
        end
    end

    // Stage 1 combinational: combine the registered partials into thresholds.
    // RAT/CAT keep two thresholds per chunk (one per row/col); BAT shares one.
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            part_sum01 = psum_cs[chunk][0] + psum_cs[chunk][1];
            part_sum23 = psum_cs[chunk][2] + psum_cs[chunk][3];
            case (act_cs[0])
                2'b01, 2'b10: begin
                    thr_a_ns[chunk] = part_sum01 >>> 3;
                    thr_b_ns[chunk] = part_sum23 >>> 3;
                end
                2'b11: begin
                    thr_a_ns[chunk] = (part_sum01 + part_sum23) >>> 4;
                    thr_b_ns[chunk] = thr_a_ns[chunk];
                end
                default: begin
                    thr_a_ns[chunk] = 16'sd0;
                    thr_b_ns[chunk] = 16'sd0;
                end
            endcase
        end
    end

    // Stage 2 combinational: apply activation to all 64 lanes in parallel using
    // the stage-1 thresholds. chunk_idx fully partitions the matrix, so every
    // element is written exactly once (no latch).
    always_comb begin
        apply_ns = matrix_cs[1];
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int lane = 0; lane < CHUNK_SIZE; lane++) begin
                apply_idx = chunk_idx(act_cs[1], mode_cs[1], chunk, lane);
                apply_thr = select_threshold(act_cs[1], lane,
                                             thr_a_cs[chunk], thr_b_cs[chunk]);
                apply_ns[1023 - (apply_idx * 16) -: 16] =
                    activate_value(get_s16(matrix_cs[1], apply_idx),
                                   act_cs[1], mode_cs[1], apply_thr);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_buf <= 1'b0;
            act_buf      <= 2'd0;
            mode_buf     <= ACT_USER;
            in_data_buf  <= 1024'd0;
            for (int i = 0; i < ACT_STAGES; i++) begin
                valid_cs[i]  <= 1'b0;
                act_cs[i]    <= 2'd0;
                mode_cs[i]   <= ACT_USER;
                matrix_cs[i] <= 1024'd0;
            end
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) psum_cs[c][p] <= 18'sd0;
                thr_a_cs[c] <= 16'sd0;
                thr_b_cs[c] <= 16'sd0;
            end
        end
        else begin
            // Input buffer: 從上游 dispatch mux 切一拍進來。
            in_valid_buf <= in_valid;
            act_buf      <= act;
            mode_buf     <= act_mode;
            in_data_buf  <= in_data;

            // Stage 0: capture matrix + partial sums.
            valid_cs[0]  <= in_valid_buf;
            act_cs[0]    <= act_buf;
            mode_cs[0]   <= mode_buf;
            matrix_cs[0] <= in_data_buf;
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) psum_cs[c][p] <= psum_ns[c][p];
            end

            // Stage 1: combine partials into thresholds, carry the matrix.
            valid_cs[1]  <= valid_cs[0];
            act_cs[1]    <= act_cs[0];
            mode_cs[1]   <= mode_cs[0];
            matrix_cs[1] <= matrix_cs[0];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                thr_a_cs[c] <= thr_a_ns[c];
                thr_b_cs[c] <= thr_b_ns[c];
            end

            // Stage 2: apply activation.
            valid_cs[2]  <= valid_cs[1];
            act_cs[2]    <= act_cs[1];
            mode_cs[2]   <= mode_cs[1];
            matrix_cs[2] <= apply_ns;
        end
    end
endmodule


module PoT_5Stage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] in_data,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAT_SIZE  = 64;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [15:0] s16_t;

    // Input registers：
    //   in_data_cs 走 src_pipe（quant 要 signed 原值）。
    //   abs_cs 餵 Matrix_Max；abs comb 從 in_data 算（上游 act/mult Q 已 reg），
    //   把 abs 的 ~15-gate carry chain 從 Matrix_Max stage 1 抽到 input edge，
    //   切短原本 in_data_cs→abs→max4→max16_cs 的 critical path。
    logic          in_valid_cs;
    logic [1023:0] in_data_cs;
    logic [1023:0] abs_cs;
    logic [1023:0] abs_ns;

    logic          max_valid;
    logic [15:0]   max_abs;
    logic [1023:0] src_pipe_cs [0:2];
    logic [3:0]    shift_next;
    logic [255:0]  out_data_ns;

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic logic [15:0] abs16(input s16_t value);
        abs16 = (value < 0) ? -value : value;
    endfunction

    // abs comb：對 64 lanes 同步算 absolute value，給下一拍 abs_cs。
    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            abs_ns[1023 - (i * 16) -: 16] = abs16(get_s16(in_data, i));
        end
    end

    // input register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_cs <= 1'b0;
        end
        else begin
            // Do not gate with in_valid; avoiding the enable mux keeps the
            // register D path simpler and gives synthesis more freedom.
            in_valid_cs <= in_valid;
            in_data_cs  <= in_data;
            abs_cs      <= abs_ns;
        end
    end

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

    // Quantize all 64 elements in one stage: each lane is an independent
    // arithmetic shift + clamp, so the two former phase-halves run in parallel
    // without lengthening the per-lane path.
    function automatic logic [255:0] quant_all(
        input logic [1023:0] src_data,
        input logic [3:0]    shift
    );
        s16_t scaled;
        begin
            quant_all = 256'd0;
            for (int idx = 0; idx < MAT_SIZE; idx++) begin
                scaled = get_s16(src_data, idx) >>> shift;
                quant_all[255 - (idx * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    Matrix_Max_3Stage_Parallel u_matrix_max (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid_cs),
        .in_abs    (abs_cs),
        .out_valid (max_valid),
        .out_max   (max_abs)
    );

    always_comb begin
        shift_next   = pot_shift(max_abs);
        out_data_ns  = quant_all(src_pipe_cs[2], shift_next);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int stage = 0; stage < 3; stage++) begin
                src_pipe_cs[stage] <= 1024'd0;
            end
        end
        else begin
            src_pipe_cs[0] <= in_data_cs;
            src_pipe_cs[1] <= src_pipe_cs[0];
            src_pipe_cs[2] <= src_pipe_cs[1];
        end
    end

    // clean timing output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end
        else begin
            out_valid  <= max_valid;
            out_data   <= out_data_ns;
        end
    end

endmodule


module Matrix_Max_3Stage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] in_abs,   // 已是 64 lanes unsigned abs（PoT 上游算好）
    output logic          out_valid,
    output logic [15:0]   out_max
);

    localparam int MAT_SIZE    = 64;
    localparam int MAX16_COUNT = 16;
    localparam int MAX4_COUNT  = 4;

    logic          st1_valid;
    logic          st2_valid;
    logic [15:0]   max16_ns [0:MAX16_COUNT-1];
    logic [15:0]   max4_ns  [0:MAX4_COUNT-1];
    logic [15:0]   max16_cs [0:MAX16_COUNT-1];
    logic [15:0]   max4_cs  [0:MAX4_COUNT-1];
    logic [15:0]   out_max_ns;

    function automatic logic [15:0] get_u16(input logic [1023:0] vec, input integer idx);
        get_u16 = vec[1023 - (idx * 16) -: 16];
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

    // 3-stage 結構（abs 已在上游 PoT 完成，這裡純比較）：
    //   Stage 1: 64 lanes → 16 個 max (max4 of 4)
    //   Stage 2: 16 → 4 (max4 of 4)
    //   Stage 3: 4 → 1 (max4)
    always_comb begin
        for (int i = 0; i < MAX16_COUNT; i++) begin
            max16_ns[i] = max4_u16(get_u16(in_abs, i*4 + 0),
                                   get_u16(in_abs, i*4 + 1),
                                   get_u16(in_abs, i*4 + 2),
                                   get_u16(in_abs, i*4 + 3));
        end

        for (int i = 0; i < MAX4_COUNT; i++) begin
            max4_ns[i] = max4_u16(max16_cs[(i*4) + 0],
                                  max16_cs[(i*4) + 1],
                                  max16_cs[(i*4) + 2],
                                  max16_cs[(i*4) + 3]);
        end

        out_max_ns = max4_u16(max4_cs[0], max4_cs[1], max4_cs[2], max4_cs[3]);
    end

    // valid pipeline (3 stages)
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

    // data pipeline
    always_ff @(posedge clk) begin
        if (in_valid) begin
            for (int i = 0; i < MAX16_COUNT; i++) begin
                max16_cs[i] <= max16_ns[i];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (st1_valid) begin
            for (int i = 0; i < MAX4_COUNT; i++) begin
                max4_cs[i] <= max4_ns[i];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (st2_valid) begin
            out_max <= out_max_ns;
        end
    end

endmodule
