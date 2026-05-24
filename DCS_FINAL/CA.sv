module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    // ============================================= //
    //                    PATTERN                    //
    // ============================================= //
    // input signals
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    // output signals
    output logic                            out_valid,
    output logic [31:0]                     out_data,

    // ============================================= //
    //                      RAM                      //
    // ============================================= //
    // READ
    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1    :0]        rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

    // WRITE
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1    :0]        wr_burst,
    output logic [RAM_WIDTH-1:0]            wr_data,
    input  logic                            wr_valid,
    input  logic                            wr_ready
);

    // ======================================================================
    // Your Design
    // ======================================================================

    localparam logic [1:0] OP_FFN  = 2'b00;
    localparam logic [1:0] OP_CONV = 2'b01;
    localparam logic [1:0] OP_SHA  = 2'b10;
    localparam logic [1:0] OP_MHA  = 2'b11;

    localparam logic [1:0] ACT_RELU = 2'b00;
    localparam logic [1:0] ACT_RAT  = 2'b01;
    localparam logic [1:0] ACT_CAT  = 2'b10;
    localparam logic [1:0] ACT_BAT  = 2'b11;

    localparam int MAT_N      = 8;
    localparam int TILE_WORDS = 128;
    localparam int TILE_COUNT = 2;
    localparam int PIPE_DEPTH = 72;
    localparam int OUT_MIN    = -8;
    localparam int OUT_MAX    = 7;

    localparam int Q_MAX_START    = 8;
    localparam int Q_QUANT_STAGE  = 16;
    localparam int K_MAX_START    = 17;
    localparam int K_QUANT_STAGE  = 25;
    localparam int V_MAX_START    = 26;
    localparam int V_QUANT_STAGE  = 34;
    localparam int SCORE_START    = 35;
    localparam int PART_STAGE     = 43;
    localparam int CTX_START      = 44;
    localparam int ACT_START      = 52;
    localparam int ACT_APPLY      = 60;
    localparam int POT_START      = 61;
    localparam int FINAL_QUANT    = 69;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [31:0] s32_t;

    typedef enum logic [2:0] {
        S_IDLE,
        S_RECV,
        S_STREAM,
        S_DRAIN,
        S_DONE
    } state_t;

    state_t cs, ns;

    logic [1:0] op_q, op_d;
    logic [1:0] act_q, act_d;
    logic [1:0] param_cnt_q, param_cnt_d;
    logic [1:0] param_need;
    logic       job_start;

    s4_t weight_q [0:2][0:MAT_N-1][0:MAT_N-1];
    s4_t weight_d [0:2][0:MAT_N-1][0:MAT_N-1];

    logic       rd_active_q, rd_active_d;
    logic [1:0] rd_tile_q, rd_tile_d;
    logic [7:0] rd_count_q, rd_count_d;
    logic       rd_stream_valid;
    logic [7:0] rd_stream_addr;
    logic [255:0] rd_stream_word;

    logic       pipe_valid_q [0:PIPE_DEPTH];
    logic [7:0] pipe_addr_q  [0:PIPE_DEPTH];
    s4_t        pipe_mat_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t       pipe_acc_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t       pipe_act_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];

    s32_t q_acc_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t k_acc_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t v_acc_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s4_t  q_mat_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s4_t  k_mat_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s4_t  v_mat_q     [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t score_lo_q  [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t score_hi_q  [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t part_lo_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t part_hi_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t context_q   [0:PIPE_DEPTH][0:MAT_N-1][0:MAT_N-1];
    s32_t q_max_q     [0:PIPE_DEPTH];
    s32_t k_max_q     [0:PIPE_DEPTH];
    s32_t v_max_q     [0:PIPE_DEPTH];
    s32_t final_max_q [0:PIPE_DEPTH];
    s32_t act_thr_q   [0:PIPE_DEPTH][0:MAT_N-1];

    logic [255:0] out_tile_q [0:TILE_COUNT-1][0:TILE_WORDS-1];
    logic [31:0]  out_row_q  [0:TILE_COUNT-1][0:TILE_WORDS-1];
    logic [6:0]   out_fill_count_q;
    logic [1:0]   out_fill_tile_q;
    logic [TILE_COUNT-1:0] out_ready_q;

    logic       wr_active_q, wr_active_d;
    logic [1:0] wr_tile_q, wr_tile_d;
    logic [7:0] wr_count_q, wr_count_d;
    logic       wr_done_beat;

    logic [8:0] in_seen_q, in_seen_d;
    logic [8:0] out_seen_q, out_seen_d;
    logic       all_inputs_seen;
    logic       all_outputs_seen;

    s4_t stage0_mat [0:MAT_N-1][0:MAT_N-1];
    logic [255:0] tail_word;
    logic [31:0]  tail_row;

    function automatic s4_t nibble_at(input logic [255:0] word, input int idx);
        nibble_at = s4_t'(word[255 - 4 * idx -: 4]);
    endfunction

    function automatic s4_t clamp_s4(input s32_t value);
        if (value > OUT_MAX)
            clamp_s4 = s4_t'(OUT_MAX);
        else if (value < OUT_MIN)
            clamp_s4 = s4_t'(OUT_MIN);
        else
            clamp_s4 = s4_t'(value[3:0]);
    endfunction

    function automatic s32_t abs_s32(input s32_t value);
        abs_s32 = (value < 0) ? -value : value;
    endfunction

    function automatic s32_t div8_toward_zero(input s32_t value);
        if (value < 0)
            div8_toward_zero = -((-value) >>> 3);
        else
            div8_toward_zero = value >>> 3;
    endfunction

    function automatic logic [4:0] pot_shift(input s32_t max_abs);
        if (max_abs[31])
            pot_shift = 5'd29;
        else if (max_abs[30])
            pot_shift = 5'd28;
        else if (max_abs[29])
            pot_shift = 5'd27;
        else if (max_abs[28])
            pot_shift = 5'd26;
        else if (max_abs[27])
            pot_shift = 5'd25;
        else if (max_abs[26])
            pot_shift = 5'd24;
        else if (max_abs[25])
            pot_shift = 5'd23;
        else if (max_abs[24])
            pot_shift = 5'd22;
        else if (max_abs[23])
            pot_shift = 5'd21;
        else if (max_abs[22])
            pot_shift = 5'd20;
        else if (max_abs[21])
            pot_shift = 5'd19;
        else if (max_abs[20])
            pot_shift = 5'd18;
        else if (max_abs[19])
            pot_shift = 5'd17;
        else if (max_abs[18])
            pot_shift = 5'd16;
        else if (max_abs[17])
            pot_shift = 5'd15;
        else if (max_abs[16])
            pot_shift = 5'd14;
        else if (max_abs[15])
            pot_shift = 5'd13;
        else if (max_abs[14])
            pot_shift = 5'd12;
        else if (max_abs[13])
            pot_shift = 5'd11;
        else if (max_abs[12])
            pot_shift = 5'd10;
        else if (max_abs[11])
            pot_shift = 5'd9;
        else if (max_abs[10])
            pot_shift = 5'd8;
        else if (max_abs[9])
            pot_shift = 5'd7;
        else if (max_abs[8])
            pot_shift = 5'd6;
        else if (max_abs[7])
            pot_shift = 5'd5;
        else if (max_abs[6])
            pot_shift = 5'd4;
        else if (max_abs[5])
            pot_shift = 5'd3;
        else if (max_abs[4])
            pot_shift = 5'd2;
        else if (max_abs[3])
            pot_shift = 5'd1;
        else
            pot_shift = 5'd0;
    endfunction

    function automatic void unpack_word(
        input  logic [255:0] word,
        output s4_t          mat [0:MAT_N-1][0:MAT_N-1]
    );
        for (int r = 0; r < MAT_N; r++) begin
            for (int c = 0; c < MAT_N; c++) begin
                mat[r][c] = nibble_at(word, r * MAT_N + c);
            end
        end
    endfunction

    function automatic void pack_word(
        input  s4_t          mat [0:MAT_N-1][0:MAT_N-1],
        output logic [255:0] word
    );
        word = 256'd0;
        for (int r = 0; r < MAT_N; r++) begin
            for (int c = 0; c < MAT_N; c++) begin
                word[255 - 4 * (r * MAT_N + c) -: 4] = mat[r][c];
            end
        end
    endfunction

    function automatic void pack_last_row(
        input  s4_t          mat [0:MAT_N-1][0:MAT_N-1],
        output logic [31:0]  row_word
    );
        row_word = 32'd0;
        for (int c = 0; c < MAT_N; c++) begin
            row_word[31 - 4 * c -: 4] = mat[MAT_N-1][c];
        end
    endfunction

    function automatic s32_t max_s32(input s32_t a, input s32_t b);
        max_s32 = (a > b) ? a : b;
    endfunction

    function automatic s32_t row_abs_max(
        input s32_t mat [0:MAT_N-1][0:MAT_N-1],
        input int   row_idx
    );
        row_abs_max = 32'sd0;
        for (int c = 0; c < MAT_N; c++) begin
            row_abs_max = max_s32(row_abs_max, abs_s32(mat[row_idx][c]));
        end
    endfunction

    function automatic s32_t act_threshold(
        input logic [1:0] act_sel,
        input s32_t       mat [0:MAT_N-1][0:MAT_N-1],
        input int         idx
    );
        int br;
        int bc;

        act_threshold = 32'sd0;
        if (act_sel == ACT_RAT) begin
            for (int c = 0; c < MAT_N; c++) begin
                act_threshold += mat[idx][c];
            end
            act_threshold = act_threshold >>> 3;
        end else if (act_sel == ACT_CAT) begin
            for (int r = 0; r < MAT_N; r++) begin
                act_threshold += mat[r][idx];
            end
            act_threshold = act_threshold >>> 3;
        end else if ((act_sel == ACT_BAT) && (idx < 4)) begin
            br = (idx / 2) * 4;
            bc = (idx % 2) * 4;
            for (int rr = 0; rr < 4; rr++) begin
                for (int cc = 0; cc < 4; cc++) begin
                    act_threshold += mat[br + rr][bc + cc];
                end
            end
            act_threshold = act_threshold >>> 4;
        end
    endfunction

    function automatic s32_t activate_elem(
        input logic [1:0] act_sel,
        input s32_t       value,
        input s32_t       threshold
    );
        if (act_sel == ACT_RELU)
            activate_elem = (value < 0) ? 32'sd0 : value;
        else
            activate_elem = (value < threshold) ? div8_toward_zero(value) : value;
    endfunction

    function automatic s4_t quant_elem(
        input s32_t value,
        input s32_t max_abs
    );
        quant_elem = clamp_s4(value >>> pot_shift(max_abs));
    endfunction

    always_comb begin
        job_start = (((cs == S_IDLE) || (cs == S_DONE)) && mem_set && in_valid);
    end

    always_comb begin
        ns          = cs;
        op_d        = op_q;
        act_d       = act_q;
        param_cnt_d = param_cnt_q;
        param_need  = ((op_q == OP_SHA) || (op_q == OP_MHA)) ? 2'd3 : 2'd1;

        for (int p = 0; p < 3; p++) begin
            for (int r = 0; r < MAT_N; r++) begin
                for (int c = 0; c < MAT_N; c++) begin
                    weight_d[p][r][c] = weight_q[p][r][c];
                end
            end
        end

        if (job_start) begin
            ns          = S_RECV;
            op_d        = op;
            act_d       = act;
            param_cnt_d = 2'd1;
            param_need  = ((op == OP_SHA) || (op == OP_MHA)) ? 2'd3 : 2'd1;
            for (int r = 0; r < MAT_N; r++) begin
                for (int c = 0; c < MAT_N; c++) begin
                    if ((op == OP_CONV) && (r < 3) && (c < 3))
                        weight_d[0][r][c] = nibble_at(param, r * 3 + c);
                    else if (op == OP_CONV)
                        weight_d[0][r][c] = '0;
                    else
                        weight_d[0][r][c] = nibble_at(param, r * MAT_N + c);
                end
            end
        end else begin
            case (cs)
                S_IDLE: begin
                    ns = S_IDLE;
                end
                S_RECV: begin
                    param_need = ((op_q == OP_SHA) || (op_q == OP_MHA)) ? 2'd3 : 2'd1;
                    if (param_cnt_q >= param_need) begin
                        ns = S_STREAM;
                    end else if (in_valid) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                weight_d[param_cnt_q][r][c] = nibble_at(param, r * MAT_N + c);
                            end
                        end
                        param_cnt_d = param_cnt_q + 2'd1;
                    end
                end
                S_STREAM: begin
                    if (all_inputs_seen)
                        ns = S_DRAIN;
                end
                S_DRAIN: begin
                    if (all_outputs_seen)
                        ns = S_DONE;
                end
                S_DONE: begin
                    if (!mem_set)
                        ns = S_IDLE;
                end
                default: begin
                    ns = S_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs          <= S_IDLE;
            op_q        <= OP_FFN;
            act_q       <= ACT_RELU;
            param_cnt_q <= 2'd0;
            for (int p = 0; p < 3; p++) begin
                for (int r = 0; r < MAT_N; r++) begin
                    for (int c = 0; c < MAT_N; c++) begin
                        weight_q[p][r][c] <= '0;
                    end
                end
            end
        end else begin
            cs          <= ns;
            op_q        <= op_d;
            act_q       <= act_d;
            param_cnt_q <= param_cnt_d;
            for (int p = 0; p < 3; p++) begin
                for (int r = 0; r < MAT_N; r++) begin
                    for (int c = 0; c < MAT_N; c++) begin
                        weight_q[p][r][c] <= weight_d[p][r][c];
                    end
                end
            end
        end
    end

    assign rd_stream_valid = rd_valid && rd_active_q;
    assign rd_stream_addr  = (rd_tile_q[0] ? 8'd128 : 8'd0) + rd_count_q;
    assign rd_stream_word  = rd_data;

    always_comb begin
        rd_en       = 1'b0;
        rd_addr     = '0;
        rd_burst    = 3'd7;
        rd_active_d = rd_active_q;
        rd_tile_d   = rd_tile_q;
        rd_count_d  = rd_count_q;

        if ((cs == S_STREAM) && (rd_tile_q < 2'd2)) begin
            if (!rd_active_q && rd_ready) begin
                rd_en       = 1'b1;
                rd_addr     = rd_tile_q[0] ? 8'd128 : 8'd0;
                rd_burst    = 3'd7;
                rd_active_d = 1'b1;
                rd_count_d  = 8'd0;
            end else if (rd_active_q && rd_valid) begin
                if (rd_count_q == 8'd127) begin
                    rd_active_d = 1'b0;
                    rd_count_d  = 8'd0;
                    rd_tile_d   = rd_tile_q + 2'd1;
                end else begin
                    rd_count_d = rd_count_q + 8'd1;
                end
            end
        end else if (job_start || (cs == S_IDLE) || (cs == S_RECV)) begin
            rd_active_d = 1'b0;
            rd_tile_d   = 2'd0;
            rd_count_d  = 8'd0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_q <= 1'b0;
            rd_tile_q   <= 2'd0;
            rd_count_q  <= 8'd0;
        end else begin
            rd_active_q <= rd_active_d;
            rd_tile_q   <= rd_tile_d;
            rd_count_q  <= rd_count_d;
        end
    end

    always_comb begin
        for (int r = 0; r < MAT_N; r++) begin
            for (int c = 0; c < MAT_N; c++) begin
                stage0_mat[r][c] = '0;
            end
        end
        if (rd_stream_valid)
            unpack_word(rd_stream_word, stage0_mat);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid_q[0] <= 1'b0;
            pipe_addr_q[0]  <= 8'd0;
            q_max_q[0]      <= 32'sd0;
            k_max_q[0]      <= 32'sd0;
            v_max_q[0]      <= 32'sd0;
            final_max_q[0]  <= 32'sd0;
            for (int i = 0; i < MAT_N; i++) begin
                act_thr_q[0][i] <= 32'sd0;
            end
            for (int r = 0; r < MAT_N; r++) begin
                for (int c = 0; c < MAT_N; c++) begin
                    pipe_mat_q[0][r][c]  <= '0;
                    pipe_acc_q[0][r][c]  <= '0;
                    pipe_act_q[0][r][c]  <= '0;
                    q_acc_q[0][r][c]     <= '0;
                    k_acc_q[0][r][c]     <= '0;
                    v_acc_q[0][r][c]     <= '0;
                    q_mat_q[0][r][c]     <= '0;
                    k_mat_q[0][r][c]     <= '0;
                    v_mat_q[0][r][c]     <= '0;
                    score_lo_q[0][r][c]  <= '0;
                    score_hi_q[0][r][c]  <= '0;
                    part_lo_q[0][r][c]   <= '0;
                    part_hi_q[0][r][c]   <= '0;
                    context_q[0][r][c]   <= '0;
                end
            end
        end else begin
            pipe_valid_q[0] <= rd_stream_valid;
            pipe_addr_q[0]  <= rd_stream_addr;
            q_max_q[0]      <= 32'sd0;
            k_max_q[0]      <= 32'sd0;
            v_max_q[0]      <= 32'sd0;
            final_max_q[0]  <= 32'sd0;
            for (int i = 0; i < MAT_N; i++) begin
                act_thr_q[0][i] <= 32'sd0;
            end
            for (int r = 0; r < MAT_N; r++) begin
                for (int c = 0; c < MAT_N; c++) begin
                    pipe_mat_q[0][r][c]  <= stage0_mat[r][c];
                    pipe_acc_q[0][r][c]  <= '0;
                    pipe_act_q[0][r][c]  <= '0;
                    q_acc_q[0][r][c]     <= '0;
                    k_acc_q[0][r][c]     <= '0;
                    v_acc_q[0][r][c]     <= '0;
                    q_mat_q[0][r][c]     <= '0;
                    k_mat_q[0][r][c]     <= '0;
                    v_mat_q[0][r][c]     <= '0;
                    score_lo_q[0][r][c]  <= '0;
                    score_hi_q[0][r][c]  <= '0;
                    part_lo_q[0][r][c]   <= '0;
                    part_hi_q[0][r][c]   <= '0;
                    context_q[0][r][c]   <= '0;
                end
            end
        end
    end

    genvar ps;
    generate
        for (ps = 0; ps < PIPE_DEPTH; ps = ps + 1) begin : g_ca_pipe
            localparam int K_IDX     = ps % MAT_N;
            localparam int KER_IDX   = ps % 9;
            localparam int KER_R     = KER_IDX / 3;
            localparam int KER_C     = KER_IDX % 3;
            localparam int Q_ROW     = ((ps >= Q_MAX_START) && (ps < Q_QUANT_STAGE)) ? (ps - Q_MAX_START) : 0;
            localparam int K_ROW     = ((ps >= K_MAX_START) && (ps < K_QUANT_STAGE)) ? (ps - K_MAX_START) : 0;
            localparam int V_ROW     = ((ps >= V_MAX_START) && (ps < V_QUANT_STAGE)) ? (ps - V_MAX_START) : 0;
            localparam int SCORE_IDX = ((ps >= SCORE_START) && (ps < PART_STAGE)) ? (ps - SCORE_START) : 0;
            localparam int CTX_IDX   = ((ps >= CTX_START) && (ps < ACT_START)) ? (ps - CTX_START) : 0;
            localparam int ACT_IDX   = ((ps >= ACT_START) && (ps < ACT_APPLY)) ? (ps - ACT_START) : 0;
            localparam int POT_ROW   = ((ps >= POT_START) && (ps < FINAL_QUANT)) ? (ps - POT_START) : 0;

            s4_t  mat_next      [0:MAT_N-1][0:MAT_N-1];
            s32_t acc_next      [0:MAT_N-1][0:MAT_N-1];
            s32_t act_next      [0:MAT_N-1][0:MAT_N-1];
            s32_t q_acc_next    [0:MAT_N-1][0:MAT_N-1];
            s32_t k_acc_next    [0:MAT_N-1][0:MAT_N-1];
            s32_t v_acc_next    [0:MAT_N-1][0:MAT_N-1];
            s4_t  q_mat_next    [0:MAT_N-1][0:MAT_N-1];
            s4_t  k_mat_next    [0:MAT_N-1][0:MAT_N-1];
            s4_t  v_mat_next    [0:MAT_N-1][0:MAT_N-1];
            s32_t score_lo_next [0:MAT_N-1][0:MAT_N-1];
            s32_t score_hi_next [0:MAT_N-1][0:MAT_N-1];
            s32_t part_lo_next  [0:MAT_N-1][0:MAT_N-1];
            s32_t part_hi_next  [0:MAT_N-1][0:MAT_N-1];
            s32_t context_next  [0:MAT_N-1][0:MAT_N-1];
            s32_t final_src     [0:MAT_N-1][0:MAT_N-1];
            s4_t  final_q       [0:MAT_N-1][0:MAT_N-1];
            s32_t q_max_next;
            s32_t k_max_next;
            s32_t v_max_next;
            s32_t final_max_next;
            s32_t act_thr_next [0:MAT_N-1];

            always_comb begin
                q_max_next     = q_max_q[ps];
                k_max_next     = k_max_q[ps];
                v_max_next     = v_max_q[ps];
                final_max_next = final_max_q[ps];
                for (int i = 0; i < MAT_N; i++) begin
                    act_thr_next[i] = act_thr_q[ps][i];
                end

                for (int r = 0; r < MAT_N; r++) begin
                    for (int c = 0; c < MAT_N; c++) begin
                        mat_next[r][c]      = pipe_mat_q[ps][r][c];
                        acc_next[r][c]      = pipe_acc_q[ps][r][c];
                        act_next[r][c]      = pipe_act_q[ps][r][c];
                        q_acc_next[r][c]    = q_acc_q[ps][r][c];
                        k_acc_next[r][c]    = k_acc_q[ps][r][c];
                        v_acc_next[r][c]    = v_acc_q[ps][r][c];
                        q_mat_next[r][c]    = q_mat_q[ps][r][c];
                        k_mat_next[r][c]    = k_mat_q[ps][r][c];
                        v_mat_next[r][c]    = v_mat_q[ps][r][c];
                        score_lo_next[r][c] = score_lo_q[ps][r][c];
                        score_hi_next[r][c] = score_hi_q[ps][r][c];
                        part_lo_next[r][c]  = part_lo_q[ps][r][c];
                        part_hi_next[r][c]  = part_hi_q[ps][r][c];
                        context_next[r][c]  = context_q[ps][r][c];
                        final_src[r][c]     = 32'sd0;
                        final_q[r][c]       = pipe_mat_q[ps][r][c];
                    end
                end

                if (op_q == OP_FFN) begin
                    if (ps < 8) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                acc_next[r][c] = pipe_acc_q[ps][r][c]
                                    + $signed(pipe_mat_q[ps][r][K_IDX])
                                    * $signed(weight_q[0][K_IDX][c]);
                            end
                        end
                    end
                end else if (op_q == OP_CONV) begin
                    if (ps < 9) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                if (((r + KER_R) >= 1) && ((r + KER_R) <= MAT_N) &&
                                    ((c + KER_C) >= 1) && ((c + KER_C) <= MAT_N)) begin
                                    acc_next[r][c] = pipe_acc_q[ps][r][c]
                                        + $signed(pipe_mat_q[ps][r + KER_R - 1][c + KER_C - 1])
                                        * $signed(weight_q[0][KER_R][KER_C]);
                                end
                            end
                        end
                    end
                end else begin
                    if (ps < 8) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                q_acc_next[r][c] = q_acc_q[ps][r][c]
                                    + $signed(pipe_mat_q[ps][r][K_IDX])
                                    * $signed(weight_q[0][K_IDX][c]);
                                k_acc_next[r][c] = k_acc_q[ps][r][c]
                                    + $signed(pipe_mat_q[ps][r][K_IDX])
                                    * $signed(weight_q[1][K_IDX][c]);
                                v_acc_next[r][c] = v_acc_q[ps][r][c]
                                    + $signed(pipe_mat_q[ps][r][K_IDX])
                                    * $signed(weight_q[2][K_IDX][c]);
                            end
                        end
                    end

                    if ((ps >= Q_MAX_START) && (ps < Q_QUANT_STAGE)) begin
                        q_max_next = max_s32(q_max_q[ps], row_abs_max(q_acc_q[ps], Q_ROW));
                    end
                    if (ps == Q_QUANT_STAGE) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                q_mat_next[r][c] = quant_elem(q_acc_q[ps][r][c], q_max_q[ps]);
                            end
                        end
                    end

                    if ((ps >= K_MAX_START) && (ps < K_QUANT_STAGE)) begin
                        k_max_next = max_s32(k_max_q[ps], row_abs_max(k_acc_q[ps], K_ROW));
                    end
                    if (ps == K_QUANT_STAGE) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                k_mat_next[r][c] = quant_elem(k_acc_q[ps][r][c], k_max_q[ps]);
                            end
                        end
                    end

                    if ((ps >= V_MAX_START) && (ps < V_QUANT_STAGE)) begin
                        v_max_next = max_s32(v_max_q[ps], row_abs_max(v_acc_q[ps], V_ROW));
                    end
                    if (ps == V_QUANT_STAGE) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                v_mat_next[r][c] = quant_elem(v_acc_q[ps][r][c], v_max_q[ps]);
                            end
                        end
                    end

                    if ((ps >= SCORE_START) && (ps < PART_STAGE)) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                if (op_q == OP_SHA) begin
                                    score_lo_next[r][c] = score_lo_q[ps][r][c]
                                        + $signed(q_mat_q[ps][r][SCORE_IDX])
                                        * $signed(k_mat_q[ps][c][SCORE_IDX]);
                                end else if (SCORE_IDX < 4) begin
                                    score_lo_next[r][c] = score_lo_q[ps][r][c]
                                        + $signed(q_mat_q[ps][r][SCORE_IDX])
                                        * $signed(k_mat_q[ps][c][SCORE_IDX]);
                                end else begin
                                    score_hi_next[r][c] = score_hi_q[ps][r][c]
                                        + $signed(q_mat_q[ps][r][SCORE_IDX])
                                        * $signed(k_mat_q[ps][c][SCORE_IDX]);
                                end
                            end
                        end
                    end

                    if (ps == PART_STAGE) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                part_lo_next[r][c] = (score_lo_q[ps][r][c] < 0)
                                    ? (score_lo_q[ps][r][c] >>> 2)
                                    : score_lo_q[ps][r][c];
                                part_hi_next[r][c] = (score_hi_q[ps][r][c] < 0)
                                    ? (score_hi_q[ps][r][c] >>> 2)
                                    : score_hi_q[ps][r][c];
                            end
                        end
                    end

                    if ((ps >= CTX_START) && (ps < ACT_START)) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                if (op_q == OP_SHA) begin
                                    context_next[r][c] = context_q[ps][r][c]
                                        + part_lo_q[ps][r][CTX_IDX]
                                        * $signed(v_mat_q[ps][CTX_IDX][c]);
                                end else if (c < 4) begin
                                    context_next[r][c] = context_q[ps][r][c]
                                        + part_lo_q[ps][r][CTX_IDX]
                                        * $signed(v_mat_q[ps][CTX_IDX][c]);
                                end else begin
                                    context_next[r][c] = context_q[ps][r][c]
                                        + part_hi_q[ps][r][CTX_IDX]
                                        * $signed(v_mat_q[ps][CTX_IDX][c]);
                                end
                            end
                        end
                    end
                end

                if (ps == ACT_START) begin
                    if ((op_q == OP_SHA) || (op_q == OP_MHA)) begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                final_src[r][c] = context_q[ps][r][c];
                                act_next[r][c] = context_q[ps][r][c];
                            end
                        end
                    end else begin
                        for (int r = 0; r < MAT_N; r++) begin
                            for (int c = 0; c < MAT_N; c++) begin
                                final_src[r][c] = pipe_acc_q[ps][r][c];
                                act_next[r][c] = pipe_acc_q[ps][r][c];
                            end
                        end
                    end
                    act_thr_next[0] = act_threshold(act_q, final_src, 0);
                end

                if ((ps > ACT_START) && (ps < ACT_APPLY)) begin
                    if ((act_q != ACT_BAT) || (ACT_IDX < 4))
                        act_thr_next[ACT_IDX] = act_threshold(act_q, pipe_act_q[ps], ACT_IDX);
                end

                if (ps == ACT_APPLY) begin
                    for (int r = 0; r < MAT_N; r++) begin
                        for (int c = 0; c < MAT_N; c++) begin
                            if (act_q == ACT_RAT)
                                act_next[r][c] = activate_elem(act_q, pipe_act_q[ps][r][c], act_thr_q[ps][r]);
                            else if (act_q == ACT_CAT)
                                act_next[r][c] = activate_elem(act_q, pipe_act_q[ps][r][c], act_thr_q[ps][c]);
                            else if (act_q == ACT_BAT)
                                act_next[r][c] = activate_elem(act_q, pipe_act_q[ps][r][c],
                                    act_thr_q[ps][(r >= 4 ? 2 : 0) + (c >= 4 ? 1 : 0)]);
                            else
                                act_next[r][c] = activate_elem(act_q, pipe_act_q[ps][r][c], 32'sd0);
                        end
                    end
                end

                if ((ps >= POT_START) && (ps < FINAL_QUANT)) begin
                    final_max_next = max_s32(final_max_q[ps], row_abs_max(pipe_act_q[ps], POT_ROW));
                end

                if (ps == FINAL_QUANT) begin
                    for (int r = 0; r < MAT_N; r++) begin
                        for (int c = 0; c < MAT_N; c++) begin
                            final_q[r][c] = quant_elem(pipe_act_q[ps][r][c], final_max_q[ps]);
                            mat_next[r][c] = final_q[r][c];
                        end
                    end
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_valid_q[ps+1] <= 1'b0;
                    pipe_addr_q[ps+1]  <= 8'd0;
                    q_max_q[ps+1]      <= 32'sd0;
                    k_max_q[ps+1]      <= 32'sd0;
                    v_max_q[ps+1]      <= 32'sd0;
                    final_max_q[ps+1]  <= 32'sd0;
                    for (int i = 0; i < MAT_N; i++) begin
                        act_thr_q[ps+1][i] <= 32'sd0;
                    end
                    for (int r = 0; r < MAT_N; r++) begin
                        for (int c = 0; c < MAT_N; c++) begin
                            pipe_mat_q[ps+1][r][c]  <= '0;
                            pipe_acc_q[ps+1][r][c]  <= '0;
                            pipe_act_q[ps+1][r][c]  <= '0;
                            q_acc_q[ps+1][r][c]     <= '0;
                            k_acc_q[ps+1][r][c]     <= '0;
                            v_acc_q[ps+1][r][c]     <= '0;
                            q_mat_q[ps+1][r][c]     <= '0;
                            k_mat_q[ps+1][r][c]     <= '0;
                            v_mat_q[ps+1][r][c]     <= '0;
                            score_lo_q[ps+1][r][c]  <= '0;
                            score_hi_q[ps+1][r][c]  <= '0;
                            part_lo_q[ps+1][r][c]   <= '0;
                            part_hi_q[ps+1][r][c]   <= '0;
                            context_q[ps+1][r][c]   <= '0;
                        end
                    end
                end else begin
                    pipe_valid_q[ps+1] <= pipe_valid_q[ps];
                    pipe_addr_q[ps+1]  <= pipe_addr_q[ps];
                    q_max_q[ps+1]      <= q_max_next;
                    k_max_q[ps+1]      <= k_max_next;
                    v_max_q[ps+1]      <= v_max_next;
                    final_max_q[ps+1]  <= final_max_next;
                    for (int i = 0; i < MAT_N; i++) begin
                        act_thr_q[ps+1][i] <= act_thr_next[i];
                    end
                    for (int r = 0; r < MAT_N; r++) begin
                        for (int c = 0; c < MAT_N; c++) begin
                            pipe_mat_q[ps+1][r][c]  <= mat_next[r][c];
                            pipe_acc_q[ps+1][r][c]  <= acc_next[r][c];
                            pipe_act_q[ps+1][r][c]  <= act_next[r][c];
                            q_acc_q[ps+1][r][c]     <= q_acc_next[r][c];
                            k_acc_q[ps+1][r][c]     <= k_acc_next[r][c];
                            v_acc_q[ps+1][r][c]     <= v_acc_next[r][c];
                            q_mat_q[ps+1][r][c]     <= q_mat_next[r][c];
                            k_mat_q[ps+1][r][c]     <= k_mat_next[r][c];
                            v_mat_q[ps+1][r][c]     <= v_mat_next[r][c];
                            score_lo_q[ps+1][r][c]  <= score_lo_next[r][c];
                            score_hi_q[ps+1][r][c]  <= score_hi_next[r][c];
                            part_lo_q[ps+1][r][c]   <= part_lo_next[r][c];
                            part_hi_q[ps+1][r][c]   <= part_hi_next[r][c];
                            context_q[ps+1][r][c]   <= context_next[r][c];
                        end
                    end
                end
            end
        end
    endgenerate

    always_comb begin
        pack_word(pipe_mat_q[PIPE_DEPTH], tail_word);
        pack_last_row(pipe_mat_q[PIPE_DEPTH], tail_row);
    end

    assign wr_done_beat = wr_active_q && wr_valid && (wr_count_q == 8'd127);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_fill_count_q <= 7'd0;
            out_fill_tile_q  <= 2'd0;
            out_ready_q      <= '0;
            for (int t = 0; t < TILE_COUNT; t++) begin
                for (int i = 0; i < TILE_WORDS; i++) begin
                    out_tile_q[t][i] <= 256'd0;
                    out_row_q[t][i]  <= 32'd0;
                end
            end
        end else if (job_start) begin
            out_fill_count_q <= 7'd0;
            out_fill_tile_q  <= 2'd0;
            out_ready_q      <= '0;
        end else begin
            if (wr_done_beat)
                out_ready_q[wr_tile_q[0]] <= 1'b0;

            if (pipe_valid_q[PIPE_DEPTH]) begin
                out_tile_q[out_fill_tile_q[0]][out_fill_count_q] <= tail_word;
                out_row_q[out_fill_tile_q[0]][out_fill_count_q]  <= tail_row;
                if (out_fill_count_q == 7'd127) begin
                    out_ready_q[out_fill_tile_q[0]] <= 1'b1;
                    out_fill_count_q <= 7'd0;
                    out_fill_tile_q  <= out_fill_tile_q + 2'd1;
                end else begin
                    out_fill_count_q <= out_fill_count_q + 7'd1;
                end
            end
        end
    end

    always_comb begin
        wr_en       = 1'b0;
        wr_addr     = '0;
        wr_burst    = 3'd7;
        wr_data     = 256'd0;
        out_valid   = 1'b0;
        out_data    = 32'd0;
        wr_active_d = wr_active_q;
        wr_tile_d   = wr_tile_q;
        wr_count_d  = wr_count_q;

        if (job_start) begin
            wr_active_d = 1'b0;
            wr_tile_d   = 2'd0;
            wr_count_d  = 8'd0;
        end else begin
            if (!wr_active_q && (wr_tile_q < 2'd2) && out_ready_q[wr_tile_q[0]] && wr_ready) begin
                wr_en       = 1'b1;
                wr_addr     = wr_tile_q[0] ? 8'd128 : 8'd0;
                wr_burst    = 3'd7;
                wr_active_d = 1'b1;
                wr_count_d  = 8'd0;
            end

            if (wr_active_q && wr_valid) begin
                wr_data   = out_tile_q[wr_tile_q[0]][wr_count_q[6:0]];
                out_valid = 1'b1;
                out_data  = out_row_q[wr_tile_q[0]][wr_count_q[6:0]];
                if (wr_count_q == 8'd127) begin
                    wr_active_d = 1'b0;
                    wr_count_d  = 8'd0;
                    wr_tile_d   = wr_tile_q + 2'd1;
                end else begin
                    wr_count_d = wr_count_q + 8'd1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active_q <= 1'b0;
            wr_tile_q   <= 2'd0;
            wr_count_q  <= 8'd0;
        end else begin
            wr_active_q <= wr_active_d;
            wr_tile_q   <= wr_tile_d;
            wr_count_q  <= wr_count_d;
        end
    end

    always_comb begin
        in_seen_d        = in_seen_q;
        out_seen_d       = out_seen_q;
        all_inputs_seen  = (in_seen_q == 9'd256);
        all_outputs_seen = (out_seen_q == 9'd256);

        if (job_start) begin
            in_seen_d  = 9'd0;
            out_seen_d = 9'd0;
        end else begin
            if (rd_stream_valid && (in_seen_q < 9'd256))
                in_seen_d = in_seen_q + 9'd1;
            if (out_valid && (out_seen_q < 9'd256))
                out_seen_d = out_seen_q + 9'd1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_seen_q  <= 9'd0;
            out_seen_q <= 9'd0;
        end else begin
            in_seen_q  <= in_seen_d;
            out_seen_q <= out_seen_d;
        end
    end

endmodule
