module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    // ============================================= //
    //                    PATTERN                    //
    // ============================================= //
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    output logic                            out_valid,
    output logic [31:0]                     out_data,

    // ============================================= //
    //                      RAM                      //
    // ============================================= //
    // READ
    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

    // WRITE
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst,
    output logic [RAM_WIDTH-1:0]            wr_data,
    input  logic                            wr_valid,
    input  logic                            wr_ready
);
    localparam int ADDR_W = $clog2(RAM_DEPTH);
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;
    localparam int MAT_ELEMS = 64;
    localparam int ACC_W = 16;
    localparam int ACC_VEC_W = MAT_ELEMS * ACC_W;
    localparam int SCORE_ELEM_W = 11;

    typedef enum logic [2:0] {
        S_IDLE,
        S_RUN,
        S_ATT_PARAM,
        S_ATT_READ,
        S_ATT_WAIT_SV
    } state_t;

    typedef enum logic {
        MT_NONE,
        MT_NORM
    } mult_tag_t;

    typedef enum logic [1:0] {
        PT_NONE,
        PT_NORM,
        PT_FINAL
    } pot_tag_t;

    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    state_t              state_q;
    logic [1:0]          op_q;
    logic [1:0]          act_q;
    logic [255:0]        param1_q;
    logic [255:0]        param2_q;
    logic [255:0]        param3_q;
    logic [1:0]          att_param_cnt_q;
    logic [1:0]          rd_req_cnt_q;
    logic [8:0]          rd_word_cnt_q;
    logic [7:0]          out_cnt_q;

    logic                att_group_high_q;
    logic [6:0]          att_final_recv_cnt_q;
    logic                wr_cmd_pending_q;
    logic                wr_cmd_half_q;
    logic                wr_next_half_q;
    logic                wr_cmd_req;

    logic                mult_issue_valid;
    logic [1:0]          mult_issue_op;
    logic [255:0]        mult_issue_A;
    mult_tag_t           mult_issue_tag;
    logic                mult_issue_first;
    logic                mult_valid;
    acc_vec_t            mult_lane_data;
    mult_tag_t           mult_out_tag;
    logic                mult_out_tag_raw;
    logic                mult_out_first;

    logic                act_in_valid;
    acc_vec_t            act_in_data;
    pot_tag_t            act_in_tag;
    logic                act_in_first;
    logic                act_valid;
    acc_vec_t            act_data;
    logic [1:0]          act_out_tag;
    logic                act_out_first;

    logic                pot_in_valid;
    acc_vec_t            pot_in_data;
    pot_tag_t            pot_in_tag;
    logic                pot_valid;
    logic [255:0]        pot_data;
    logic [1:0]          pot_out_tag;
    logic                att_issue_valid;
    logic                att_issue_first;
    logic                att_valid;
    logic                att_out_first;
    acc_vec_t            att_out_data;

    assign wr_cmd_req = act_valid &&
                        act_out_first &&
                        ((pot_tag_t'(act_out_tag) == PT_NORM) ||
                         (pot_tag_t'(act_out_tag) == PT_FINAL));
    always_comb begin
        mult_issue_valid       = 1'b0;
        mult_issue_op          = 2'b00;
        mult_issue_A           = 256'd0;
        mult_issue_tag         = MT_NONE;
        mult_issue_first       = 1'b0;

        case (state_q)
            S_RUN: begin
                if (rd_valid && (rd_word_cnt_q < 9'd256)) begin
                    mult_issue_valid = 1'b1;
                    mult_issue_op    = op_q;
                    mult_issue_A     = rd_data;
                    mult_issue_tag   = MT_NORM;
                    mult_issue_first = (rd_word_cnt_q[6:0] == 7'd0);
                end
            end

            default: begin
            end
        endcase
    end

    assign att_issue_valid = (state_q == S_ATT_READ) &&
                             rd_valid &&
                             (rd_word_cnt_q < 9'd128);
    assign att_issue_first = (rd_word_cnt_q == 9'd0);

    assign act_in_valid = att_valid ||
                          (mult_valid && (mult_out_tag == MT_NORM));
    assign act_in_data  = att_valid ? att_out_data :
                          ((mult_valid && (mult_out_tag == MT_NORM)) ? mult_lane_data : '0);
    assign act_in_first = att_valid ? att_out_first :
                          ((mult_valid && (mult_out_tag == MT_NORM)) ? mult_out_first : 1'b0);

    always_comb begin
        if (att_valid) begin
            act_in_tag = PT_FINAL;
        end
        else begin
            case (mult_out_tag)
                MT_NORM:  act_in_tag = PT_NORM;
                default:  act_in_tag = PT_NONE;
            endcase
        end
    end

    assign pot_in_valid = act_valid;
    assign pot_in_data  = act_data;
    assign pot_in_tag   = act_valid ? pot_tag_t'(act_out_tag) : PT_NONE;

    mult_5stage_parallel #(
        .ACC_W       (ACC_W),
        .MAT_SIZE    (MAT_ELEMS)
    ) u_mult (
        .clk         (clk),
        .rst_n       (rst_n),
        .op          (mult_issue_op),
        .in_valid    (mult_issue_valid),
        .in_data_A   (mult_issue_A),
        .in_data_B   (param1_q),
        .in_tag      (mult_issue_valid ? mult_issue_tag : MT_NONE),
        .in_first    (mult_issue_first),
        .out_valid   (mult_valid),
        .out_lane_data(mult_lane_data),
        .out_tag     (mult_out_tag_raw),
        .out_first   (mult_out_first)
    );

    assign mult_out_tag = mult_tag_t'(mult_out_tag_raw);

    att_full_parallel #(
        .ACC_W       (ACC_W),
        .MAT_SIZE    (MAT_ELEMS),
        .SCORE_ELEM_W(SCORE_ELEM_W)
    ) u_att (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (att_issue_valid),
        .is_mha      (op_q == 2'b11),
        .in_first    (att_issue_first),
        .src_data    (rd_data),
        .wq_data     (param1_q),
        .wk_data     (param2_q),
        .wv_data     (param3_q),
        .out_valid   (att_valid),
        .out_first   (att_out_first),
        .out_data    (att_out_data)
    );

    act_4stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (act_in_valid),
        .act       (act_q),
        .in_data   (act_in_data),
        .in_tag    (act_in_tag),
        .in_first  (act_in_first),
        .out_valid (act_valid),
        .out_data  (act_data),
        .out_tag   (act_out_tag),
        .out_first (act_out_first)
    );

    pot_5stage_parallel #(
        .ACC_W   (ACC_W),
        .MAT_SIZE(MAT_ELEMS)
    ) u_pot (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pot_in_valid),
        .in_data   (pot_in_data),
        .in_tag    (pot_in_tag),
        .out_valid (pot_valid),
        .out_data  (pot_data),
        .out_tag   (pot_out_tag)
    );


    // ==============================================================
    // Control-path sequential registers
    // - FSM, RAM protocol, output valid/data, counters, and attention group control.
    // ==============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ==========================================================
            // Output / RAM interface registers
            // ==========================================================
            rd_en                 <= 1'b0;
            rd_addr               <= '0;
            rd_burst              <= '0;
            wr_en                 <= 1'b0;
            wr_addr               <= '0;
            wr_burst              <= '0;
            wr_data               <= '0;
            out_valid             <= 1'b0;
            out_data              <= 32'd0;

            // ==========================================================
            // Top-level FSM / operation control
            // ==========================================================
            state_q               <= S_IDLE;
            op_q                  <= 2'd0;
            act_q                 <= 2'd0;
            att_param_cnt_q       <= 2'd0;

            // ==========================================================
            // Normal read / write / output counters
            // ==========================================================
            rd_req_cnt_q          <= 2'd0;
            rd_word_cnt_q         <= 9'd0;
            out_cnt_q             <= 8'd0;
            wr_cmd_pending_q      <= 1'b0;
            wr_cmd_half_q         <= 1'b0;
            wr_next_half_q        <= 1'b0;

            // ==========================================================
            // Attention control counters / flags
            // ==========================================================
            att_group_high_q      <= 1'b0;
            att_final_recv_cnt_q  <= 7'd0;

        end
        else begin
            rd_en     <= 1'b0;
            wr_en     <= 1'b0;
            out_valid <= 1'b0;
            rd_burst  <= '0;
            wr_burst  <= '0;

            if (wr_cmd_pending_q && wr_ready) begin
                wr_en             <= 1'b1;
                wr_addr           <= wr_cmd_half_q ? HALF_ADDR : '0;
                wr_burst          <= BURST_128;
                wr_cmd_pending_q  <= 1'b0;
            end

            if (wr_cmd_req) begin
                wr_next_half_q <= 1'b1;

                if (wr_ready && !wr_cmd_pending_q) begin
                    wr_en           <= 1'b1;
                    wr_addr         <= wr_next_half_q ? HALF_ADDR : '0;
                    wr_burst        <= BURST_128;
                end
                else if (!wr_cmd_pending_q || wr_ready) begin
                    wr_cmd_pending_q <= 1'b1;
                    wr_cmd_half_q    <= wr_next_half_q;
                end
            end

            if (pot_valid) begin
                case (pot_out_tag)
                    PT_NORM: begin
                        wr_data   <= pot_data;
                        out_valid <= 1'b1;
                        out_data  <= pot_data[31:0];

                        if (out_cnt_q == 8'd255) begin
                            state_q <= S_IDLE;
                        end
                        else begin
                            out_cnt_q <= out_cnt_q + 1'b1;
                        end
                    end
                    PT_FINAL: begin
                        wr_data   <= pot_data;
                        out_valid <= 1'b1;
                        out_data  <= pot_data[31:0];

                        if (att_final_recv_cnt_q == 7'd127) begin
                            if (att_group_high_q) begin
                                state_q <= S_IDLE;
                            end
                            else begin
                                att_group_high_q     <= 1'b1;
                                rd_req_cnt_q         <= 2'd0;
                                rd_word_cnt_q        <= 9'd0;
                                att_final_recv_cnt_q <= 7'd0;
                                state_q              <= S_ATT_READ;
                            end
                        end
                        else begin
                            att_final_recv_cnt_q <= att_final_recv_cnt_q + 1'b1;
                        end
                    end
                    default: begin
                    end
                endcase
            end

            case (state_q)
                S_IDLE: begin
                    op_q     <= op;
                    act_q    <= act;
                    param1_q <= param;

                    if (mem_set && in_valid) begin
                        if ((op == 2'b00) || (op == 2'b01)) begin
                            rd_req_cnt_q       <= 2'd0;
                            rd_word_cnt_q      <= 9'd0;
                            out_cnt_q          <= 8'd0;
                            wr_next_half_q     <= 1'b0;
                            state_q            <= S_RUN;
                        end
                        else begin
                            att_param_cnt_q <= 2'd1;
                            state_q         <= S_ATT_PARAM;
                        end
                    end
                end

                S_ATT_PARAM: begin
                    if (in_valid) begin
                        if (att_param_cnt_q == 2'd1) begin
                            param2_q <= param;
                            att_param_cnt_q <= 2'd2;
                        end
                        else begin
                            param3_q <= param;
                            att_group_high_q <= 1'b0;
                            rd_req_cnt_q     <= 2'd0;
                            rd_word_cnt_q    <= 9'd0;
                            out_cnt_q        <= 8'd0;
                            wr_next_half_q   <= 1'b0;
                            att_final_recv_cnt_q <= 7'd0;
                            state_q          <= S_ATT_READ;
                        end
                    end
                end

                S_RUN: begin
                    if ((rd_req_cnt_q < 2'd2) && rd_ready) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= rd_req_cnt_q[0] ? HALF_ADDR : '0;
                        rd_burst     <= BURST_128;
                        rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
                    end

                    if (mult_issue_valid) begin
                        rd_word_cnt_q <= rd_word_cnt_q + 1'b1;
                    end
                end

                S_ATT_READ: begin
                    if ((rd_req_cnt_q == 2'd0) && rd_ready) begin
                        rd_en        <= 1'b1;
                        rd_addr      <= att_group_high_q ? HALF_ADDR : '0;
                        rd_burst     <= BURST_128;
                        rd_req_cnt_q <= 2'd1;
                    end

                    if (rd_valid && (rd_word_cnt_q < 9'd128)) begin
                        rd_word_cnt_q <= rd_word_cnt_q + 1'b1;

                        if (rd_word_cnt_q == 9'd127) begin
                            state_q <= S_ATT_WAIT_SV;
                        end
                    end
                end

                S_ATT_WAIT_SV: begin
                    // The final outputs are counted in the PT_FINAL path above.
                end

                default: begin
                    state_q <= S_IDLE;
                end
            endcase
        end
    end

endmodule


module att_full_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64,
    parameter int SCORE_ELEM_W = 11
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_mha,
    input  logic                 in_first,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    input  logic [255:0]         wk_data,
    input  logic [255:0]         wv_data,
    output logic                 out_valid,
    output logic                 out_first,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data
);

    localparam int ROW_ELEM   = 8;
    localparam int PROJ_W     = 11;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [7:0]  prod_t;
    typedef logic signed [8:0]  score_pair_t;
    typedef logic signed [9:0]  score_half_t;
    typedef logic signed [10:0] score_sum_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic signed [12:0] score_prod_t;
    typedef logic signed [14:0] final_part_t;
    typedef logic signed [SCORE_ELEM_W-1:0] score_t;
    typedef logic [3:0] mag4_t;
    typedef logic [6:0] magprod_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    logic                 proj_valid;
    logic                 proj_mha;
    logic                 proj_first;
    logic [255:0]         q_proj_data;
    logic [255:0]         k_proj_data;
    logic [255:0]         v_proj_data;

    logic                 score_prod_valid_q;
    logic                 score_prod_mha_q;
    logic                 score_prod_first_q;
    logic [255:0]         score_prod_v_q;
    prod_t                score_prod_q [0:MAT_SIZE-1][0:ROW_ELEM-1];

    logic                 score_pair_valid_q;
    logic                 score_pair_mha_q;
    logic                 score_pair_first_q;
    logic [255:0]         score_pair_v_q;
    score_pair_t          score_pair_q [0:MAT_SIZE-1][0:3];

    logic                 score_part_valid_q;
    logic                 score_part_mha_q;
    logic                 score_part_first_q;
    logic [255:0]         score_part_v_q;
    score_half_t          score_lo_q [0:MAT_SIZE-1];
    score_half_t          score_hi_q [0:MAT_SIZE-1];

    logic                 score_valid_q;
    logic                 score_first_q;
    logic [255:0]         score_v_q;
    score_t               score0_q [0:MAT_SIZE-1];
    score_t               score1_q [0:MAT_SIZE-1];

    logic                 final_prod_valid_q;
    logic                 final_prod_first_q;
    score_prod_t          final_prod_q [0:MAT_SIZE-1][0:7];

    logic                 final_part_valid_q;
    logic                 final_part_first_q;
    final_part_t          final_part_q [0:MAT_SIZE-1][0:1];

    prod_t                score_prod_next [0:MAT_SIZE-1][0:ROW_ELEM-1];
    score_pair_t          score_pair_next [0:MAT_SIZE-1][0:3];
    score_half_t          score_lo_next [0:MAT_SIZE-1];
    score_half_t          score_hi_next [0:MAT_SIZE-1];
    score_t               score0_next [0:MAT_SIZE-1];
    score_t               score1_next [0:MAT_SIZE-1];
    score_prod_t          final_prod_next [0:MAT_SIZE-1][0:7];
    final_part_t          final_part_next [0:MAT_SIZE-1][0:1];
    acc_vec_t             final_next;

    att_qkv_proj_pipe #(
        .PROJ_W  (PROJ_W),
        .MAT_SIZE(MAT_SIZE)
    ) u_qkv_proj (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .is_mha     (is_mha),
        .in_first   (in_first),
        .src_data   (src_data),
        .wq_data    (wq_data),
        .wk_data    (wk_data),
        .wv_data    (wv_data),
        .out_valid  (proj_valid),
        .out_mha    (proj_mha),
        .out_first  (proj_first),
        .q_data     (q_proj_data),
        .k_data     (k_proj_data),
        .v_data     (v_proj_data)
    );

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic score_t att_score_value(input score_sum_t value);
        score_sum_t act_score;
        begin
            act_score = (value < 0) ? (value >>> 2) : value;
            att_score_value = score_t'(act_score);
        end
    endfunction

    function automatic mag4_t abs_s4(input s4_t value);
        abs_s4 = value[3] ? mag4_t'(~value + 4'd1) : mag4_t'(value);
    endfunction

    function automatic magprod_t pp_term(input mag4_t mag, input logic bit_en, input int shift);
        magprod_t ext_mag;
        begin
            ext_mag = magprod_t'(mag);
            pp_term = bit_en ? magprod_t'(ext_mag << shift) : '0;
        end
    endfunction

    function automatic prod_t mul_s4_shift(input s4_t a, input s4_t b);
        mag4_t    amag;
        mag4_t    bmag;
        magprod_t mag_prod;
        logic [7:0] unsigned_prod;
        begin
            amag = abs_s4(a);
            bmag = abs_s4(b);
            mag_prod = (pp_term(amag, bmag[0], 0) + pp_term(amag, bmag[1], 1)) +
                       (pp_term(amag, bmag[2], 2) + pp_term(amag, bmag[3], 3));
            unsigned_prod = {1'b0, mag_prod};
            mul_s4_shift = (a[3] ^ b[3]) ? prod_t'(-$signed(unsigned_prod)) :
                                           prod_t'($signed(unsigned_prod));
        end
    endfunction

    function automatic prod_t calc_score_prod(
        input logic [255:0] q_mat,
        input logic [255:0] k_mat,
        input integer       row,
        input integer       lane,
        input integer       tap
    );
        begin
            calc_score_prod = prod_t'($signed(get_s4(q_mat, (row * ROW_ELEM) + tap)) *
                                      $signed(get_s4(k_mat, (lane * ROW_ELEM) + tap)));
        end
    endfunction

    function automatic score_prod_t booth_pp(
        input score_t     value,
        input logic [2:0] booth
    );
        score_prod_t ext_value;
        begin
            ext_value = score_prod_t'(value);
            unique case (booth)
                3'b001,
                3'b010: booth_pp = ext_value;
                3'b011: booth_pp = score_prod_t'(ext_value <<< 1);
                3'b100: booth_pp = score_prod_t'(-(ext_value <<< 1));
                3'b101,
                3'b110: booth_pp = score_prod_t'(-ext_value);
                default: booth_pp = '0;
            endcase
        end
    endfunction

    function automatic score_prod_t calc_final_prod(
        input score_t       score_mat [0:MAT_SIZE-1],
        input logic [255:0] v_mat,
        input integer       row,
        input integer       lane,
        input integer       tap_idx
    );
        s4_t         v_value;
        score_prod_t pp0;
        score_prod_t pp1;
        begin
            v_value = get_s4(v_mat, (tap_idx * ROW_ELEM) + lane);
            pp0 = booth_pp(score_mat[(row * ROW_ELEM) + tap_idx],
                           {v_value[1], v_value[0], 1'b0});
            pp1 = booth_pp(score_mat[(row * ROW_ELEM) + tap_idx],
                           {v_value[3], v_value[2], v_value[1]});
            calc_final_prod = score_prod_t'(pp0 + score_prod_t'(pp1 <<< 2));
        end
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    score_prod_next[(row * ROW_ELEM) + lane][tap] =
                        calc_score_prod(q_proj_data, k_proj_data, row, lane, tap);
                end
                score_pair_next[(row * ROW_ELEM) + lane][0] =
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][0]) +
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][1]);
                score_pair_next[(row * ROW_ELEM) + lane][1] =
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][2]) +
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][3]);
                score_pair_next[(row * ROW_ELEM) + lane][2] =
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][4]) +
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][5]);
                score_pair_next[(row * ROW_ELEM) + lane][3] =
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][6]) +
                    score_pair_t'(score_prod_q[(row * ROW_ELEM) + lane][7]);
                score_lo_next[(row * ROW_ELEM) + lane] =
                    score_half_t'(score_pair_q[(row * ROW_ELEM) + lane][0]) +
                    score_half_t'(score_pair_q[(row * ROW_ELEM) + lane][1]);
                score_hi_next[(row * ROW_ELEM) + lane] =
                    score_half_t'(score_pair_q[(row * ROW_ELEM) + lane][2]) +
                    score_half_t'(score_pair_q[(row * ROW_ELEM) + lane][3]);
                score0_next[(row * ROW_ELEM) + lane] = score_part_mha_q ?
                    att_score_value(score_sum_t'(score_lo_q[(row * ROW_ELEM) + lane])) :
                    att_score_value(score_sum_t'(score_lo_q[(row * ROW_ELEM) + lane] +
                                                 score_hi_q[(row * ROW_ELEM) + lane]));
                score1_next[(row * ROW_ELEM) + lane] = score_part_mha_q ?
                    att_score_value(score_sum_t'(score_hi_q[(row * ROW_ELEM) + lane])) :
                    score0_next[(row * ROW_ELEM) + lane];
                for (int tap = 0; tap < ROW_ELEM; tap++) begin
                    if (lane < 4) begin
                        final_prod_next[(row * ROW_ELEM) + lane][tap] =
                            calc_final_prod(score0_q, score_v_q, row, lane, tap);
                    end
                    else begin
                        final_prod_next[(row * ROW_ELEM) + lane][tap] =
                            calc_final_prod(score1_q, score_v_q, row, lane, tap);
                    end
                end
                final_part_next[(row * ROW_ELEM) + lane][0] =
                    (final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][0]) +
                     final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][1])) +
                    (final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][2]) +
                     final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][3]));
                final_part_next[(row * ROW_ELEM) + lane][1] =
                    (final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][4]) +
                     final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][5])) +
                    (final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][6]) +
                     final_part_t'(final_prod_q[(row * ROW_ELEM) + lane][7]));

                final_next[ACC_VEC_W - 1 - (((row * ROW_ELEM) + lane) * ACC_W) -: ACC_W] =
                    acc_t'(final_part_q[(row * ROW_ELEM) + lane][0]) +
                    acc_t'(final_part_q[(row * ROW_ELEM) + lane][1]);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            score_prod_valid_q <= 1'b0;
            score_pair_valid_q <= 1'b0;
            score_part_valid_q <= 1'b0;
            score_valid_q      <= 1'b0;
            final_prod_valid_q <= 1'b0;
            final_part_valid_q <= 1'b0;
            out_valid          <= 1'b0;
            out_first          <= 1'b0;
        end
        else begin
            score_prod_valid_q <= proj_valid;
            score_pair_valid_q <= score_prod_valid_q;
            score_part_valid_q <= score_pair_valid_q;
            score_valid_q      <= score_part_valid_q;
            final_prod_valid_q <= score_valid_q;
            final_part_valid_q <= final_prod_valid_q;
            out_valid          <= final_part_valid_q;

            if (proj_valid) begin
                score_prod_mha_q   <= proj_mha;
                score_prod_first_q <= proj_first;
                score_prod_v_q     <= v_proj_data;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        score_prod_q[i][tap] <= score_prod_next[i][tap];
                    end
                end
            end

            if (score_prod_valid_q) begin
                score_pair_mha_q   <= score_prod_mha_q;
                score_pair_first_q <= score_prod_first_q;
                score_pair_v_q     <= score_prod_v_q;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int p = 0; p < 4; p++) begin
                        score_pair_q[i][p] <= score_pair_next[i][p];
                    end
                end
            end

            if (score_pair_valid_q) begin
                score_part_mha_q   <= score_pair_mha_q;
                score_part_first_q <= score_pair_first_q;
                score_part_v_q     <= score_pair_v_q;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    score_lo_q[i] <= score_lo_next[i];
                    score_hi_q[i] <= score_hi_next[i];
                end
            end

            if (score_part_valid_q) begin
                score_first_q <= score_part_first_q;
                score_v_q     <= score_part_v_q;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    score0_q[i] <= score0_next[i];
                    score1_q[i] <= score1_next[i];
                end
            end

            if (score_valid_q) begin
                final_prod_first_q <= score_first_q;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        final_prod_q[i][tap] <= final_prod_next[i][tap];
                    end
                end
            end

            if (final_prod_valid_q) begin
                final_part_first_q <= final_prod_first_q;
                for (int i = 0; i < MAT_SIZE; i++) begin
                    for (int p = 0; p < 2; p++) begin
                        final_part_q[i][p] <= final_part_next[i][p];
                    end
                end
            end

            if (final_part_valid_q) begin
                out_first <= final_part_first_q;
                out_data  <= final_next;
            end
        end
    end

endmodule


module att_qkv_proj_pipe #(
    parameter int PROJ_W = 11,
    parameter int MAT_SIZE = 64
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic                 is_mha,
    input  logic                 in_first,
    input  logic [255:0]         src_data,
    input  logic [255:0]         wq_data,
    input  logic [255:0]         wk_data,
    input  logic [255:0]         wv_data,
    output logic                 out_valid,
    output logic                 out_mha,
    output logic                 out_first,
    output logic [255:0]         q_data,
    output logic [255:0]         k_data,
    output logic [255:0]         v_data
);

    localparam int ROW_ELEM    = 8;
    localparam int PIPE_COUNT  = 3;
    localparam int Q_PIPE      = 0;
    localparam int K_PIPE      = 1;
    localparam int V_PIPE      = 2;
    localparam int SHIFT_W     = $clog2(PROJ_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0] s4_t;
    typedef logic signed [7:0] prod_t;
    typedef logic signed [9:0] part_t;
    typedef logic signed [PROJ_W-1:0] proj_t;
    typedef logic [PROJ_W-1:0] proj_mag_t;
    typedef logic [3:0] mag4_t;
    typedef logic [6:0] magprod_t;

    logic                 buf_valid_q;
    logic                 pp_valid_q;
    logic                 prod_valid_q;
    logic                 part_valid_q;
    logic                 sum_valid_q;
    logic                 max_valid_q;
    logic [255:0]         src_q;
    logic                 mha0_q;
    logic                 first0_q;
    logic                 mha1_q;
    logic                 first1_q;
    logic                 mha2_q;
    logic                 first2_q;
    logic                 mha3_q;
    logic                 first3_q;
    logic                 mha4_q;
    logic                 first4_q;
    logic                 mha5_q;
    logic                 first5_q;

    s4_t   src_sel_q [0:MAT_SIZE-1][0:7];
    s4_t   weight_sel_q [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    logic  prod_sign_q [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    magprod_t prod_lo_q [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    magprod_t prod_hi_q [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    prod_t prod_q    [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    part_t part_q    [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:1];
    proj_t sum_q     [0:PIPE_COUNT-1][0:MAT_SIZE-1];
    proj_t max_data_q [0:PIPE_COUNT-1][0:MAT_SIZE-1];
    proj_mag_t max_mask_q [0:PIPE_COUNT-1];
    s4_t   src_sel_next [0:MAT_SIZE-1][0:7];
    s4_t   weight_sel_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    logic  prod_sign_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    magprod_t prod_lo_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    magprod_t prod_hi_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    prod_t prod_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:7];
    part_t part_next [0:PIPE_COUNT-1][0:MAT_SIZE-1][0:1];
    proj_t sum_next  [0:PIPE_COUNT-1][0:MAT_SIZE-1];

    function automatic s4_t get_s4(input logic [255:0] vec, input integer idx);
        get_s4 = $signed(vec[255 - (idx * 4) -: 4]);
    endfunction

    function automatic proj_mag_t abs_proj(input proj_t value);
        abs_proj = value[PROJ_W - 1] ? proj_mag_t'(-value) : proj_mag_t'(value);
    endfunction

    function automatic mag4_t abs_s4(input s4_t value);
        abs_s4 = value[3] ? mag4_t'(~value + 4'd1) : mag4_t'(value);
    endfunction

    function automatic magprod_t pp_term(input mag4_t mag, input logic bit_en, input int shift);
        magprod_t ext_mag;
        begin
            ext_mag = magprod_t'(mag);
            pp_term = bit_en ? magprod_t'(ext_mag << shift) : '0;
        end
    endfunction

    function automatic prod_t signed_product_from_parts(
        input logic     sign,
        input magprod_t lo,
        input magprod_t hi
    );
        logic [7:0] unsigned_prod;
        begin
            unsigned_prod = {1'b0, magprod_t'(lo + hi)};
            signed_product_from_parts = sign ? prod_t'(-$signed(unsigned_prod)) :
                                               prod_t'($signed(unsigned_prod));
        end
    endfunction

    function automatic logic prod_sign_part(input s4_t a, input s4_t b);
        prod_sign_part = a[3] ^ b[3];
    endfunction

    function automatic magprod_t prod_lo_part(input s4_t a, input s4_t b);
        mag4_t amag;
        mag4_t bmag;
        begin
            amag = abs_s4(a);
            bmag = abs_s4(b);
            prod_lo_part = pp_term(amag, bmag[0], 0) +
                           pp_term(amag, bmag[1], 1);
        end
    endfunction

    function automatic magprod_t prod_hi_part(input s4_t a, input s4_t b);
        mag4_t amag;
        mag4_t bmag;
        begin
            amag = abs_s4(a);
            bmag = abs_s4(b);
            prod_hi_part = pp_term(amag, bmag[2], 2) +
                           pp_term(amag, bmag[3], 3);
        end
    endfunction

    function automatic proj_mag_t max_abs_pipe(input integer pipe);
        begin
            max_abs_pipe = '0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                max_abs_pipe |= abs_proj(sum_q[pipe][i]);
            end
        end
    endfunction

    function automatic logic [SHIFT_W-1:0] pot_shift(input proj_mag_t max_abs);
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

    function automatic logic [255:0] quant_pipe(
        input integer             pipe,
        input logic [SHIFT_W-1:0] shift
    );
        begin
            quant_pipe = 256'd0;

            for (int i = 0; i < MAT_SIZE; i++) begin
                quant_pipe[255 - (i * 4) -: 4] = clamp_s4(max_data_q[pipe][i] >>> shift);
            end
        end
    endfunction

    function automatic prod_t calc_proj_prod(
        input logic [255:0] src,
        input logic [255:0] weight,
        input integer       row,
        input integer       lane,
        input integer       tap
    );
        begin
            calc_proj_prod = prod_t'($signed(get_s4(src, (row * ROW_ELEM) + tap)) *
                                     $signed(get_s4(weight, (tap * ROW_ELEM) + lane)));
        end
    endfunction

    function automatic prod_t calc_proj_prod_from_s4(input s4_t src, input s4_t weight);
        calc_proj_prod_from_s4 = prod_t'($signed(src) * $signed(weight));
    endfunction

    function automatic logic [255:0] proj_weight(input integer pipe);
        begin
            unique case (pipe)
                Q_PIPE:  proj_weight = wq_data;
                K_PIPE:  proj_weight = wk_data;
                default: proj_weight = wv_data;
            endcase
        end
    endfunction

    function automatic proj_t calc_proj_sum(input integer pipe, input integer elem);
        begin
            calc_proj_sum = proj_t'(part_q[pipe][elem][0]) +
                            proj_t'(part_q[pipe][elem][1]);
        end
    endfunction

    always_comb begin
        for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
            for (int row = 0; row < ROW_ELEM; row++) begin
                for (int lane = 0; lane < ROW_ELEM; lane++) begin
                    for (int tap = 0; tap < ROW_ELEM; tap++) begin
                        src_sel_next[(row * ROW_ELEM) + lane][tap] =
                            get_s4(src_data, (row * ROW_ELEM) + tap);
                        weight_sel_next[pipe][(row * ROW_ELEM) + lane][tap] =
                            get_s4(proj_weight(pipe), (tap * ROW_ELEM) + lane);
                        prod_next[pipe][(row * ROW_ELEM) + lane][tap] =
                            calc_proj_prod_from_s4(src_sel_q[(row * ROW_ELEM) + lane][tap],
                                                   weight_sel_q[pipe][(row * ROW_ELEM) + lane][tap]);
                    end
                    part_next[pipe][(row * ROW_ELEM) + lane][0] =
                        (part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][0]) +
                         part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][1])) +
                        (part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][2]) +
                         part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][3]));
                    part_next[pipe][(row * ROW_ELEM) + lane][1] =
                        (part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][4]) +
                         part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][5])) +
                        (part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][6]) +
                         part_t'(prod_q[pipe][(row * ROW_ELEM) + lane][7]));
                    sum_next[pipe][(row * ROW_ELEM) + lane] =
                        calc_proj_sum(pipe, (row * ROW_ELEM) + lane);
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid_q  <= 1'b0;
            prod_valid_q <= 1'b0;
            part_valid_q <= 1'b0;
            sum_valid_q  <= 1'b0;
            max_valid_q  <= 1'b0;
            out_valid    <= 1'b0;
            out_mha      <= 1'b0;
            out_first    <= 1'b0;
        end
        else begin
            buf_valid_q  <= in_valid;
            prod_valid_q <= buf_valid_q;
            part_valid_q <= prod_valid_q;
            sum_valid_q  <= part_valid_q;
            max_valid_q  <= sum_valid_q;
            out_valid    <= max_valid_q;

            src_q             <= src_data;
            mha0_q            <= is_mha;
            first0_q          <= in_first;

            if (in_valid) begin
                for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        for (int tap = 0; tap < ROW_ELEM; tap++) begin
                            src_sel_q[i][tap]          <= src_sel_next[i][tap];
                            weight_sel_q[pipe][i][tap] <= weight_sel_next[pipe][i][tap];
                        end
                    end
                end
            end

            if (buf_valid_q) begin
                mha1_q   <= mha0_q;
                first1_q <= first0_q;
                for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        for (int tap = 0; tap < ROW_ELEM; tap++) begin
                            prod_q[pipe][i][tap] <= prod_next[pipe][i][tap];
                        end
                    end
                end
            end

            if (prod_valid_q) begin
                mha2_q   <= mha1_q;
                first2_q <= first1_q;
                for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        for (int p = 0; p < 2; p++) begin
                            part_q[pipe][i][p] <= part_next[pipe][i][p];
                        end
                    end
                end
            end

            if (part_valid_q) begin
                mha3_q   <= mha2_q;
                first3_q <= first2_q;
                for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        sum_q[pipe][i] <= sum_next[pipe][i];
                    end
                end
            end

            if (sum_valid_q) begin
                mha4_q   <= mha3_q;
                first4_q <= first3_q;
                for (int pipe = 0; pipe < PIPE_COUNT; pipe++) begin
                    max_mask_q[pipe] <= max_abs_pipe(pipe);
                    for (int i = 0; i < MAT_SIZE; i++) begin
                        max_data_q[pipe][i] <= sum_q[pipe][i];
                    end
                end
            end

            if (max_valid_q) begin
                out_mha   <= mha4_q;
                out_first <= first4_q;
                q_data    <= quant_pipe(Q_PIPE, pot_shift(max_mask_q[Q_PIPE]));
                k_data    <= quant_pipe(K_PIPE, pot_shift(max_mask_q[K_PIPE]));
                v_data    <= quant_pipe(V_PIPE, pot_shift(max_mask_q[V_PIPE]));
            end
        end
    end

endmodule


module mult_5stage_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic                 in_valid,
    input  logic [255:0]         in_data_A,
    input  logic [255:0]         in_data_B,
    input  logic                 in_tag,
    input  logic                 in_first,
    output logic                 out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_lane_data,
    output logic                 out_tag,
    output logic                 out_first
);

    localparam int ROW_ELEM = 8;
    localparam int DOT_SIZE = 9;
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [7:0]  prod_t;
    typedef logic signed [9:0]  part_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [3:0] mag4_t;
    typedef logic [6:0] magprod_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    // Pipeline:
    //   issue cycle
    //   +1 input buffer visible to selected operand logic
    //   +2 selected operand registers
    //   +3 product registers
    //   +4 partial-sum registers
    //   +5 lane sum registers / externally visible output
    logic         buf_valid_q;
    logic         sel_valid_q;
    logic         pp_valid_q;
    logic         prod_valid_q;
    logic         part_valid_q;

    logic [1:0]   op_q;
    logic [255:0] in_data_A_q;

    logic tag0_q, tag1_q, tag2_q, tag3_q, tag4_q;
    logic first0_q, first1_q, first2_q, first3_q, first4_q;

    s4_t   a_sel_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t   b_sel_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    logic  prod_sign_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    magprod_t prod_lo_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    magprod_t prod_hi_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    prod_t prod_q [0:MAT_SIZE-1][0:DOT_SIZE-1];
    part_t part_q [0:MAT_SIZE-1][0:1];
    acc_t  sum_q  [0:MAT_SIZE-1];

    s4_t   a_sel_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    s4_t   b_sel_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    logic  prod_sign_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    magprod_t prod_lo_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    magprod_t prod_hi_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    prod_t prod_next [0:MAT_SIZE-1][0:DOT_SIZE-1];
    part_t part_next [0:MAT_SIZE-1][0:1];
    acc_t  sum_next  [0:MAT_SIZE-1];
    acc_vec_t sum_plain_q;

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

    function automatic mag4_t abs_s4(input s4_t value);
        abs_s4 = value[3] ? mag4_t'(~value + 4'd1) : mag4_t'(value);
    endfunction

    function automatic magprod_t pp_term(input mag4_t mag, input logic bit_en, input int shift);
        magprod_t ext_mag;
        begin
            ext_mag = magprod_t'(mag);
            pp_term = bit_en ? magprod_t'(ext_mag << shift) : '0;
        end
    endfunction

    function automatic prod_t signed_product_from_parts(
        input logic     sign,
        input magprod_t lo,
        input magprod_t hi
    );
        logic [7:0] unsigned_prod;
        begin
            unsigned_prod = {1'b0, magprod_t'(lo + hi)};
            signed_product_from_parts = sign ? prod_t'(-$signed(unsigned_prod)) :
                                               prod_t'($signed(unsigned_prod));
        end
    endfunction

    function automatic logic prod_sign_part(input s4_t a, input s4_t b);
        prod_sign_part = a[3] ^ b[3];
    endfunction

    function automatic magprod_t prod_lo_part(input s4_t a, input s4_t b);
        mag4_t amag;
        mag4_t bmag;
        begin
            amag = abs_s4(a);
            bmag = abs_s4(b);
            prod_lo_part = pp_term(amag, bmag[0], 0) +
                           pp_term(amag, bmag[1], 1);
        end
    endfunction

    function automatic magprod_t prod_hi_part(input s4_t a, input s4_t b);
        mag4_t amag;
        mag4_t bmag;
        begin
            amag = abs_s4(a);
            bmag = abs_s4(b);
            prod_hi_part = pp_term(amag, bmag[2], 2) +
                           pp_term(amag, bmag[3], 3);
        end
    endfunction

    function automatic s4_t sel_a4(
        input logic [255:0] mat_A,
        input logic [1:0]   op_sel,
        input integer       elem_idx,
        input integer       tap
    );
        integer row;
        integer col;
        begin
            row = elem_idx / ROW_ELEM;
            col = elem_idx % ROW_ELEM;

            if (op_sel == 2'b01) begin
                sel_a4 = get_pad_s4(mat_A, row + (tap / 3) - 1, col + (tap % 3) - 1);
            end
            else if (tap == 8) begin
                sel_a4 = 4'sd0;
            end
            else begin
                sel_a4 = get_s4(mat_A, (row * ROW_ELEM) + tap);
            end
        end
    endfunction

    function automatic s4_t sel_b4(
        input logic [255:0] mat_B,
        input logic [1:0]   op_sel,
        input integer       lane,
        input integer       tap
    );
        begin
            if (op_sel == 2'b01) begin
                sel_b4 = get_s4(mat_B, tap);
            end
            else if (tap == 8) begin
                sel_b4 = 4'sd0;
            end
            else begin
                sel_b4 = get_s4(mat_B, (tap * ROW_ELEM) + lane);
            end
        end
    endfunction

    always_comb begin
        for (int row = 0; row < ROW_ELEM; row++) begin
            for (int lane = 0; lane < ROW_ELEM; lane++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    b_sel_next[(row * ROW_ELEM) + lane][tap] =
                        sel_b4(in_data_B, op_q, lane, tap);
                    a_sel_next[(row * ROW_ELEM) + lane][tap] =
                        sel_a4(in_data_A_q, op_q, (row * ROW_ELEM) + lane, tap);
                    prod_next[(row * ROW_ELEM) + lane][tap] =
                        prod_t'($signed(a_sel_q[(row * ROW_ELEM) + lane][tap]) *
                                $signed(b_sel_q[(row * ROW_ELEM) + lane][tap]));
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < MAT_SIZE; i++) begin
            part_next[i][0] = (part_t'(prod_q[i][0]) + part_t'(prod_q[i][1])) +
                              (part_t'(prod_q[i][2]) + part_t'(prod_q[i][3]));
            part_next[i][1] = (part_t'(prod_q[i][4]) + part_t'(prod_q[i][5])) +
                              (part_t'(prod_q[i][6]) + part_t'(prod_q[i][7])) +
                              part_t'(prod_q[i][8]);
            sum_next[i] = acc_t'(part_q[i][0]) + acc_t'(part_q[i][1]);
        end
    end
    function automatic acc_vec_t pack_sum(input acc_t lanes [0:MAT_SIZE-1]);
        begin
            pack_sum = '0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                pack_sum[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] = lanes[i];
            end
        end
    endfunction

    assign sum_plain_q = pack_sum(sum_q);
    assign out_lane_data = sum_plain_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid_q  <= 1'b0;
            sel_valid_q  <= 1'b0;
            prod_valid_q <= 1'b0;
            part_valid_q <= 1'b0;
            out_valid    <= 1'b0;
            out_tag      <= 1'b0;
            out_first    <= 1'b0;
        end
        else begin
            // Stage 0: register whole matrix operands.
            buf_valid_q      <= in_valid;
            op_q             <= op;
            in_data_A_q      <= in_data_A;

            tag0_q  <= in_tag;
            first0_q <= in_first;

            // Pipeline valid and metadata.
            sel_valid_q  <= buf_valid_q;
            prod_valid_q <= sel_valid_q;
            part_valid_q <= prod_valid_q;
            tag1_q       <= tag0_q;
            first1_q     <= first0_q;
            tag2_q       <= tag1_q;
            first2_q     <= first1_q;
            tag3_q       <= tag2_q;
            first3_q     <= first2_q;

            out_valid <= part_valid_q;

            if (part_valid_q) begin
                out_tag   <= tag3_q;
                out_first <= first3_q;
            end

        end
    end

    always_ff @(posedge clk) begin
        // Stage 1: select operands, cutting the mode mux away from the
        // multiplier stage for shorter clock targets.
        if (buf_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    a_sel_q[i][tap] <= a_sel_next[i][tap];
                end
            end

            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    b_sel_q[i][tap] <= b_sel_next[i][tap];
                end
            end
        end

        // Stage 2: one shared explicit signed 4-bit multiplier array.
        if (sel_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int tap = 0; tap < DOT_SIZE; tap++) begin
                    prod_q[i][tap] <= prod_next[i][tap];
                end
            end
        end

        // Stage 3: reduce nine products into two partial sums.
        if (prod_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                for (int p = 0; p < 2; p++) begin
                    part_q[i][p] <= part_next[i][p];
                end
            end
        end

        // Stage 4: reduce two partial sums into one 16-bit lane sum.
        if (part_valid_q) begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                sum_q[i] <= sum_next[i];
            end
        end
    end

endmodule


module act_4stage_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1:0]    act,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    input  logic [1:0]    in_tag,
    input  logic          in_first,
    output logic          out_valid,
    output logic [(MAT_SIZE*ACC_W)-1:0] out_data,
    output logic [1:0]    out_tag,
    output logic          out_first
);

    localparam int ROW_ELEM   = 8;
    localparam int AVG_GROUPS = 8;
    localparam int PSUM_CNT   = 4;
    localparam int ACC_VEC_W  = MAT_SIZE * ACC_W;
    localparam int PSUM_W     = ACC_W + 2;
    localparam int AVG_SUM_W  = ACC_W + 4;

    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;
    typedef logic signed [PSUM_W-1:0] psum_t;
    typedef logic signed [AVG_SUM_W-1:0] avg_sum_t;
    typedef logic signed [ACC_W-1:0] avg_t;

    logic          s0_valid_q;
    logic [1:0]    s0_act_q;
    acc_vec_t      s0_data_q;
    logic [1:0]    s0_tag_q;
    logic          s0_first_q;

    logic          psum_valid_q;
    logic [1:0]    psum_act_q;
    acc_vec_t      psum_data_q;
    logic [1:0]    psum_tag_q;
    logic          psum_first_q;
    psum_t         psum_q [0:AVG_GROUPS-1][0:PSUM_CNT-1];

    logic          avg_valid_q;
    logic          avg_relu_q;
    logic          avg_rat_q;
    logic          avg_cat_q;
    acc_vec_t      avg_data_q;
    logic [1:0]    avg_tag_q;
    logic          avg_first_q;
    avg_t          avg_q [0:AVG_GROUPS-1];

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic psum_t ext_psum(input acc_t value);
        ext_psum = psum_t'(value);
    endfunction

    function automatic psum_t calc_rat_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        begin
            calc_rat_psum = ext_psum(get_acc(matrix, (group * ROW_ELEM) + (part * 2) + 0)) +
                            ext_psum(get_acc(matrix, (group * ROW_ELEM) + (part * 2) + 1));
        end
    endfunction

    function automatic psum_t calc_cat_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        begin
            calc_cat_psum = ext_psum(get_acc(matrix, (((part * 2) + 0) * ROW_ELEM) + group)) +
                            ext_psum(get_acc(matrix, (((part * 2) + 1) * ROW_ELEM) + group));
        end
    endfunction

    function automatic psum_t calc_bat_row_psum(
        input acc_vec_t matrix,
        input integer   group,
        input integer   part
    );
        integer row_base;
        integer col_base;
        integer row;
        integer base_idx;
        psum_t  sum_lo;
        psum_t  sum_hi;
        begin
            if (group < 4) begin
                row_base = (group / 2) * 4;
                col_base = (group % 2) * 4;
                row = row_base + part;
                base_idx = (row * ROW_ELEM) + col_base;
                sum_lo = ext_psum(get_acc(matrix, base_idx + 0)) +
                         ext_psum(get_acc(matrix, base_idx + 1));
                sum_hi = ext_psum(get_acc(matrix, base_idx + 2)) +
                         ext_psum(get_acc(matrix, base_idx + 3));
                calc_bat_row_psum = sum_lo + sum_hi;
            end
            else begin
                calc_bat_row_psum = '0;
            end
        end
    endfunction

    function automatic avg_t calc_final_avg(
        input logic [1:0] act_sel,
        input psum_t      p0,
        input psum_t      p1,
        input psum_t      p2,
        input psum_t      p3
    );
        logic [AVG_SUM_W-1:0] sx0;
        logic [AVG_SUM_W-1:0] sx1;
        logic [AVG_SUM_W-1:0] sx2;
        logic [AVG_SUM_W-1:0] sx3;
        logic [AVG_SUM_W-1:0] csa1_sum;
        logic [AVG_SUM_W-1:0] csa1_carry;
        logic [AVG_SUM_W-1:0] csa2_sum;
        logic [AVG_SUM_W-1:0] csa2_carry;
        avg_sum_t sum;
        begin
            sx0 = avg_sum_t'(p0);
            sx1 = avg_sum_t'(p1);
            sx2 = avg_sum_t'(p2);
            sx3 = avg_sum_t'(p3);

            csa1_sum   = sx0 ^ sx1 ^ sx2;
            csa1_carry = ((sx0 & sx1) | (sx0 & sx2) | (sx1 & sx2)) << 1;
            csa2_sum   = csa1_sum ^ csa1_carry ^ sx3;
            csa2_carry = ((csa1_sum & csa1_carry) |
                          (csa1_sum & sx3) |
                          (csa1_carry & sx3)) << 1;
            sum = avg_sum_t'(csa2_sum) + avg_sum_t'(csa2_carry);

            calc_final_avg = (&act_sel) ? avg_t'(sum[AVG_SUM_W-1 -: ACC_W]) :
                                          avg_t'(sum[AVG_SUM_W-2 -: ACC_W]);
        end
    endfunction

    function automatic acc_t relu_value(input acc_t value);
        begin
            relu_value = (value < 0) ? '0 : value;
        end
    endfunction

    function automatic acc_t avg_act_value(
        input acc_t value,
        input avg_t threshold
    );
        begin
            avg_act_value = (value < threshold) ? (value >>> 3) : value;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid_q   <= 1'b0;
            psum_valid_q <= 1'b0;
            avg_valid_q  <= 1'b0;
            out_valid    <= 1'b0;
        end
        else begin
            s0_valid_q   <= in_valid;
            psum_valid_q <= s0_valid_q;
            avg_valid_q  <= psum_valid_q;
            out_valid    <= avg_valid_q;
        end
    end

    always_ff @(posedge clk) begin
        // Stage 0: input register moved from CA top into ACT.
        if (in_valid) begin
            s0_act_q  <= act;
            s0_data_q <= in_data;
            s0_tag_q  <= in_tag;
            s0_first_q <= in_first;
        end

        // Stage 1: partial sums.
        // RAT/CAT: 8 inputs -> four 2-input partial sums.
        // BAT:     16 inputs -> four row-wise 4-input partial sums.
        if (s0_valid_q) begin
            psum_act_q  <= s0_act_q;
            psum_data_q <= s0_data_q;
            psum_tag_q  <= s0_tag_q;
            psum_first_q <= s0_first_q;

            for (int g = 0; g < AVG_GROUPS; g++) begin
                for (int p = 0; p < PSUM_CNT; p++) begin
                    unique case (s0_act_q)
                        2'b01: begin
                            psum_q[g][p] <= calc_rat_psum(s0_data_q, g, p);
                        end
                        2'b10: begin
                            psum_q[g][p] <= calc_cat_psum(s0_data_q, g, p);
                        end
                        2'b11: begin
                            psum_q[g][p] <= calc_bat_row_psum(s0_data_q, g, p);
                        end
                        default: begin
                            psum_q[g][p] <= '0;
                        end
                    endcase
                end
            end
        end

        // Stage 2: final average threshold from four partial sums.
        if (psum_valid_q) begin
            avg_relu_q  <= (psum_act_q == 2'b00);
            avg_rat_q   <= (psum_act_q == 2'b01);
            avg_cat_q   <= (psum_act_q == 2'b10);
            avg_data_q  <= psum_data_q;
            avg_tag_q   <= psum_tag_q;
            avg_first_q <= psum_first_q;

            for (int g = 0; g < AVG_GROUPS; g++) begin
                avg_q[g] <= calc_final_avg(psum_act_q,
                                           psum_q[g][0], psum_q[g][1],
                                           psum_q[g][2], psum_q[g][3]);
            end
        end

        // Stage 3: activation using the registered threshold.
        if (avg_valid_q) begin
            out_tag <= avg_tag_q;
            out_first <= avg_first_q;
            for (int i = 0; i < MAT_SIZE; i++) begin
                if (avg_relu_q) begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                        relu_value(get_acc(avg_data_q, i));
                end
                else if (avg_rat_q) begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                        avg_act_value(get_acc(avg_data_q, i), avg_q[i / ROW_ELEM]);
                end
                else if (avg_cat_q) begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                        avg_act_value(get_acc(avg_data_q, i), avg_q[i % ROW_ELEM]);
                end
                else begin
                    out_data[ACC_VEC_W - 1 - (i * ACC_W) -: ACC_W] <=
                        avg_act_value(get_acc(avg_data_q, i),
                                      avg_q[((i / 32) * 2) + ((i % ROW_ELEM) / 4)]);
                end
            end
        end
    end

endmodule

module pot_5stage_parallel #(
    parameter int ACC_W = 16,
    parameter int MAT_SIZE = 64
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [(MAT_SIZE*ACC_W)-1:0] in_data,
    input  logic [1:0]    in_tag,
    output logic          out_valid,
    output logic [255:0]  out_data,
    output logic [1:0]    out_tag
);

    localparam int MAX_L0    = 16;  // 64 values -> 16 max4 results
    localparam int MAX_L1    = 4;   // 16 values -> 4 max4 results
    localparam int ACC_VEC_W = MAT_SIZE * ACC_W;
    localparam int SHIFT_W   = $clog2(ACC_W);
    localparam logic [SHIFT_W-1:0] SHIFT_TWO = 2;

    typedef logic signed [3:0]  s4_t;
    typedef logic signed [ACC_W-1:0] acc_t;
    typedef logic [ACC_W-1:0] mag_t;
    typedef logic [ACC_VEC_W-1:0] acc_vec_t;

    logic          abs_valid_q;
    logic          max0_valid_q;
    logic          max1_valid_q;
    logic          max2_valid_q;
    acc_vec_t      abs_data_q;
    acc_vec_t      max0_data_q;
    acc_vec_t      max1_data_q;
    acc_vec_t      max2_data_q;
    logic [1:0]    tag0_q, tag1_q, tag2_q, tag3_q;
    mag_t          abs_q [0:MAT_SIZE-1];
    mag_t          max0_q [0:MAX_L0-1];
    mag_t          max1_q [0:MAX_L1-1];
    mag_t          max2_next;
    logic [SHIFT_W-1:0] shift_q;

    function automatic acc_t get_acc(input acc_vec_t vec, input integer idx);
        get_acc = $signed(vec[ACC_VEC_W - 1 - (idx * ACC_W) -: ACC_W]);
    endfunction

    function automatic mag_t abs_acc(input acc_t value);
        abs_acc = (value[ACC_W - 1]) ? -value : value;
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

    function automatic logic [255:0] quant_all(
        input acc_vec_t             src_data,
        input logic [SHIFT_W-1:0]   shift
    );
        acc_t   scaled;
        begin
            quant_all = 256'd0;

            for (int i = 0; i < MAT_SIZE; i++) begin
                scaled = get_acc(src_data, i) >>> shift;
                quant_all[255 - (i * 4) -: 4] = clamp_s4(scaled);
            end
        end
    endfunction

    assign max2_next = mag_or4(max1_q[0], max1_q[1], max1_q[2], max1_q[3]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            abs_valid_q  <= 1'b0;
            max0_valid_q <= 1'b0;
            max1_valid_q <= 1'b0;
            max2_valid_q <= 1'b0;
            out_valid    <= 1'b0;
            out_tag      <= 2'd0;
        end
        else begin
            abs_valid_q  <= in_valid;
            max0_valid_q <= abs_valid_q;
            max1_valid_q <= max0_valid_q;
            max2_valid_q <= max1_valid_q;
            out_valid    <= max2_valid_q;

            tag0_q <= in_tag;
            tag1_q <= tag0_q;
            tag2_q <= tag1_q;
            tag3_q <= tag2_q;

            // Stage 0: register absolute magnitudes.
            if (in_valid) begin
                abs_data_q <= in_data;

                for (int i = 0; i < MAT_SIZE; i++) begin
                    abs_q[i] <= abs_acc(get_acc(in_data, i));
                end
            end

            // Stage 1: reduce each group of four magnitudes.
            if (abs_valid_q) begin
                max0_data_q <= abs_data_q;

                for (int g = 0; g < MAX_L0; g++) begin
                    max0_q[g] <= mag_or4(abs_q[(g * 4) + 0],
                                          abs_q[(g * 4) + 1],
                                          abs_q[(g * 4) + 2],
                                          abs_q[(g * 4) + 3]);
                end
            end

            // Stage 2: 16 OR groups -> 4 OR groups.
            if (max0_valid_q) begin
                max1_data_q <= max0_data_q;

                for (int g = 0; g < MAX_L1; g++) begin
                    max1_q[g] <= mag_or4(max0_q[(g * 4) + 0],
                                          max0_q[(g * 4) + 1],
                                          max0_q[(g * 4) + 2],
                                          max0_q[(g * 4) + 3]);
                end
            end

            // Stage 3: 4 OR groups -> one global magnitude-bit mask.
            if (max1_valid_q) begin
                max2_data_q <= max1_data_q;
                shift_q     <= pot_shift(max2_next);
            end

            // Stage 4: quantize all 64 elements to signed 4-bit using the registered shift.
            if (max2_valid_q) begin
                out_data <= quant_all(max2_data_q, shift_q);
                out_tag  <= tag3_q;
            end
        end
    end
endmodule
