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
    logic          datapath_in_valid;
    logic          datapath_result_valid;
    logic          datapath_result_commit;

    // CA only wires the two halves together:
    // - CA_Control owns the FSM and RAM commands.
    // - CA_DataPath owns the matrix pipeline and committed output data.
    CA_Control #(
        .RAM_DEPTH (RAM_DEPTH),
        .BURST_BIT (BURST_BIT)
    ) u_control (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .mem_set               (mem_set),
        .in_valid              (in_valid),
        .op                    (op),
        .act                   (act),
        .param                 (param),
        .rd_ready              (rd_ready),
        .rd_valid              (rd_valid),
        .datapath_result_valid (datapath_result_valid),
        .exec_op               (exec_op),
        .exec_act              (exec_act),
        .exec_param            (exec_param),
        .datapath_in_valid     (datapath_in_valid),
        .datapath_result_commit(datapath_result_commit),
        .rd_en                 (rd_en),
        .rd_addr               (rd_addr),
        .rd_burst              (rd_burst),
        .wr_en                 (wr_en),
        .wr_addr               (wr_addr),
        .wr_burst              (wr_burst)
    );

    CA_DataPath #(
        .RAM_WIDTH (RAM_WIDTH)
    ) u_datapath (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .in_valid              (datapath_in_valid),
        .op                    (exec_op),
        .act                   (exec_act),
        .param                 (exec_param),
        .rd_data               (rd_data),
        .result_commit         (datapath_result_commit),
        .result_valid          (datapath_result_valid),
        .wr_data               (wr_data),
        .out_valid             (out_valid),
        .out_data              (out_data)
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
    output logic                            datapath_in_valid,
    output logic                            datapath_result_commit,

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

    typedef enum logic [1:0] {
        S_IDLE,
        S_RUN
    } state_t;

    state_t      state_q;
    logic [1:0]  rd_req_cnt_q;
    logic [8:0]  rd_word_cnt_q;
    logic [8:0]  wr_cmd_cnt_q;
    logic [8:0]  out_cnt_q;
    logic [9:0]  wr_pre_pipe_q;

    logic        job_start;
    logic        rd_cmd_fire;
    logic        wr_pre_fire;
    logic        wr_cmd_fire;
    logic        result_last;

    function automatic logic op_supported(input logic [1:0] op_sel);
        op_supported = (op_sel == 2'b00) || (op_sel == 2'b01);
    endfunction

    // PATTERN only raises the next in_valid after the previous 256-word output
    // stream is complete, so the controller accepts jobs only from IDLE.
    assign job_start = (state_q == S_IDLE) && mem_set && in_valid && op_supported(op);

    // Feed exactly 256 RAM words into the compute pipe while the job is running.
    assign datapath_in_valid      = rd_valid && (rd_word_cnt_q < 9'd256);
    assign datapath_result_commit = datapath_result_valid;
    assign result_last            = datapath_result_commit && (out_cnt_q == 9'd255);

    // The write command is issued at each 128-word boundary.  Pipelining the
    // PoT max reduction adds two cycles beyond the previous PoT stage count.
    assign wr_pre_fire = wr_pre_pipe_q[9];
    assign wr_cmd_fire = (state_q == S_RUN) && wr_pre_fire;
    assign rd_cmd_fire = (state_q == S_RUN) && (rd_req_cnt_q < 2'd2) && rd_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
        end
        else begin
            case (state_q)
                S_IDLE: begin
                    if (job_start) begin
                        state_q <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (result_last) begin
                        state_q <= S_IDLE;
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
            exec_op    <= 2'b00;
            exec_act   <= 2'b00;
            exec_param <= 256'd0;
        end
        else if (job_start) begin
            exec_op    <= op;
            exec_act   <= act;
            exec_param <= param;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req_cnt_q <= 2'd0;
        end
        else if (job_start) begin
            rd_req_cnt_q <= 2'd0;
        end
        else if (rd_cmd_fire) begin
            rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_word_cnt_q <= 9'd0;
        end
        else if (job_start) begin
            rd_word_cnt_q <= 9'd0;
        end
        else if (datapath_in_valid) begin
            rd_word_cnt_q <= rd_word_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cmd_cnt_q <= 9'd0;
        end
        else if (job_start) begin
            wr_cmd_cnt_q <= 9'd0;
        end
        else if (wr_cmd_fire) begin
            wr_cmd_cnt_q <= wr_cmd_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_cnt_q <= 9'd0;
        end
        else if (job_start) begin
            out_cnt_q <= 9'd0;
        end
        else if (datapath_result_commit && (out_cnt_q != 9'd255)) begin
            out_cnt_q <= out_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_pre_pipe_q <= 10'd0;
        end
        else if (job_start) begin
            wr_pre_pipe_q <= 10'd0;
        end
        else if (state_q == S_RUN) begin
            wr_pre_pipe_q <= {wr_pre_pipe_q[8:0], datapath_in_valid};
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
            rd_burst <= '0;

            if (rd_cmd_fire) begin
                rd_en    <= 1'b1;
                rd_addr  <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
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
            wr_burst <= '0;

            if (state_q == S_RUN) begin
                wr_burst <= BURST_128;
            end

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
    input  logic                 in_valid,
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [RAM_WIDTH-1:0] rd_data,
    input  logic                 result_commit,

    output logic                 result_valid,
    output logic [RAM_WIDTH-1:0] wr_data,
    output logic                 out_valid,
    output logic [31:0]          out_data
);

    logic          mult_valid;
    logic [2047:0] mult_data;
    logic          act_valid;
    logic [2047:0] act_data;
    logic          pot_valid;
    logic [255:0]  pot_data;

    // Matrix pipeline: RAM word -> 32-bit accumulation -> activation -> PoT.
    Mult_8Stage_Parallel u_mult (
        .clk       (clk),
        .rst_n     (rst_n),
        .op        (op),
        .in_valid  (in_valid),
        .in_data_A (rd_data),
        .in_data_B (param),
        .out_valid (mult_valid),
        .out_data  (mult_data)
    );

    ACT_TwoStage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (mult_valid),
        .act       (act),
        .in_data   (mult_data),
        .out_valid (act_valid),
        .out_data  (act_data)
    );

    PoT_FiveStage_Parallel u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_valid),
        .in_data   (act_data),
        .out_valid (pot_valid),
        .out_data  (pot_data)
    );

    assign result_valid = pot_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end
        else begin
            out_valid <= result_commit;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_data  <= '0;
            out_data <= 32'd0;
        end
        else if (result_commit) begin
            wr_data  <= pot_data;
            out_data <= pot_data[31:0];
        end
    end

endmodule

module Mult_8Stage_Parallel (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic                 in_valid,
    input  logic [255:0]         in_data_A,
    input  logic [255:0]         in_data_B,
    output logic                 out_valid,
    output logic [2047:0]        out_data
);

    localparam int STAGES = 8;
    localparam int ROW_ELEM = 8;
    localparam int MAT_SIZE = 64;
    localparam int STAGE_LANES = 8;
    localparam int FFN_PRODUCTS = 8;
    localparam int CONV_PRODUCTS = 9;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [31:0] s32_t;

    logic         valid_q    [0:STAGES-1];
    logic [255:0] mat_A_q    [0:STAGES-1];
    s32_t         data_q     [0:STAGES-1][0:MAT_SIZE-1];

    // Packed matrix order is MSB-to-LSB raster: element 0 is vec[255:252].
    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic s4_t get_pad_s4(input logic [255:0] vec, input integer row, input integer col);
        if ((row < 0) || (row >= ROW_ELEM) || (col < 0) || (col >= ROW_ELEM)) begin
            get_pad_s4 = 4'sd0;
        end
        else begin
            get_pad_s4 = get_s4(vec, (row * ROW_ELEM) + col);
        end
    endfunction

    function automatic s32_t shared_dot(
        input logic [1:0]   op_sel,
        input logic [255:0] mat_A,
        input logic [255:0] mat_B,
        input integer       stage_idx,
        input integer       lane
    );
        s4_t    mul_a;
        s4_t    mul_b;
        integer product;
        integer pix_idx;
        integer row;
        integer col;
        begin
            pix_idx    = (stage_idx * STAGE_LANES) + lane;
            row        = pix_idx / ROW_ELEM;
            col        = pix_idx % ROW_ELEM;
            shared_dot = 32'sd0;

            // One lane has nine multiplier slots.  FFN uses slots 0..7 and
            // drives slot 8 to zero; Conv uses all nine 3x3-kernel slots.
            for (product = 0; product < CONV_PRODUCTS; product++) begin
                mul_a = 4'sd0;
                mul_b = 4'sd0;

                if (op_sel == 2'b01) begin
                    mul_a = get_pad_s4(mat_A, row + (product / 3) - 1, col + (product % 3) - 1);
                    mul_b = get_s4(mat_B, product);
                end
                else if (product < FFN_PRODUCTS) begin
                    mul_a = get_s4(mat_A, (stage_idx * ROW_ELEM) + product);
                    mul_b = get_s4(mat_B, (product * ROW_ELEM) + lane);
                end

                shared_dot += mul_a * mul_b;
            end
        end
    endfunction

    // FFN and Conv share the same 8 lanes in each stage.  Each lane has nine
    // multiplier slots: FFN consumes eight products, Conv consumes all nine.
    genvar st;
    generate
        for (st = 0; st < STAGES; st++) begin : g_stage
            localparam int PREV_STAGE = (st == 0) ? 0 : st - 1;

            logic [255:0] stage_A;
            logic         stage_valid;
            s32_t         data_next [0:MAT_SIZE-1];
            s32_t         value;
            integer       idx;

            always_comb begin
                stage_valid = (st == 0) ? in_valid  : valid_q[PREV_STAGE];
                stage_A     = (st == 0) ? in_data_A : mat_A_q[PREV_STAGE];

                for (int i = 0; i < MAT_SIZE; i++) begin
                    data_next[i] = (st == 0) ? 32'sd0 : data_q[PREV_STAGE][i];
                end

                for (int lane = 0; lane < STAGE_LANES; lane++) begin
                    idx            = (st * STAGE_LANES) + lane;
                    value          = shared_dot(op, stage_A, in_data_B, st, lane);
                    data_next[idx] = value;
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_q[st] <= 1'b0;
                    mat_A_q[st] <= 256'd0;
                end
                else begin
                    valid_q[st] <= stage_valid;
                    mat_A_q[st] <= stage_A;
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        data_q[st][i] <= 32'sd0;
                    end
                end
                else begin
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

module ACT_TwoStage_Parallel (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [2047:0] in_data,
    output logic          out_valid,
    output logic [2047:0] out_data
);

    localparam int MAT_SIZE  = 64;
    localparam int ROW_ELEM  = 8;
    localparam int HALF_SIZE = MAT_SIZE / 2;

    typedef logic signed [31:0] s32_t;
    typedef logic signed [39:0] s40_t;

    logic          st1_valid;
    logic [2047:0] st1_src;
    logic [2047:0] st1_matrix;
    logic [2047:0] st0_matrix_next;
    logic [2047:0] st1_matrix_next;

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic s40_t ext40(input s32_t value);
        ext40 = {{8{value[31]}}, value};
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
                    block    = (phase ? 2 : 0) + (lane / 16);
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

    function automatic s40_t group_sum(
        input logic [2047:0] matrix,
        input logic [1:0]    act_sel,
        input logic          phase,
        input integer        group
    );
        integer lane;
        integer group_size;
        begin
            group_sum  = 40'sd0;
            group_size = (act_sel == 2'b11) ? 16 : ROW_ELEM;

            if ((act_sel != 2'b00) && !((act_sel == 2'b11) && (group > 1))) begin
                for (int i = 0; i < 16; i++) begin
                    if (i < group_size) begin
                        lane = (group * group_size) + i;
                        group_sum += ext40(get_i32(matrix, lane_idx(act_sel, phase, lane)));
                    end
                end
            end
        end
    endfunction

    function automatic s32_t activate(input s32_t value, input logic [1:0] act_sel, input s40_t threshold);
        begin
            if (act_sel == 2'b00) begin
                activate = (value < 0) ? 32'sd0 : value;
            end
            else begin
                activate = (ext40(value) < threshold) ? (value >>> 3) : value;
            end
        end
    endfunction

    function automatic logic [2047:0] run_half(
        input logic [2047:0] base_matrix,
        input logic [2047:0] src_matrix,
        input logic [1:0]    act_sel,
        input logic          phase
    );
        integer idx;
        integer group;
        s40_t  sum [0:3];
        s40_t  threshold;
        begin
            run_half = base_matrix;

            for (group = 0; group < 4; group++) begin
                sum[group] = group_sum(src_matrix, act_sel, phase, group);
            end

            for (int lane = 0; lane < HALF_SIZE; lane++) begin
                idx       = lane_idx(act_sel, phase, lane);
                group     = lane_group(act_sel, lane);
                threshold = (act_sel == 2'b11) ? (sum[group] >>> 4) : (sum[group] >>> 3);
                run_half[2047 - (idx * 32) -: 32] = activate(get_i32(src_matrix, idx), act_sel, threshold);
            end
        end
    endfunction

    always_comb begin
        st0_matrix_next = run_half(in_data, in_data, act, 1'b0);
        st1_matrix_next = run_half(st1_matrix, st1_src, act, 1'b1);
    end

    // Keep valid bits in their own block so timing/control can be read quickly.
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

    // Stage 1 stores the first half activation and the original matrix.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1_src    <= 2048'd0;
            st1_matrix <= 2048'd0;
        end
        else if (in_valid) begin
            st1_src    <= in_data;
            st1_matrix <= st0_matrix_next;
        end
    end

    // Stage 2 finishes the second half of activation.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= 2048'd0;
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
    input  logic [2047:0] in_data,
    output logic          out_valid,
    output logic [255:0]  out_data
);

    localparam int MAT_SIZE  = 64;
    localparam int HALF_SIZE = MAT_SIZE / 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [31:0] s32_t;

    logic          max_valid;
    logic [31:0]   max_abs;
    logic [2047:0] src_pipe_q [0:2];
    logic          quant_valid;
    logic [5:0]    quant_shift;
    logic [2047:0] quant_src;
    logic [255:0]  quant_data;
    logic [5:0]    shift_next;
    logic [255:0]  quant_data_next;
    logic [255:0]  out_data_next;

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
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

    function automatic logic [255:0] quant_half(
        input logic [255:0]  base_data,
        input logic [2047:0] src_data,
        input logic [5:0]    shift,
        input logic          phase
    );
        integer idx;
        s32_t   scaled;
        begin
            quant_half = base_data;

            for (int lane = 0; lane < HALF_SIZE; lane++) begin
                idx    = (phase ? HALF_SIZE : 0) + lane;
                scaled = get_i32(src_data, idx) >>> shift;
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

    // Keep the activated matrix aligned with the three-stage max pipeline.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int stage = 0; stage < 3; stage++) begin
                src_pipe_q[stage] <= 2048'd0;
            end
        end
        else begin
            src_pipe_q[0] <= in_data;
            src_pipe_q[1] <= src_pipe_q[0];
            src_pipe_q[2] <= src_pipe_q[1];
        end
    end

    // Valid staging for the two quantization stages after max_abs is ready.
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

    // Quant stage 1: encode the shift and quantize elements 0..31.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quant_shift <= 6'd0;
            quant_src   <= 2048'd0;
            quant_data  <= 256'd0;
        end
        else if (max_valid) begin
            quant_shift <= shift_next;
            quant_src   <= src_pipe_q[2];
            quant_data  <= quant_data_next;
        end
    end

    // Quant stage 2: reuse the saved shift and quantize elements 32..63.
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
    input  logic [2047:0] in_data,
    output logic          out_valid,
    output logic [31:0]   out_max
);

    localparam int MAT_SIZE    = 64;
    localparam int MAX16_COUNT = 16;
    localparam int MAX4_COUNT  = 4;

    typedef logic signed [31:0] s32_t;

    logic          st1_valid;
    logic          st2_valid;
    logic [31:0]   max16_q [0:MAX16_COUNT-1];
    logic [31:0]   max4_q  [0:MAX4_COUNT-1];
    logic [31:0]   max16_next [0:MAX16_COUNT-1];
    logic [31:0]   max4_next  [0:MAX4_COUNT-1];
    logic [31:0]   max_abs_next;

    function automatic s32_t get_i32(input logic [2047:0] vec, input integer idx);
        get_i32 = $signed(vec[2047 - (idx * 32) -: 32]);
    endfunction

    function automatic logic [31:0] abs32(input s32_t value);
        abs32 = (value < 0) ? -value : value;
    endfunction

    function automatic logic [31:0] max4_u32(
        input logic [31:0] a,
        input logic [31:0] b,
        input logic [31:0] c,
        input logic [31:0] d
    );
        logic [31:0] ab;
        logic [31:0] cd;
        begin
            ab       = (a > b) ? a : b;
            cd       = (c > d) ? c : d;
            max4_u32 = (ab > cd) ? ab : cd;
        end
    endfunction

    function automatic logic [31:0] max4_abs(
        input logic [2047:0] src_data,
        input integer        group
    );
        integer base;
        begin
            base = group * 4;
            max4_abs = max4_u32(
                abs32(get_i32(src_data, base)),
                abs32(get_i32(src_data, base + 1)),
                abs32(get_i32(src_data, base + 2)),
                abs32(get_i32(src_data, base + 3))
            );
        end
    endfunction

    always_comb begin
        for (int group = 0; group < MAX16_COUNT; group++) begin
            max16_next[group] = max4_abs(in_data, group);
        end

        for (int group = 0; group < MAX4_COUNT; group++) begin
            max4_next[group] = max4_u32(
                max16_q[(group * 4)],
                max16_q[(group * 4) + 1],
                max16_q[(group * 4) + 2],
                max16_q[(group * 4) + 3]
            );
        end

        max_abs_next = max4_u32(max4_q[0], max4_q[1], max4_q[2], max4_q[3]);
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

    // Stage 1: reduce 64 signed values into sixteen absolute maxima.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int group = 0; group < MAX16_COUNT; group++) begin
                max16_q[group] <= 32'd0;
            end
        end
        else if (in_valid) begin
            for (int group = 0; group < MAX16_COUNT; group++) begin
                max16_q[group] <= max16_next[group];
            end
        end
    end

    // Stage 2: reduce sixteen group maxima into four maxima.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int group = 0; group < MAX4_COUNT; group++) begin
                max4_q[group] <= 32'd0;
            end
        end
        else if (st1_valid) begin
            for (int group = 0; group < MAX4_COUNT; group++) begin
                max4_q[group] <= max4_next[group];
            end
        end
    end

    // Stage 3: reduce the final four values into one matrix max.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_max <= 32'd0;
        end
        else if (st2_valid) begin
            out_max <= max_abs_next;
        end
    end

endmodule