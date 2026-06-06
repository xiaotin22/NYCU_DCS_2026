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
    logic [5:0]    datapath_issue_idx;
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
        .op                     (exec_op),
        .act                    (exec_act),
        .param                  (exec_param),
        .weight_k               (exec_weight_k),
        .weight_v               (exec_weight_v),
        // Reading from RAM
        .rd_data                (rd_data),
        // Output to Control Module
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
    input  logic                            datapath_result_valid,

    output logic [1:0]                      exec_op,
    output logic [1:0]                      exec_act,
    output logic [255:0]                    exec_param,
    output logic [255:0]                    exec_weight_k,
    output logic [255:0]                    exec_weight_v,
    output logic                            datapath_issue_valid,
    output issue_mode_t                     datapath_issue_mode,
    output logic [5:0]                      datapath_issue_idx,

    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst
);

    localparam int ADDR_W = $clog2(RAM_DEPTH);
    // Attention group-32 streaming（burst-32 in/out）：QKV 直接吃 rd_data，
    // SV 由 Q/K PoT stream 觸發，FINAL 再切到 6-way MHA head0/head1 並行。
    localparam logic [ADDR_W-1:0]    GROUP_STEP = 8'd32;   // group size = 32
    localparam logic [ADDR_W-1:0]    LAST_BASE  = 8'd224;   // 256 - 32
    localparam logic [BURST_BIT-1:0] BURST_GRP  = 3'd5;     // 2^5 = 32 words
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;
    // 6-mult schedule:
    //   front: 3 engines Q/K/V + 2 engines SV score stream.
    //   final: 6 engines compute MHA head0/head1 d0/d1/d2 in the same 32 phases.
    //   HA_FRONT_WAIT covers the fixed latency from the last streaming Q/K PoT
    //   output to the last score_mem write. FINAL phase 0 is useful for both
    //   SHA and MHA.
    localparam logic [6:0] HA_RESTART_SHA = 7'd35;
    localparam logic [6:0] HA_RESTART_MHA = 7'd35;
    localparam logic [6:0] HA_WR_SHA      = 7'd11;
    localparam logic [6:0] HA_WR_MHA      = 7'd11;
    localparam logic [5:0] HA_FRONT_WAIT  = 6'd18;
    localparam logic [5:0] HA_PF_SHA_SV_PHASE = 6'd4;

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
    logic [4:0]  ha_rd_word_cnt_cs;
    logic [7:0]  wr_cmd_cnt_cs;
    logic [7:0]  out_cnt_cs;
    logic [11:0] wr_pre_pipe_cs;  // Multiple_Processor output reg plus one cycle: tap [11].
    logic [7:0]  ha_group_base_cs;
    // Stored at FINAL start so write-back stays on the draining group while
    // ha_group_base_cs can advance to the next compute group.
    logic [7:0]  ha_write_base_cs;
    logic [5:0]  ha_phase_cnt_cs;
    // Counter equivalent of the old ha_wr_pipe shift register.
    // ha_final_start launches one timer per group; ha_wr_fire stops it.
    // 7-bit：HA_RESTART_MHA 已達 67（>63），需 7-bit。
    logic [6:0]  ha_wr_cnt_cs;
    logic        ha_wr_run_cs;
    logic        ha_prefetch_pending_cs;

    logic        job_start;
    logic        ha_start;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        rd_cmd_fire;
    logic        fast_first_rd_fire;
    logic        ha_read_fire;
    logic        ha_first_read_fire;
    logic        ha_prefetch_fire;
    logic        ha_qkv_stream_fire;
    logic        ha_wait_stream_start;
    logic        ha_has_next_group;
    logic        ha_next_group_fire;
    logic        result_last;
    logic        ha_final_start;
    logic        ha_wr_fire;
    logic [7:0]  ha_next_group_base;
    logic [5:0]  ha_phase_last;

    assign job_start              = (state_cs == S_IDLE) && mem_set && in_valid;
    assign ha_start        = job_start && ((op == 2'b10) || (op == 2'b11));
    assign result_last            = datapath_result_valid && (out_cnt_cs == 8'd255);
    assign wr_pre_fire            = wr_pre_pipe_cs[11];
    assign wr_cmd_fire            = (state_cs == S_FAST_RUN) && wr_pre_fire;
    assign rd_cmd_fire            = (state_cs == S_FAST_RUN) && (rd_req_cnt_cs < 2'd2) && rd_ready;
    assign fast_first_rd_fire     = job_start && !ha_start && rd_ready;
    assign ha_read_fire          = (state_cs == S_HA_READ) &&
                                    !ha_prefetch_pending_cs &&
                                    rd_ready;
    assign ha_first_read_fire     = (state_cs == S_HA_PARAM) && in_valid &&
                                    ha_param_phase_cs && rd_ready;
    assign ha_has_next_group      = (ha_group_base_cs != LAST_BASE);
    // With x_mem removed, read data must return exactly when the next QKV stream
    // can consume it. SHA needs the command during SV; MHA needs it during FINAL.
    assign ha_prefetch_fire      = ha_has_next_group &&
                                    !ha_prefetch_pending_cs &&
                                    rd_ready &&
                                    (((exec_op != 2'b11) &&
                                      (state_cs == S_HA_ISSUE) &&
                                      (ha_stage_cs == ST_SV) &&
                                      (ha_phase_cnt_cs == HA_PF_SHA_SV_PHASE)) ||
                                     ((exec_op == 2'b11) &&
                                      ha_final_start));
    // Barrier 放寬後 SV→FINAL 在 S_HA_ISSUE 內直接接，FINAL phase 0 在 ISSUE 發，
    // 計時器即於該拍啟動（固定排程，不等待 DataPath ready bitmap）。
    assign ha_final_start        = (state_cs == S_HA_ISSUE) &&
                                    (ha_stage_cs == ST_FINAL) &&
                                    (ha_phase_cnt_cs == 6'd0);
    assign ha_next_group_fire    = ha_wr_run_cs &&
                                    (ha_wr_cnt_cs == ((exec_op == 2'b11) ?
                                                     HA_RESTART_MHA : HA_RESTART_SHA));
    // group-32：write tap 對齊 FINAL output stream；restart tap 讓 FSM 先回
    // S_HA_READ 等 prefetched rd_valid。下一組 QKV 的 Q PoT input 會落在本組
    // FINAL ACT/PoT drain 之後，避免 lane0 PoT 撞車。
    assign ha_wr_fire            = ha_wr_run_cs &&
                                    (ha_wr_cnt_cs == ((exec_op == 2'b11) ?
                                                     HA_WR_MHA : HA_WR_SHA));
    assign ha_next_group_base    = ha_group_base_cs + GROUP_STEP;
    assign ha_wait_stream_start  = (state_cs == S_HA_WAIT) &&
                                    ha_has_next_group &&
                                    ha_next_group_fire;
    assign ha_qkv_stream_fire    = rd_valid &&
                                    ((state_cs == S_HA_READ) ||
                                     ha_wait_stream_start);
    // QKV is issued directly in S_HA_READ. SHA/MHA SV score is launched
    // internally from the Q/K PoT stream, so ST_SV is only a fixed front-drain
    // wait before FINAL can consume score_mem.
    assign ha_phase_last         = (ha_stage_cs == ST_SV) ?
                                   (HA_FRONT_WAIT - 6'd1) :
                                   /* ST_FINAL */             6'd31;

    always_comb begin
        datapath_issue_valid   = 1'b0;
        datapath_issue_mode    = IM_NONE;
        datapath_issue_idx     = 6'd0;

        case (state_cs)
            S_FAST_RUN: begin
                if (rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_NORM;
                end
            end

            S_HA_READ: begin
                if (rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_QKV;
                    datapath_issue_idx   = {1'b0, ha_rd_word_cnt_cs};
                end
            end

            S_HA_ISSUE: begin
                if (ha_stage_cs == ST_FINAL) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_FINAL;
                    datapath_issue_idx   = ha_phase_cnt_cs;
                end
            end

            S_HA_WAIT: begin
                if (ha_wait_stream_start && rd_valid) begin
                    datapath_issue_valid = 1'b1;
                    datapath_issue_mode  = IM_QKV;
                    datapath_issue_idx   = 6'd0;
                end
                // FINAL drain：不發 issue（QKV/SV/FINAL phase 0 皆在 S_HA_ISSUE 內發）。
            end

            default: begin
            end
        endcase

    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_cs               <= S_IDLE;
            ha_stage_cs            <= ST_QKV;
            ha_param_phase_cs      <= 1'b0;
            rd_req_cnt_cs          <= 2'd0;
            ha_rd_word_cnt_cs      <= 5'd0;
            wr_cmd_cnt_cs          <= 8'd0;
            out_cnt_cs             <= 8'd0;
            wr_pre_pipe_cs         <= 12'd0;
            ha_group_base_cs       <= 8'd0;
            ha_write_base_cs       <= 8'd0;
            ha_phase_cnt_cs        <= 6'd0;
            ha_wr_cnt_cs           <= 7'd0;
            ha_wr_run_cs           <= 1'b0;
            ha_prefetch_pending_cs <= 1'b0;
        end
        else begin
            // Timer update for next-group and write taps. State-specific resets
            // below intentionally override these defaults in this always_ff block.
            // group-32 起 HA_WR < HA_RESTART（write 對齊量 < next-group 啟動量），
            // 故 timer 必須跑到 ha_next_group_fire(HA_RESTART) 才停，途中先經過
            // ha_wr_fire(HA_WR) 發出 burst write。原 group-8 兩者相等才在 wr_fire 停。
            if (ha_final_start) begin
                ha_wr_run_cs     <= 1'b1;
                ha_wr_cnt_cs     <= 7'd0;
                ha_write_base_cs <= ha_group_base_cs;
            end
            else if (ha_next_group_fire) begin
                ha_wr_run_cs <= 1'b0;
            end
            else if (ha_wr_run_cs) begin
                ha_wr_cnt_cs <= ha_wr_cnt_cs + 1'b1;
            end

            if (ha_first_read_fire || ha_read_fire || ha_prefetch_fire) begin
                ha_prefetch_pending_cs <= 1'b1;
            end

            if (ha_qkv_stream_fire && (ha_rd_word_cnt_cs == 5'd31)) begin
                ha_prefetch_pending_cs <= 1'b0;
            end

            case (state_cs)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op   <= op;
                        exec_act  <= act;
                        exec_param <= param;

                        // FAST_RUN counters only; attention-specific state is
                        // initialised in S_HA_PARAM right before S_HA_READ.
                        rd_req_cnt_cs  <= fast_first_rd_fire ? 2'd1 : 2'd0;
                        wr_cmd_cnt_cs  <= 8'd0;
                        out_cnt_cs     <= 8'd0;
                        wr_pre_pipe_cs <= 12'd0;

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
                    wr_pre_pipe_cs <= {wr_pre_pipe_cs[10:0], datapath_issue_valid};

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
                            ha_write_base_cs       <= 8'd0;
                            rd_req_cnt_cs           <= ha_first_read_fire ? 2'd1 : 2'd0;
                            ha_rd_word_cnt_cs      <= 5'd0;
                            out_cnt_cs              <= 8'd0;
                            ha_wr_cnt_cs           <= 7'd0;
                            ha_wr_run_cs           <= 1'b0;
                            ha_prefetch_pending_cs <= ha_first_read_fire;
                            state_cs                <= S_HA_READ;
                        end
                    end
                end

                S_HA_READ: begin
                    if (ha_read_fire) begin
                        rd_req_cnt_cs <= 2'd1;
                    end

                    if (ha_qkv_stream_fire) begin
                        if (ha_rd_word_cnt_cs == 5'd31) begin
                            ha_rd_word_cnt_cs <= 5'd0;
                            ha_phase_cnt_cs   <= 6'd0;
                            ha_stage_cs       <= ST_SV;
                            state_cs           <= S_HA_ISSUE;
                        end
                        else begin
                            ha_rd_word_cnt_cs <= ha_rd_word_cnt_cs + 1'b1;
                        end
                    end
                end

                S_HA_ISSUE: begin
                    if (ha_phase_cnt_cs == ha_phase_last) begin
                        // Barrier 放寬：QKV/SV 的 issue 一發完就直接接下一 stage，
                        //   不再進 S_HA_WAIT 等 ready bitmap。SV/FINAL 照 issue
                        //   順序消費 q/k/v_mem、score_mem，而 PoT/score 照順序生產且
                        //   領先 ≥5(SHA SV)/≥21(MHA SV) cycle，operand 必已就緒。
                        //   只有 FINAL 仍進 WAIT 做 drain + 切下一組。
                        case (ha_stage_cs)
                            ST_QKV: begin
                                ha_stage_cs     <= ST_SV;
                                ha_phase_cnt_cs <= 6'd0;
                            end
                            ST_SV: begin
                                ha_stage_cs     <= ST_FINAL;
                                ha_phase_cnt_cs <= 6'd0;
                                // 計時器在下一拍 ha_final_start(FINAL phase0) 啟動。
                            end
                            default: begin  // ST_FINAL
                                state_cs <= S_HA_WAIT;
                            end
                        endcase
                    end
                    else begin
                        ha_phase_cnt_cs <= ha_phase_cnt_cs + 1'b1;
                    end
                end

                // Barrier 放寬後只有 FINAL 進得來（QKV/SV 在 ISSUE 內直接接）。
                // 在此 drain 當組 FINAL 結果並（用 ha_next_group_fire）啟動下一組。
                S_HA_WAIT: begin
                    if (ha_has_next_group && ha_next_group_fire) begin
                        ha_group_base_cs  <= ha_next_group_base;
                        rd_req_cnt_cs      <= ha_prefetch_pending_cs ? 2'd1 : 2'd0;
                        ha_rd_word_cnt_cs <= rd_valid ? 5'd1 : 5'd0;
                        ha_phase_cnt_cs   <= 6'd0;
                        ha_stage_cs       <= ST_QKV;
                        state_cs          <= S_HA_READ;
                    end
                    else if (!ha_has_next_group && result_last) begin
                        state_cs <= S_IDLE;
                    end
                end

                default: begin
                    state_cs <= S_IDLE;
                end
            endcase

            if (exec_op[1] && datapath_result_valid && (out_cnt_cs != 8'd255)) begin
                out_cnt_cs <= out_cnt_cs + 1'b1;
            end
        end
    end

    // All RAM-read command outputs (rd_en/rd_burst/rd_addr) live here. The fire
    // conditions are mutually exclusive (each gated on a distinct state), so
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en <= 1'b0;
        end
        else begin
            rd_en    <= 1'b0;
            rd_burst <= '0;
            if (fast_first_rd_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_128;
                rd_addr  <= '0;
            end
            else if (rd_cmd_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_128;
                rd_addr  <= rd_req_cnt_cs[0] ? HALF_ADDR : '0;
            end
            else if (ha_first_read_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_GRP;
                rd_addr  <= '0;
            end
            else if (ha_read_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_GRP;
                rd_addr  <= ha_group_base_cs[ADDR_W-1:0];
            end
            else if (ha_prefetch_fire) begin
                rd_en    <= 1'b1;
                rd_burst <= BURST_GRP;
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

            // Attention: one BURST_32 per group, timed by ha_wr_cnt_cs.
            if (ha_wr_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= ha_write_base_cs[ADDR_W-1:0];
                wr_burst <= BURST_GRP;
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
//   Multiple_Processor: in→[1 issue buf]→[5 mult stages]→[1 output reg] → mult_valid
//   ACT_5Stage_Parallel: in→[1 input buf]→[4 act stages]                → act_valid
//   PoT_5Stage_Parallel: in+abs→[1 input buf]→[3 max stages]→[1 final] → pot_valid (cycle 5)
//
// Sideband (tag/idx) pipeline 長度跟著走：
//   act_*_cs[0..4]  → 5 級 (對齊 ACT 5-stage)
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
    input  logic [5:0]           issue_idx,
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [255:0]         weight_k,
    input  logic [255:0]         weight_v,
    input  logic [RAM_WIDTH-1:0] rd_data,

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

    // score_mem 每 lane 存預先算好的 base-16 signed-digit {d0,d1,d2}（各 s4 = 12-bit），
    // 而非原始 11-bit score。進位拆解搬到寫入端，FINAL 讀取端只切片（critical path↓）。
    localparam int SCORE_ELEM_W   = 12;
    localparam int SCORE_PACK_W   = SCORE_ELEM_W * 64;
    // combine_mha_heads 只取 head0 每 row 的 col 0-3，所以 FINAL head0 buffer
    // 只存 32 lanes（col 4-7 計算後丟棄）。

    // ------------------------------------------------------------------------
    // 區塊 2：跨 issue 的中間儲存（這些是 DataPath 的「狀態」，必須留在這層）
    // ------------------------------------------------------------------------
    // Burst-32 intermediate state. Q/K are streamed directly into the score
    // path as soon as their PoT outputs are ready; only V and score must be
    // retained for the later FINAL phase.
    logic [255:0]              v_mem        [0:31];
    logic [SCORE_PACK_W-1:0]   score_mem    [0:63];

    // ------------------------------------------------------------------------
    // 區塊 3：Submodule output 線（comb，從各 submodule 出來的訊號）
    // ------------------------------------------------------------------------
    logic          mult_valid;
    logic [1023:0] mult_data;
    mult_tag_t     mult_tag_out;
    logic [5:0]    mult_idx_out;
    // engine1/2：QKV 並行的 K / V（tag 恆 MT_K / MT_V）
    logic          mult_k_valid;
    logic [1023:0] mult_k_data;
    logic [5:0]    mult_k_idx;
    logic          mult_v_valid;
    logic [1023:0] mult_v_data;
    logic [5:0]    mult_v_idx;
    // engine1 SV 平行 score（head1/奇數 matrix）→ 寫 score_mem（用 mult_k_data/idx）
    logic          mult_k_score_valid;
    logic          sv0_score_valid;
    logic [1023:0] sv0_score_data;
    logic [5:0]    sv0_score_idx;
    logic          sv1_score_valid;
    logic [1023:0] sv1_score_data;
    logic [5:0]    sv1_score_idx;

    logic          act_valid;
    logic [1023:0] act_data;

    // 3 路 PoT：lane0 = engine0 的 Q / NORM / FINAL（經 ACT）；lane1/2 = K / V。
    logic          pot_valid;
    logic [255:0]  pot_data;
    logic          pot_k_valid;
    logic [255:0]  pot_k_data;
    logic          pot_v_valid;
    logic [255:0]  pot_v_data;

    // ------------------------------------------------------------------------
    // 區塊 4：Issue / capture 入口 buffer
    //   * issue path 給 Multiple_Processor，先打一拍切短上游 mux
    //   * rd_data_cs 同時服務 capture (寫 x_mem) 和 IM_NORM (送進 MP)，
    //     兩者互斥，所以共享一個 register 不衝突
    // ------------------------------------------------------------------------
    logic                 issue_valid_cs;
    issue_mode_t          issue_mode_cs;
    logic [5:0]           issue_idx_cs;
    logic [RAM_WIDTH-1:0] rd_data_cs;

    // ------------------------------------------------------------------------
    // 區塊 5：Dispatch comb 線（mult → ACT / PoT 的分流）
    // ------------------------------------------------------------------------
    logic          act_in_valid;
    logic [1:0]    act_in_mode;
    logic [1023:0] act_in_data;
    mult_tag_t     act_in_tag;
    logic [5:0]    act_in_idx;

    logic          pot_in_valid;
    logic [1023:0] pot_in_data;
    mult_tag_t     pot_in_tag;
    logic [5:0]    pot_in_idx;

    // K/V PoT lane 入口（純 bypass：直接拿 mult engine1/2 輸出）
    logic          pot_k_in_valid;
    logic          pot_v_in_valid;
    logic [5:0]    pot_v_in_idx;

    logic          qk_stream_valid;

    logic          use_act_for_pot;

    // ------------------------------------------------------------------------
    // 區塊 6：Sideband pipeline (跟 ACT/PoT 的延遲對齊)
    //   act_*_cs: 5 級 (input buf + 4 stages)
    //   pot_*_cs: 5 級 (input buf + Matrix_Max 3 stages + final 1 stage)
    // ------------------------------------------------------------------------
    mult_tag_t     act_tag_cs [0:4];  // ACT 5-stage (input_buf + pair + psum + thr + apply)
    logic [5:0]    act_idx_cs [0:4];
    mult_tag_t     pot_tag_cs [0:4];
    logic [5:0]    pot_idx_cs [0:4];
    // K/V PoT lane idx sideband（tag 恆 K/V，valid 直接用 PoT out_valid）。對齊 5-stage。
    logic [5:0]    pot_v_idx_cs   [0:4];

    // ========================================================================
    // 函式：MHA head 合併 / score 壓縮 / mha_out0 壓縮解壓
    // ========================================================================
    // 把 attention activation (x<0 → x>>2) 跟 16→11 bit truncation 都搬到這裡
    // combinational 做掉，SCORE 直接從 mult_data 寫進 score_mem，不過 ACT pipeline。
    function automatic logic [SCORE_PACK_W-1:0] pack_attention_score(input logic [1023:0] src);
        logic signed [15:0] elem;
        logic signed [15:0] activated;
        logic [10:0]        ls;     // 11-bit truncated score
        logic [4:0]         raw1;   // ls[7:4] + carry-in，最大 16
        logic               c1;
        logic [3:0]         d0, d1, d2;
        begin
            for (int i = 0; i < 64; i++) begin
                elem      = $signed(src[1023 - (i * 16) -: 16]);
                activated = (elem < 0) ? (elem >>> 2) : elem;
                ls        = activated[10:0];
                // base-16 signed-digit 拆解（與舊 read-side 同式，搬到寫入端）：
                //   score = d0 + 16·d1 + 256·d2，每個 dk ∈ [-8,7]。進位互相抵銷。
                // c1 = (ls[7:4]+ls[3]) ≥ 8 直接寫成布林式，d2 不必等 raw1 完整加法器
                //   → 縮短 ls→c1→d2 的 carry 鏈（寫入端 critical path↓）。
                raw1 = {1'b0, ls[7:4]} + {4'b0, ls[3]};
                c1   = ls[7] | (ls[6] & ls[5] & ls[4] & ls[3]);
                d0   = ls[3:0];
                d1   = raw1[3:0];
                d2   = {ls[10], ls[10:8]} + c1;
                pack_attention_score[SCORE_PACK_W-1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W] =
                    {d0, d1, d2};
            end
        end
    endfunction

    // ========================================================================
    // 區塊 7：result_valid 給 Control 看的回報訊號
    // ========================================================================
    // Fixed attention scheduling guarantees QKV/SV availability; no ready
    // bitmap feedback is needed after the stream-in rewrite.
    assign result_valid = pot_valid &&
                          ((pot_tag_cs[4] == MT_NORM) ||
                           (pot_tag_cs[4] == MT_FINAL));

    // ========================================================================
    // 區塊 8：Mult-output dispatch (mult → ACT / PoT / score_mem / V storage)
    //
    //   MT_NORM            → ACT (tag=MT_NORM)
    //   MT_SCORE           → score_mem 直接（comb pack_attention_score，省 4 cycles）
    //   MT_FINAL           → ACT (SHA direct; MHA already head-combined)
    //   MT_Q/K/V           → PoT (直接，不過 ACT)
    // ========================================================================
    // SCORE 直接走 mult → score_mem 不過 ACT，因此 ACT 入口只剩 NORM / FINAL。
    assign act_in_valid = mult_valid &&
                          ((mult_tag_out == MT_NORM) ||
                           (mult_tag_out == MT_FINAL));
    assign act_in_data  = mult_data;
    assign act_in_idx   = (mult_tag_out == MT_FINAL) ? mult_idx_out : 6'd0;

    always_comb begin
        // ACT 永遠 USER mode（SCORE 的 SPECIAL act 已內嵌進 pack_attention_score）。
        act_in_mode = ACT_USER;
        act_in_tag  = mult_tag_out;
    end

    // ========================================================================
    // 區塊 9：ACT-output / Mult-Q/K/V dispatch (→ PoT)
    //
    //   MT_NORM/MT_FINAL (after ACT) → PoT (走 ACT→PoT 路徑)
    //   MT_Q/K/V (from mult, bypass ACT) → PoT 直接
    //   (MT_SCORE 已不走 ACT，直接從 mult 寫 score_mem——見區塊 11)
    // ========================================================================
    assign use_act_for_pot = act_valid &&
                             ((act_tag_cs[4] == MT_NORM) || (act_tag_cs[4] == MT_FINAL));

    // lane0：ACT 輸出 (NORM/FINAL) 或 engine0 的 Q（K/V 改走 lane1/2）。
    assign pot_in_valid = use_act_for_pot ||
                          (mult_valid && (mult_tag_out == MT_Q));
    assign pot_in_data  = use_act_for_pot ? act_data       : mult_data;
    assign pot_in_idx   = use_act_for_pot ? act_idx_cs[4]  : mult_idx_out;
    assign pot_in_tag   = use_act_for_pot ? act_tag_cs[4]  : mult_tag_out;

    // lane1 (K) / lane2 (V)：直接 bypass engine1/2 輸出（tag 恆 K/V）。
    assign pot_k_in_valid = mult_k_valid;
    assign pot_v_in_valid = mult_v_valid;
    assign pot_v_in_idx   = mult_v_idx;

    assign qk_stream_valid = pot_valid &&
                             pot_k_valid &&
                             (pot_tag_cs[4] == MT_Q);

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
        .q_stream_valid (qk_stream_valid),
        .q_stream_idx   (pot_idx_cs[4]),
        .q_stream_data  (pot_data),
        .k_stream_data  (pot_k_data),
        .v_mem        (v_mem),
        .score_mem    (score_mem),
        .mult_valid   (mult_valid),
        .mult_data    (mult_data),
        .mult_tag_out (mult_tag_out),
        .mult_idx_out (mult_idx_out),
        .mult_k_valid (mult_k_valid),
        .mult_k_data  (mult_k_data),
        .mult_k_idx   (mult_k_idx),
        .mult_v_valid (mult_v_valid),
        .mult_v_data  (mult_v_data),
        .mult_v_idx   (mult_v_idx),
        .mult_k_score_valid (mult_k_score_valid),
        .sv0_score_valid (sv0_score_valid),
        .sv0_score_data  (sv0_score_data),
        .sv0_score_idx   (sv0_score_idx),
        .sv1_score_valid (sv1_score_valid),
        .sv1_score_data  (sv1_score_data),
        .sv1_score_idx   (sv1_score_idx)
    );

    ACT_5Stage_Parallel u_act (
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

    // lane1 (K) / lane2 (V)：QKV 並行三路的後兩路。輸入直接拿 mult engine1/2。
    PoT_5Stage_Parallel u_pot_k (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_k_in_valid),
        .in_data   (mult_k_data),
        .out_valid (pot_k_valid),
        .out_data  (pot_k_data)
    );

    PoT_5Stage_Parallel u_pot_v (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_v_in_valid),
        .in_data   (mult_v_data),
        .out_valid (pot_v_valid),
        .out_data  (pot_v_data)
    );

    // ========================================================================
    // 區塊 11：所有狀態更新 (always_ff)
    //   1. Issue 入口 buffer
    //   2. Sideband pipeline (act_*_cs / pot_*_cs)
    //   3. Memory writes (q/k/v/score)
    //   4. Output buffer (wr_data / out_valid / out_data)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // (1) issue buffer
            issue_valid_cs   <= 1'b0;
            issue_mode_cs    <= IM_NONE;
            issue_idx_cs     <= 6'd0;
            rd_data_cs       <= '0;

            // (2) sideband
            for (int i = 0; i < 5; i++) begin
                act_tag_cs[i] <= MT_NONE;
                act_idx_cs[i] <= 6'd0;
            end
            for (int i = 0; i < 5; i++) begin
                pot_tag_cs[i] <= MT_NONE;
                pot_idx_cs[i] <= 6'd0;
            end
            for (int i = 0; i < 5; i++) begin
                pot_v_idx_cs[i] <= 6'd0;
            end

            // (4) output buffer
            out_valid <= 1'b0;
            out_data  <= 32'd0;
        end
        else begin
            // ---------------- (1) Issue buffer ------------------------------
            issue_valid_cs   <= issue_valid;
            issue_mode_cs    <= issue_valid ? issue_mode : IM_NONE;
            issue_idx_cs     <= issue_valid ? issue_idx  : 6'd0;
            rd_data_cs       <= rd_data;

            // ---------------- (2) Sideband pipeline -------------------------
            // ACT path: 5 級 (input buf + pair + psum + thr + apply)
            act_tag_cs[0] <= act_in_valid ? act_in_tag : MT_NONE;
            act_idx_cs[0] <= act_in_idx;
            for (int i = 1; i < 5; i++) begin
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

            // K/V lane idx sideband（對齊 PoT 5-stage）
            pot_v_idx_cs[0] <= pot_v_in_idx;
            for (int i = 1; i < 5; i++) begin
                pot_v_idx_cs[i] <= pot_v_idx_cs[i - 1];
            end

            // ---------------- (3) Memory writes -----------------------------
            // score_mem ← Mult (MT_SCORE) — attention activation 內嵌於 pack_attention_score
            // 省掉 ACT pipeline 4 cycles（SCORE 是 SV→FINAL 的 critical path）。
            if (mult_valid && (mult_tag_out == MT_SCORE)) begin
                score_mem[mult_idx_out]      <= pack_attention_score(mult_data);
            end
            // engine1 平行 score（SV head1/奇數 matrix）→ 與 engine0 同拍寫不同 slot
            if (mult_k_score_valid) begin
                score_mem[mult_k_idx]      <= pack_attention_score(mult_k_data);
            end
            if (sv0_score_valid) begin
                score_mem[sv0_score_idx] <= pack_attention_score(sv0_score_data);
            end
            if (sv1_score_valid) begin
                score_mem[sv1_score_idx] <= pack_attention_score(sv1_score_data);
            end

            // Q/K stream directly into score computation; only V is retained
            // for FINAL score*V.
            if (pot_v_valid) begin
                v_mem[pot_v_idx_cs[4][4:0]]      <= pot_v_data;
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
    input  logic [5:0]     issue_idx,

    input  logic [1:0]     op,
    input  logic [255:0]   param,
    input  logic [255:0]   weight_k,
    input  logic [255:0]   weight_v,
    input  logic [255:0]   rd_data,

    input  logic           q_stream_valid,
    input  logic [5:0]     q_stream_idx,
    input  logic [255:0]   q_stream_data,
    input  logic [255:0]   k_stream_data,

    input  logic [255:0]   v_mem       [0:31],
    input  logic [767:0]   score_mem   [0:63], // 12-bit signed-digit {d0,d1,d2} × 64 lanes

    // engine0：QKV 的 Q / SCORE / FINAL / NORM（保留全部原機制，含 nibble 累加）
    output logic           mult_valid,
    output logic [1023:0]  mult_data,
    output mult_tag_t      mult_tag_out,
    output logic [5:0]     mult_idx_out,
    // engine1 / engine2：QKV 並行的 K / V（純 matmul，bypass ACT/nibble）。
    //   tag 恆為 MT_K / MT_V，所以只輸出 valid/data/idx。latency 與 engine0 對齊
    //   (mult 5 stage + output reg 1 = 6)，故 Q/K/V 同拍抵達下游 3 路 PoT。
    output logic           mult_k_valid,
    output logic [1023:0]  mult_k_data,
    output logic [5:0]     mult_k_idx,
    output logic           mult_v_valid,
    output logic [1023:0]  mult_v_data,
    output logic [5:0]     mult_v_idx,
    // SV 階段 engine1 平行算 head1(MHA) / 奇數 matrix(SHA) 的 score：
    //   結果走 mult_k_data/mult_k_idx，但用此 valid 通知 DataPath 寫 score_mem
    //   （而非 QKV 的 PoT 路徑）。engine0 的 head0/偶數 score 仍走 MT_SCORE。
    output logic           mult_k_score_valid,
    output logic           sv0_score_valid,
    output logic [1023:0]  sv0_score_data,
    output logic [5:0]     sv0_score_idx,
    output logic           sv1_score_valid,
    output logic [1023:0]  sv1_score_data,
    output logic [5:0]     sv1_score_idx
);

    // Matches Mult internal pipeline depth
    //   (input buf + operand + prod + partial + sum = 5 stages，
    //    operand reg 把 op-MUX 從 multiplier 的 input cone 移走)。
    localparam int MULT_STAGES = 5;

    logic          mult_issue_valid;
    logic          mult_issue_b_transpose;
    logic [255:0]  mult_issue_A;           // signed 4-bit packed A for the multiplier
    logic [255:0]  mult_issue_B;
    mult_tag_t     mult_issue_tag;
    logic [5:0]    mult_issue_idx;

    // engine1 / engine2 issue operands（QKV 的 K/V、FINAL 的 d1/d2、或 SV 的 head1 score）。
    logic          mult_k_issue_valid;
    logic [255:0]  mult_k_issue_A;
    logic [255:0]  mult_k_issue_B;
    logic          mult_k_issue_btr;  // engine1 b_transpose（SV head1 score = 1）
    logic          mult_v_issue_valid;
    logic [255:0]  mult_v_issue_A;
    logic [255:0]  mult_v_issue_B;
    logic [5:0]    mult_kv_issue_idx;
    logic          mult_kv_is_qkv;    // 1 = QKV(K/V→PoT)
    logic          mult_kv_is_score;  // 1 = SV head1/奇數 score(engine1→score_mem)

    logic          aux0_issue_valid;
    logic          aux0_issue_btr;
    logic [255:0]  aux0_issue_A;
    logic [255:0]  aux0_issue_B;
    logic [5:0]    aux0_issue_idx;
    logic          aux0_issue_score;

    logic          aux1_issue_valid;
    logic          aux1_issue_btr;
    logic [255:0]  aux1_issue_A;
    logic [255:0]  aux1_issue_B;
    logic [5:0]    aux1_issue_idx;
    logic          aux1_issue_score;

    logic          aux2_issue_valid;
    logic [255:0]  aux2_issue_A;
    logic [255:0]  aux2_issue_B;

    mult_tag_t  mult_tag_cs    [0:MULT_STAGES-1];
    logic [5:0] mult_idx_cs    [0:MULT_STAGES-1];

    // engine1/2 用途 pipeline（跟 idx 一起傳，stage4 用來 gate 下游）：
    //   role_cs  : 1 = QKV(K/V→PoT)，0 = FINAL(d1/d2 internal) 或 SV(由 score_cs 區分)
    //   score_cs : 1 = SV engine1 score(→score_mem)
    logic       mult_kv_role_cs  [0:MULT_STAGES-1];
    logic       mult_kv_score_cs [0:MULT_STAGES-1];
    logic [5:0] aux0_idx_cs      [0:MULT_STAGES-1];
    logic [5:0] aux1_idx_cs      [0:MULT_STAGES-1];
    logic       aux0_score_cs    [0:MULT_STAGES-1];
    logic       aux1_score_cs    [0:MULT_STAGES-1];

    // FINAL counters：head(outer) > mat(inner)。3 路並行做 d0/d1/d2，無 nibble 維度。
    //   SHA: 32 mat = 32 phase；MHA: 2 head × 32 mat = 64 phase。
    logic [4:0] fin_mat_cs;    // matrix within group 0..31 (inner)
    logic       fin_head_cs;   // MHA head 0/1 (outer; SHA stays 0)

    // Extract one phase's signed-digit vector as 4-bit packed A.
    //
    // score_mem 已於寫入時 (pack_attention_score) 預先算好 base-16 signed-digit，
    // 每 lane 存 {d0[11:8], d1[7:4], d2[3:0]}（各 s4）。讀取端只做 phase 切片，
    // 不再有進位加法 —— 原本掛在 issue→in_data_A 的 XOR carry 移除。
    function automatic logic [255:0] extract_score_nibble_s4(
        input logic [767:0] src,
        input logic [1:0]   phase
    );
        logic [11:0] ld;
        logic [3:0]  d;
        begin
            for (int s = 0; s < 64; s++) begin
                ld = src[767 - (s * 12) -: 12];
                case (phase)
                    2'd0:    d = ld[11:8];   // d0
                    2'd1:    d = ld[7:4];    // d1
                    default: d = ld[3:0];    // d2
                endcase
                extract_score_nibble_s4[255 - (s * 4) -: 4] = d;
            end
        end
    endfunction

    // FINAL 的 score_mem 索引（engine0 d0 與 engine1/2 d1/d2 共用）。
    function automatic logic [255:0] mask_mha_head0(input logic [255:0] src);
        begin
            mask_mha_head0 = src;
            for (int r = 0; r < 8; r++) begin
                mask_mha_head0[239 - 32*r -: 16] = 16'd0;
            end
        end
    endfunction

    function automatic logic [255:0] mask_mha_head1(input logic [255:0] src);
        begin
            mask_mha_head1 = src;
            for (int r = 0; r < 8; r++) begin
                mask_mha_head1[255 - 32*r -: 16] = 16'd0;
            end
        end
    endfunction

    function automatic logic [1023:0] combine_mha_heads_full(
        input logic [1023:0] head0,
        input logic [1023:0] head1
    );
        begin
            combine_mha_heads_full = 1024'd0;
            for (int r = 0; r < 8; r++) begin
                combine_mha_heads_full[1023 -  r*128       -: 64] =
                    head0[1023 -  r*128       -: 64];
                combine_mha_heads_full[1023 - (r*128 + 64) -: 64] =
                    head1[1023 - (r*128 + 64) -: 64];
            end
        end
    endfunction

    logic [5:0] fin_score_idx;
    assign fin_score_idx = (op == 2'b11) ? {fin_head_cs, fin_mat_cs}
                                         : {1'b0, fin_mat_cs};

    always_comb begin
        mult_issue_valid       = 1'b0;
        mult_issue_b_transpose = 1'b0;
        mult_issue_A           = 256'd0;
        mult_issue_B           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_idx         = 6'd0;

        if (issue_valid) begin
            mult_issue_valid = 1'b1;

            case (issue_mode)
                IM_NORM: begin
                    mult_issue_A   = rd_data;
                    mult_issue_B   = param;
                    mult_issue_tag = MT_NORM;
                end

                IM_QKV: begin
                    // 3 路並行：32 phase = 32 matrix。engine0 算 Q，engine1/2 算 K/V
                    // （見下方 mult_kv_issue_*）。同 x、3 個權重 → Q/K/V 同拍出。
                    mult_issue_idx = {1'b0, issue_idx[4:0]};
                    mult_issue_A   = rd_data;
                    mult_issue_B   = param;       // W_Q
                    mult_issue_tag = MT_Q;
                end

                IM_SV: begin
                    // 2-way SV：engine0 算 head0(MHA) / 偶數 matrix(SHA) 的 score，
                    //   engine1 同 phase 算 head1 / 奇數 matrix（見下方 mult_kv_issue）。
                    //   phase 數因此 MHA 64→32、SHA 32→16。
                    //   head_mask：每 row 32-bit，high16=tap0..3、low16=tap4..7。
                    if (op == 2'b11) begin
                        // MHA：phase = matrix；engine0 = head0（保留 tap0..3，清 low16）
                        mult_issue_A   = 256'd0;
                        mult_issue_B   = 256'd0;
                        for (int r = 0; r < 8; r++) begin
                            mult_issue_A[239 - 32*r -: 16] = 16'd0;
                            mult_issue_B[239 - 32*r -: 16] = 16'd0;
                        end
                        mult_issue_idx = {1'b0, issue_idx[4:0]};      // score_mem[matrix]
                    end
                    else begin
                        // SHA：engine0 = 偶數 matrix 2·phase（無 head split）
                        mult_issue_A   = 256'd0;
                        mult_issue_B   = 256'd0;
                        mult_issue_idx = {issue_idx[3:0], 1'b0};      // score_mem[2·phase]
                    end
                    mult_issue_b_transpose = 1'b1;
                    mult_issue_tag         = MT_SCORE;
                    mult_issue_valid       = 1'b0;
                end

                IM_FINAL: begin
                    // engine0 = nibble d0；engine1/2 = d1/d2（見下方 mult_kv issue）。
                    // 3 路同 phase 算 score×V 的三個 base-16 digit，輸出端一拍重組
                    //   result = P0 + (P1<<4) + (P2<<8)（= 原 3-pass nibble 累加）。
                    mult_issue_idx = fin_score_idx;
                    mult_issue_A   = extract_score_nibble_s4(
                                         score_mem[fin_score_idx], 2'd0);  // d0
                    mult_issue_B   = v_mem[fin_mat_cs];
                    // No head_mask in FINAL: MHA does a full 8-tap score×V dot;
                    // the per-head column split happens later in 6-way combine.
                    mult_issue_tag = MT_FINAL;
                end

                default: begin
                    mult_issue_valid = 1'b0;
                end
            endcase
        end
    end

    // engine1 / engine2 operand：
    //   QKV  → engine1=K, engine2=V（downstream→PoT，is_qkv=1）
    //   SV   → engine1=head1/奇數 score（downstream→score_mem，is_score=1）；engine2 閒置
    //   FINAL→ engine1=d1, engine2=d2（internal→engine0 輸出端重組，gate off）
    always_comb begin
        mult_k_issue_valid = 1'b0;
        mult_v_issue_valid = 1'b0;
        mult_k_issue_A     = 256'd0;
        mult_k_issue_B     = 256'd0;
        mult_k_issue_btr   = 1'b0;
        mult_v_issue_A     = 256'd0;
        mult_v_issue_B     = 256'd0;
        mult_kv_issue_idx  = {1'b0, issue_idx[4:0]};
        mult_kv_is_qkv     = 1'b0;
        mult_kv_is_score   = 1'b0;

        if (issue_valid) begin
            case (issue_mode)
                IM_QKV: begin
                    mult_k_issue_valid = 1'b1;
                    mult_v_issue_valid = 1'b1;
                    mult_k_issue_A     = rd_data;
                    mult_k_issue_B     = weight_k;
                    mult_v_issue_A     = rd_data;
                    mult_v_issue_B     = weight_v;
                    mult_kv_issue_idx  = {1'b0, issue_idx[4:0]};
                    mult_kv_is_qkv     = 1'b1;
                end
                IM_SV: begin
                    // 2-way SV：engine1 與 engine0 同 phase，算另一半 score。
                    //   b_transpose=1（Q×K^T）；結果→score_mem（is_score=1）。engine2 閒置。
                    mult_k_issue_valid = 1'b1;
                    mult_k_issue_btr   = 1'b1;
                    mult_kv_is_score   = 1'b1;
                    if (op == 2'b11) begin
                        // MHA：同 matrix，engine1 = head1（保留 tap4..7，清 high16）
                        mult_k_issue_A = 256'd0;
                        mult_k_issue_B = 256'd0;
                        for (int r = 0; r < 8; r++) begin
                            mult_k_issue_A[255 - 32*r -: 16] = 16'd0;
                            mult_k_issue_B[255 - 32*r -: 16] = 16'd0;
                        end
                        mult_kv_issue_idx = {1'b1, issue_idx[4:0]};   // score_mem[32+matrix]
                    end
                    else begin
                        // SHA：engine1 = 奇數 matrix 2·phase+1（無 head split）
                        mult_k_issue_A    = 256'd0;
                        mult_k_issue_B    = 256'd0;
                        mult_kv_issue_idx = {issue_idx[3:0], 1'b1};   // score_mem[2·phase+1]
                    end
                    mult_k_issue_valid = 1'b0;
                    mult_kv_is_score   = 1'b0;
                end
                IM_FINAL: begin
                    mult_k_issue_valid = 1'b1;
                    mult_v_issue_valid = 1'b1;
                    mult_k_issue_A     = extract_score_nibble_s4(
                                             score_mem[fin_score_idx], 2'd1);  // d1
                    mult_k_issue_B     = v_mem[fin_mat_cs];
                    mult_v_issue_A     = extract_score_nibble_s4(
                                             score_mem[fin_score_idx], 2'd2);  // d2
                    mult_v_issue_B     = v_mem[fin_mat_cs];
                    mult_kv_is_qkv     = 1'b0;  // internal partial, gated off downstream
                end
                default: begin end
            endcase
        end
    end

    always_comb begin
        aux0_issue_valid = 1'b0;
        aux0_issue_btr   = 1'b0;
        aux0_issue_A     = 256'd0;
        aux0_issue_B     = 256'd0;
        aux0_issue_idx   = 6'd0;
        aux0_issue_score = 1'b0;

        aux1_issue_valid = 1'b0;
        aux1_issue_btr   = 1'b0;
        aux1_issue_A     = 256'd0;
        aux1_issue_B     = 256'd0;
        aux1_issue_idx   = 6'd0;
        aux1_issue_score = 1'b0;

        aux2_issue_valid = 1'b0;
        aux2_issue_A     = 256'd0;
        aux2_issue_B     = 256'd0;

        if (issue_valid && (issue_mode == IM_FINAL) && (op == 2'b11)) begin
            aux0_issue_valid = 1'b1;
            aux1_issue_valid = 1'b1;
            aux2_issue_valid = 1'b1;
            aux0_issue_A     = extract_score_nibble_s4(
                                   score_mem[{1'b1, fin_mat_cs}], 2'd0);
            aux0_issue_B     = v_mem[fin_mat_cs];
            aux1_issue_A     = extract_score_nibble_s4(
                                   score_mem[{1'b1, fin_mat_cs}], 2'd1);
            aux1_issue_B     = v_mem[fin_mat_cs];
            aux2_issue_A     = extract_score_nibble_s4(
                                   score_mem[{1'b1, fin_mat_cs}], 2'd2);
            aux2_issue_B     = v_mem[fin_mat_cs];
        end
        else if (q_stream_valid) begin
            aux0_issue_valid = 1'b1;
            aux0_issue_btr   = 1'b1;
            aux0_issue_A     = (op == 2'b11) ? mask_mha_head0(q_stream_data)
                                             : q_stream_data;
            aux0_issue_B     = (op == 2'b11) ? mask_mha_head0(k_stream_data)
                                             : k_stream_data;
            aux0_issue_idx   = {1'b0, q_stream_idx[4:0]};
            aux0_issue_score = 1'b1;

            if (op == 2'b11) begin
                aux1_issue_valid = 1'b1;
                aux1_issue_btr   = 1'b1;
                aux1_issue_A     = mask_mha_head1(q_stream_data);
                aux1_issue_B     = mask_mha_head1(k_stream_data);
                aux1_issue_idx   = {1'b1, q_stream_idx[4:0]};
                aux1_issue_score = 1'b1;
            end
        end
    end

    // ---- FINAL matrix counter ----
    //   SHA uses the original three engines for one matrix per phase.
    //   MHA uses all six engines: head0 d0/d1/d2 and head1 d0/d1/d2 in the
    //   same matrix phase, then combines the heads before ACT.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fin_mat_cs  <= 3'd0;
            fin_head_cs <= 1'b0;
        end
        else if (issue_valid) begin
            if (issue_mode == IM_FINAL) begin
                if (fin_mat_cs == 5'd31) begin
                    fin_mat_cs  <= 5'd0;
                    fin_head_cs <= fin_head_cs + 1'b1; // MHA: head0→head1
                end else begin
                    fin_mat_cs <= fin_mat_cs + 1'b1;
                end
            end else begin
                // Reset at start of any non-FINAL issue (QKV / SV)
                fin_mat_cs  <= 5'd0;
                fin_head_cs <= 1'b0;
            end
        end
    end

    // Raw multiplier outputs (before nibble accumulation)
    logic          mult_raw_valid;
    logic [1023:0] mult_raw_data;

    Mult_5Stage_Parallel u_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (mult_issue_b_transpose),
        .in_valid    (mult_issue_valid),
        .in_data_A   (mult_issue_A),
        .in_data_B   (mult_issue_B),
        .out_valid   (mult_raw_valid),
        .out_data    (mult_raw_data)
    );

    // engine1：QKV 算 K、SV 算 head1/奇數 score（transpose）、FINAL 算 d1。
    // engine2：QKV 算 V、FINAL 算 d2。無 transpose。
    logic          mult_k_raw_valid;
    logic [1023:0] mult_k_raw_data;
    logic          mult_v_raw_valid;
    logic [1023:0] mult_v_raw_data;
    logic          aux0_raw_valid;
    logic [1023:0] aux0_raw_data;
    logic          aux1_raw_valid;
    logic [1023:0] aux1_raw_data;
    logic          aux2_raw_valid;
    logic [1023:0] aux2_raw_data;
    logic [5:0]    mult_k_idx_cs [0:MULT_STAGES-1];
    logic [5:0]    mult_v_idx_cs [0:MULT_STAGES-1];

    Mult_5Stage_Parallel u_mult_k (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (mult_k_issue_btr),
        .in_valid    (mult_k_issue_valid),
        .in_data_A   (mult_k_issue_A),
        .in_data_B   (mult_k_issue_B),
        .out_valid   (mult_k_raw_valid),
        .out_data    (mult_k_raw_data)
    );

    Mult_5Stage_Parallel u_mult_v (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (1'b0),
        .in_valid    (mult_v_issue_valid),
        .in_data_A   (mult_v_issue_A),
        .in_data_B   (mult_v_issue_B),
        .out_valid   (mult_v_raw_valid),
        .out_data    (mult_v_raw_data)
    );

    Mult_5Stage_Parallel u_mult_aux0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (aux0_issue_btr),
        .in_valid    (aux0_issue_valid),
        .in_data_A   (aux0_issue_A),
        .in_data_B   (aux0_issue_B),
        .out_valid   (aux0_raw_valid),
        .out_data    (aux0_raw_data)
    );

    Mult_5Stage_Parallel u_mult_aux1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (aux1_issue_btr),
        .in_valid    (aux1_issue_valid),
        .in_data_A   (aux1_issue_A),
        .in_data_B   (aux1_issue_B),
        .out_valid   (aux1_raw_valid),
        .out_data    (aux1_raw_data)
    );

    Mult_5Stage_Parallel u_mult_aux2 (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (1'b0),
        .in_valid    (aux2_issue_valid),
        .in_data_A   (aux2_issue_A),
        .in_data_B   (aux2_issue_B),
        .out_valid   (aux2_raw_valid),
        .out_data    (aux2_raw_data)
    );

    // K/V idx + role + score pipeline（對齊 mult 5-stage）。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MULT_STAGES; i++) begin
                mult_k_idx_cs[i]    <= 6'd0;
                mult_v_idx_cs[i]    <= 6'd0;
                mult_kv_role_cs[i]  <= 1'b0;
                mult_kv_score_cs[i] <= 1'b0;
                aux0_idx_cs[i]      <= 6'd0;
                aux1_idx_cs[i]      <= 6'd0;
                aux0_score_cs[i]    <= 1'b0;
                aux1_score_cs[i]    <= 1'b0;
            end
        end
        else begin
            mult_k_idx_cs[0]    <= mult_kv_issue_idx;
            mult_v_idx_cs[0]    <= mult_kv_issue_idx;
            mult_kv_role_cs[0]  <= mult_kv_is_qkv;
            mult_kv_score_cs[0] <= mult_kv_is_score;
            aux0_idx_cs[0]      <= aux0_issue_idx;
            aux1_idx_cs[0]      <= aux1_issue_idx;
            aux0_score_cs[0]    <= aux0_issue_score;
            aux1_score_cs[0]    <= aux1_issue_score;
            for (int i = 1; i < MULT_STAGES; i++) begin
                mult_k_idx_cs[i]    <= mult_k_idx_cs[i - 1];
                mult_v_idx_cs[i]    <= mult_v_idx_cs[i - 1];
                mult_kv_role_cs[i]  <= mult_kv_role_cs[i - 1];
                mult_kv_score_cs[i] <= mult_kv_score_cs[i - 1];
                aux0_idx_cs[i]      <= aux0_idx_cs[i - 1];
                aux1_idx_cs[i]      <= aux1_idx_cs[i - 1];
                aux0_score_cs[i]    <= aux0_score_cs[i - 1];
                aux1_score_cs[i]    <= aux1_score_cs[i - 1];
            end
        end
    end

    // Tag / idx pipeline (mirrors Mult internal pipeline depth)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MULT_STAGES; i++) begin
                mult_tag_cs[i] <= MT_NONE;
                mult_idx_cs[i] <= 6'd0;
            end
        end
        else begin
            mult_tag_cs[0] <= mult_issue_valid ? mult_issue_tag : MT_NONE;
            mult_idx_cs[0] <= mult_issue_idx;
            for (int i = 1; i < MULT_STAGES; i++) begin
                mult_tag_cs[i] <= mult_tag_cs[i - 1];
                mult_idx_cs[i] <= mult_idx_cs[i - 1];
            end
        end
    end

    // ---- FINAL nibble 一拍重組（取代舊 3-pass nibb_acc）---------------------
    // 3 路引擎同 phase 算出 score 的 3 個 base-16 digit × V：
    //   engine0 = d0×V (P0)、engine1 = d1×V (P1)、engine2 = d2×V (P2)
    // 重組 result = P0 + (P1<<4) + (P2<<8)（per-lane 16-bit 截斷，與舊
    // lane_shift_add 同語義；score = d0 + 16·d1 + 256·d2 → score×V 等值）。
    logic [1023:0] nibb_combine;
    logic [1023:0] nibb_combine_h1;
    always_comb begin
        nibb_combine = 1024'd0;
        nibb_combine_h1 = 1024'd0;
        for (int i = 0; i < 64; i++) begin
            logic signed [15:0] p0;
            logic signed [15:0] p1;
            logic signed [15:0] p2;
            logic signed [15:0] h1_p0;
            logic signed [15:0] h1_p1;
            logic signed [15:0] h1_p2;
            p0 = mult_raw_data  [1023 - (i * 16) -: 16];
            p1 = mult_k_raw_data[1023 - (i * 16) -: 16];
            p2 = mult_v_raw_data[1023 - (i * 16) -: 16];
            h1_p0 = aux0_raw_data[1023 - (i * 16) -: 16];
            h1_p1 = aux1_raw_data[1023 - (i * 16) -: 16];
            h1_p2 = aux2_raw_data[1023 - (i * 16) -: 16];
            nibb_combine[1023 - (i * 16) -: 16] = p0 + (p1 <<< 4) + (p2 <<< 8);
            nibb_combine_h1[1023 - (i * 16) -: 16] =
                h1_p0 + (h1_p1 <<< 4) + (h1_p2 <<< 8);
        end
    end

    // 內部 combinational 版本（FINAL：選 nibb_combine；其餘：raw_data 直通）
    logic          mult_valid_comb;
    logic [1023:0] mult_data_comb;
    mult_tag_t     mult_tag_comb;
    logic [5:0]    mult_idx_comb;
    logic          mha_final_comb;

    // 每個 issue 都產生一個結果（FINAL 不再有 nibble 累加的 0/1 phase）。
    assign mult_valid_comb = mult_raw_valid;
    assign mha_final_comb  = (mult_tag_cs[MULT_STAGES-1] == MT_FINAL) &&
                             (op == 2'b11);
    assign mult_data_comb  = (mult_tag_cs[MULT_STAGES-1] == MT_FINAL) ?
                              (mha_final_comb ?
                               combine_mha_heads_full(nibb_combine, nibb_combine_h1) :
                               nibb_combine) :
                              mult_raw_data;
    assign mult_tag_comb   = mult_tag_cs[MULT_STAGES-1];
    assign mult_idx_comb   = mha_final_comb ? {1'b0, mult_idx_cs[MULT_STAGES-1][4:0]} :
                                             mult_idx_cs[MULT_STAGES-1];

    // 輸出 register：把 FINAL MUX cone 跟下游 ACT/PoT 的 abs/MUX cone 切到兩個
    // cycle，clk 從原本的 ~3 ns 邊界繼續往下推。+1 cycle latency。
    // engine1/2（K/V）共用同一拍 output reg，與 engine0 latency 對齊（6 cycle）。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_valid         <= 1'b0;
            mult_tag_out       <= MT_NONE;
            mult_idx_out       <= 6'd0;
            mult_k_valid       <= 1'b0;
            mult_k_idx         <= 6'd0;
            mult_k_score_valid <= 1'b0;
            mult_v_valid       <= 1'b0;
            mult_v_idx         <= 6'd0;
            sv0_score_valid    <= 1'b0;
            sv0_score_idx      <= 6'd0;
            sv1_score_valid    <= 1'b0;
            sv1_score_idx      <= 6'd0;
        end
        else begin
            mult_valid   <= mult_valid_comb;
            mult_data    <= mult_data_comb;
            mult_tag_out <= mult_tag_comb;
            mult_idx_out <= mult_idx_comb;

            // engine1 K/V valid 只在 QKV（role=1）→ PoT；FINAL 的 d1/d2 partial
            // 由 nibb_combine 內部消化、SV 的 score 走 score path，皆不可送 PoT。
            mult_k_valid       <= mult_k_raw_valid && mult_kv_role_cs[MULT_STAGES-1];
            mult_k_data        <= mult_k_raw_data;
            mult_k_idx         <= mult_k_idx_cs[MULT_STAGES-1];
            // SV head1/奇數 score → DataPath 寫 score_mem（用 mult_k_data/mult_k_idx）。
            mult_k_score_valid <= mult_k_raw_valid && mult_kv_score_cs[MULT_STAGES-1];
            mult_v_valid       <= mult_v_raw_valid && mult_kv_role_cs[MULT_STAGES-1];
            mult_v_data        <= mult_v_raw_data;
            mult_v_idx         <= mult_v_idx_cs[MULT_STAGES-1];
            sv0_score_valid    <= aux0_raw_valid && aux0_score_cs[MULT_STAGES-1];
            sv0_score_data     <= aux0_raw_data;
            sv0_score_idx      <= aux0_idx_cs[MULT_STAGES-1];
            sv1_score_valid    <= aux1_raw_valid && aux1_score_cs[MULT_STAGES-1];
            sv1_score_data     <= aux1_raw_data;
            sv1_score_idx      <= aux1_idx_cs[MULT_STAGES-1];
        end
    end

endmodule

module Mult_5Stage_Parallel (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [1:0]   op,
    input  logic         b_transpose,
    input  logic         in_valid,
    input  logic [255:0] in_data_A,   // signed 4-bit packed (s4 per lane)
    input  logic [255:0] in_data_B,
    output logic         out_valid,
    output logic [1023:0] out_data
);

    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int DOT_SIZE = 9;

    typedef logic signed [3:0]  s4_t;
    // 範圍分析: sel_a ∈ [-8, 7]（FINAL score 改用 signed-digit 也落在此區間）,
    //   sel_b ∈ [-8, 7] → product ∈ [-8×-8, ...] = [-56, 64]，落在 s8 [-128, 127] 內。
    //   A 從 s5 降到 s4：乘法器由 s5×s4 (5 PP rows) → s4×s4 (4 PP rows)，
    //   partial-product reduction 少一級，並省 operand_a 576 flops。
    typedef logic signed [7:0]  s8_t;   // product: s4 × s4 → s8 (max +64 fits)
    typedef logic signed [11:0] s12_t;  // partial sum: 5×s8 fits s12
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

    // Returns signed 4-bit A element.
    //   Conv:    padded 4-bit element (zero-pad out of range)
    //   tap==8:  zero (bias slot — non-Conv only;此分支對 Conv 不會命中)
    //   normal:  raw signed 4-bit；FINAL 為 signed-digit（皆 [-8,7]）
    function automatic s4_t sel_a(
        input logic [255:0] mat_A,
        input logic [1:0]   op_sel,
        input integer       row_idx,
        input integer       lane,
        input integer       tap
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
                sel_a = 4'sd0;
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
        input integer       lane,
        input integer       tap
    );
        begin
            if (op_sel == 2'b01)
                sel_b = get_s4(mat_B, tap);
            else if (tap == 8)
                sel_b = 4'sd0;
            else if (b_transpose_sel)
                sel_b = get_s4(mat_B, (lane * ROW_ELEM) + tap);
            else
                sel_b = get_s4(mat_B, (tap * ROW_ELEM) + lane);
        end
    endfunction

    // Stage 0: input buffer (operands + control)。Decouples upstream issue mux。
    // Stage 1: 576 個 (s4_a, s4_b) operand pair：op-dependent sel_a/sel_b 在這級 register，
    //          下一級的 prod_next cone 就跟 op 解耦了。
    // Stage 2: 576 partial products s4×s4 → s8 (max +64)。
    // Stage 3: split 9-input sum 5+4 → 2 partial sums (s12)，加法樹深度切半。
    // Stage 4: 2-input add → s16 sum。
    // (從 4-stage 變 5-stage：把 op[1:0] 從 multiplier 的 input cone 移出去，clk 大幅縮短。)
    logic         in_valid_cs;
    // op 在一個 job 內為常數（exec_op 已存在 Control），不需要 input register。
    logic         b_transpose_cs;
    logic [255:0] in_data_A_cs;
    logic [255:0] in_data_B_cs;

    logic stage1_valid_cs;
    logic stage2_valid_cs;
    logic stage3_valid_cs;
    logic stage4_valid_cs;
    s4_t  operand_a_cs [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t  operand_b_cs [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s8_t  prod_cs      [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s12_t partial_cs   [0:MAT_SIZE-1][0:1];
    s16_t sum_cs       [0:MAT_SIZE-1];

    s4_t  operand_a_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t  operand_b_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s8_t  prod_next      [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s12_t partial_next   [0:MAT_SIZE-1][0:1];
    s16_t sum_next       [0:MAT_SIZE-1];

    // Stage 1: op-dependent operand selection (Conv vs FFN/SHA/MHA 位址)
    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    operand_a_next[(row * ROW_ELEM) + lane][tap] =
                        sel_a(in_data_A_cs, op, row, lane, tap);
                    operand_b_next[(row * ROW_ELEM) + lane][tap] =
                        sel_b(in_data_B_cs, op, b_transpose_cs, lane, tap);
                end
            end
        end
    end

    // Stage 2: pure s4×s4 multiplier，input 已被 stage 1 register 隔開 op
    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            for (int t = 0; t < DOT_SIZE; t++) begin
                prod_next[i][t] = s8_t'(
                    $signed(operand_a_cs[i][t]) * $signed(operand_b_cs[i][t]));
            end
        end
    end

    // Stage 3: 5 + 4 partial sums (each in s12)
    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            partial_next[i][0] = s12_t'(prod_cs[i][0]) + s12_t'(prod_cs[i][1]) +
                                 s12_t'(prod_cs[i][2]) + s12_t'(prod_cs[i][3]) +
                                 s12_t'(prod_cs[i][4]);
            partial_next[i][1] = s12_t'(prod_cs[i][5]) + s12_t'(prod_cs[i][6]) +
                                 s12_t'(prod_cs[i][7]) + s12_t'(prod_cs[i][8]);
        end
    end

    // Stage 4: combine 2 partials → s16
    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_next[i] = s16_t'(partial_cs[i][0]) + s16_t'(partial_cs[i][1]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_cs     <= 1'b0;
            stage1_valid_cs <= 1'b0;
            stage2_valid_cs <= 1'b0;
            stage3_valid_cs <= 1'b0;
            stage4_valid_cs <= 1'b0;
        end
        else begin
            in_valid_cs     <= in_valid;
            b_transpose_cs  <= b_transpose;
            in_data_A_cs    <= in_data_A;
            in_data_B_cs    <= in_data_B;

            stage1_valid_cs <= in_valid_cs;
            stage2_valid_cs <= stage1_valid_cs;
            stage3_valid_cs <= stage2_valid_cs;
            stage4_valid_cs <= stage3_valid_cs;
            for (int i = 0; i < MAT_SIZE; i++)
                for (int t = 0; t < DOT_SIZE; t++) begin
                    operand_a_cs[i][t] <= operand_a_next[i][t];
                    operand_b_cs[i][t] <= operand_b_next[i][t];
                end
            for (int i = 0; i < MAT_SIZE; i++)
                for (int t = 0; t < DOT_SIZE; t++)
                    prod_cs[i][t] <= prod_next[i][t];
            for (int i = 0; i < MAT_SIZE; i++) begin
                partial_cs[i][0] <= partial_next[i][0];
                partial_cs[i][1] <= partial_next[i][1];
            end
            for (int i = 0; i < MAT_SIZE; i++)
                sum_cs[i] <= sum_next[i];
        end
    end

    assign out_valid = stage4_valid_cs;

    always_comb begin
        out_data = 1024'd0;
        for (int i = 0; i < MAT_SIZE; i++)
            out_data[1023 - (i * 16) -: 16] = sum_cs[i];
    end
endmodule

module ACT_5Stage_Parallel (
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
    localparam int ACT_STAGES = 4;  // pair → psum → threshold → apply

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;

    typedef logic signed [15:0] s16_t;
    typedef logic signed [16:0] s17_t;  // pair: s16+s16 → ±65K, fits s17
    typedef logic signed [17:0] s18_t;  // psum: 4×s16 → range ±131K, fits s18
    typedef logic signed [19:0] s20_t;  // 留給 stage-1 中間 (part_sum01/23, BAT 和)

    // Input buffer (decouples upstream dispatch mux from psum tree; ACT 從外面
    // 看是 4-stage：input_buf → psum → threshold → apply)。
    logic          in_valid_buf;
    logic [1:0]    act_buf;
    // Duplicated stage-0 selects reduce fanout from the ACT selector into the
    // pair-sum mux/add logic. Keep them separate so synthesis does not merge
    // the equivalent registers back into one high-fanout driver.
    (* dont_touch = "true" *) logic [1:0] act_chunk_buf [0:NUM_CHUNK-1];
    logic [1:0]    mode_buf;
    logic [1023:0] in_data_buf;

    logic          valid_cs  [0:ACT_STAGES-1];
    logic [1:0]    act_cs    [0:ACT_STAGES-1];
    logic [1:0]    mode_cs   [0:ACT_STAGES-1];
    logic [1023:0] matrix_cs [0:ACT_STAGES-1];

    // Pipeline stages (after input_buf)：
    //   Stage 0: pair sums per chunk×p×half = 16×2 (act-MUX + 1 add level，s17)
    //   Stage 1: psum_cs = pair_a + pair_b (1 add level，s18)。切半原本 stage-0 加法樹深度。
    //   Stage 2: thresholds from psum (RAT/CAT 2-input；BAT 4-input)
    //   Stage 3: apply activation
    s17_t          pair_a_cs [0:NUM_CHUNK-1][0:3];  // e0+e1
    s17_t          pair_b_cs [0:NUM_CHUNK-1][0:3];  // e2+e3
    s18_t          psum_cs   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_cs  [0:NUM_CHUNK-1];
    s16_t          thr_b_cs  [0:NUM_CHUNK-1];

    s17_t          pair_a_ns [0:NUM_CHUNK-1][0:3];
    s17_t          pair_b_ns [0:NUM_CHUNK-1][0:3];
    s18_t          psum_ns   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_ns  [0:NUM_CHUNK-1];
    s16_t          thr_b_ns  [0:NUM_CHUNK-1];
    logic [1023:0] apply_ns;

    s20_t          part_sum01;
    s20_t          part_sum23;

    assign out_valid = valid_cs[ACT_STAGES-1];
    assign out_data  = matrix_cs[ACT_STAGES-1];

    function automatic s16_t get_s16(input logic [1023:0] vec, input integer idx);
        get_s16 = $signed(vec[1023 - (idx * 16) -: 16]);
    endfunction

    function automatic s18_t ext18(input s16_t value);
        ext18 = {{2{value[15]}}, value};
    endfunction

    // Half pair sum：把原本 chunk_partial_sum 4-element 切成 2 個 2-element pair。
    //   half=0 → e0+e1；half=1 → e2+e3。stage 0 register 兩個 pair，stage 1 再合併。
    //   每個 pair 是 s16+s16 = s17，最後 s17+s17=s18 跟原 psum 同 range。
    function automatic s17_t chunk_half_sum(
        input logic [1023:0] matrix,
        input logic [1:0]    act_sel,
        input integer        chunk,
        input integer        p,
        input integer        half  // 0 = e0+e1, 1 = e2+e3
    );
        integer row;
        integer col;
        integer base_row;
        integer base_col;
        integer blk_row;
        s16_t   a;
        s16_t   b;
        begin
            a = 16'sd0;
            b = 16'sd0;

            case (act_sel)
                2'b01: begin  // RAT
                    row = (chunk * 2) + (p / 2);
                    col = (p % 2) * 4 + (half * 2);
                    a = get_s16(matrix, (row * ROW_ELEM) + col + 0);
                    b = get_s16(matrix, (row * ROW_ELEM) + col + 1);
                end

                2'b10: begin  // CAT
                    col = (chunk * 2) + (p / 2);
                    row = (p % 2) * 4 + (half * 2);
                    a = get_s16(matrix, ((row + 0) * ROW_ELEM) + col);
                    b = get_s16(matrix, ((row + 1) * ROW_ELEM) + col);
                end

                2'b11: begin  // BAT
                    base_row = (chunk / 2) * 4;
                    base_col = (chunk % 2) * 4;
                    blk_row  = base_row + p;
                    col      = base_col + (half * 2);
                    a = get_s16(matrix, (blk_row * ROW_ELEM) + col + 0);
                    b = get_s16(matrix, (blk_row * ROW_ELEM) + col + 1);
                end

                default: begin
                    a = 16'sd0;
                    b = 16'sd0;
                end
            endcase

            chunk_half_sum = s17_t'(a) + s17_t'(b);
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

    // Per-position threshold lookup（element-centric, 取代原 chunk_idx + select_threshold
    // 的 (chunk, lane)→pos cross-bar MUX）。對每個 output position pos：
    //   RAT/CAT/BAT 各對應一個固定的 thr_a[c] 或 thr_b[c]（compile-time）；
    //   再用 act_sel 做 3-way MUX。write addr 是常數 pos，不需 cross-bar。
    function automatic s16_t thr_for_position(
        input logic [1:0] act_sel,
        input integer     pos,
        input s16_t       thr_a [0:NUM_CHUNK-1],
        input s16_t       thr_b [0:NUM_CHUNK-1]
    );
        integer rat_chunk;
        integer cat_chunk;
        integer bat_chunk;
        s16_t   rat_thr;
        s16_t   cat_thr;
        s16_t   bat_thr;
        begin
            // RAT: pos = chunk*16 + lane; lane<8 → thr_a
            rat_chunk = pos / 16;
            rat_thr   = ((pos % 16) < ROW_ELEM) ? thr_a[rat_chunk] : thr_b[rat_chunk];

            // CAT: lane = (pos/8)*2 + pos%2; lane%2==0 ↔ pos%2==0 → thr_a
            cat_chunk = (pos % ROW_ELEM) / 2;
            cat_thr   = ((pos % 2) == 0) ? thr_a[cat_chunk] : thr_b[cat_chunk];

            // BAT: 4x4 block; chunk = (row/4)*2 + col/4, all elements use thr_a
            bat_chunk = ((pos / ROW_ELEM) / 4) * 2 + ((pos % ROW_ELEM) / 4);
            bat_thr   = thr_a[bat_chunk];

            case (act_sel)
                2'b01:   thr_for_position = rat_thr;
                2'b10:   thr_for_position = cat_thr;
                2'b11:   thr_for_position = bat_thr;
                default: thr_for_position = 16'sd0;
            endcase
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

    // Stage 0 combinational: 16 chunks×p pair sums (e0+e1, e2+e3) — act-MUX + 1 add level
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int p = 0; p < 4; p++) begin
                pair_a_ns[chunk][p] = chunk_half_sum(
                    in_data_buf, act_chunk_buf[chunk], chunk, p, 0);
                pair_b_ns[chunk][p] = chunk_half_sum(
                    in_data_buf, act_chunk_buf[chunk], chunk, p, 1);
            end
        end
    end

    // Stage 1 combinational: combine pair_a + pair_b → psum (1 add level)
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int p = 0; p < 4; p++) begin
                psum_ns[chunk][p] = s18_t'(pair_a_cs[chunk][p]) +
                                    s18_t'(pair_b_cs[chunk][p]);
            end
        end
    end

    // Stage 2 combinational: combine the registered partials into thresholds.
    // RAT/CAT keep two thresholds per chunk (one per row/col); BAT shares one.
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            part_sum01 = psum_cs[chunk][0] + psum_cs[chunk][1];
            part_sum23 = psum_cs[chunk][2] + psum_cs[chunk][3];
            case (act_cs[1])
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

    // Stage 3 combinational: apply activation per output position（element-centric）。
    // 每個 position 的 read/write 位址都是常數，act_sel 只在 threshold MUX 出現。
    // 比原 (chunk, lane)→apply_idx 的 cross-bar 寫入結構淺。
    always_comb begin
        for (int pos = 0; pos < MAT_SIZE; pos++) begin
            apply_ns[1023 - (pos * 16) -: 16] = activate_value(
                get_s16(matrix_cs[2], pos),
                act_cs[2],
                mode_cs[2],
                thr_for_position(act_cs[2], pos, thr_a_cs, thr_b_cs));
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
                act_chunk_buf[c] <= 2'd0;
                for (int p = 0; p < 4; p++) begin
                    pair_a_cs[c][p] <= 17'sd0;
                    pair_b_cs[c][p] <= 17'sd0;
                    psum_cs[c][p]   <= 18'sd0;
                end
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
            for (int c = 0; c < NUM_CHUNK; c++) begin
                act_chunk_buf[c] <= act;
            end

            // Stage 0: pair sums (act-MUX + 1 add level)，capture matrix。
            valid_cs[0]  <= in_valid_buf;
            act_cs[0]    <= act_buf;
            mode_cs[0]   <= mode_buf;
            matrix_cs[0] <= in_data_buf;
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) begin
                    pair_a_cs[c][p] <= pair_a_ns[c][p];
                    pair_b_cs[c][p] <= pair_b_ns[c][p];
                end
            end

            // Stage 1: pair_a + pair_b → psum (1 add level)，carry matrix。
            valid_cs[1]  <= valid_cs[0];
            act_cs[1]    <= act_cs[0];
            mode_cs[1]   <= mode_cs[0];
            matrix_cs[1] <= matrix_cs[0];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) psum_cs[c][p] <= psum_ns[c][p];
            end

            // Stage 2: combine partials into thresholds, carry the matrix.
            valid_cs[2]  <= valid_cs[1];
            act_cs[2]    <= act_cs[1];
            mode_cs[2]   <= mode_cs[1];
            matrix_cs[2] <= matrix_cs[1];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                thr_a_cs[c] <= thr_a_ns[c];
                thr_b_cs[c] <= thr_b_ns[c];
            end

            // Stage 3: apply activation.
            valid_cs[3]  <= valid_cs[2];
            act_cs[3]    <= act_cs[2];
            mode_cs[3]   <= mode_cs[2];
            matrix_cs[3] <= apply_ns;
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
    logic [3:0]    shift_from_max;  // Matrix_Max 已算好的 4-bit shift 量
    logic [1023:0] src_pipe_cs [0:2];
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
        .out_shift (shift_from_max)
    );

    // pot_shift 已在 Matrix_Max 內 1-cycle 算完，PoT 這裡只剩 quant_all。
    assign out_data_ns = quant_all(src_pipe_cs[2], shift_from_max);

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
    input  logic [1023:0] in_abs,    // 64 lanes unsigned abs（PoT 上游算好）
    output logic          out_valid,
    output logic [3:0]    out_shift  // PoT 所需的 arithmetic-shift 量（已算好）
);

    // PoT 只需要 max_abs 的 MSB 位置 → arithmetic-shift 量。
    //   max_abs 的 MSB == OR_reduction(abs[]) 的 MSB（max 是其中一員），
    //   所以 64-input bitwise OR 等價於 max 給 PoT。
    // Stage 1: 64-input bitwise OR (per bit 6-level OR tree ≈ 0.6 ns)
    // Stage 2: pot_shift priority-encode（從原本 PoT 端 1.26 ns critical path 搬到這）
    // Stage 3: shift 量 register 用來 fanout 給 PoT 的 quant_all（64 lanes）
    // 介面從 16-bit max 改成 4-bit shift：上游 1024-bit→16-bit→4-bit 還省 24 flops。
    localparam int MAT_SIZE = 64;

    logic        st1_valid;
    logic        st2_valid;
    logic [15:0] or_ns;
    logic [15:0] or_cs;
    logic [3:0]  shift_ns;
    logic [3:0]  shift_cs;

    function automatic logic [15:0] get_u16(input logic [1023:0] vec, input integer idx);
        get_u16 = vec[1023 - (idx * 16) -: 16];
    endfunction

    // pot_shift：找 max_abs 最高位的 set bit，回傳 (msb - LOG2_OUT_MAX) clamped 至 0。
    //   OUT_MAX = 7 → LOG2_OUT_MAX = 2，shift = max(msb - 2, 0)
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

    // Stage 1: 64-input bitwise OR
    always_comb begin
        or_ns = 16'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            or_ns = or_ns | get_u16(in_abs, i);
        end
    end

    // Stage 2: pot_shift on OR-reduced value
    assign shift_ns = pot_shift(or_cs);

    // valid pipeline (3 stages, 與原本一致)
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

    // data pipeline (3 stages：OR → shift → shift_register for fanout)
    always_ff @(posedge clk) begin
        if (in_valid)  or_cs     <= or_ns;
        if (st1_valid) shift_cs  <= shift_ns;
        if (st2_valid) out_shift <= shift_cs;
    end

endmodule
