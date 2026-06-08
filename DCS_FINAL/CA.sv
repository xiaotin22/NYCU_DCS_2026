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

    logic [1:0] fast_rd_req_cnt_cs;
    logic [6:0] fast_group_result_cnt_cs;
    logic fast_result_half_cs;
    logic [6:0] fast_pre_result_cnt_cs;
    logic fast_pre_write_half_cs;
    logic fast_wr_pending_cs;
    logic fast_pre_wr_issued_cs;

    logic att_param_phase_cs;
    logic att_rd_issued_cs;
    logic [7:0] att_rd_word_cnt_cs;
    logic att_read_half_cs;
    logic att_result_half_cs;
    logic [6:0] att_pre_result_cnt_cs;
    logic att_pre_write_half_cs;
    logic [6:0] att_group_result_cnt_cs;
    logic att_wr_pending_cs;
    logic att_pre_wr_issued_cs;

    logic job_start;
    logic fast_rd_req;
    logic [ADDR_W-1:0] fast_rd_addr;
    logic fast_rd_fire;
    logic fast_first_pre_result;
    logic fast_wr_req;
    logic [ADDR_W-1:0] fast_wr_addr;
    logic fast_wr_fire;
    logic att_first_rd_req;
    logic att_read_rd_req;
    logic att_half_rd_req;
    logic att_rd_req;
    logic [ADDR_W-1:0] att_rd_addr;
    logic att_rd_fire;
    logic att_rd_data_fire;
    logic att_result_active;
    logic att_first_pre_result;
    logic att_wr_req;
    logic [ADDR_W-1:0] att_wr_addr;
    logic att_wr_fire;
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
    assign fast_first_pre_result = (state_cs == S_FAST_RUN) &&
                                   datapath_result_pre_valid &&
                                   (fast_pre_result_cnt_cs == 7'd0) &&
                                   !fast_pre_wr_issued_cs;
    assign fast_wr_req        = (state_cs == S_FAST_RUN) &&
                                (fast_wr_pending_cs || fast_first_pre_result);
    assign fast_wr_addr       = fast_pre_write_half_cs ? HALF_ADDR : '0;
    assign fast_wr_fire       = fast_wr_req && wr_ready;

    assign att_first_rd_req    = (state_cs == S_ATT_PARAM) && in_valid &&
                                 att_param_phase_cs;
    assign att_read_rd_req     = (state_cs == S_ATT_READ) && !att_rd_issued_cs;
    assign att_half_rd_req     = (state_cs == S_ATT_WAIT) &&
                                 !att_read_half_cs &&
                                 att_pre_wr_issued_cs;
    assign att_rd_req          = att_first_rd_req || att_read_rd_req || att_half_rd_req;
    assign att_rd_addr         = (att_half_rd_req || att_read_half_cs) ? HALF_ADDR : '0;
    assign att_rd_fire         = att_rd_req && rd_ready;
    assign att_rd_data_fire    = (state_cs == S_ATT_READ) && rd_valid &&
                                 (att_rd_word_cnt_cs < 8'd128);
    assign att_result_active   = (state_cs == S_ATT_READ) || (state_cs == S_ATT_WAIT);
    assign att_first_pre_result = att_result_active &&
                                  datapath_result_pre_valid &&
                                  (att_pre_result_cnt_cs == 7'd0) &&
                                  !att_pre_wr_issued_cs;
    assign att_wr_req          = att_result_active &&
                                 (att_wr_pending_cs || att_first_pre_result);
    assign att_wr_addr         = att_pre_write_half_cs ? HALF_ADDR : '0;
    assign att_wr_fire         = att_wr_req && wr_ready;
    assign rd_cmd_req          = fast_rd_req || att_rd_req;
    assign rd_cmd_addr         = fast_rd_req ? fast_rd_addr : att_rd_addr;
    assign rd_cmd_fire         = rd_cmd_req && rd_ready;
    assign wr_cmd_req          = fast_wr_req || att_wr_req;
    assign wr_cmd_addr         = fast_wr_req ? fast_wr_addr : att_wr_addr;
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
            state_cs                 <= S_IDLE;
            exec_op                  <= 2'd0;
            exec_act                 <= 2'd0;
            exec_param               <= 256'd0;
            exec_weight_k            <= 256'd0;
            exec_weight_v            <= 256'd0;
            fast_rd_req_cnt_cs       <= 2'd0;
            fast_group_result_cnt_cs <= 7'd0;
            fast_result_half_cs      <= 1'b0;
            fast_pre_result_cnt_cs   <= 7'd0;
            fast_pre_write_half_cs   <= 1'b0;
            fast_wr_pending_cs       <= 1'b0;
            fast_pre_wr_issued_cs    <= 1'b0;
            att_param_phase_cs       <= 1'b0;
            att_rd_issued_cs         <= 1'b0;
            att_rd_word_cnt_cs       <= 8'd0;
            att_read_half_cs         <= 1'b0;
            att_result_half_cs       <= 1'b0;
            att_pre_result_cnt_cs    <= 7'd0;
            att_pre_write_half_cs    <= 1'b0;
            att_group_result_cnt_cs  <= 7'd0;
            att_wr_pending_cs        <= 1'b0;
            att_pre_wr_issued_cs     <= 1'b0;
        end
        else begin
            if (fast_first_pre_result) begin
                fast_wr_pending_cs <= 1'b1;
            end
            if (fast_wr_fire) begin
                fast_wr_pending_cs    <= 1'b0;
                fast_pre_wr_issued_cs <= 1'b1;
            end

            if (att_first_pre_result) begin
                att_wr_pending_cs <= 1'b1;
            end
            if (att_wr_fire) begin
                att_wr_pending_cs    <= 1'b0;
                att_pre_wr_issued_cs <= 1'b1;
            end

            case (state_cs)
                S_IDLE: begin
                    if (job_start) begin
                        exec_op    <= op;
                        exec_act   <= act;
                        exec_param <= param;

                        fast_rd_req_cnt_cs       <= fast_rd_fire ? 2'd1 : 2'd0;
                        fast_group_result_cnt_cs <= 7'd0;
                        fast_result_half_cs      <= 1'b0;
                        fast_pre_result_cnt_cs   <= 7'd0;
                        fast_pre_write_half_cs   <= 1'b0;
                        fast_wr_pending_cs       <= 1'b0;
                        fast_pre_wr_issued_cs    <= 1'b0;

                        att_param_phase_cs       <= 1'b0;
                        att_rd_issued_cs         <= 1'b0;
                        att_rd_word_cnt_cs       <= 8'd0;
                        att_read_half_cs         <= 1'b0;
                        att_result_half_cs       <= 1'b0;
                        att_pre_result_cnt_cs    <= 7'd0;
                        att_pre_write_half_cs    <= 1'b0;
                        att_group_result_cnt_cs  <= 7'd0;
                        att_wr_pending_cs        <= 1'b0;
                        att_pre_wr_issued_cs     <= 1'b0;

                        state_cs <= op[1] ? S_ATT_PARAM : S_FAST_RUN;
                    end
                end

                S_FAST_RUN: begin
                    if (fast_rd_fire) begin
                        fast_rd_req_cnt_cs <= fast_rd_req_cnt_cs + 1'b1;
                    end

                    if (datapath_result_pre_valid) begin
                        if (fast_pre_result_cnt_cs == 7'd127) begin
                            fast_pre_result_cnt_cs <= 7'd0;
                            if (!fast_pre_write_half_cs) begin
                                fast_pre_write_half_cs <= 1'b1;
                                fast_pre_wr_issued_cs  <= 1'b0;
                                fast_wr_pending_cs     <= 1'b0;
                            end
                        end
                        else begin
                            fast_pre_result_cnt_cs <= fast_pre_result_cnt_cs + 1'b1;
                        end
                    end

                    if (datapath_result_valid) begin
                        if (fast_group_result_cnt_cs == 7'd127) begin
                            if (fast_result_half_cs) begin
                                state_cs <= S_IDLE;
                            end
                            else begin
                                fast_result_half_cs      <= 1'b1;
                                fast_group_result_cnt_cs <= 7'd0;
                            end
                        end
                        else begin
                            fast_group_result_cnt_cs <= fast_group_result_cnt_cs + 1'b1;
                        end
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (!att_param_phase_cs) begin
                            exec_weight_k      <= param;
                            att_param_phase_cs <= 1'b1;
                        end
                        else begin
                            exec_weight_v            <= param;
                            att_rd_issued_cs         <= att_rd_fire;
                            att_rd_word_cnt_cs       <= 8'd0;
                            att_read_half_cs         <= 1'b0;
                            att_result_half_cs       <= 1'b0;
                            att_pre_result_cnt_cs    <= 7'd0;
                            att_pre_write_half_cs    <= 1'b0;
                            att_group_result_cnt_cs  <= 7'd0;
                            att_pre_wr_issued_cs     <= 1'b0;
                            att_wr_pending_cs        <= 1'b0;
                            state_cs                 <= S_ATT_READ;
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
                        att_read_half_cs  <= 1'b1;
                        att_rd_issued_cs  <= 1'b1;
                        att_rd_word_cnt_cs <= 8'd0;
                        state_cs          <= S_ATT_READ;
                    end
                end

                default: begin
                    state_cs <= S_IDLE;
                end
            endcase

            if (att_result_active && datapath_result_pre_valid) begin
                if (att_pre_result_cnt_cs == 7'd127) begin
                    att_pre_result_cnt_cs <= 7'd0;
                    if (!att_pre_write_half_cs) begin
                        att_pre_write_half_cs <= 1'b1;
                        att_pre_wr_issued_cs  <= 1'b0;
                        att_wr_pending_cs     <= 1'b0;
                    end
                end
                else begin
                    att_pre_result_cnt_cs <= att_pre_result_cnt_cs + 1'b1;
                end
            end

            if (att_result_active && datapath_result_valid) begin
                if (att_group_result_cnt_cs == 7'd127) begin
                    att_group_result_cnt_cs <= 7'd0;
                    if (att_result_half_cs) begin
                        state_cs <= S_IDLE;
                    end
                    else begin
                        att_result_half_cs <= 1'b1;
                    end
                end
                else begin
                    att_group_result_cnt_cs <= att_group_result_cnt_cs + 1'b1;
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
    localparam int RESULT_PRE_PIPE = 4;


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
    logic [1023:0] norm_mult_data;

    logic att_in_valid;
    logic att_core_valid;
    logic [1023:0] att_core_data;

    logic act_in_valid;
    logic [1023:0] act_in_data;
    datapath_tag_t act_in_tag;
    logic act_valid;
    logic [1023:0] act_data;

    logic pot_in_valid;
    logic [1023:0] pot_in_data;
    datapath_tag_t pot_in_tag;
    logic pot_valid;
    logic [255:0] pot_data;

    datapath_tag_t act_tag_cs [0:4];
    datapath_tag_t pot_tag_cs [0:4];

    logic         result_pre_pipe_cs [0:RESULT_PRE_PIPE-1];
    logic [255:0] wr_data_skid_cs;
    logic         wr_data_skid_valid_cs;

    assign norm_in_valid = issue_valid_cs && (issue_mode_cs == IM_NORM);
    assign att_in_valid  = issue_valid_cs && (issue_mode_cs == IM_ATT);

    assign act_in_valid = norm_mult_valid || att_core_valid;
    assign act_in_data  = att_core_valid ? att_core_data : norm_mult_data;
    assign act_in_tag   = att_core_valid ? DT_ATT :
                          (norm_mult_valid ? DT_NORM : DT_NONE);

    assign pot_in_valid = act_valid && (act_tag_cs[4] != DT_NONE);
    assign pot_in_data  = act_data;
    assign pot_in_tag   = act_tag_cs[4];

    assign result_valid = pot_valid && (pot_tag_cs[4] != DT_NONE);
    assign result_pre_valid = result_pre_pipe_cs[RESULT_PRE_PIPE-1];
    assign wr_data      = wr_data_skid_valid_cs ? wr_data_skid_cs : pot_data;

    Mult_5Stage_Parallel u_norm_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (op),
        .b_transpose (1'b0),
        .in_valid    (norm_in_valid),
        .in_data_A   (rd_data_cs),
        .in_data_B   (param),
        .out_valid   (norm_mult_valid),
        .out_data    (norm_mult_data)
    );

    ATT_Stream_Core u_att_stream_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (att_in_valid),
        .is_mha    (op[0]),
        .src_data  (rd_data_cs),
        .wq_data   (param),
        .wk_data   (weight_k),
        .wv_data   (weight_v),
        .out_valid (att_core_valid),
        .out_data  (att_core_data)
    );

    ACT_5Stage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act),
        .act_mode  (ACT_USER),
        .in_data   (act_in_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    PoT_5Stage_Parallel u_pot (
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
            for (int i = 0; i < 5; i++) begin
                act_tag_cs[i] <= DT_NONE;
                pot_tag_cs[i] <= DT_NONE;
            end
        end
        else begin
            issue_valid_cs <= issue_valid;
            issue_mode_cs  <= issue_valid ? issue_mode : IM_NONE;
            rd_data_cs     <= rd_data;

            act_tag_cs[0] <= act_in_valid ? act_in_tag : DT_NONE;
            for (int i = 1; i < 5; i++) begin
                act_tag_cs[i] <= act_tag_cs[i - 1];
            end

            pot_tag_cs[0] <= pot_in_valid ? pot_in_tag : DT_NONE;
            for (int i = 1; i < 5; i++) begin
                pot_tag_cs[i] <= pot_tag_cs[i - 1];
            end

            result_pre_pipe_cs[0] <= act_in_valid;
            for (int i = 1; i < RESULT_PRE_PIPE; i++) begin
                result_pre_pipe_cs[i] <= result_pre_pipe_cs[i - 1];
            end

            if (wr_data_skid_valid_cs) begin
                if (wr_valid) begin
                    if (result_valid) begin
                        wr_data_skid_cs <= pot_data;
                    end
                    else begin
                        wr_data_skid_valid_cs <= 1'b0;
                    end
                end
            end
            else begin
                if (result_valid && !wr_valid) begin
                    wr_data_skid_cs       <= pot_data;
                    wr_data_skid_valid_cs <= 1'b1;
                end
            end

            out_valid <= result_valid;
            if (result_valid) begin
                out_data <= pot_data[31:0];
            end
        end
    end

endmodule

module ATT_Stream_Core #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 11
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_mha,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    input  logic [255:0]         wk_data,
    input  logic [255:0]         wv_data,
    output logic                 out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data
);

    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int PROJ_W = 11;
    localparam int PROJ_VEC_W = MAT_SIZE * PROJ_W;

    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic [PROJ_VEC_W-1:0] proj_vec_t;
    localparam int SCORE_BUS_W = MAT_SIZE * SCORE_ELEM_W;

    logic qkv_valid_s0_cs;
    logic [255:0] qkv_src_s0_cs;
    logic qkv_mha_s0_cs;
    logic qkv_mha_s1_cs;
    logic qkv_mha_s2_cs;
    logic qkv_mha_s3_cs;
    logic quant_mha_s0_cs;
    logic quant_mha_s1_cs;
    logic quant_mha_s2_cs;
    logic quant_mha_s3_cs;
    logic q_matmul_valid;
    logic k_matmul_valid;
    logic v_matmul_valid;
    logic matmul_valid;
    proj_vec_t q_comp_data;
    proj_vec_t k_comp_data;
    proj_vec_t v_comp_data;

    logic quant_valid_cs;
    logic quant_mha_cs;
    logic q_quant_valid;
    logic k_quant_valid;
    logic v_quant_valid;
    logic qk_quant_valid_cs;
    logic [255:0] q_word_cs;
    logic [255:0] k_word_cs;
    logic [255:0] v_word_cs;
    logic [255:0] q_word_align_cs;
    logic [255:0] k_word_align_cs;

    logic score_pipe_valid;
    logic score_pipe_mha;
    logic [255:0] score_pipe_v;
    logic [SCORE_BUS_W-1:0] score0_data;
    logic [SCORE_BUS_W-1:0] score1_data;
    logic final_valid;
    acc_vec_t final_data;

    ATT_QKV_Matmul_3Stage #(
        .PROJ_W   (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_q_matmul (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (qkv_valid_s0_cs),
        .in_data_A (qkv_src_s0_cs),
        .in_data_B (wq_data),
        .out_valid (q_matmul_valid),
        .out_data  (q_comp_data)
    );

    ATT_QKV_Matmul_3Stage #(
        .PROJ_W   (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_k_matmul (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (qkv_valid_s0_cs),
        .in_data_A (qkv_src_s0_cs),
        .in_data_B (wk_data),
        .out_valid (k_matmul_valid),
        .out_data  (k_comp_data)
    );

    ATT_QKV_Matmul_3Stage #(
        .PROJ_W   (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_v_matmul (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (qkv_valid_s0_cs),
        .in_data_A (qkv_src_s0_cs),
        .in_data_B (wv_data),
        .out_valid (v_matmul_valid),
        .out_data  (v_comp_data)
    );

    ATT_Quant_3Stage #(
        .ACC_W    (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_q_quant (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (matmul_valid),
        .in_data   (q_comp_data),
        .out_valid (q_quant_valid),
        .out_data  (q_word_cs)
    );

    ATT_Quant_3Stage #(
        .ACC_W    (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_k_quant (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (matmul_valid),
        .in_data   (k_comp_data),
        .out_valid (k_quant_valid),
        .out_data  (k_word_cs)
    );

    ATT_Quant_4Stage #(
        .ACC_W    (PROJ_W),
        .MAT_SIZE (MAT_SIZE)
    ) u_att_v_quant (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (matmul_valid),
        .in_data   (v_comp_data),
        .out_valid (v_quant_valid),
        .out_data  (v_word_cs)
    );

    ATT_Score_8Tap #(
        .MAT_SIZE     (MAT_SIZE),
        .SCORE_ELEM_W (SCORE_ELEM_W)
    ) u_att_score_8tap (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (quant_valid_cs),
        .is_mha      (quant_mha_cs),
        .q_data      (q_word_align_cs),
        .k_data      (k_word_align_cs),
        .v_data      (v_word_cs),
        .out_valid   (score_pipe_valid),
        .out_mha     (score_pipe_mha),
        .out_v_data  (score_pipe_v),
        .score0_data (score0_data),
        .score1_data (score1_data)
    );

    ATT_Final_Booth_Acc #(
        .ACC_W        (ACC_W),
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
        .out_data    (final_data)
    );

    assign matmul_valid = q_matmul_valid && k_matmul_valid && v_matmul_valid;
    assign quant_valid_cs = qk_quant_valid_cs && v_quant_valid;
    assign quant_mha_cs = quant_mha_s3_cs;
    assign out_valid = final_valid;
    assign out_data  = final_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qkv_valid_s0_cs <= 1'b0;
            qkv_src_s0_cs   <= 256'd0;
            qkv_mha_s0_cs  <= 1'b0;
            qkv_mha_s1_cs  <= 1'b0;
            qkv_mha_s2_cs  <= 1'b0;
            qkv_mha_s3_cs  <= 1'b0;
            quant_mha_s0_cs <= 1'b0;
            quant_mha_s1_cs <= 1'b0;
            quant_mha_s2_cs <= 1'b0;
            quant_mha_s3_cs <= 1'b0;
            qk_quant_valid_cs <= 1'b0;
        end
        else begin
            qkv_valid_s0_cs <= in_valid;
            if (in_valid) begin
                qkv_src_s0_cs <= src_data;
            end

            qkv_mha_s0_cs   <= qkv_valid_s0_cs ? is_mha : 1'b0;
            qkv_mha_s1_cs   <= qkv_mha_s0_cs;
            qkv_mha_s2_cs   <= qkv_mha_s1_cs;
            qkv_mha_s3_cs   <= qkv_mha_s2_cs;
            quant_mha_s0_cs <= matmul_valid ? qkv_mha_s3_cs : 1'b0;
            quant_mha_s1_cs <= quant_mha_s0_cs;
            quant_mha_s2_cs <= quant_mha_s1_cs;
            quant_mha_s3_cs <= quant_mha_s2_cs;

            qk_quant_valid_cs <= q_quant_valid && k_quant_valid;
            if (q_quant_valid && k_quant_valid) begin
                q_word_align_cs <= q_word_cs;
                k_word_align_cs <= k_word_cs;
            end
        end
    end

endmodule


module ATT_QKV_Matmul_3Stage #(
    parameter int PROJ_W = 11,
    parameter int MAT_SIZE = 64
)(
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           in_valid,
    input  logic [255:0]                   in_data_A,
    input  logic [255:0]                   in_data_B,
    output logic                           out_valid,
    output logic [(MAT_SIZE*PROJ_W)-1:0]   out_data
);

    localparam int ROW_ELEM = 8;
    localparam int NUM_PAIR = 4;
    localparam int PROJ_VEC_W = MAT_SIZE * PROJ_W;

    typedef logic signed [3:0]          s4_t;
    typedef logic signed [7:0]          prod_t;
    typedef logic signed [8:0]          pair_t;
    typedef logic signed [PROJ_W-1:0]   proj_t;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic [255:0] in_data_A_cs;
    logic [255:0] in_data_B_cs;
    prod_t prod_cs [0:MAT_SIZE-1][0:ROW_ELEM-1];
    prod_t prod_ns [0:MAT_SIZE-1][0:ROW_ELEM-1];
    pair_t pair_cs [0:MAT_SIZE-1][0:NUM_PAIR-1];
    pair_t pair_ns [0:MAT_SIZE-1][0:NUM_PAIR-1];
    proj_t sum_ns  [0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    prod_ns[out_idx][tap] =
                        prod_t'($signed(get_s4(in_data_A_cs, (row * ROW_ELEM) + tap)) *
                                $signed(get_s4(in_data_B_cs, (tap * ROW_ELEM) + lane)));
                end

                for (int pair_idx = 0; pair_idx < NUM_PAIR; pair_idx++) begin
                    int tap0;
                    int tap1;

                    tap0 = pair_idx * 2;
                    tap1 = tap0 + 1;
                    pair_ns[out_idx][pair_idx] =
                        pair_t'(prod_cs[out_idx][tap0]) +
                        pair_t'(prod_cs[out_idx][tap1]);
                end
            end
        end

        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_ns[i] =
                proj_t'(proj_t'(pair_cs[i][0]) + proj_t'(pair_cs[i][1])) +
                proj_t'(proj_t'(pair_cs[i][2]) + proj_t'(pair_cs[i][3]));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            out_valid   <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            out_valid   <= valid_s2_cs;

            if (in_valid) begin
                in_data_A_cs <= in_data_A;
                in_data_B_cs <= in_data_B;
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
                    for (int pair_idx = 0; pair_idx < NUM_PAIR; pair_idx++) begin
                        pair_cs[i][pair_idx] <= pair_ns[i][pair_idx];
                    end
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    out_data[PROJ_VEC_W - 1 - (i * PROJ_W) -: PROJ_W] <= sum_ns[i];
                end
            end
        end
    end

endmodule


module ATT_Matmul_8Tap_2Stage #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          in_valid,
    input  logic [255:0]                  in_data_A,
    input  logic [255:0]                  in_data_B,
    output logic                          out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0]   out_data
);

    localparam int ROW_ELEM = 8;
    localparam int NUM_PAIR = 4;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;

    typedef logic signed [3:0]          s4_t;
    typedef logic signed [7:0]          prod_t;
    typedef logic signed [8:0]          pair_t;
    typedef logic signed [ACC_W-1:0]    acc_t;

    logic valid_s1_cs;
    logic valid_s2_cs;
    prod_t prod_cs [0:MAT_SIZE-1][0:ROW_ELEM-1];
    prod_t prod_ns [0:MAT_SIZE-1][0:ROW_ELEM-1];
    pair_t pair_cs [0:MAT_SIZE-1][0:NUM_PAIR-1];
    pair_t pair_ns [0:MAT_SIZE-1][0:NUM_PAIR-1];
    acc_t  sum_ns  [0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                int out_idx;
                out_idx = (row * ROW_ELEM) + lane;

                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    prod_ns[out_idx][tap] =
                        prod_t'($signed(get_s4(in_data_A, (row * ROW_ELEM) + tap)) *
                                $signed(get_s4(in_data_B, (tap * ROW_ELEM) + lane)));
                end

                for (int pair_idx = 0; pair_idx < NUM_PAIR; pair_idx++) begin
                    int tap0;
                    int tap1;

                    tap0 = pair_idx * 2;
                    tap1 = tap0 + 1;
                    pair_ns[out_idx][pair_idx] =
                        pair_t'(prod_cs[out_idx][tap0]) +
                        pair_t'(prod_cs[out_idx][tap1]);
                end
            end
        end

        for (int i = 0; i < MAT_SIZE; i++) begin
            sum_ns[i] =
                acc_t'(acc_t'(pair_cs[i][0]) + acc_t'(pair_cs[i][1])) +
                acc_t'(acc_t'(pair_cs[i][2]) + acc_t'(pair_cs[i][3]));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            out_valid   <= 1'b0;
        end
        else begin
            valid_s1_cs <= in_valid;
            valid_s2_cs <= valid_s1_cs;
            out_valid   <= valid_s2_cs;

            if (in_valid) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        prod_cs[i][tap] <= prod_ns[i][tap];
                    end
                end
            end

            if (valid_s1_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int pair_idx = 0; pair_idx < NUM_PAIR; pair_idx++) begin
                        pair_cs[i][pair_idx] <= pair_ns[i][pair_idx];
                    end
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < MAT_SIZE; i++) begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <= sum_ns[i];
                end
            end
        end
    end

endmodule


module ATT_Quant_3Stage #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0]  in_data,
    output logic                         out_valid,
    output logic [255:0]                 out_data
);

    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]       s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_W-1:0]        mag_t;

    logic valid_s1_cs;
    logic valid_s2_cs;
    logic [ACC_VEC_W-1:0] data_s1_cs;
    logic [ACC_VEC_W-1:0] data_s2_cs;
    mag_t max_bits_s1_cs;
    mag_t max_bits_ns;
    logic [SHIFT_W-1:0] shift_s2_cs;
    logic [255:0] quant_ns;

    function automatic acc_t get_acc(input logic [ACC_VEC_W-1:0] vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic mag_t abs_acc(input acc_t value);
        abs_acc = value[ACC_W - 1] ? mag_t'(-value) : mag_t'(value);
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

    always_comb begin
        max_bits_ns = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            max_bits_ns |= abs_acc(get_acc(in_data, i));
        end
    end

    always_comb begin
        quant_ns = 256'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            acc_t scaled;
            scaled = get_acc(data_s2_cs, i) >>> shift_s2_cs;
            quant_ns[255 - (i * 4) -: 4] = clamp_s4(scaled);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_cs    <= 1'b0;
            valid_s2_cs    <= 1'b0;
            out_valid      <= 1'b0;
        end
        else begin
            valid_s1_cs <= in_valid;
            valid_s2_cs <= valid_s1_cs;
            out_valid   <= valid_s2_cs;

            if (in_valid) begin
                data_s1_cs     <= in_data;
                max_bits_s1_cs <= max_bits_ns;
            end

            if (valid_s1_cs) begin
                data_s2_cs  <= data_s1_cs;
                shift_s2_cs <= pot_shift(max_bits_s1_cs);
            end

            if (valid_s2_cs) begin
                out_data <= quant_ns;
            end
        end
    end

endmodule


module ATT_Quant_4Stage #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0]  in_data,
    output logic                         out_valid,
    output logic [255:0]                 out_data
);

    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]       s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_W-1:0]        mag_t;

    logic valid_s0_cs;
    logic valid_s1_cs;
    logic valid_s2_cs;
    logic [ACC_VEC_W-1:0] data_s0_cs;
    logic [ACC_VEC_W-1:0] data_s1_cs;
    logic [ACC_VEC_W-1:0] data_s2_cs;
    mag_t max_bits_s1_cs;
    mag_t max_bits_ns;
    logic [SHIFT_W-1:0] shift_s2_cs;
    logic [255:0] quant_ns;

    function automatic acc_t get_acc(input logic [ACC_VEC_W-1:0] vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic mag_t abs_acc(input acc_t value);
        abs_acc = value[ACC_W - 1] ? mag_t'(-value) : mag_t'(value);
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

    always_comb begin
        max_bits_ns = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            max_bits_ns |= abs_acc(get_acc(data_s0_cs, i));
        end
    end

    always_comb begin
        quant_ns = 256'd0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            acc_t scaled;
            scaled = get_acc(data_s2_cs, i) >>> shift_s2_cs;
            quant_ns[255 - (i * 4) -: 4] = clamp_s4(scaled);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs   <= 1'b0;
            valid_s1_cs   <= 1'b0;
            valid_s2_cs   <= 1'b0;
            out_valid     <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            out_valid   <= valid_s2_cs;

            if (in_valid) begin
                data_s0_cs     <= in_data;
            end

            if (valid_s0_cs) begin
                data_s1_cs     <= data_s0_cs;
                max_bits_s1_cs <= max_bits_ns;
            end

            if (valid_s1_cs) begin
                data_s2_cs  <= data_s1_cs;
                shift_s2_cs <= pot_shift(max_bits_s1_cs);
            end

            if (valid_s2_cs) begin
                out_data <= quant_ns;
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
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic mha_s0_cs;
    logic mha_s1_cs;
    logic mha_s2_cs;
    logic mha_s3_cs;
    logic mha_s4_cs;
    logic [255:0] q_s0_cs;
    logic [255:0] k_s0_cs;
    logic [255:0] v_s0_cs;
    logic [255:0] v_s1_cs;
    logic [255:0] v_s2_cs;
    logic [255:0] v_s3_cs;
    logic [255:0] v_s4_cs;
    logic lane_valid [0:MAT_SIZE-1];
    logic signed [SCORE_ELEM_W-1:0] lane_score0 [0:MAT_SIZE-1];
    logic signed [SCORE_ELEM_W-1:0] lane_score1 [0:MAT_SIZE-1];

    genvar row_idx;
    genvar lane_idx;
    generate
        for (row_idx = 0; row_idx < ROW_ELEM; row_idx++) begin : gen_score_row
            for (lane_idx = 0; lane_idx < ROW_ELEM; lane_idx++) begin : gen_score_lane
                localparam int OUT_IDX = (row_idx * ROW_ELEM) + lane_idx;

                ATT_Score_Lane_8Tap #(
                    .ROW_ELEM     (ROW_ELEM),
                    .SCORE_ELEM_W (SCORE_ELEM_W),
                    .ROW_IDX      (row_idx),
                    .LANE_IDX     (lane_idx)
                ) u_score_lane (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .in_valid   (valid_s0_cs),
                    .is_mha     (mha_s0_cs),
                    .q_data     (q_s0_cs),
                    .k_data     (k_s0_cs),
                    .out_valid  (lane_valid[OUT_IDX]),
                    .score0_out (lane_score0[OUT_IDX]),
                    .score1_out (lane_score1[OUT_IDX])
                );
            end
        end
    endgenerate

    assign out_valid = lane_valid[0];

    always_comb begin
        score0_data = '0;
        score1_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            score0_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -:
                        SCORE_ELEM_W] = lane_score0[i];
            score1_data[SCORE_BUS_W - 1 - (i * SCORE_ELEM_W) -:
                        SCORE_ELEM_W] = lane_score1[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
            valid_s1_cs <= 1'b0;
            valid_s2_cs <= 1'b0;
            valid_s3_cs <= 1'b0;
            valid_s4_cs <= 1'b0;
            mha_s0_cs   <= 1'b0;
            mha_s1_cs   <= 1'b0;
            mha_s2_cs   <= 1'b0;
            mha_s3_cs   <= 1'b0;
            mha_s4_cs   <= 1'b0;
            out_mha     <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;
            valid_s1_cs <= valid_s0_cs;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;

            if (in_valid) begin
                mha_s0_cs <= is_mha;
                q_s0_cs   <= q_data;
                k_s0_cs   <= k_data;
                v_s0_cs   <= v_data;
            end

            if (valid_s0_cs) begin
                mha_s1_cs <= mha_s0_cs;
                v_s1_cs   <= v_s0_cs;
            end

            if (valid_s1_cs) begin
                mha_s2_cs <= mha_s1_cs;
                v_s2_cs   <= v_s1_cs;
            end

            if (valid_s2_cs) begin
                mha_s3_cs <= mha_s2_cs;
                v_s3_cs   <= v_s2_cs;
            end

            if (valid_s3_cs) begin
                mha_s4_cs <= mha_s3_cs;
                v_s4_cs   <= v_s3_cs;
            end

            if (valid_s4_cs) begin
                out_mha    <= mha_s4_cs;
                out_v_data <= v_s4_cs;
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
    localparam int SCORE_ROW_W = ROW_ELEM * SCORE_ELEM_W;

    typedef logic signed [ACC_W-1:0] acc_t;

    logic [SCORE_ROW_W-1:0] score_low_row_cs  [0:ROW_ELEM-1];
    logic [SCORE_ROW_W-1:0] score_high_row_cs [0:ROW_ELEM-1];
    logic                   lane_valid    [0:MAT_SIZE-1];
    acc_t                   lane_data     [0:MAT_SIZE-1];
    logic                   valid_s0_cs;
    logic [255:0]           v_data_cs;

    genvar row_idx;
    genvar lane_idx;
    generate
        for (row_idx = 0; row_idx < ROW_ELEM; row_idx++) begin : gen_final_row
            for (lane_idx = 0; lane_idx < ROW_ELEM; lane_idx++) begin : gen_final_lane
                localparam int OUT_IDX = (row_idx * ROW_ELEM) + lane_idx;
                localparam int LANE_SEL = lane_idx;

                ATT_Final_Lane_Booth_Acc #(
                    .ACC_W        (ACC_W),
                    .ROW_ELEM     (ROW_ELEM),
                    .SCORE_ELEM_W (SCORE_ELEM_W),
                    .LANE_IDX     (LANE_SEL)
                ) u_lane_booth_acc (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .in_valid   (valid_s0_cs),
                    .score_data ((LANE_SEL >= 4) ?
                                 score_high_row_cs[row_idx] :
                                 score_low_row_cs[row_idx]),
                    .v_data     (v_data_cs),
                    .out_valid  (lane_valid[OUT_IDX]),
                    .out_data   (lane_data[OUT_IDX])
                );
            end
        end
    endgenerate

    assign out_valid = lane_valid[0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0_cs <= 1'b0;
        end
        else begin
            valid_s0_cs <= in_valid;

            if (in_valid) begin
                v_data_cs <= v_data;
                for (int row = 0; row < ROW_ELEM; row++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        score_low_row_cs[row][SCORE_ROW_W - 1 -
                                              (tap * SCORE_ELEM_W) -:
                                              SCORE_ELEM_W] <=
                            score0_data[SCORE_BUS_W - 1 -
                                        (((row * ROW_ELEM) + tap) *
                                         SCORE_ELEM_W) -:
                                        SCORE_ELEM_W];
                        score_high_row_cs[row][SCORE_ROW_W - 1 -
                                               (tap * SCORE_ELEM_W) -:
                                               SCORE_ELEM_W] <=
                            is_mha ?
                            score1_data[SCORE_BUS_W - 1 -
                                        (((row * ROW_ELEM) + tap) *
                                         SCORE_ELEM_W) -:
                                        SCORE_ELEM_W] :
                            score0_data[SCORE_BUS_W - 1 -
                                        (((row * ROW_ELEM) + tap) *
                                         SCORE_ELEM_W) -:
                                        SCORE_ELEM_W];
                    end
                end
            end
        end
    end

    always_comb begin
        out_data = '0;
        for (int i = 0; i < MAT_SIZE; i++) begin
            out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = lane_data[i];
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
    localparam int PROD_W      = SCORE_ELEM_W + 3;
    localparam int PAIR_W      = PROD_W + 1;
    localparam int HALF_W      = PROD_W + 2;

    typedef logic signed [3:0]             s4_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;
    typedef logic signed [PROD_W-1:0]      prod_t;
    typedef logic signed [PAIR_W-1:0]      pair_t;
    typedef logic signed [HALF_W-1:0]      half_t;
    typedef logic signed [ACC_W-1:0]       acc_t;

    logic valid_s1_cs;
    logic valid_s2_cs;
    logic valid_s3_cs;
    logic valid_s4_cs;
    logic valid_s5_cs;
    logic valid_s6_cs;

    score_t score_tap [0:ROW_ELEM-1];
    score_t score_tap_cs [0:ROW_ELEM-1];
    s4_t    v_tap     [0:ROW_ELEM-1];
    s4_t    v_tap_cs  [0:ROW_ELEM-1];
    logic [2:0] booth_lo [0:ROW_ELEM-1];
    logic [2:0] booth_hi [0:ROW_ELEM-1];
    prod_t pp_lo [0:ROW_ELEM-1];
    prod_t pp_hi [0:ROW_ELEM-1];
    prod_t pp_lo_cs [0:ROW_ELEM-1];
    prod_t pp_hi_cs [0:ROW_ELEM-1];
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
            assign score_tap[tap_idx] =
                $signed(score_data[SCORE_ROW_W - 1 -
                                   (tap_idx * SCORE_ELEM_W) -:
                                   SCORE_ELEM_W]);
            assign v_tap[tap_idx] =
                get_s4(v_data, (tap_idx * ROW_ELEM) + LANE_IDX);
            assign booth_lo[tap_idx] =
                {v_tap_cs[tap_idx][1], v_tap_cs[tap_idx][0], 1'b0};
            assign booth_hi[tap_idx] =
                {v_tap_cs[tap_idx][3], v_tap_cs[tap_idx][2],
                 v_tap_cs[tap_idx][1]};

            ATT_Booth_PP #(
                .SCORE_ELEM_W (SCORE_ELEM_W),
                .PROD_W       (PROD_W)
            ) u_booth_lo (
                .score (score_tap_cs[tap_idx]),
                .booth (booth_lo[tap_idx]),
                .pp    (pp_lo[tap_idx])
            );

            ATT_Booth_PP #(
                .SCORE_ELEM_W (SCORE_ELEM_W),
                .PROD_W       (PROD_W)
            ) u_booth_hi (
                .score (score_tap_cs[tap_idx]),
                .booth (booth_hi[tap_idx]),
                .pp    (pp_hi[tap_idx])
            );

            assign prod_ns[tap_idx] =
                prod_t'(pp_lo_cs[tap_idx] + prod_t'(pp_hi_cs[tap_idx] <<< 2));
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
            valid_s6_cs <= 1'b0;
            out_valid   <= 1'b0;
        end
        else begin
            valid_s1_cs <= in_valid;
            valid_s2_cs <= valid_s1_cs;
            valid_s3_cs <= valid_s2_cs;
            valid_s4_cs <= valid_s3_cs;
            valid_s5_cs <= valid_s4_cs;
            valid_s6_cs <= valid_s5_cs;
            out_valid   <= valid_s6_cs;

            if (in_valid) begin
                for (int i = 0; i < ROW_ELEM; i++) begin
                    score_tap_cs[i] <= score_tap[i];
                    v_tap_cs[i] <= v_tap[i];
                end
            end

            if (valid_s1_cs) begin
                for (int i = 0; i < ROW_ELEM; i++) begin
                    pp_lo_cs[i] <= pp_lo[i];
                    pp_hi_cs[i] <= pp_hi[i];
                end
            end

            if (valid_s2_cs) begin
                for (int i = 0; i < ROW_ELEM; i++) begin
                    prod_cs[i] <= prod_ns[i];
                end
            end

            if (valid_s3_cs) begin
                for (int i = 0; i < 4; i++) begin
                    pair_cs[i] <= pair_ns[i];
                end
            end

            if (valid_s4_cs) begin
                for (int i = 0; i < 2; i++) begin
                    half_cs[i] <= half_ns[i];
                end
            end

            if (valid_s5_cs) begin
                result_cs <= result_ns;
            end

            if (valid_s6_cs) begin
                out_data <= result_cs;
            end
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
    typedef logic signed [9:0]  part_t; // partial sum: 5×s8 fits 10 bits
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
    // Stage 3: split 9-input sum 5+4 → 2 partial sums，加法樹深度切半。
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
    part_t partial_cs  [0:MAT_SIZE-1][0:1];
    s16_t sum_cs       [0:MAT_SIZE-1];

    s4_t  operand_a_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t  operand_b_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s8_t  prod_next      [0:MAT_SIZE-1][0:DOT_SIZE-1];
    part_t partial_next  [0:MAT_SIZE-1][0:1];
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

    // Stage 3: 5 + 4 partial sums
    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            partial_next[i][0] = part_t'(prod_cs[i][0]) + part_t'(prod_cs[i][1]) +
                                 part_t'(prod_cs[i][2]) + part_t'(prod_cs[i][3]) +
                                 part_t'(prod_cs[i][4]);
            partial_next[i][1] = part_t'(prod_cs[i][5]) + part_t'(prod_cs[i][6]) +
                                 part_t'(prod_cs[i][7]) + part_t'(prod_cs[i][8]);
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
