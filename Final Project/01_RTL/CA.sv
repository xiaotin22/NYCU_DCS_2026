// clk=3.0 area = 11.2M
typedef enum logic [1:0] {
    IM_NONE = 2'd0,
    IM_NORM = 2'd1,
    IM_ATT  = 2'd2
} issue_mode_t;

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
    logic          datapath_result_pre_valid;
    logic          datapath_result_valid;

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
        .wr_ready               (wr_ready),
        .datapath_result_pre_valid (datapath_result_pre_valid),
        .datapath_result_valid  (datapath_result_valid),
        .exec_op                (exec_op),
        .exec_act               (exec_act),
        .exec_param             (exec_param),
        .exec_weight_k          (exec_weight_k),
        .exec_weight_v          (exec_weight_v),
        .datapath_issue_valid   (datapath_issue_valid),
        .datapath_issue_mode    (datapath_issue_mode),
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
        .op                     (exec_op),
        .act                    (exec_act),
        .param                  (exec_param),
        .weight_k               (exec_weight_k),
        .weight_v               (exec_weight_v),
        .rd_data                (rd_data),
        .wr_valid               (wr_valid),
        .result_pre_valid       (datapath_result_pre_valid),
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
    input  logic                            wr_ready,
    input  logic                            datapath_result_pre_valid,
    input  logic                            datapath_result_valid,

    output logic [1:0]                      exec_op,
    output logic [1:0]                      exec_act,
    output logic [255:0]                    exec_param,
    output logic [255:0]                    exec_weight_k,
    output logic [255:0]                    exec_weight_v,
    output logic                            datapath_issue_valid,
    output issue_mode_t                     datapath_issue_mode,

    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst
);

    localparam int ADDR_W = $clog2(RAM_DEPTH);
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;

    typedef enum logic [2:0] {
        S_IDLE,
        S_FAST_RUN,
        S_ATT_PARAM,
        S_ATT_READ,
        S_ATT_WAIT
    } state_t;

    state_t state_cs;

    // 讀取排程（FAST 與 ATT 各自獨立，性質不同故不合併）
    logic [1:0] fast_rd_req_cnt_cs;
    logic       att_param_phase_cs;
    logic       att_rd_issued_cs;
    logic [7:0] att_rd_word_cnt_cs;
    logic       att_read_half_cs;

    // 寫回 + 完成追蹤 — FAST 與 ATT 共用一套。
    //   兩者互斥（一個 job 不是 FAST 就是 ATT，中間必經 S_IDLE），且這段邏輯
    //   逐行相同，故塌成單一套，由 result_active 統一 gate。
    logic [6:0] pre_result_cnt_cs;
    logic       pre_write_half_cs;
    logic       wr_pending_cs;
    logic       pre_wr_issued_cs;
    logic [6:0] group_result_cnt_cs;
    logic       result_half_cs;

    logic job_start;
    logic fast_rd_req;
    logic [ADDR_W-1:0] fast_rd_addr;
    logic fast_rd_fire;
    logic att_first_rd_req;
    logic att_read_rd_req;
    logic att_half_rd_req;
    logic att_rd_req;
    logic [ADDR_W-1:0] att_rd_addr;
    logic att_rd_fire;
    logic att_rd_data_fire;
    logic result_active;
    logic first_pre_result;
    logic rd_cmd_req;
    logic [ADDR_W-1:0] rd_cmd_addr;
    logic rd_cmd_fire;
    logic wr_cmd_req;
    logic [ADDR_W-1:0] wr_cmd_addr;
    logic wr_cmd_fire;

    assign job_start          = (state_cs == S_IDLE) && mem_set && in_valid;
    assign fast_rd_req        = (job_start && !op[1]) ||
                                ((state_cs == S_FAST_RUN) &&
                                 (fast_rd_req_cnt_cs < 2'd2));
    assign fast_rd_addr       = ((state_cs == S_FAST_RUN) && fast_rd_req_cnt_cs[0]) ?
                                HALF_ADDR : '0;
    assign fast_rd_fire       = fast_rd_req && rd_ready;

    assign att_first_rd_req    = (state_cs == S_ATT_PARAM) && in_valid &&
                                  att_param_phase_cs;
    assign att_read_rd_req     = (state_cs == S_ATT_READ) && !att_rd_issued_cs;
    assign att_half_rd_req     = (state_cs == S_ATT_WAIT) &&
                                 !att_read_half_cs &&
                                 pre_wr_issued_cs;
    assign att_rd_req          = att_first_rd_req || att_read_rd_req || att_half_rd_req;
    assign att_rd_addr         = (att_half_rd_req || att_read_half_cs) ? HALF_ADDR : '0;
    assign att_rd_fire         = att_rd_req && rd_ready;
    assign att_rd_data_fire    = (state_cs == S_ATT_READ) && rd_valid &&
                                 (att_rd_word_cnt_cs < 8'd128);

    // result_active：FAST 與 ATT 共用的「正在出結果」窗口
    assign result_active       = (state_cs == S_FAST_RUN) ||
                                 (state_cs == S_ATT_READ) ||
                                 (state_cs == S_ATT_WAIT);
    assign first_pre_result    = result_active &&
                                 datapath_result_pre_valid &&
                                 (pre_result_cnt_cs == 7'd0) &&
                                 !pre_wr_issued_cs;

    assign rd_cmd_req          = fast_rd_req || att_rd_req;
    assign rd_cmd_addr         = fast_rd_req ? fast_rd_addr : att_rd_addr;
    assign rd_cmd_fire         = rd_cmd_req && rd_ready;
    assign wr_cmd_req          = result_active &&
                                 (wr_pending_cs || first_pre_result);
    assign wr_cmd_addr         = pre_write_half_cs ? HALF_ADDR : '0;
    assign wr_cmd_fire         = wr_cmd_req && wr_ready;

    always_comb begin
        datapath_issue_valid = 1'b0;
        datapath_issue_mode  = IM_NONE;

        if ((state_cs == S_FAST_RUN) && rd_valid) begin
            datapath_issue_valid = 1'b1;
            datapath_issue_mode  = IM_NORM;
        end
        else if (att_rd_data_fire) begin
            datapath_issue_valid = 1'b1;
            datapath_issue_mode  = IM_ATT;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_cs            <= S_IDLE;
            exec_op             <= 2'd0;
            exec_act            <= 2'd0;
            exec_param          <= 256'd0;
            exec_weight_k       <= 256'd0;
            exec_weight_v       <= 256'd0;
            fast_rd_req_cnt_cs  <= 2'd0;
            att_param_phase_cs  <= 1'b0;
            att_rd_issued_cs    <= 1'b0;
            att_rd_word_cnt_cs  <= 8'd0;
            att_read_half_cs    <= 1'b0;
            pre_result_cnt_cs   <= 7'd0;
            pre_write_half_cs   <= 1'b0;
            wr_pending_cs       <= 1'b0;
            pre_wr_issued_cs    <= 1'b0;
            group_result_cnt_cs <= 7'd0;
            result_half_cs      <= 1'b0;
        end
        else begin
            // 寫回 pending/issued（FAST/ATT 共用）
            if (first_pre_result) begin
                wr_pending_cs <= 1'b1;
            end
            if (wr_cmd_fire) begin
                wr_pending_cs    <= 1'b0;
                pre_wr_issued_cs <= 1'b1;
            end

            case (state_cs)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op    <= op;
                        exec_act   <= act;
                        exec_param <= param;

                        fast_rd_req_cnt_cs  <= fast_rd_fire ? 2'd1 : 2'd0;
                        att_param_phase_cs  <= 1'b0;
                        att_rd_issued_cs    <= 1'b0;
                        att_rd_word_cnt_cs  <= 8'd0;
                        att_read_half_cs    <= 1'b0;

                        pre_result_cnt_cs   <= 7'd0;
                        pre_write_half_cs   <= 1'b0;
                        wr_pending_cs       <= 1'b0;
                        pre_wr_issued_cs    <= 1'b0;
                        group_result_cnt_cs <= 7'd0;
                        result_half_cs      <= 1'b0;

                        state_cs <= op[1] ? S_ATT_PARAM : S_FAST_RUN;
                    end
                end

                S_FAST_RUN: begin
                    if (fast_rd_fire) begin
                        fast_rd_req_cnt_cs <= fast_rd_req_cnt_cs + 1'b1;
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (!att_param_phase_cs) begin
                            exec_weight_k      <= param;
                            att_param_phase_cs <= 1'b1;
                        end
                        else begin
                            exec_weight_v       <= param;
                            att_rd_issued_cs    <= att_rd_fire;
                            att_rd_word_cnt_cs  <= 8'd0;
                            att_read_half_cs    <= 1'b0;

                            pre_result_cnt_cs   <= 7'd0;
                            pre_write_half_cs   <= 1'b0;
                            wr_pending_cs       <= 1'b0;
                            pre_wr_issued_cs    <= 1'b0;
                            group_result_cnt_cs <= 7'd0;
                            result_half_cs      <= 1'b0;

                            state_cs            <= S_ATT_READ;
                        end
                    end
                end

                S_ATT_READ: begin
                    if (att_rd_fire) begin
                        att_rd_issued_cs <= 1'b1;
                    end

                    if (att_rd_data_fire) begin
                        if (att_rd_word_cnt_cs == 8'd127) begin
                            att_rd_word_cnt_cs <= 8'd0;
                            state_cs           <= S_ATT_WAIT;
                        end
                        else begin
                            att_rd_word_cnt_cs <= att_rd_word_cnt_cs + 1'b1;
                        end
                    end
                end

                S_ATT_WAIT: begin
                    if (att_rd_fire) begin
                        att_read_half_cs   <= 1'b1;
                        att_rd_issued_cs   <= 1'b1;
                        att_rd_word_cnt_cs <= 8'd0;
                        state_cs           <= S_ATT_READ;
                    end
                end

                default: begin
                    state_cs <= S_IDLE;
                end
            endcase

            // 寫回 pre-result 計數（FAST/ATT 共用）：每 128 筆翻一次 write half
            if (result_active && datapath_result_pre_valid) begin
                if (pre_result_cnt_cs == 7'd127) begin
                    pre_result_cnt_cs <= 7'd0;
                    if (!pre_write_half_cs) begin
                        pre_write_half_cs <= 1'b1;
                        pre_wr_issued_cs  <= 1'b0;
                        wr_pending_cs     <= 1'b0;
                    end
                end
                else begin
                    pre_result_cnt_cs <= pre_result_cnt_cs + 1'b1;
                end
            end

            // 完成計數（FAST/ATT 共用）：兩個 half 都出滿 → 回 S_IDLE
            if (result_active && datapath_result_valid) begin
                if (group_result_cnt_cs == 7'd127) begin
                    group_result_cnt_cs <= 7'd0;
                    if (result_half_cs) begin
                        state_cs <= S_IDLE;
                    end
                    else begin
                        result_half_cs <= 1'b1;
                    end
                end
                else begin
                    group_result_cnt_cs <= group_result_cnt_cs + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en    <= 1'b0;
            rd_addr  <= '0;
            rd_burst <= '0;
        end
        else begin
            rd_en    <= 1'b0;
            rd_addr  <= '0;
            rd_burst <= '0;

            if (rd_cmd_fire) begin
                rd_en    <= 1'b1;
                rd_addr  <= rd_cmd_addr;
                rd_burst <= BURST_128;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en    <= 1'b0;
            wr_addr  <= '0;
            wr_burst <= '0;
        end
        else begin
            wr_en    <= 1'b0;
            wr_addr  <= '0;
            wr_burst <= '0;

            if (wr_cmd_fire) begin
                wr_en    <= 1'b1;
                wr_addr  <= wr_cmd_addr;
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
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [255:0]         weight_k,
    input  logic [255:0]         weight_v,
    input  logic [RAM_WIDTH-1:0] rd_data,
    input  logic                 wr_valid,

    output logic                 result_pre_valid,
    output logic                 result_valid,
    output logic [RAM_WIDTH-1:0] wr_data,
    output logic                 out_valid,
    output logic [31:0]          out_data
);
    localparam int ACT_OUT_TAG_STAGE = 5;
    localparam int POT_OUT_TAG_STAGE = 4;
    localparam int RESULT_PRE_PIPE = ACT_OUT_TAG_STAGE;
    localparam int MAT_SIZE = 64;
    localparam int ACC_W = 12;
    localparam int ATT_ACC_W = 16;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int ATT_VEC_W = MAT_SIZE * ATT_ACC_W;
    localparam int SCORE_ELEM_W = 11;


    localparam logic [1:0] ACT_USER = 2'd0;

    typedef enum logic [1:0] {
        DT_NONE = 2'd0,
        DT_NORM = 2'd1,
        DT_ATT  = 2'd2
    } datapath_tag_t;

    logic                 issue_valid_cs;
    issue_mode_t          issue_mode_cs;
    logic [RAM_WIDTH-1:0] rd_data_cs;

    logic norm_in_valid;
    logic norm_mult_valid;
    logic [ACC_VEC_W-1:0] norm_mult_data;

    logic att_in_valid;
    logic att_core_valid;
    logic [ATT_VEC_W-1:0] att_core_data;

    logic act_in_valid;
    logic [ATT_VEC_W-1:0] norm_act_in_data;
    logic [ATT_VEC_W-1:0] act_in_data;
    datapath_tag_t act_in_tag;
    logic act_valid;
    logic [ATT_VEC_W-1:0] act_data;

    logic pot_in_valid;
    logic [ATT_VEC_W-1:0] pot_in_data;
    datapath_tag_t pot_in_tag;
    logic pot_valid;
    logic [255:0] pot_data;
    logic result_valid_ns;
    logic [255:0] result_data_ns;

    datapath_tag_t act_tag_cs [0:ACT_OUT_TAG_STAGE];
    datapath_tag_t pot_tag_cs [0:POT_OUT_TAG_STAGE];

    logic         result_pre_pipe_cs [0:RESULT_PRE_PIPE-1];
    logic [255:0] wr_data_skid_cs;
    logic         wr_data_skid_valid_cs;

    assign norm_in_valid = issue_valid_cs && (issue_mode_cs == IM_NORM);
    assign att_in_valid  = issue_valid_cs && (issue_mode_cs == IM_ATT);

    assign act_in_valid = norm_mult_valid || att_core_valid;
    assign act_in_data  = att_core_valid ? att_core_data : norm_act_in_data;
    assign act_in_tag   = att_core_valid ? DT_ATT :
                          (norm_mult_valid ? DT_NORM : DT_NONE);

    assign pot_in_valid = act_valid &&
                          (act_tag_cs[ACT_OUT_TAG_STAGE] != DT_NONE);
    assign pot_in_tag   = act_tag_cs[ACT_OUT_TAG_STAGE];

    assign result_valid_ns = pot_valid &&
                             (pot_tag_cs[POT_OUT_TAG_STAGE] != DT_NONE);
    assign result_data_ns = pot_data;
    assign result_valid = result_valid_ns;
    assign result_pre_valid = result_pre_pipe_cs[RESULT_PRE_PIPE-1];
    assign wr_data      = wr_data_skid_valid_cs ? wr_data_skid_cs : result_data_ns;
    assign pot_in_data  = act_data;

    always_comb begin
        norm_act_in_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            norm_act_in_data[ATT_VEC_W - 1 - (i * ATT_ACC_W) -: ATT_ACC_W] =
                {{(ATT_ACC_W-ACC_W)
                  {norm_mult_data[ACC_VEC_W - 1 - (i * ACC_W)]}},
                 norm_mult_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W]};
        end
    end

    ATT_Stream_Core #(
        .ACC_W        (ACC_W),
        .OUT_W        (ATT_ACC_W),
        .MAT_SIZE     (MAT_SIZE),
        .SCORE_ELEM_W (SCORE_ELEM_W)
    ) u_att_stream_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (norm_in_valid || att_in_valid),
        .is_att    (att_in_valid),
        .is_mha    (op[0]),
        .op        (op),
        .src_data  (rd_data_cs),
        .wq_data   (param),
        .wk_data   (weight_k),
        .wv_data   (weight_v),
        .norm_valid(norm_mult_valid),
        .norm_data (norm_mult_data),
        .out_valid (att_core_valid),
        .out_data  (att_core_data)
    );

    ACT_5Stage_Parallel #(
        .ACC_W    (ATT_ACC_W),
        .OUT_W    (ATT_ACC_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act),
        .act_mode  (ACT_USER),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    PoT_5Stage_Parallel #(
        .ACC_W    (ATT_ACC_W),
        .MAT_SIZE (MAT_SIZE)
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
            issue_valid_cs   <= 1'b0;
            issue_mode_cs    <= IM_NONE;
            rd_data_cs       <= '0;
            out_valid        <= 1'b0;
            out_data         <= 32'd0;
            wr_data_skid_cs       <= 256'd0;
            wr_data_skid_valid_cs <= 1'b0;
            for (int i = 0; i < RESULT_PRE_PIPE; i++) begin
                result_pre_pipe_cs[i] <= 1'b0;
            end
            for (int i = 0; i <= ACT_OUT_TAG_STAGE; i++) begin
                act_tag_cs[i] <= DT_NONE;
            end
            for (int i = 0; i <= POT_OUT_TAG_STAGE; i++) begin
                pot_tag_cs[i] <= DT_NONE;
            end
        end
        else begin
            issue_valid_cs <= issue_valid;
            issue_mode_cs  <= issue_valid ? issue_mode : IM_NONE;
            rd_data_cs     <= rd_data;
            act_tag_cs[0] <= act_in_valid ? act_in_tag : DT_NONE;
            for (int i = 1; i <= ACT_OUT_TAG_STAGE; i++) begin
                act_tag_cs[i] <= act_tag_cs[i - 1];
            end

            pot_tag_cs[0] <= pot_in_valid ? pot_in_tag : DT_NONE;
            for (int i = 1; i <= POT_OUT_TAG_STAGE; i++) begin
                pot_tag_cs[i] <= pot_tag_cs[i - 1];
            end

            result_pre_pipe_cs[0] <= act_in_valid;
            for (int i = 1; i < RESULT_PRE_PIPE; i++) begin
                result_pre_pipe_cs[i] <= result_pre_pipe_cs[i - 1];
            end

            if (wr_data_skid_valid_cs) begin
                if (wr_valid) begin
                    if (result_valid) begin
                        wr_data_skid_cs <= result_data_ns;
                    end
                    else begin
                        wr_data_skid_valid_cs <= 1'b0;
                    end
                end
            end
            else begin
                if (result_valid && !wr_valid) begin
                    wr_data_skid_cs       <= result_data_ns;
                    wr_data_skid_valid_cs <= 1'b1;
                end
            end

            out_valid <= result_valid;
            if (result_valid) begin
                out_data <= result_data_ns[31:0];
            end
        end
    end

endmodule

module ATT_Stream_Core #(
    parameter int ACC_W = 16,
    parameter int OUT_W = ACC_W,
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 10
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_att,
    input  logic                 is_mha,
    input  logic [1:0]           op,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    input  logic [255:0]         wk_data,
    input  logic [255:0]         wv_data,
    output logic                 norm_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] norm_data,
    output logic                 out_valid,
    output logic [(MAT_SIZE*OUT_W)-1:0] out_data
);

    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int OUT_VEC_W = MAT_SIZE * OUT_W;
    localparam int PROJ_W = 11;
    localparam int SCORE_CORE_ELEM_W = SCORE_ELEM_W;
    localparam int FINAL_ACC_W = OUT_W;
    localparam int FINAL_EXT_W = (OUT_W > FINAL_ACC_W) ?
                                 (OUT_W - FINAL_ACC_W) : 1;
    localparam int FINAL_ACC_VEC_W = MAT_SIZE * FINAL_ACC_W;

    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic [OUT_VEC_W-1:0] out_vec_t;
    typedef logic [FINAL_ACC_VEC_W-1:0] final_acc_vec_t;
    localparam int SCORE_BUS_W = MAT_SIZE * SCORE_ELEM_W;
    localparam int SCORE_CORE_BUS_W = MAT_SIZE * SCORE_CORE_ELEM_W;

    logic qkv_word_valid;
    logic qkv_word_mha;
    logic [255:0] q_word_cs;
    logic [255:0] k_word_cs;
    logic [255:0] v_word_cs;

    logic score_pipe_valid;
    logic score_pipe_mha;
    logic [255:0] score_pipe_v;
    logic [SCORE_CORE_BUS_W-1:0] score0_core_data;
    logic [SCORE_CORE_BUS_W-1:0] score1_core_data;
    logic [SCORE_BUS_W-1:0] score0_data;
    logic [SCORE_BUS_W-1:0] score1_data;
    logic final_valid;
    final_acc_vec_t final_core_data;
    out_vec_t final_data;

    ATT_QKV_Proj_Quant_Parallel #(
        .PROJ_W   (PROJ_W),
        .MAT_SIZE (MAT_SIZE),
        .NORM_W   (ACC_W)
    ) u_att_qkv_proj_quant (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .is_att    (is_att),
        .is_mha    (is_mha),
        .op        (op),
        .src_data  (src_data),
        .wq_data   (wq_data),
        .wk_data   (wk_data),
        .wv_data   (wv_data),
        .norm_valid(norm_valid),
        .norm_data (norm_data),
        .out_valid (qkv_word_valid),
        .out_mha   (qkv_word_mha),
        .q_data    (q_word_cs),
        .k_data    (k_word_cs),
        .v_data    (v_word_cs)
    );

    ATT_Score_8Tap #(
        .MAT_SIZE     (MAT_SIZE),
        .SCORE_ELEM_W (SCORE_CORE_ELEM_W)
    ) u_att_score_8tap (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (qkv_word_valid),
        .is_mha      (qkv_word_mha),
        .q_data      (q_word_cs),
        .k_data      (k_word_cs),
        .v_data      (v_word_cs),
        .out_valid   (score_pipe_valid),
        .out_mha     (score_pipe_mha),
        .out_v_data  (score_pipe_v),
        .score0_data (score0_core_data),
        .score1_data (score1_core_data)
    );

    always_comb begin
        score0_data = '0;
        score1_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            score0_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W] =
                {{(SCORE_ELEM_W-SCORE_CORE_ELEM_W)
                  {score0_core_data[SCORE_CORE_BUS_W - 1 -
                                    (i * SCORE_CORE_ELEM_W)]}},
                 score0_core_data[SCORE_CORE_BUS_W - 1 -
                                  (i * SCORE_CORE_ELEM_W) -:
                                  SCORE_CORE_ELEM_W]};
            score1_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -: SCORE_ELEM_W] =
                {{(SCORE_ELEM_W-SCORE_CORE_ELEM_W)
                  {score1_core_data[SCORE_CORE_BUS_W - 1 -
                                    (i * SCORE_CORE_ELEM_W)]}},
                 score1_core_data[SCORE_CORE_BUS_W - 1 -
                                  (i * SCORE_CORE_ELEM_W) -:
                                  SCORE_CORE_ELEM_W]};
        end
    end

    ATT_Final_Booth_Acc #(
        .ACC_W        (FINAL_ACC_W),
        .MAT_SIZE     (MAT_SIZE),
        .SCORE_ELEM_W (SCORE_ELEM_W)
    ) u_att_final_booth_acc (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (score_pipe_valid),
        .is_mha      (score_pipe_mha),
        .score0_data (score0_data),
        .score1_data (score1_data),
        .v_data      (score_pipe_v),
        .out_valid   (final_valid),
        .out_data    (final_core_data)
    );

    always_comb begin
        final_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            if (OUT_W == FINAL_ACC_W) begin
                final_data[OUT_VEC_W - 1 - (i * OUT_W) -: OUT_W] =
                    final_core_data[FINAL_ACC_VEC_W - 1 -
                                    (i * FINAL_ACC_W) -:
                                    FINAL_ACC_W];
            end
            else begin
                final_data[OUT_VEC_W - 1 - (i * OUT_W) -: OUT_W] =
                    {{FINAL_EXT_W
                      {final_core_data[FINAL_ACC_VEC_W - 1 -
                                       (i * FINAL_ACC_W)]}},
                     final_core_data[FINAL_ACC_VEC_W - 1 -
                                     (i * FINAL_ACC_W) -:
                                     FINAL_ACC_W]};
            end
        end
    end

    assign out_valid = final_valid;
    assign out_data  = final_data;

endmodule


module ATT_QNorm_Proj_Pipe #(
    parameter int PROJ_W = 11,
    parameter int MAT_SIZE = 64,
    parameter int NORM_W = 16
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_att,
    input  logic                 is_mha,
    input  logic [1:0]           op,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    output logic                 norm_valid,
    output logic [(MAT_SIZE*NORM_W)-1:0] norm_data,
    output logic                 q_valid,
    output logic                 q_mha,
    output logic [255:0]         q_data
);

    localparam int ROW_ELEM   = 8;
    localparam int DOT_SIZE   = 9;
    localparam int SHIFT_W    = $clog2(PROJ_W);
    localparam int NORM_VEC_W = MAT_SIZE * NORM_W;
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]        s4_t;
    typedef logic signed [7:0]        prod_t;
    typedef logic signed [9:0]        q_part_t;
    typedef logic signed [PROJ_W-1:0] proj_t;
    typedef logic signed [NORM_W-1:0] norm_t;
    typedef logic [PROJ_W-1:0]        mag_t;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic att_s0_cs;
    logic att_s1_cs;
    logic att_s2_cs;
    logic att_s3_cs;
    logic att_s4_cs;
    logic mha_s0_cs;
    logic mha_s1_cs;
    logic mha_s2_cs;
    logic mha_s3_cs;
    logic mha_s4_cs;

    s4_t     q_op_a_cs   [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t     q_op_b_cs   [0:ROW_ELEM-1][0:DOT_SIZE-1];
    prod_t   q_prod_cs   [0:MAT_SIZE-1][0:DOT_SIZE-1];
    q_part_t q_part_cs   [0:MAT_SIZE-1][0:1];
    proj_t   q_sum_cs    [0:MAT_SIZE-1];
    norm_t   norm_sum_cs [0:MAT_SIZE-1];
    proj_t   q_max_data_cs [0:MAT_SIZE-1];
    mag_t    q_max_bits_cs;

    s4_t     q_op_a_ns  [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t     q_op_b_ns  [0:ROW_ELEM-1][0:DOT_SIZE-1];
    prod_t   q_prod_ns  [0:MAT_SIZE-1][0:DOT_SIZE-1];
    q_part_t q_part_ns  [0:MAT_SIZE-1][0:1];
    proj_t   q_sum_ns   [0:MAT_SIZE-1];
    norm_t   norm_sum_ns [0:MAT_SIZE-1];
    mag_t    q_max_bits_ns;
    logic [SHIFT_W-1:0] q_shift_ns;
    logic [255:0] q_quant_ns;
    logic [NORM_VEC_W-1:0] norm_pack_ns;

    assign norm_valid = valid_s3_cs && !att_s3_cs;
    assign norm_data  = norm_pack_ns;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s4_t get_src_s4(
        input logic [255:0] vec,
        input integer row,
        input integer col
    );
        if ((row < 0) || (row >= ROW_ELEM) ||
            (col < 0) || (col >= ROW_ELEM)) begin
            get_src_s4 = 4'sd0;
        end
        else begin
            get_src_s4 = get_s4(vec, (row * ROW_ELEM) + col);
        end
    endfunction

    function automatic s4_t select_q_a(
        input logic [255:0] vec,
        input logic conv_en,
        input integer row,
        input integer lane,
        input integer tap
    );
        integer out_row;
        integer out_col;
        begin
            if (conv_en) begin
                out_row = row;
                out_col = lane;
                select_q_a = get_src_s4(vec,
                                        out_row + (tap / 3) - 1,
                                        out_col + (tap % 3) - 1);
            end
            else if (tap < ROW_ELEM) begin
                select_q_a = get_src_s4(vec, row, tap);
            end
            else begin
                select_q_a = 4'sd0;
            end
        end
    endfunction

    function automatic mag_t abs_proj(input proj_t value);
        abs_proj = value[PROJ_W - 1] ? mag_t'(-value) : mag_t'(value);
    endfunction

    function automatic logic [SHIFT_W-1:0] pot_shift(input mag_t max_abs);
        logic [SHIFT_W-1:0] msb;
        begin
            msb = '0;
            for (int b = 0; b < PROJ_W; b++) begin
                if (max_abs[b]) begin
                    msb = b[SHIFT_W-1:0];
                end
            end
            pot_shift = (msb > SHIFT_TWO) ? (msb - SHIFT_TWO) : '0;
        end
    endfunction

    function automatic s4_t clamp_s4(input proj_t value);
        begin
            if (value > proj_t'(7)) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < proj_t'(-8)) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    always_comb begin
        q_max_bits_ns = '0;
        q_shift_ns    = pot_shift(q_max_bits_cs);
        q_quant_ns    = 256'd0;
        norm_pack_ns  = '0;

        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    q_op_a_ns[out_idx][tap] =
                        select_q_a(src_data, !is_att && (op == 2'b01),
                                   row, lane, tap);
                end
            end
        end

        for (int lane = 0; lane < ROW_ELEM; lane++) begin
            for (int tap = 0; tap < DOT_SIZE; tap++) begin
                if (!is_att && (op == 2'b01)) begin
                    q_op_b_ns[lane][tap] = get_s4(wq_data, tap);
                end
                else if (tap < ROW_ELEM) begin
                    q_op_b_ns[lane][tap] =
                        get_s4(wq_data, (tap * ROW_ELEM) + lane);
                end
                else begin
                    q_op_b_ns[lane][tap] = 4'sd0;
                end
            end
        end

        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    q_prod_ns[out_idx][tap] =
                        prod_t'($signed(q_op_a_cs[out_idx][tap]) *
                                $signed(q_op_b_cs[lane][tap]));
                end

                q_part_ns[out_idx][0] =
                    q_part_t'(q_prod_cs[out_idx][0]) +
                    q_part_t'(q_prod_cs[out_idx][1]) +
                    q_part_t'(q_prod_cs[out_idx][2]) +
                    q_part_t'(q_prod_cs[out_idx][3]) +
                    q_part_t'(q_prod_cs[out_idx][4]);
                q_part_ns[out_idx][1] =
                    q_part_t'(q_prod_cs[out_idx][5]) +
                    q_part_t'(q_prod_cs[out_idx][6]) +
                    q_part_t'(q_prod_cs[out_idx][7]) +
                    q_part_t'(q_prod_cs[out_idx][8]);
                q_sum_ns[out_idx] =
                    proj_t'(q_part_cs[out_idx][0]) +
                    proj_t'(q_part_cs[out_idx][1]);

                norm_sum_ns[out_idx] =
                    norm_t'(q_part_cs[out_idx][0]) +
                    norm_t'(q_part_cs[out_idx][1]);

                q_max_bits_ns |= abs_proj(q_sum_cs[out_idx]);

                q_quant_ns[255 - (out_idx * 4) -: 4] =
                    clamp_s4(q_max_data_cs[out_idx] >>> q_shift_ns);

                norm_pack_ns[NORM_VEC_W - 1 - (out_idx * NORM_W) -:
                             NORM_W] = norm_sum_cs[out_idx];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            valid_s3_cs <= 1'b0;
            valid_s4_cs <= 1'b0;
            att_s0_cs   <= 1'b0;
            att_s1_cs   <= 1'b0;
            att_s2_cs   <= 1'b0;
            att_s3_cs   <= 1'b0;
            att_s4_cs   <= 1'b0;
            q_valid     <= 1'b0;
            q_mha       <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;
            q_valid     <= valid_s4_cs && att_s4_cs;

            if (in_valid) begin
                att_s0_cs <= is_att;
                mha_s0_cs <= is_mha;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        q_op_a_cs[i][tap] <= q_op_a_ns[i][tap];
                    end
                end
                for (int lane = 0; lane < ROW_ELEM; lane++) begin
                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        q_op_b_cs[lane][tap] <= q_op_b_ns[lane][tap];
                    end
                end
            end
            mha_s1_cs <= mha_s0_cs;
            mha_s2_cs <= mha_s1_cs;
            mha_s3_cs <= mha_s2_cs;
            mha_s4_cs <= mha_s3_cs;
            att_s1_cs <= att_s0_cs;
            att_s2_cs <= att_s1_cs;
            att_s3_cs <= att_s2_cs;
            att_s4_cs <= att_s3_cs;

            if (valid_s0_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < DOT_SIZE; tap++) begin
                        q_prod_cs[i][tap] <= q_prod_ns[i][tap];
                    end
                end
            end

            if (valid_s1_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    q_part_cs[i][0] <= q_part_ns[i][0];
                    q_part_cs[i][1] <= q_part_ns[i][1];
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    q_sum_cs[i]    <= q_sum_ns[i];
                    norm_sum_cs[i] <= norm_sum_ns[i];
                end
            end

            if (valid_s3_cs) begin
                q_max_bits_cs <= q_max_bits_ns;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    q_max_data_cs[i] <= q_sum_cs[i];
                end
            end

            if (valid_s4_cs && att_s4_cs) begin
                q_mha  <= mha_s4_cs;
                q_data <= q_quant_ns;
            end
        end
    end
endmodule


module ATT_QKV_Proj_Quant_Parallel #(
    parameter int PROJ_W = 11,
    parameter int MAT_SIZE = 64,
    parameter int NORM_W = 16
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_att,
    input  logic                 is_mha,
    input  logic [1:0]           op,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    input  logic [255:0]         wk_data,
    input  logic [255:0]         wv_data,
    output logic                 norm_valid,
    output logic [(MAT_SIZE*NORM_W)-1:0] norm_data,
    output logic                 out_valid,
    output logic                 out_mha,
    output logic [255:0]         q_data,
    output logic [255:0]         k_data,
    output logic [255:0]         v_data
);

    localparam int ROW_ELEM   = 8;
    localparam int KV_DOT_SIZE = 8;
    localparam int KV_PIPE_COUNT = 2;
    localparam int K_PIPE     = 0;
    localparam int V_PIPE     = 1;
    localparam int SHIFT_W    = $clog2(PROJ_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]        s4_t;
    typedef logic signed [7:0]        prod_t;
    typedef logic signed [8:0]        kv_part_t;
    typedef logic signed [PROJ_W-1:0] proj_t;
    typedef logic [PROJ_W-1:0]        mag_t;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic att_s0_cs;
    logic att_s1_cs;
    logic att_s2_cs;
    logic att_s3_cs;
    logic att_s4_cs;
    logic [255:0] wk_data_s0_cs;
    logic [255:0] wv_data_s0_cs;

    s4_t     src_row_cs  [0:ROW_ELEM-1][0:ROW_ELEM-1];
    prod_t    kv_prod_cs [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1][0:KV_DOT_SIZE-1];
    kv_part_t kv_part_cs [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1][0:1];
    proj_t    kv_sum_cs  [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1];
    proj_t    kv_max_data_cs [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1];
    mag_t     kv_max_bits_cs [0:KV_PIPE_COUNT-1];

    s4_t     src_row_ns [0:ROW_ELEM-1][0:ROW_ELEM-1];
    prod_t    kv_prod_ns [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1][0:KV_DOT_SIZE-1];
    kv_part_t kv_part_ns [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1][0:1];
    proj_t    kv_sum_ns  [0:KV_PIPE_COUNT-1][0:MAT_SIZE-1];
    mag_t     kv_max_bits_ns [0:KV_PIPE_COUNT-1];
    logic [SHIFT_W-1:0] kv_shift_ns [0:KV_PIPE_COUNT-1];
    logic [255:0] kv_quant_ns [0:KV_PIPE_COUNT-1];

    ATT_QNorm_Proj_Pipe #(
        .PROJ_W   (PROJ_W),
        .MAT_SIZE (MAT_SIZE),
        .NORM_W   (NORM_W)
    ) u_att_qnorm_proj_pipe (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .is_att     (is_att),
        .is_mha     (is_mha),
        .op         (op),
        .src_data   (src_data),
        .wq_data    (wq_data),
        .norm_valid (norm_valid),
        .norm_data  (norm_data),
        .q_valid    (out_valid),
        .q_mha      (out_mha),
        .q_data     (q_data)
    );

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s4_t select_kv_b(
        input integer pipe,
        input integer lane,
        input integer tap
    );
        begin
            if (pipe == K_PIPE) begin
                select_kv_b = get_s4(wk_data_s0_cs,
                                     (tap * ROW_ELEM) + lane);
            end
            else begin
                select_kv_b = get_s4(wv_data_s0_cs,
                                     (tap * ROW_ELEM) + lane);
            end
        end
    endfunction

    function automatic mag_t abs_proj(input proj_t value);
        abs_proj = value[PROJ_W - 1] ? mag_t'(-value) : mag_t'(value);
    endfunction

    function automatic logic [SHIFT_W-1:0] pot_shift(input mag_t max_abs);
        logic [SHIFT_W-1:0] msb;
        begin
            msb = '0;
            for (int b = 0; b < PROJ_W; b++) begin
                if (max_abs[b]) begin
                    msb = b[SHIFT_W-1:0];
                end
            end
            pot_shift = (msb > SHIFT_TWO) ? (msb - SHIFT_TWO) : '0;
        end
    endfunction

    function automatic s4_t clamp_s4(input proj_t value);
        begin
            if (value > proj_t'(7)) begin
                clamp_s4 = 4'sd7;
            end
            else if (value < proj_t'(-8)) begin
                clamp_s4 = -4'sd8;
            end
            else begin
                clamp_s4 = value[3:0];
            end
        end
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int tap = 0; tap < ROW_ELEM; tap++) begin
                src_row_ns[row][tap] = get_s4(src_data, (row * ROW_ELEM) + tap);
            end
        end

        for (int pipe = 0; pipe < KV_PIPE_COUNT; pipe++) begin
            kv_max_bits_ns[pipe] = '0;
            kv_shift_ns[pipe] = pot_shift(kv_max_bits_cs[pipe]);
            kv_quant_ns[pipe] = 256'd0;

            for (int row = 0; row < ROW_ELEM; row++) begin
                for (int lane = 0; lane < ROW_ELEM; lane++) begin
                    int out_idx;
                    out_idx = (row * ROW_ELEM) + lane;

                    for (int tap = 0; tap < KV_DOT_SIZE; tap++) begin
                        kv_prod_ns[pipe][out_idx][tap] =
                            prod_t'($signed(src_row_cs[row][tap]) *
                                    $signed(select_kv_b(pipe, lane, tap)));
                    end

                    kv_part_ns[pipe][out_idx][0] =
                        kv_part_t'(kv_prod_cs[pipe][out_idx][0]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][1]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][2]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][3]);
                    kv_part_ns[pipe][out_idx][1] =
                        kv_part_t'(kv_prod_cs[pipe][out_idx][4]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][5]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][6]) +
                        kv_part_t'(kv_prod_cs[pipe][out_idx][7]);
                    kv_sum_ns[pipe][out_idx] =
                        proj_t'(kv_part_cs[pipe][out_idx][0]) +
                        proj_t'(kv_part_cs[pipe][out_idx][1]);

                    kv_max_bits_ns[pipe] |= abs_proj(kv_sum_cs[pipe][out_idx]);
                    kv_quant_ns[pipe][255 - (out_idx * 4) -: 4] =
                        clamp_s4(kv_max_data_cs[pipe][out_idx] >>>
                                  kv_shift_ns[pipe]);
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            valid_s3_cs <= 1'b0;
            valid_s4_cs <= 1'b0;
            att_s0_cs   <= 1'b0;
            att_s1_cs   <= 1'b0;
            att_s2_cs   <= 1'b0;
            att_s3_cs   <= 1'b0;
            att_s4_cs   <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;

            if (in_valid) begin
                att_s0_cs <= is_att;
                wk_data_s0_cs <= wk_data;
                wv_data_s0_cs <= wv_data;
            end
            att_s1_cs <= att_s0_cs;
            att_s2_cs <= att_s1_cs;
            att_s3_cs <= att_s2_cs;
            att_s4_cs <= att_s3_cs;

            if (in_valid) begin
                for (int row = 0; row < ROW_ELEM; row++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        src_row_cs[row][tap] <= src_row_ns[row][tap];
                    end
                end
            end

            if (valid_s0_cs) begin
                for (int pipe = 0; pipe < KV_PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        for (int tap = 0; tap < KV_DOT_SIZE; tap++) begin
                            kv_prod_cs[pipe][i][tap] <= kv_prod_ns[pipe][i][tap];
                        end
                    end
                end
            end

            if (valid_s1_cs) begin
                for (int pipe = 0; pipe < KV_PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        kv_part_cs[pipe][i][0] <= kv_part_ns[pipe][i][0];
                        kv_part_cs[pipe][i][1] <= kv_part_ns[pipe][i][1];
                    end
                end
            end

            if (valid_s2_cs) begin
                for (int pipe = 0; pipe < KV_PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        kv_sum_cs[pipe][i] <= kv_sum_ns[pipe][i];
                    end
                end
            end

            if (valid_s3_cs) begin
                for (int pipe = 0; pipe < KV_PIPE_COUNT; pipe++) begin
                    kv_max_bits_cs[pipe] <= kv_max_bits_ns[pipe];
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        kv_max_data_cs[pipe][i] <= kv_sum_cs[pipe][i];
                    end
                end
            end

            if (valid_s4_cs && att_s4_cs) begin
                k_data  <= kv_quant_ns[K_PIPE];
                v_data  <= kv_quant_ns[V_PIPE];
            end
        end
    end

endmodule






module ATT_Score_8Tap #(
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 11
)(
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                in_valid,
    input  logic                                is_mha,
    input  logic [255:0]                        q_data,
    input  logic [255:0]                        k_data,
    input  logic [255:0]                        v_data,
    output logic                                out_valid,
    output logic                                out_mha,
    output logic [255:0]                        out_v_data,
    output logic [(MAT_SIZE*SCORE_ELEM_W)-1:0] score0_data,
    output logic [(MAT_SIZE*SCORE_ELEM_W)-1:0] score1_data
);

    localparam int ROW_ELEM   = 8;
    localparam int SCORE_BUS_W = MAT_SIZE * SCORE_ELEM_W;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic mha_s0_cs;
    logic mha_s1_cs;
    logic mha_s2_cs;
    logic [255:0] v_s0_cs;
    logic [255:0] v_s1_cs;
    logic [255:0] v_s2_cs;

    localparam int PROD_W = 8;
    localparam int HALF_W = 10;

    typedef logic signed [3:0]              s4_t;
    typedef logic signed [PROD_W-1:0]       prod_t;
    typedef logic signed [HALF_W-1:0]       score_half_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;

    prod_t       prod_cs [0:MAT_SIZE-1][0:ROW_ELEM-1];
    score_half_t head0_sum_cs [0:MAT_SIZE-1];
    score_half_t head1_sum_cs [0:MAT_SIZE-1];
    score_t      head0_score_cs [0:MAT_SIZE-1];
    score_t      head1_score_cs [0:MAT_SIZE-1];
    score_t      full_sum_cs [0:MAT_SIZE-1];
    score_t      score0_out_cs [0:MAT_SIZE-1];
    score_t      score1_out_cs [0:MAT_SIZE-1];

    prod_t       prod_ns [0:MAT_SIZE-1][0:ROW_ELEM-1];
    score_half_t head0_sum_ns [0:MAT_SIZE-1];
    score_half_t head1_sum_ns [0:MAT_SIZE-1];
    score_t      full_sum_ns [0:MAT_SIZE-1];
    score_t      score0_raw_ns [0:MAT_SIZE-1];
    score_t      score1_raw_ns [0:MAT_SIZE-1];
    score_t      score0_act_ns [0:MAT_SIZE-1];
    score_t      score1_act_ns [0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic score_t score_act(input score_t value);
        score_act = (value < 0) ? (value >>> 2) : value;
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    prod_ns[out_idx][tap] = prod_t'(
                        $signed(get_s4(q_data,
                                       (row * ROW_ELEM) + tap)) *
                        $signed(get_s4(k_data,
                                       (lane * ROW_ELEM) + tap)));
                end

                head0_sum_ns[out_idx] =
                    (score_half_t'(prod_cs[out_idx][0]) +
                     score_half_t'(prod_cs[out_idx][1])) +
                    (score_half_t'(prod_cs[out_idx][2]) +
                     score_half_t'(prod_cs[out_idx][3]));
                head1_sum_ns[out_idx] =
                    (score_half_t'(prod_cs[out_idx][4]) +
                     score_half_t'(prod_cs[out_idx][5])) +
                    (score_half_t'(prod_cs[out_idx][6]) +
                     score_half_t'(prod_cs[out_idx][7]));
                full_sum_ns[out_idx] =
                    score_t'(head0_sum_cs[out_idx]) +
                    score_t'(head1_sum_cs[out_idx]);

                score0_raw_ns[out_idx] = mha_s2_cs ?
                    head0_score_cs[out_idx] : full_sum_cs[out_idx];
                score1_raw_ns[out_idx] = mha_s2_cs ?
                    head1_score_cs[out_idx] : full_sum_cs[out_idx];
                score0_act_ns[out_idx] = score_act(score0_raw_ns[out_idx]);
                score1_act_ns[out_idx] = score_act(score1_raw_ns[out_idx]);
            end
        end
    end

    always_comb begin
        score0_data = '0;
        score1_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            score0_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -:
                        SCORE_ELEM_W] = score0_out_cs[i];
            score1_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -:
                        SCORE_ELEM_W] = score1_out_cs[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            mha_s0_cs   <= 1'b0;
            mha_s1_cs   <= 1'b0;
            mha_s2_cs   <= 1'b0;
            out_valid   <= 1'b0;
            out_mha     <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            out_valid   <= valid_s2_cs;

            if (in_valid) begin
                mha_s0_cs <= is_mha;
                v_s0_cs   <= v_data;
            end

            if (valid_s0_cs) begin
                mha_s1_cs <= mha_s0_cs;
                v_s1_cs   <= v_s0_cs;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    head0_sum_cs[i] <= head0_sum_ns[i];
                    head1_sum_cs[i] <= head1_sum_ns[i];
                end
            end

            if (valid_s1_cs) begin
                mha_s2_cs <= mha_s1_cs;
                v_s2_cs   <= v_s1_cs;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    head0_score_cs[i] <= score_t'(head0_sum_cs[i]);
                    head1_score_cs[i] <= score_t'(head1_sum_cs[i]);
                    full_sum_cs[i]    <= full_sum_ns[i];
                end
            end

            if (valid_s2_cs) begin
                out_mha    <= mha_s2_cs;
                out_v_data <= v_s2_cs;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    score0_out_cs[i] <= score0_act_ns[i];
                    score1_out_cs[i] <= score1_act_ns[i];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    prod_cs[i][tap] <= prod_ns[i][tap];
                end
            end
        end
    end

endmodule


module ATT_Score_Lane_8Tap #(
    parameter int ROW_ELEM = 8,
    parameter int SCORE_ELEM_W = 11,
    parameter int ROW_IDX = 0,
    parameter int LANE_IDX = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          in_valid,
    input  logic                          is_mha,
    input  logic [255:0]                  q_data,
    input  logic [255:0]                  k_data,
    output logic                          out_valid,
    output logic signed [SCORE_ELEM_W-1:0] score0_out,
    output logic signed [SCORE_ELEM_W-1:0] score1_out
);

    localparam int PROD_W = 8;
    localparam int PAIR_W = 9;
    localparam int HALF_W = 10;

    typedef logic signed [3:0] s4_t;
    typedef logic signed [PROD_W-1:0] prod_t;
    typedef logic signed [PAIR_W-1:0] score_pair_t;
    typedef logic signed [HALF_W-1:0] score_half_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;

    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic is_mha_s1_cs;
    logic is_mha_s2_cs;
    logic is_mha_s3_cs;
    logic is_mha_s4_cs;
    prod_t prod_cs [0:ROW_ELEM-1];
    score_pair_t pair_cs [0:3];
    score_pair_t pair_ns [0:3];
    prod_t prod_ns [0:ROW_ELEM-1];
    score_half_t head0_sum_cs;
    score_half_t head1_sum_cs;
    score_half_t head0_sum_ns;
    score_half_t head1_sum_ns;
    score_t head0_score_cs;
    score_t head1_score_cs;
    score_t full_sum_cs;
    score_t full_sum_ns;
    score_t score0_raw_ns;
    score_t score1_raw_ns;
    score_t score0_act_ns;
    score_t score1_act_ns;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    always_comb begin
        for (int tap = 0; tap < ROW_ELEM; tap++) begin
            prod_ns[tap] = prod_t'(
                $signed(get_s4(q_data, (ROW_IDX * ROW_ELEM) + tap)) *
                $signed(get_s4(k_data, (LANE_IDX * ROW_ELEM) + tap)));
        end

        for (int pair_idx = 0; pair_idx < 4; pair_idx++) begin
            pair_ns[pair_idx] =
                score_pair_t'(prod_cs[pair_idx * 2]) +
                score_pair_t'(prod_cs[(pair_idx * 2) + 1]);
        end

        head0_sum_ns =
            score_half_t'(pair_cs[0]) + score_half_t'(pair_cs[1]);
        head1_sum_ns =
            score_half_t'(pair_cs[2]) + score_half_t'(pair_cs[3]);
        full_sum_ns =
            score_t'(head0_sum_cs) + score_t'(head1_sum_cs);

        score0_raw_ns = is_mha_s4_cs ? head0_score_cs : full_sum_cs;
        score1_raw_ns = head1_score_cs;
        score0_act_ns = (score0_raw_ns < 0) ? (score0_raw_ns >>> 2) : score0_raw_ns;
        score1_act_ns = (score1_raw_ns < 0) ? (score1_raw_ns >>> 2) : score1_raw_ns;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_cs  <= 1'b0;
            valid_s2_cs  <= 1'b0;
            valid_s3_cs  <= 1'b0;
            valid_s4_cs  <= 1'b0;
            is_mha_s1_cs <= 1'b0;
            is_mha_s2_cs <= 1'b0;
            is_mha_s3_cs <= 1'b0;
            is_mha_s4_cs <= 1'b0;
            out_valid    <= 1'b0;
        end
        else begin
            valid_s1_cs <= in_valid;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;
            out_valid   <= valid_s4_cs;

            if (in_valid) begin
                is_mha_s1_cs <= is_mha;
                for (int i = 0; i < ROW_ELEM; i++) begin
                    prod_cs[i] <= prod_ns[i];
                end
            end

            if (valid_s1_cs) begin
                is_mha_s2_cs <= is_mha_s1_cs;
                for (int i = 0; i < 4; i++) begin
                    pair_cs[i] <= pair_ns[i];
                end
            end

            if (valid_s2_cs) begin
                is_mha_s3_cs <= is_mha_s2_cs;
                head0_sum_cs <= head0_sum_ns;
                head1_sum_cs <= head1_sum_ns;
            end

            if (valid_s3_cs) begin
                is_mha_s4_cs  <= is_mha_s3_cs;
                head0_score_cs <= score_t'(head0_sum_cs);
                head1_score_cs <= score_t'(head1_sum_cs);
                full_sum_cs    <= full_sum_ns;
            end

            if (valid_s4_cs) begin
                score0_out <= score_t'(score0_act_ns);
                score1_out <= score_t'(score1_act_ns);
            end
        end
    end

endmodule


module ATT_Final_Booth_Acc #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 11
)(
    input  logic                                 clk,
    input  logic                                 rst_n,
    input  logic                                 in_valid,
    input  logic                                 is_mha,
    input  logic [(MAT_SIZE*SCORE_ELEM_W)-1:0]  score0_data,
    input  logic [(MAT_SIZE*SCORE_ELEM_W)-1:0]  score1_data,
    input  logic [255:0]                         v_data,
    output logic                                 out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0]          out_data
);

    localparam int ROW_ELEM   = 8;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;
    localparam int SCORE_BUS_W = MAT_SIZE * SCORE_ELEM_W;
    localparam int PROD_W      = SCORE_ELEM_W + 2;
    localparam int PROD_CALC_W = PROD_W;
    localparam int HALF_W      = PROD_W + 2;

    typedef logic signed [3:0]              s4_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;
    typedef logic signed [PROD_W-1:0]       prod_t;
    typedef logic signed [PROD_CALC_W-1:0]  prod_calc_t;
    typedef logic signed [HALF_W-1:0]       half_t;
    typedef logic signed [ACC_W-1:0]        acc_t;
    typedef logic [2:0]                     booth_t;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;

    score_t score0_cs [0:MAT_SIZE-1];
    score_t score1_cs [0:MAT_SIZE-1];
    booth_t v_booth_lo_cs [0:MAT_SIZE-1];
    booth_t v_booth_hi_cs [0:ROW_ELEM-1][0:MAT_SIZE-1];
    prod_t  prod_cs [0:MAT_SIZE-1][0:ROW_ELEM-1];
    half_t  half_cs [0:MAT_SIZE-1][0:1];
    acc_t   result_cs [0:MAT_SIZE-1];

    score_t score0_ns [0:MAT_SIZE-1];
    score_t score1_ns [0:MAT_SIZE-1];
    booth_t v_booth_lo_ns [0:MAT_SIZE-1];
    booth_t v_booth_hi_ns [0:MAT_SIZE-1];
    prod_t  prod_ns [0:MAT_SIZE-1][0:ROW_ELEM-1];
    half_t  half_ns [0:MAT_SIZE-1][0:1];
    acc_t   result_ns [0:MAT_SIZE-1];

    assign out_valid = valid_s3_cs;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic score_t get_score(
        input logic [SCORE_BUS_W-1:0] vec,
        input integer idx
    );
        get_score = $signed(vec[SCORE_BUS_W - 1 -
                                (idx * SCORE_ELEM_W) -:
                                SCORE_ELEM_W]);
    endfunction

    function automatic booth_t booth_lo(input s4_t value);
        booth_lo = {value[1], value[0], 1'b0};
    endfunction

    function automatic booth_t booth_hi(input s4_t value);
        booth_hi = {value[3], value[2], value[1]};
    endfunction

    function automatic prod_t booth_pp(
        input score_t value,
        input booth_t booth
    );
        prod_t value_ext;
        begin
            value_ext = prod_t'(value);
            unique case (booth)
                3'b001,
                3'b010: booth_pp = value_ext;
                3'b011: booth_pp = prod_t'(value_ext <<< 1);
                3'b100: booth_pp = prod_t'(-(value_ext <<< 1));
                3'b101,
                3'b110: booth_pp = -value_ext;
                default: booth_pp = '0;
            endcase
        end
    endfunction

    function automatic prod_t final_prod(
        input score_t score_value,
        input booth_t lo_booth,
        input booth_t hi_booth
    );
        prod_t lo_pp;
        prod_t hi_pp;
        begin
            lo_pp = booth_pp(score_value, lo_booth);
            hi_pp = booth_pp(score_value, hi_booth);
            final_prod = prod_t'(prod_calc_t'(lo_pp) +
                         (prod_calc_t'(hi_pp) <<< 2));
        end
    endfunction

    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            s4_t v_value;

            score0_ns[i] = get_score(score0_data, i);
            score1_ns[i] = get_score(score1_data, i);

            v_value = get_s4(v_data, i);
            v_booth_lo_ns[i] = booth_lo(v_value);
            v_booth_hi_ns[i] = booth_hi(v_value);
        end
    end

    always_comb begin
        out_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = result_cs[i];
        end

        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    int score_idx;
                    int v_idx;
                    score_t score_value;

                    score_idx = (row * ROW_ELEM) + tap;
                    v_idx = (tap * ROW_ELEM) + lane;
                    score_value = (lane >= 4) ?
                                  score1_cs[score_idx] :
                                  score0_cs[score_idx];

                    prod_ns[out_idx][tap] =
                        final_prod(score_value,
                                   v_booth_lo_cs[v_idx],
                                   v_booth_hi_cs[row][v_idx]);
                end

                half_ns[out_idx][0] =
                    (half_t'(prod_cs[out_idx][0]) +
                     half_t'(prod_cs[out_idx][1])) +
                    (half_t'(prod_cs[out_idx][2]) +
                     half_t'(prod_cs[out_idx][3]));
                half_ns[out_idx][1] =
                    (half_t'(prod_cs[out_idx][4]) +
                     half_t'(prod_cs[out_idx][5])) +
                    (half_t'(prod_cs[out_idx][6]) +
                     half_t'(prod_cs[out_idx][7]));

                result_ns[out_idx] =
                    acc_t'(half_cs[out_idx][0]) +
                    acc_t'(half_cs[out_idx][1]);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            valid_s3_cs <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;

            if (in_valid) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    score0_cs[i]      <= score0_ns[i];
                    score1_cs[i]      <= score1_ns[i];
                    v_booth_lo_cs[i]  <= v_booth_lo_ns[i];
                end

                for (int row = 0; row < ROW_ELEM; row++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        v_booth_hi_cs[row][i] <= v_booth_hi_ns[i];
                    end
                end
            end

            if (valid_s0_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        prod_cs[i][tap] <= prod_ns[i][tap];
                    end
                end
            end

            if (valid_s1_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int half_idx = 0; half_idx < 2; half_idx++) begin
                        half_cs[i][half_idx] <= half_ns[i][half_idx];
                    end
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    result_cs[i] <= result_ns[i];
                end
            end

        end
    end

endmodule


module ATT_Booth_PP #(
    parameter int SCORE_ELEM_W = 11,
    parameter int PROD_W = 13
)(
    input  logic signed [SCORE_ELEM_W-1:0] score,
    input  logic [2:0]                     booth,
    output logic signed [PROD_W-1:0]       pp
);

    logic signed [PROD_W-1:0] score_ext;

    always_comb begin
        score_ext = score;
        unique case (booth)
            3'b001,
            3'b010: pp = score_ext;
            3'b011: pp = score_ext <<< 1;
            3'b100: pp = -(score_ext <<< 1);
            3'b101,
            3'b110: pp = -score_ext;
            default: pp = '0;
        endcase
    end

endmodule


module ATT_Final_Lane_Booth_Acc #(
    parameter int ACC_W = 16,
    parameter int ROW_ELEM = 8,
    parameter int SCORE_ELEM_W = 11,
    parameter int LANE_IDX = 0
)(
    input  logic                                 clk,
    input  logic                                 rst_n,
    input  logic                                 in_valid,
    input  logic [(ROW_ELEM*SCORE_ELEM_W)-1:0]  score_data,
    input  logic [255:0]                         v_data,
    output logic                                 out_valid,
    output logic signed [ACC_W-1:0]              out_data
);

    localparam int SCORE_ROW_W = ROW_ELEM * SCORE_ELEM_W;
    // Score is bounded by the 8-tap score activation before FINAL, so
    // score * signed-4b V fits in s13. Keep the shifted Booth sum wider.
    localparam int PROD_W      = SCORE_ELEM_W + 2;
    localparam int PROD_CALC_W = PROD_W;
    localparam int PAIR_W      = PROD_W + 1;
    localparam int HALF_W      = PROD_W + 2;

    typedef logic signed [3:0]             s4_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;
    typedef logic signed [PROD_W-1:0]      prod_t;
    typedef logic signed [PROD_CALC_W-1:0] prod_calc_t;
    typedef logic signed [PAIR_W-1:0]      pair_t;
    typedef logic signed [HALF_W-1:0]      half_t;
    typedef logic signed [ACC_W-1:0]       acc_t;

    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic valid_s5_cs;

    score_t score_tap_ns [0:ROW_ELEM-1];
    score_t score_tap_cs [0:ROW_ELEM-1];
    s4_t    v_tap_ns     [0:ROW_ELEM-1];
    logic [2:0] booth_lo_ns [0:ROW_ELEM-1];
    logic [2:0] booth_hi_ns [0:ROW_ELEM-1];
    logic [2:0] booth_lo_cs [0:ROW_ELEM-1];
    logic [2:0] booth_hi_cs [0:ROW_ELEM-1];
    prod_t pp_lo [0:ROW_ELEM-1];
    prod_t pp_hi [0:ROW_ELEM-1];
    prod_t prod_cs [0:ROW_ELEM-1];
    prod_t prod_ns [0:ROW_ELEM-1];
    pair_t pair_cs [0:3];
    pair_t pair_ns [0:3];
    half_t half_cs [0:1];
    half_t half_ns [0:1];
    acc_t  result_cs;
    acc_t  result_ns;

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    genvar tap_idx;
    generate
        for (tap_idx = 0; tap_idx < ROW_ELEM; tap_idx++) begin : gen_final_booth_pp
            assign score_tap_ns[tap_idx] =
                $signed(score_data[SCORE_ROW_W - 1 -
                                   (tap_idx * SCORE_ELEM_W) -:
                                   SCORE_ELEM_W]);
            assign v_tap_ns[tap_idx] =
                get_s4(v_data, (tap_idx * ROW_ELEM) + LANE_IDX);
            assign booth_lo_ns[tap_idx] =
                {v_tap_ns[tap_idx][1], v_tap_ns[tap_idx][0], 1'b0};
            assign booth_hi_ns[tap_idx] =
                {v_tap_ns[tap_idx][3], v_tap_ns[tap_idx][2],
                 v_tap_ns[tap_idx][1]};

            ATT_Booth_PP #(
                .SCORE_ELEM_W (SCORE_ELEM_W),
                .PROD_W       (PROD_W)
            ) u_booth_lo (
                .score (score_tap_cs[tap_idx]),
                .booth (booth_lo_cs[tap_idx]),
                .pp    (pp_lo[tap_idx])
            );

            ATT_Booth_PP #(
                .SCORE_ELEM_W (SCORE_ELEM_W),
                .PROD_W       (PROD_W)
            ) u_booth_hi (
                .score (score_tap_cs[tap_idx]),
                .booth (booth_hi_cs[tap_idx]),
                .pp    (pp_hi[tap_idx])
            );

            assign prod_ns[tap_idx] =
                prod_t'(prod_calc_t'(pp_lo[tap_idx]) +
                        (prod_calc_t'(pp_hi[tap_idx]) <<< 2));
        end
    endgenerate

    always_comb begin
        for (int pair_idx = 0; pair_idx < 4; pair_idx++) begin
            pair_ns[pair_idx] =
                pair_t'(prod_cs[pair_idx * 2]) +
                pair_t'(prod_cs[(pair_idx * 2) + 1]);
        end

        half_ns[0] = half_t'(pair_cs[0]) + half_t'(pair_cs[1]);
        half_ns[1] = half_t'(pair_cs[2]) + half_t'(pair_cs[3]);
        result_ns = acc_t'(half_cs[0]) + acc_t'(half_cs[1]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            valid_s3_cs <= 1'b0;
            valid_s4_cs <= 1'b0;
            valid_s5_cs <= 1'b0;
            out_valid   <= 1'b0;
        end
        else begin
            valid_s1_cs <= in_valid;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;
            valid_s5_cs <= valid_s4_cs;
            out_valid   <= valid_s5_cs;

            if (in_valid) begin
                for (int i = 0; i < ROW_ELEM; i++) begin
                    score_tap_cs[i] <= score_tap_ns[i];
                    booth_lo_cs[i]  <= booth_lo_ns[i];
                    booth_hi_cs[i]  <= booth_hi_ns[i];
                end
            end

            if (valid_s1_cs) begin
                for (int i = 0; i < ROW_ELEM; i++) begin
                    prod_cs[i] <= prod_ns[i];
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < 4; i++) begin
                    pair_cs[i] <= pair_ns[i];
                end
            end

            if (valid_s3_cs) begin
                for (int i = 0; i < 2; i++) begin
                    half_cs[i] <= half_ns[i];
                end
            end

            if (valid_s4_cs) begin
                result_cs <= result_ns;
            end

            if (valid_s5_cs) begin
                out_data <= result_cs;
            end
        end
    end

endmodule


module ACT_5Stage_Parallel #(
    parameter int ACC_W = 16,
    parameter int OUT_W = ACC_W,
    parameter int MAT_SIZE = 64
)(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [1:0]    act_mode,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    output logic          out_valid,
    output logic [(MAT_SIZE*OUT_W)-1:0] out_data
);

    localparam int ROW_ELEM   = 8;
    localparam int CHUNK_SIZE = 16;
    localparam int NUM_CHUNK  = 4;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;
    localparam int OUT_VEC_W  = MAT_SIZE * OUT_W;
    localparam int ACT_STAGES = 4;  // pair → psum → threshold → apply

    localparam logic [1:0] ACT_USER    = 2'd0;
    localparam logic [1:0] ACT_SPECIAL = 2'd2;
    localparam int ACT_PIPE_STAGES = 5;

    typedef logic signed [ACC_W-1:0] s16_t;
    typedef logic signed [ACC_W:0] s17_t;  // pair: acc+acc
    typedef logic signed [ACC_W+1:0] s18_t;  // psum: 4*acc
    typedef logic signed [ACC_W+3:0] s20_t;

    // Input buffer (decouples upstream dispatch mux from psum tree; ACT 從外面
    // 看是 4-stage：input_buf → psum → threshold → apply)。
    logic          in_valid_buf;
    logic [1:0]    act_buf;
    // Duplicated stage-0 selects reduce fanout from the ACT selector into the
    // pair-sum mux/add logic. Keep them separate so synthesis does not merge
    // the equivalent registers back into one high-fanout driver.
    (* dont_touch = "true" *) logic [1:0] act_chunk_buf [0:NUM_CHUNK-1];
    logic [1:0]    mode_buf;
    logic [ACC_VEC_W-1:0] in_data_buf;

    logic          valid_cs  [0:ACT_PIPE_STAGES-1];
    logic [1:0]    act_cs    [0:ACT_PIPE_STAGES-1];
    logic [1:0]    mode_cs   [0:ACT_PIPE_STAGES-1];
    logic [ACC_VEC_W-1:0] matrix_cs [0:ACT_PIPE_STAGES-2];
    (* dont_touch = "true" *) logic [1:0] act_apply_cs  [0:NUM_CHUNK-1];
    (* dont_touch = "true" *) logic [1:0] mode_apply_cs [0:NUM_CHUNK-1];

    // Pipeline stages (after input_buf)：
    //   Stage 0: pair sums per chunk×p×half = 16×2 (act-MUX + 1 add level，s17)
    //   Stage 1: psum_cs = pair_a + pair_b (1 add level，s18)。切半原本 stage-0 加法樹深度。
    //   Stage 2: thresholds from psum (RAT/CAT 2-input；BAT 4-input)
    //   Stage 3: apply activation
    s16_t          pair_a_lhs_cs [0:NUM_CHUNK-1][0:3];
    s16_t          pair_a_rhs_cs [0:NUM_CHUNK-1][0:3];
    s16_t          pair_b_lhs_cs [0:NUM_CHUNK-1][0:3];
    s16_t          pair_b_rhs_cs [0:NUM_CHUNK-1][0:3];
    s17_t          pair_a_cs [0:NUM_CHUNK-1][0:3];  // e0+e1
    s17_t          pair_b_cs [0:NUM_CHUNK-1][0:3];  // e2+e3
    s18_t          psum_cs   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_cs  [0:NUM_CHUNK-1];
    s16_t          thr_b_cs  [0:NUM_CHUNK-1];
    s16_t          pair_a_lhs_ns [0:NUM_CHUNK-1][0:3];
    s16_t          pair_a_rhs_ns [0:NUM_CHUNK-1][0:3];
    s16_t          pair_b_lhs_ns [0:NUM_CHUNK-1][0:3];
    s16_t          pair_b_rhs_ns [0:NUM_CHUNK-1][0:3];
    s17_t          pair_a_ns [0:NUM_CHUNK-1][0:3];
    s17_t          pair_b_ns [0:NUM_CHUNK-1][0:3];
    s18_t          psum_ns   [0:NUM_CHUNK-1][0:3];
    s16_t          thr_a_ns  [0:NUM_CHUNK-1];
    s16_t          thr_b_ns  [0:NUM_CHUNK-1];
    logic [OUT_VEC_W-1:0] apply_ns;

    s20_t          part_sum01;
    s20_t          part_sum23;

    assign out_valid = valid_cs[ACT_PIPE_STAGES-1];
    function automatic s16_t get_s16(input logic [ACC_VEC_W-1:0] vec, input integer idx);
        get_s16 = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic s18_t ext18(input s16_t value);
        ext18 = {{2{value[ACC_W-1]}}, value};
    endfunction

    // Half pair sum：把原本 chunk_partial_sum 4-element 切成 2 個 2-element pair。
    //   half=0 → e0+e1；half=1 → e2+e3。stage 0 register 兩個 pair，stage 1 再合併。
    //   每個 pair 是 s16+s16 = s17，最後 s17+s17=s18 跟原 psum 同 range。
    function automatic s17_t chunk_half_sum(
        input logic [ACC_VEC_W-1:0] matrix,
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
            a = s16_t'(0);
            b = s16_t'(0);

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
                    a = s16_t'(0);
                    b = s16_t'(0);
                end
            endcase

            chunk_half_sum = s17_t'(a) + s17_t'(b);
        end
    endfunction

    function automatic s16_t chunk_half_value(
        input logic [ACC_VEC_W-1:0] matrix,
        input logic [1:0]    act_sel,
        input integer        chunk,
        input integer        p,
        input integer        half,
        input integer        elem
    );
        integer row;
        integer col;
        integer base_row;
        integer base_col;
        integer blk_row;
        begin
            chunk_half_value = s16_t'(0);

            case (act_sel)
                2'b01: begin  // RAT
                    row = (chunk * 2) + (p / 2);
                    col = (p % 2) * 4 + (half * 2);
                    chunk_half_value =
                        get_s16(matrix, (row * ROW_ELEM) + col + elem);
                end

                2'b10: begin  // CAT
                    col = (chunk * 2) + (p / 2);
                    row = (p % 2) * 4 + (half * 2);
                    chunk_half_value =
                        get_s16(matrix, ((row + elem) * ROW_ELEM) + col);
                end

                2'b11: begin  // BAT
                    base_row = (chunk / 2) * 4;
                    base_col = (chunk % 2) * 4;
                    blk_row  = base_row + p;
                    col      = base_col + (half * 2);
                    chunk_half_value =
                        get_s16(matrix, (blk_row * ROW_ELEM) + col + elem);
                end

                default: begin
                    chunk_half_value = s16_t'(0);
                end
            endcase
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
                default: thr_for_position = s16_t'(0);
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
                    select_threshold = s16_t'(0);
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
                        activate_value = (value < 0) ? s16_t'(0) : value;
                    end
                    else begin
                        activate_value = (value < threshold) ? (value >>> 3) : value;
                    end
                end
            endcase
        end
    endfunction

    function automatic logic [OUT_W-1:0] activate_value_out(
        input s16_t       value,
        input logic [1:0] act_sel,
        input logic [1:0] mode_sel,
        input s16_t       threshold
    );
        s16_t activated;
        begin
            activated = activate_value(value, act_sel, mode_sel, threshold);
            activate_value_out = activated[OUT_W-1:0];
        end
    endfunction

    // Stage 0 combinational: 16 chunks×p pair sums (e0+e1, e2+e3) — act-MUX + 1 add level
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int p = 0; p < 4; p++) begin
                pair_a_lhs_ns[chunk][p] =
                    chunk_half_value(in_data_buf, act_chunk_buf[chunk],
                                     chunk, p, 0, 0);
                pair_a_rhs_ns[chunk][p] =
                    chunk_half_value(in_data_buf, act_chunk_buf[chunk],
                                     chunk, p, 0, 1);
                pair_b_lhs_ns[chunk][p] =
                    chunk_half_value(in_data_buf, act_chunk_buf[chunk],
                                     chunk, p, 1, 0);
                pair_b_rhs_ns[chunk][p] =
                    chunk_half_value(in_data_buf, act_chunk_buf[chunk],
                                     chunk, p, 1, 1);
            end
        end
    end

    // Stage 1 combinational: combine pair_a + pair_b → psum (1 add level)
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            for (int p = 0; p < 4; p++) begin
                pair_a_ns[chunk][p] = s17_t'(pair_a_lhs_cs[chunk][p]) +
                                      s17_t'(pair_a_rhs_cs[chunk][p]);
                pair_b_ns[chunk][p] = s17_t'(pair_b_lhs_cs[chunk][p]) +
                                      s17_t'(pair_b_rhs_cs[chunk][p]);
                psum_ns[chunk][p] = s18_t'(pair_a_cs[chunk][p]) +
                                    s18_t'(pair_b_cs[chunk][p]);
            end
        end
    end

    // Stage 2 combinational: combine the registered partials into thresholds.
    // RAT/CAT keep two thresholds per chunk (one per row/col); BAT shares one.
    always_comb begin
        for (int chunk = 0; chunk < NUM_CHUNK; chunk++) begin
            part_sum01 = s20_t'(psum_cs[chunk][0]) +
                         s20_t'(psum_cs[chunk][1]);
            part_sum23 = s20_t'(psum_cs[chunk][2]) +
                         s20_t'(psum_cs[chunk][3]);
            case (act_cs[2])
                2'b01, 2'b10: begin
                    thr_a_ns[chunk] = part_sum01 >>> 3;
                    thr_b_ns[chunk] = part_sum23 >>> 3;
                end
                2'b11: begin
                    thr_a_ns[chunk] = (part_sum01 + part_sum23) >>> 4;
                    thr_b_ns[chunk] = thr_a_ns[chunk];
                end
                default: begin
                    thr_a_ns[chunk] = s16_t'(0);
                    thr_b_ns[chunk] = s16_t'(0);
                end
            endcase
        end
    end

    // Stage 3 combinational: apply activation per output position（element-centric）。
    // 每個 position 的 read/write 位址都是常數，act_sel 只在 threshold MUX 出現。
    // 比原 (chunk, lane)→apply_idx 的 cross-bar 寫入結構淺。
    always_comb begin
        for (int pos = 0; pos < MAT_SIZE; pos++) begin
            apply_ns[OUT_VEC_W - 1 - (pos * OUT_W) -: OUT_W] =
                activate_value_out(
                    get_s16(matrix_cs[3], pos),
                    act_apply_cs[pos / CHUNK_SIZE],
                    mode_apply_cs[pos / CHUNK_SIZE],
                    thr_for_position(act_apply_cs[pos / CHUNK_SIZE],
                                     pos, thr_a_cs, thr_b_cs));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_buf <= 1'b0;
            for (int i = 0; i < ACT_PIPE_STAGES; i++) begin
                valid_cs[i]  <= 1'b0;
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
                    pair_a_lhs_cs[c][p] <= pair_a_lhs_ns[c][p];
                    pair_a_rhs_cs[c][p] <= pair_a_rhs_ns[c][p];
                    pair_b_lhs_cs[c][p] <= pair_b_lhs_ns[c][p];
                    pair_b_rhs_cs[c][p] <= pair_b_rhs_ns[c][p];
                end
            end

            // Stage 1: pair_a + pair_b → psum (1 add level)，carry matrix。
            valid_cs[1]  <= valid_cs[0];
            act_cs[1]    <= act_cs[0];
            mode_cs[1]   <= mode_cs[0];
            matrix_cs[1] <= matrix_cs[0];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) begin
                    pair_a_cs[c][p] <= pair_a_ns[c][p];
                    pair_b_cs[c][p] <= pair_b_ns[c][p];
                end
            end

            // Stage 2: combine partials into thresholds, carry the matrix.
            valid_cs[2]  <= valid_cs[1];
            act_cs[2]    <= act_cs[1];
            mode_cs[2]   <= mode_cs[1];
            matrix_cs[2] <= matrix_cs[1];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                for (int p = 0; p < 4; p++) psum_cs[c][p] <= psum_ns[c][p];
            end

            // Stage 3: threshold and source carry.
            valid_cs[3]  <= valid_cs[2];
            act_cs[3]    <= act_cs[2];
            mode_cs[3]   <= mode_cs[2];
            matrix_cs[3] <= matrix_cs[2];
            for (int c = 0; c < NUM_CHUNK; c++) begin
                act_apply_cs[c]  <= act_cs[2];
                mode_apply_cs[c] <= mode_cs[2];
                thr_a_cs[c]      <= thr_a_ns[c];
                thr_b_cs[c]      <= thr_b_ns[c];
            end

            // Stage 4: apply activation and narrow to the PoT input width.
            valid_cs[4]  <= valid_cs[3];
            act_cs[4]    <= act_cs[3];
            mode_cs[4]   <= mode_cs[3];
            out_data     <= apply_ns;
        end
    end
endmodule


module PoT_5Stage_Parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
)(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam int MAX_GROUP = 16;
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] s16_t;
    typedef logic [ACC_W-1:0] mag_t;

    // Keep one full-width source copy; later alignment is only 256-bit quant data.
    logic          in_valid_cs;
    logic          max0_valid_cs;
    logic          max1_valid_cs;
    logic          max2_valid_cs;
    logic [ACC_VEC_W-1:0] src_data_cs;
    mag_t          max0_cs [0:MAX_GROUP-1];
    mag_t          max_mask_ns;
    logic [255:0]  quant_cs;
    logic [255:0]  quant_pipe_cs;
    logic [255:0]  quant_pipe2_cs;

    function automatic s16_t get_s16(input logic [ACC_VEC_W-1:0] vec, input integer idx);
        get_s16 = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic logic [ACC_W-1:0] abs16(input s16_t value);
        abs16 = (value < 0) ? -value : value;
    endfunction

    function automatic mag_t mag_or4(
        input mag_t a,
        input mag_t b,
        input mag_t c,
        input mag_t d
    );
        mag_or4 = a | b | c | d;
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

    function automatic s4_t quant_lane(
        input s16_t                  value,
        input logic [SHIFT_W-1:0]    shift
    );
        begin
            unique case (shift)
                4'd0:    quant_lane = s4_t'(value[3:0]);
                4'd1:    quant_lane = s4_t'(value[4:1]);
                4'd2:    quant_lane = s4_t'(value[5:2]);
                4'd3:    quant_lane = s4_t'(value[6:3]);
                4'd4:    quant_lane = s4_t'(value[7:4]);
                4'd5:    quant_lane = s4_t'(value[8:5]);
                4'd6:    quant_lane = s4_t'(value[9:6]);
                4'd7:    quant_lane = s4_t'(value[10:7]);
                4'd8:    quant_lane = s4_t'(value[11:8]);
                4'd9:    quant_lane = s4_t'(value[12:9]);
                4'd10:   quant_lane = s4_t'(value[13:10]);
                4'd11:   quant_lane = s4_t'(value[14:11]);
                4'd12:   quant_lane = s4_t'(value[15:12]);
                default: quant_lane = s4_t'({value[15], value[15], value[14], value[13]});
            endcase
        end
    endfunction

    // Quantize all 64 elements in one stage. pot_shift is derived from the
    // global magnitude mask, so the shifted value already fits in signed 4b.
    function automatic logic [255:0] quant_all(
        input logic [ACC_VEC_W-1:0] src_data,
        input logic [SHIFT_W-1:0]   shift
    );
        begin
            quant_all = 256'd0;
            for (int idx = 0; idx < MAT_SIZE; idx++) begin
                quant_all[255 - (idx * 4) -: 4] =
                    quant_lane(get_s16(src_data, idx), shift);
            end
        end
    endfunction

    assign max_mask_ns = mag_or4(
        mag_or4(max0_cs[0],  max0_cs[1],  max0_cs[2],  max0_cs[3]),
        mag_or4(max0_cs[4],  max0_cs[5],  max0_cs[6],  max0_cs[7]),
        mag_or4(max0_cs[8],  max0_cs[9],  max0_cs[10], max0_cs[11]),
        mag_or4(max0_cs[12], max0_cs[13], max0_cs[14], max0_cs[15])
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_cs   <= 1'b0;
            max0_valid_cs <= 1'b0;
            max1_valid_cs <= 1'b0;
            max2_valid_cs <= 1'b0;
            out_valid     <= 1'b0;
        end
        else begin
            in_valid_cs   <= in_valid;
            max0_valid_cs <= in_valid_cs;
            max1_valid_cs <= max0_valid_cs;
            max2_valid_cs <= max1_valid_cs;
            out_valid     <= max2_valid_cs;
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid) begin
            src_data_cs <= in_data;

            for (int g = 0; g < MAX_GROUP; g++) begin
                max0_cs[g] <= mag_or4(abs16(get_s16(in_data, (g * 4) + 0)),
                                      abs16(get_s16(in_data, (g * 4) + 1)),
                                      abs16(get_s16(in_data, (g * 4) + 2)),
                                      abs16(get_s16(in_data, (g * 4) + 3)));
            end
        end

        if (in_valid_cs) begin
            quant_cs <= quant_all(src_data_cs, pot_shift(max_mask_ns));
        end

        if (max0_valid_cs) begin
            quant_pipe_cs <= quant_cs;
        end

        if (max1_valid_cs) begin
            quant_pipe2_cs <= quant_pipe_cs;
        end

        if (max2_valid_cs) begin
            out_data <= quant_pipe2_cs;
        end
    end

endmodule


module Matrix_Max_3Stage_Parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
)(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_abs,    // 64 lanes unsigned abs
    output logic          out_valid,
    output logic [$clog2(ACC_W)-1:0] out_shift  // PoT 所需的 arithmetic-shift 量（已算好）
);

    // PoT 只需要 max_abs 的 MSB 位置 → arithmetic-shift 量。
    //   max_abs 的 MSB == OR_reduction(abs[]) 的 MSB（max 是其中一員），
    //   所以 64-input bitwise OR 等價於 max 給 PoT。
    // Stage 1: 64-input bitwise OR (per bit 6-level OR tree ≈ 0.6 ns)
    // Stage 2: pot_shift priority-encode（從原本 PoT 端 1.26 ns critical path 搬到這）
    // Stage 3: shift 量 register 用來 fanout 給 PoT 的 quant_all（64 lanes）
    // 介面從 16-bit max 改成 4-bit shift：上游 1024-bit→16-bit→4-bit 還省 24 flops。
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    logic        st1_valid;
    logic        st2_valid;
    logic [ACC_W-1:0] or_ns;
    logic [ACC_W-1:0] or_cs;
    logic [SHIFT_W-1:0] shift_ns;
    logic [SHIFT_W-1:0] shift_cs;

    function automatic logic [ACC_W-1:0] get_u16(
        input logic [ACC_VEC_W-1:0] vec,
        input integer idx
    );
        get_u16 = vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W];
    endfunction

    // pot_shift：找 max_abs 最高位的 set bit，回傳 (msb - LOG2_OUT_MAX) clamped 至 0。
    //   OUT_MAX = 7 → LOG2_OUT_MAX = 2，shift = max(msb - 2, 0)
    function automatic logic [SHIFT_W-1:0] pot_shift(input logic [ACC_W-1:0] max_abs);
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

    // Stage 1: 64-input bitwise OR
    always_comb begin
        or_ns = '0;
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
