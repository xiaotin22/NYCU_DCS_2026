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
    logic          datapath_result_valid;
    logic          datapath_result_commit;

    // FIFO control bridging Control (timing decision) and DataPath (storage).
    logic          fifo_flush;
    logic          fifo_push_en;
    logic          fifo_pop_en;
    logic          fifo_empty;
    logic [4:0]    fifo_count;

    // Schedule signals Control -> DataPath.
    logic          mult_in_valid;  // Mult input valid (slot-paced for SHA, == fifo_pop_en for FFN/Conv)
    logic [4:0]    sched_tag;      // {work_type[2:0], matrix_id_lo[1:0]}

    // CA only wires the two halves together:
    // - CA_Control owns the FSM, RAM commands, and FIFO push/pop scheduling.
    // - CA_DataPath owns the matrix pipeline (FIFO -> Mult -> ACT -> PoT).
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
        .fifo_empty            (fifo_empty),
        .fifo_count            (fifo_count),
        .datapath_result_valid (datapath_result_valid),
        .exec_op               (exec_op),
        .exec_act              (exec_act),
        .exec_param            (exec_param),
        .weight_k              (exec_weight_k),
        .weight_v              (exec_weight_v),
        .fifo_flush            (fifo_flush),
        .fifo_push_en          (fifo_push_en),
        .fifo_pop_en           (fifo_pop_en),
        .mult_in_valid         (mult_in_valid),
        .sched_tag             (sched_tag),
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
        .op                    (exec_op),
        .act                   (exec_act),
        .param                 (exec_param),
        .weight_k              (exec_weight_k),
        .weight_v              (exec_weight_v),
        .rd_data               (rd_data),
        .fifo_flush            (fifo_flush),
        .fifo_push_en          (fifo_push_en),
        .fifo_pop_en           (fifo_pop_en),
        .fifo_empty            (fifo_empty),
        .fifo_count            (fifo_count),
        .mult_in_valid         (mult_in_valid),
        .sched_tag             (sched_tag),
        .result_commit         (datapath_result_commit),
        .result_valid          (datapath_result_valid),
        .wr_valid              (wr_valid),
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
    input  logic                            fifo_empty,
    input  logic [4:0]                      fifo_count,
    input  logic                            datapath_result_valid,

    output logic [1:0]                      exec_op,
    output logic [1:0]                      exec_act,
    output logic [255:0]                    exec_param,
    output logic [255:0]                    weight_k,    // SHA/MHA W_K (latched in S_PARAM)
    output logic [255:0]                    weight_v,    // SHA/MHA W_V (latched in S_PARAM)
    output logic                            fifo_flush,
    output logic                            fifo_push_en,
    output logic                            fifo_pop_en,
    output logic                            mult_in_valid,  // Mult input valid (slot-paced for SHA)
    output logic [4:0]                      sched_tag,      // {work_type[2:0], matrix_id_lo[1:0]}
    output logic                            datapath_result_commit,

    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1:0]            rd_burst,
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1:0]            wr_burst
);

    localparam int ADDR_W = $clog2(RAM_DEPTH);
    localparam logic [BURST_BIT-1:0] BURST_128 = 3'd7;   // 2^7 = 128 words
    localparam logic [BURST_BIT-1:0] BURST_16  = 3'd4;   // 2^4 =  16 words
    localparam logic [ADDR_W-1:0]    HALF_ADDR = 8'd128;
    localparam logic [4:0]           BURSTS_FFN_CONV = 5'd2;   // 2 bursts of 128
    localparam logic [4:0]           BURSTS_ATTN     = 5'd16;  // 16 bursts of 16
    localparam logic [4:0]           FIFO_THRESHOLD  = 5'd10;  // accept burst when count <= 10

    // Work type encoding (3 bits) carried in sched_tag[4:2]. Phase 2 hardcodes WT_FFN.
    localparam logic [2:0] WT_FFN = 3'd0;   // FFN/Conv result -> RAM + out_data
    localparam logic [2:0] WT_Q   = 3'd1;   // SHA/MHA -> Q_buf
    localparam logic [2:0] WT_K   = 3'd2;   // SHA/MHA -> K_buf
    localparam logic [2:0] WT_V   = 3'd3;   // SHA/MHA -> V_buf
    localparam logic [2:0] WT_QKT = 3'd4;   // SHA/MHA -> score_buf (after SPECIAL act)
    localparam logic [2:0] WT_SV  = 3'd5;   // SHA/MHA -> RAM + out_data (final)

    typedef enum logic [1:0] {
        S_IDLE,
        S_PARAM,   // SHA/MHA only: collecting W_K then W_V after job_start latched W_Q
        S_RUN
    } state_t;

    state_t        state_q;
    logic [4:0]    rd_req_cnt_q;     // 5-bit: up to 16 bursts for SHA/MHA
    logic [8:0]    push_word_cnt_q;
    logic [8:0]    pop_word_cnt_q;
    logic [8:0]    wr_cmd_cnt_q;
    logic [8:0]    out_cnt_q;
    logic [9:0]    wr_pre_pipe_q;

    // Attention weight latches. W_Q reuses exec_param (latched at job_start).
    logic [1:0]    weight_idx_q;     // 0 = K turn, 1 = V turn, 2 = done
    logic [255:0]  weight_k_q;
    logic [255:0]  weight_v_q;

    // SHA 5-slot schedule. slot_q cycles 0..4, iter_q advances on wrap.
    // Useful iters: 0..255 for input matrices; tail (iter 256..261) drains slot 3/4 pipeline.
    logic [2:0]    slot_q;
    logic [8:0]    iter_q;

    logic                  job_start;
    logic                  is_attention_in;    // op (live) is SHA/MHA
    logic                  is_attention_exec;  // exec_op (latched) is SHA/MHA
    logic                  weights_done;       // last W_V latch this cycle
    logic [4:0]            total_bursts;       // FFN/Conv = 2, SHA/MHA = 16
    logic [BURST_BIT-1:0]  burst_setting;      // BURST_128 or BURST_16
    logic                  fifo_can_accept;    // throttle: burst won't overflow FIFO
    logic                  wr_boundary;        // current wr_cmd_cnt is at burst boundary
    logic                  rd_cmd_fire;
    logic                  wr_pre_fire;
    logic                  wr_cmd_fire;
    logic                  wr_pre_shift_in;    // 1 cycle that produces a user-visible result
    logic                  result_last;

    // SHA schedule helpers
    logic                  sched_active;       // S_RUN && SHA
    logic                  sched_done;         // schedule complete
    logic                  slot_in_input_rng;  // slot 0/1/2 (consumes FIFO data)
    logic                  sha_no_work_input;  // slot 0/1/2 but iter past last matrix
    logic                  sha_no_work_qkt;    // slot 3 but iter < 3 (no valid Q,K yet)
    logic                  sha_no_work_sv;     // slot 4 but iter < 6 (no valid score yet)
    logic                  sha_no_work;        // any of the above
    logic                  slot_need_fifo;     // only when slot 0/1/2 and we'd do real work
    logic                  sha_can_advance;
    logic                  sha_slot_advance;   // slot/iter counters advance (no_work still advances)
    logic                  sha_advance;        // produce real Mult input (mult_in_valid)
    logic                  sha_pop_en;
    logic [8:0]            slot_matrix;        // matrix_id processed at current slot (iter - offset)
    logic [2:0]            slot_wt;            // work_type for current slot
    logic                  slot_is_user_res;   // current slot produces user-visible output

    // SHA output burst tracking. Each burst-16 fires after 16 user results accumulate.
    logic [4:0]            sha_groups_issued_q;  // count of bursts already issued (0..16)
    logic [4:0]            sha_groups_accum;     // floor(out_cnt_q / 16)
    logic                  sha_wr_due;           // a new group is ready and not yet issued
    logic                  ffn_wr_cmd_fire;
    logic                  sha_wr_cmd_fire;

    // Phase 2: accept FFN (00), Conv (01), SHA (10). MHA (11) reserved for Phase 3.
    function automatic logic op_supported(input logic [1:0] op_sel);
        op_supported = (op_sel == 2'b00) || (op_sel == 2'b01) || (op_sel == 2'b10);
    endfunction

    // PATTERN only raises the next in_valid after the previous 256-word output
    // stream is complete, so the controller accepts jobs only from IDLE.
    assign job_start         = (state_q == S_IDLE) && mem_set && in_valid && op_supported(op);
    assign is_attention_in   = (op == 2'b10) || (op == 2'b11);
    assign is_attention_exec = (exec_op == 2'b10) || (exec_op == 2'b11);
    assign weights_done      = (state_q == S_PARAM) && in_valid && (weight_idx_q == 2'd1);

    // Burst configuration: FFN/Conv use burst-128 (2 reads), SHA/MHA use burst-16 (16 reads).
    assign total_bursts  = is_attention_exec ? BURSTS_ATTN : BURSTS_FFN_CONV;
    assign burst_setting = is_attention_exec ? BURST_16    : BURST_128;

    // For SHA/MHA, throttle next burst until FIFO has room. FFN/Conv never throttles
    // (push and pop rates match, so steady-state FIFO occupancy stays at 1).
    assign fifo_can_accept = is_attention_exec ? (fifo_count <= FIFO_THRESHOLD) : 1'b1;

    // Flush input FIFO at job_start as a safety reset for any residual entries.
    assign fifo_flush = job_start;

    // Push every RAM word into the FIFO until we've captured the full 256-word set.
    assign fifo_push_en = (state_q == S_RUN) && rd_valid && (push_word_cnt_q < 9'd256);

    // ---- SHA 5-slot schedule ----
    // slot 0/1/2: matrix[iter] × W_Q/W_K/W_V  (input from FIFO)
    // slot 3:     matrix[iter-3] Q × K^T      (offset 3, input from buffers)
    // slot 4:     matrix[iter-6] score × V    (offset 6, input from buffers)
    // Total useful slots: 256 matrices × 5 = 1280; last useful iter = 261 (matrix[255] at slot 4).
    //
    // sha_no_work_*: "phantom" slots where the schedule advances but no real work happens.
    // We still cycle slot/iter so the schedule can reach later real slots, but mult_in_valid
    // stays low so the Mult pipeline doesn't latch garbage and PoT doesn't fire.
    assign sched_active       = (state_q == S_RUN) && is_attention_exec;
    assign sched_done         = (iter_q >= 9'd262);  // matrix[255] slot 4 is iter=261, done after wrap
    assign slot_in_input_rng  = (slot_q == 3'd0) || (slot_q == 3'd1) || (slot_q == 3'd2);
    assign sha_no_work_input  = slot_in_input_rng  && (iter_q >= 9'd256);  // past last input matrix
    assign sha_no_work_qkt    = (slot_q == 3'd3) && (iter_q <  9'd3);      // slot 3 needs iter >= 3
    assign sha_no_work_sv     = (slot_q == 3'd4) && (iter_q <  9'd6);      // slot 4 needs iter >= 6
    assign sha_no_work        = sha_no_work_input || sha_no_work_qkt || sha_no_work_sv;

    // Only stall on FIFO empty when we'd actually pop from FIFO this slot (real input work).
    assign slot_need_fifo     = slot_in_input_rng && !sha_no_work_input;
    assign sha_can_advance    = !(slot_need_fifo && fifo_empty);

    assign sha_slot_advance   = sched_active && !sched_done && sha_can_advance;
    assign sha_advance        = sha_slot_advance && !sha_no_work;
    assign sha_pop_en         = sha_advance && (slot_q == 3'd2);

    // matrix_id processed at current slot (with offset). Negative values during start-up
    // produce don't-care work (gated by sched_done condition or by tag-driven routing).
    always_comb begin
        case (slot_q)
            3'd3:    slot_matrix = iter_q - 9'd3;
            3'd4:    slot_matrix = iter_q - 9'd6;
            default: slot_matrix = iter_q;
        endcase
    end

    always_comb begin
        case (slot_q)
            3'd0:    slot_wt = WT_Q;
            3'd1:    slot_wt = WT_K;
            3'd2:    slot_wt = WT_V;
            3'd3:    slot_wt = WT_QKT;
            default: slot_wt = WT_SV;  // slot 4
        endcase
    end

    assign slot_is_user_res = is_attention_exec ? (slot_q == 3'd4) : 1'b1;

    // FIFO pop: FFN/Conv every cycle when non-empty; SHA only at slot 2.
    assign fifo_pop_en = is_attention_exec
                         ? sha_pop_en
                         : ((state_q == S_RUN) && !fifo_empty && (pop_word_cnt_q < 9'd256));

    // Mult.in_valid: FFN/Conv same as fifo_pop_en; SHA fires every advancing slot.
    assign mult_in_valid = is_attention_exec
                           ? sha_advance
                           : ((state_q == S_RUN) && !fifo_empty && (pop_word_cnt_q < 9'd256));

    // Tag for current Mult input.
    assign sched_tag = is_attention_exec ? {slot_wt, slot_matrix[1:0]}
                                         : {WT_FFN, 2'b00};

    // Weight outputs (only meaningful for SHA/MHA; FFN/Conv ignores in DataPath).
    assign weight_k = weight_k_q;
    assign weight_v = weight_v_q;

    assign datapath_result_commit = datapath_result_valid;

    // SHA only goes IDLE after the 16th burst is issued (out_cnt_q reaches 256 AND
    // all 16 groups have been wr_en-pulsed). FFN/Conv exits on the 256th commit.
    logic sha_all_done;
    assign sha_all_done = (sha_groups_issued_q == 5'd16) && (out_cnt_q == 9'd256);
    assign result_last  = is_attention_exec
                          ? sha_all_done
                          : (datapath_result_commit && (out_cnt_q == 9'd255));

    // wr_pre_pipe shift source: fires once per user-visible-result-producing cycle.
    // FFN/Conv: every mult input. SHA: only slot 4 (WT_SV).
    assign wr_pre_shift_in = mult_in_valid && slot_is_user_res;

    // wr_cmd boundary (FFN/Conv only): every burst-128 (cnt[6:0]==0).
    assign wr_boundary = (wr_cmd_cnt_q[6:0] == 7'd0);

    // FFN/Conv: original wr_pre_pipe-based timing (wr_en 10 cycles after FIFO pop).
    assign wr_pre_fire     = wr_pre_pipe_q[9];
    assign ffn_wr_cmd_fire = (state_q == S_RUN) && wr_pre_fire && !is_attention_exec;
    assign wr_cmd_fire     = ffn_wr_cmd_fire;  // counters track FFN/Conv path only

    // SHA: wr_en fires when out_cnt_q has accumulated another group of 16 (FIFO has 16+ entries).
    // out_cnt_q counts result_commits 0..255. groups_accum = floor(out_cnt_q / 16) = bits [8:4].
    assign sha_groups_accum = out_cnt_q[8:4];
    assign sha_wr_due       = is_attention_exec && (sha_groups_accum > sha_groups_issued_q);
    assign sha_wr_cmd_fire  = (state_q == S_RUN) && sha_wr_due;

    assign rd_cmd_fire = (state_q == S_RUN) && (rd_req_cnt_q < total_bursts) && rd_ready && fifo_can_accept;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
        end
        else begin
            case (state_q)
                S_IDLE: begin
                    if (job_start) begin
                        state_q <= is_attention_in ? S_PARAM : S_RUN;
                    end
                end

                S_PARAM: begin
                    if (weights_done) begin
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

    // SHA/MHA weight collection: after job_start latched W_Q into exec_param,
    // S_PARAM collects W_K (idx 0), then W_V (idx 1). FFN/Conv never enters S_PARAM.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_idx_q <= 2'd0;
        end
        else if (job_start) begin
            weight_idx_q <= 2'd0;
        end
        else if ((state_q == S_PARAM) && in_valid && (weight_idx_q < 2'd2)) begin
            weight_idx_q <= weight_idx_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_k_q <= 256'd0;
            weight_v_q <= 256'd0;
        end
        else if ((state_q == S_PARAM) && in_valid) begin
            if (weight_idx_q == 2'd0) begin
                weight_k_q <= param;
            end
            if (weight_idx_q == 2'd1) begin
                weight_v_q <= param;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req_cnt_q <= 5'd0;
        end
        else if (job_start) begin
            rd_req_cnt_q <= 5'd0;
        end
        else if (rd_cmd_fire) begin
            rd_req_cnt_q <= rd_req_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            push_word_cnt_q <= 9'd0;
        end
        else if (job_start) begin
            push_word_cnt_q <= 9'd0;
        end
        else if (fifo_push_en) begin
            push_word_cnt_q <= push_word_cnt_q + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pop_word_cnt_q <= 9'd0;
        end
        else if (job_start) begin
            pop_word_cnt_q <= 9'd0;
        end
        else if (fifo_pop_en) begin
            pop_word_cnt_q <= pop_word_cnt_q + 1'b1;
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

    // SHA slot/iter advancement. Cycles 0..4 within iter; iter increments on 4->0 wrap.
    // Uses sha_slot_advance (not sha_advance): phantom slots still cycle counters so
    // the schedule can reach later real slots even though no Mult work happens there.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_q <= 3'd0;
            iter_q <= 9'd0;
        end
        else if (job_start) begin
            slot_q <= 3'd0;
            iter_q <= 9'd0;
        end
        else if (sha_slot_advance) begin
            if (slot_q == 3'd4) begin
                slot_q <= 3'd0;
                iter_q <= iter_q + 1'b1;
            end
            else begin
                slot_q <= slot_q + 1'b1;
            end
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
            wr_pre_pipe_q <= {wr_pre_pipe_q[8:0], wr_pre_shift_in};
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
                // FFN/Conv: addr = cnt * 128 (0 or 128). SHA/MHA: addr = cnt * 16 (0,16,...,240).
                rd_addr  <= is_attention_exec ? {rd_req_cnt_q[3:0], 4'd0}
                                              : (rd_req_cnt_q[0] ? HALF_ADDR : '0);
                rd_burst <= burst_setting;
            end
        end
    end

    // SHA: tracks number of bursts issued so far. wr_en pulses when sha_wr_due (combinational
    // condition); after the pulse, this counter increments and sha_wr_due de-asserts for one
    // group, naturally giving a 1-cycle wr_en pulse.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sha_groups_issued_q <= 5'd0;
        end
        else if (job_start) begin
            sha_groups_issued_q <= 5'd0;
        end
        else if (sha_wr_cmd_fire) begin
            sha_groups_issued_q <= sha_groups_issued_q + 1'b1;
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
                wr_burst <= burst_setting;
            end

            if (is_attention_exec) begin
                // SHA: fire wr_en when a new 16-result group is ready; addr = group * 16.
                if (sha_wr_cmd_fire) begin
                    wr_en    <= 1'b1;
                    wr_addr  <= {sha_groups_issued_q[3:0], 4'd0};
                    wr_burst <= burst_setting;
                end
            end
            else begin
                // FFN/Conv: original timing (every 128 results).
                if (ffn_wr_cmd_fire && wr_boundary) begin
                    wr_en    <= 1'b1;
                    wr_addr  <= wr_cmd_cnt_q[ADDR_W-1:0];
                    wr_burst <= burst_setting;
                end
            end
        end
    end

endmodule

module CA_DataPath #(
    parameter RAM_WIDTH = 256
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [1:0]           op,
    input  logic [1:0]           act,
    input  logic [255:0]         param,
    input  logic [255:0]         weight_k,
    input  logic [255:0]         weight_v,
    input  logic [RAM_WIDTH-1:0] rd_data,
    input  logic                 fifo_flush,
    input  logic                 fifo_push_en,
    input  logic                 fifo_pop_en,
    output logic                 fifo_empty,
    output logic [4:0]           fifo_count,
    input  logic                 mult_in_valid,
    input  logic [4:0]           sched_tag,    // {work_type[2:0], matrix_id_lo[1:0]}
    input  logic                 result_commit,
    input  logic                 wr_valid,     // RAM asserts during burst; drives output FIFO pop

    output logic                 result_valid,
    output logic [RAM_WIDTH-1:0] wr_data,
    output logic                 out_valid,
    output logic [31:0]          out_data
);

    // Work type encoding (must match CA_Control localparams).
    localparam logic [2:0] WT_FFN = 3'd0;
    localparam logic [2:0] WT_Q   = 3'd1;
    localparam logic [2:0] WT_K   = 3'd2;
    localparam logic [2:0] WT_V   = 3'd3;
    localparam logic [2:0] WT_QKT = 3'd4;
    localparam logic [2:0] WT_SV  = 3'd5;

    logic [RAM_WIDTH-1:0] fifo_pop_data;
    logic [RAM_WIDTH-1:0] mult_in_data_A;
    logic                 mult_valid;
    logic [2047:0]        mult_data;
    logic                 act_valid;
    logic [2047:0]        act_data;
    logic                 pot_valid;
    logic [255:0]         pot_data;

    // SHA/MHA intermediate buffers (filled in by schedule FSM in P2.7).
    // Depth chosen to cover lifetime of each PoT-quantized matrix in the schedule.
    logic                 q_buf_wr_en;
    logic                 k_buf_wr_en;
    logic                 v_buf_wr_en;
    logic                 score_buf_wr_en;
    logic [0:0]           q_buf_wr_addr,  q_buf_rd_addr;
    logic [0:0]           k_buf_wr_addr,  k_buf_rd_addr;
    logic [1:0]           v_buf_wr_addr,  v_buf_rd_addr;
    logic [0:0]           score_buf_wr_addr, score_buf_rd_addr;
    logic [255:0]         q_buf_rd_data;
    logic [255:0]         k_buf_rd_data;
    logic [255:0]         v_buf_rd_data;
    logic [255:0]         score_buf_rd_data;

    // Input FIFO decouples burst-RAM read rate from compute consumer rate.
    // FFN/Conv pop 1 word/cycle (steady-state occupancy stays at 1).
    // SHA/MHA (Phase 2) pop slower; burst-16 keeps peak occupancy ~13.
    CA_InputFIFO #(
        .DEPTH (16),
        .WIDTH (RAM_WIDTH)
    ) u_in_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .flush     (fifo_flush),
        .push_en   (fifo_push_en),
        .push_data (rd_data),
        .pop_en    (fifo_pop_en),
        .pop_data  (fifo_pop_data),
        .empty     (fifo_empty),
        .full      (),
        .count     (fifo_count)
    );

    // Q/K/V/score ring buffers (skeletons; wr_en stays 0 until P2.7 schedule FSM).
    // For Phase 2 FFN/Conv path, these are inert and synthesis can prune them
    // until the schedule FSM activates writes.
    CA_MatrixRing #(.DEPTH(2), .WIDTH(256)) u_q_buf (
        .clk     (clk),
        .wr_en   (q_buf_wr_en),
        .wr_addr (q_buf_wr_addr),
        .wr_data (pot_data),
        .rd_addr (q_buf_rd_addr),
        .rd_data (q_buf_rd_data)
    );

    CA_MatrixRing #(.DEPTH(2), .WIDTH(256)) u_k_buf (
        .clk     (clk),
        .wr_en   (k_buf_wr_en),
        .wr_addr (k_buf_wr_addr),
        .wr_data (pot_data),
        .rd_addr (k_buf_rd_addr),
        .rd_data (k_buf_rd_data)
    );

    CA_MatrixRing #(.DEPTH(4), .WIDTH(256)) u_v_buf (
        .clk     (clk),
        .wr_en   (v_buf_wr_en),
        .wr_addr (v_buf_wr_addr),
        .wr_data (pot_data),
        .rd_addr (v_buf_rd_addr),
        .rd_data (v_buf_rd_data)
    );

    CA_MatrixRing #(.DEPTH(2), .WIDTH(256)) u_score_buf (
        .clk     (clk),
        .wr_en   (score_buf_wr_en),
        .wr_addr (score_buf_wr_addr),
        .wr_data (pot_data),
        .rd_addr (score_buf_rd_addr),
        .rd_data (score_buf_rd_data)
    );

    // ---- Tag pipeline (15 stages = Mult 8 + ACT 2 + PoT 5) ----
    // Each entry mirrors sched_tag for the data currently at that pipeline stage.
    // No reset on tag flops; they are only meaningful when pot_valid (which is reset-clean).
    logic [4:0] tag_pipe_q [0:14];
    logic [4:0] tag_at_pot_out;
    logic [2:0] tag_wt_out;
    logic [1:0] tag_mid_out;

    always_ff @(posedge clk) begin
        tag_pipe_q[0] <= sched_tag;
        for (int i = 1; i < 15; i++) begin
            tag_pipe_q[i] <= tag_pipe_q[i-1];
        end
    end

    assign tag_at_pot_out = tag_pipe_q[14];
    assign tag_wt_out     = tag_at_pot_out[4:2];
    assign tag_mid_out    = tag_at_pot_out[1:0];

    // Buffer writes: tag-gated. For FFN/Conv (tag stays WT_FFN), all wr_en = 0.
    assign q_buf_wr_en     = pot_valid && (tag_wt_out == WT_Q);
    assign k_buf_wr_en     = pot_valid && (tag_wt_out == WT_K);
    assign v_buf_wr_en     = pot_valid && (tag_wt_out == WT_V);
    assign score_buf_wr_en = pot_valid && (tag_wt_out == WT_QKT);

    // Buffer addresses from tag's matrix_id_lo. Q/K/score use 1 bit, V uses 2 bits.
    assign q_buf_wr_addr     = tag_mid_out[0];
    assign k_buf_wr_addr     = tag_mid_out[0];
    assign v_buf_wr_addr     = tag_mid_out[1:0];
    assign score_buf_wr_addr = tag_mid_out[0];

    // Buffer read addresses derived from sched_tag's matrix_id_lo. For SHA slot 3/4,
    // Control sets sched_tag based on iter-offset; for other slots / FFN/Conv the
    // address is don't-care because the Mult input MUX selects a different source.
    assign q_buf_rd_addr     = sched_tag[0];
    assign k_buf_rd_addr     = sched_tag[0];
    assign v_buf_rd_addr     = sched_tag[1:0];
    assign score_buf_rd_addr = sched_tag[0];

    // K^T pure-wire reorder: K^T[r][c] = K[c][r]. Used at SHA slot 3 (Q × K^T).
    logic [255:0] k_transposed;
    always_comb begin
        for (int r = 0; r < 8; r++) begin
            for (int c = 0; c < 8; c++) begin
                k_transposed[255 - ((r * 8) + c) * 4 -: 4]
                    = k_buf_rd_data[255 - ((c * 8) + r) * 4 -: 4];
            end
        end
    end

    // Per-cycle decode of sched_tag work_type drives Mult input MUXes and ACT mode.
    logic [2:0] cur_wt;
    logic [1:0] mult_a_sel;
    logic [2:0] mult_b_sel;
    logic [1:0] act_mode_cur;
    logic [RAM_WIDTH-1:0] mult_in_data_B;

    assign cur_wt = sched_tag[4:2];

    always_comb begin
        case (cur_wt)
            WT_Q:    begin mult_a_sel = 2'b00; mult_b_sel = 3'b001; act_mode_cur = 2'b01; end // FIFO × W_Q, BYPASS
            WT_K:    begin mult_a_sel = 2'b00; mult_b_sel = 3'b010; act_mode_cur = 2'b01; end // FIFO × W_K, BYPASS
            WT_V:    begin mult_a_sel = 2'b00; mult_b_sel = 3'b011; act_mode_cur = 2'b01; end // FIFO × W_V, BYPASS
            WT_QKT:  begin mult_a_sel = 2'b01; mult_b_sel = 3'b100; act_mode_cur = 2'b10; end // Q_buf × K^T, SPECIAL
            WT_SV:   begin mult_a_sel = 2'b10; mult_b_sel = 3'b101; act_mode_cur = 2'b00; end // score_buf × V_buf, USER
            default: begin mult_a_sel = 2'b00; mult_b_sel = 3'b000; act_mode_cur = 2'b00; end // WT_FFN: FIFO × param, USER
        endcase
    end

    // Input_A MUX: 00 = FIFO pop, 01 = Q_buf, 10 = score_buf
    always_comb begin
        case (mult_a_sel)
            2'b01:   mult_in_data_A = q_buf_rd_data;
            2'b10:   mult_in_data_A = score_buf_rd_data;
            default: mult_in_data_A = fifo_pop_data;
        endcase
    end

    // Input_B MUX: 000 = param (WT_FFN), 001 = W_Q (= exec_param), 010 = W_K, 011 = W_V,
    //              100 = K^T, 101 = V_buf
    // Note WT_Q reuses param too (since exec_param holds W_Q); we treat sel 001 = param for that.
    always_comb begin
        case (mult_b_sel)
            3'b001:  mult_in_data_B = param;          // W_Q (latched at job_start)
            3'b010:  mult_in_data_B = weight_k;       // W_K (latched at S_PARAM idx 0)
            3'b011:  mult_in_data_B = weight_v;       // W_V (latched at S_PARAM idx 1)
            3'b100:  mult_in_data_B = k_transposed;   // K^T (wire reorder of K_buf)
            3'b101:  mult_in_data_B = v_buf_rd_data;  // V
            default: mult_in_data_B = param;          // WT_FFN: original param path
        endcase
    end

    // Matrix pipeline: Mult -> ACT -> PoT. Valid driven by Control (slot-paced for SHA).
    Mult_8Stage_Parallel u_mult (
        .clk       (clk),
        .rst_n     (rst_n),
        .op        (op),
        .in_valid  (mult_in_valid),
        .in_data_A (mult_in_data_A),
        .in_data_B (mult_in_data_B),
        .out_valid (mult_valid),
        .out_data  (mult_data)
    );

    ACT_TwoStage_Parallel u_act (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (mult_valid),
        .act       (act),
        .act_mode  (act_mode_cur),
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

    // Only WT_FFN and WT_SV PoT outputs are user-visible results (go to RAM + out_data).
    // WT_Q/K/V/QKT outputs feed internal buffers, do not advance out_cnt.
    logic is_user_result;
    assign is_user_result = (tag_wt_out == WT_FFN) || (tag_wt_out == WT_SV);
    assign result_valid   = pot_valid && is_user_result;

    // Output FIFO: bridges per-result production rate to RAM burst consumption rate.
    // FFN/Conv: push and pop both 1/cycle, FIFO occupancy stays near 1.
    // SHA/MHA: push 1/5 cycle, pop 1/cycle during burst; FIFO peaks ~21, depth 32 is safe.
    logic [255:0] out_fifo_pop_data;
    logic         out_fifo_empty;
    logic [5:0]   out_fifo_count;

    CA_InputFIFO #(
        .DEPTH (32),
        .WIDTH (256)
    ) u_out_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .flush     (fifo_flush),
        .push_en   (result_commit),
        .push_data (pot_data),
        .pop_en    (wr_valid),
        .pop_data  (out_fifo_pop_data),
        .empty     (out_fifo_empty),
        .full      (),
        .count     (out_fifo_count)
    );

    // wr_data driven combinationally from output FIFO head. RAM samples per wr_valid cycle.
    assign wr_data = out_fifo_pop_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end
        else begin
            out_valid <= result_commit;
        end
    end

    // out_data tracks the latest user-visible result (last token = result row 7).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= 32'd0;
        end
        else if (result_commit) begin
            out_data <= pot_data[31:0];
        end
    end

endmodule

module CA_InputFIFO #(
    parameter int DEPTH = 16,    // must be a power of 2 for natural pointer wrap
    parameter int WIDTH = 256
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              flush,
    input  logic              push_en,
    input  logic [WIDTH-1:0]  push_data,
    input  logic              pop_en,
    output logic [WIDTH-1:0]  pop_data,
    output logic              empty,
    output logic              full,
    output logic [$clog2(DEPTH+1)-1:0] count
);

    localparam int PTR_W   = $clog2(DEPTH);
    localparam int COUNT_W = $clog2(DEPTH + 1);

    logic [WIDTH-1:0]   mem_q [0:DEPTH-1];
    logic [PTR_W-1:0]   head_q;
    logic [PTR_W-1:0]   tail_q;
    logic [COUNT_W-1:0] count_q;

    logic [COUNT_W-1:0] count_next;

    assign empty    = (count_q == '0);
    assign full     = (count_q == COUNT_W'(DEPTH));
    assign count    = count_q;
    assign pop_data = mem_q[head_q];

    always_comb begin
        case ({push_en, pop_en})
            2'b10:   count_next = count_q + 1'b1;
            2'b01:   count_next = count_q - 1'b1;
            default: count_next = count_q;
        endcase
    end

    // Pointers and count: cleared on reset and on job_start flush.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end
        else if (flush) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end
        else begin
            count_q <= count_next;
            if (push_en) begin
                tail_q <= tail_q + 1'b1;
            end
            if (pop_en) begin
                head_q <= head_q + 1'b1;
            end
        end
    end

    // Storage: deliberately no reset on the memory array to avoid 4096 flop
    // reset wiring; entries are don't-care until written by push.
    always_ff @(posedge clk) begin
        if (push_en && !flush) begin
            mem_q[tail_q] <= push_data;
        end
    end

endmodule

// Indexed register file used as a ring buffer for Q/K/V/score storage.
// Address = matrix_id[log2(DEPTH)-1:0]. No reset on mem_q (overwritten before read).
module CA_MatrixRing #(
    parameter int DEPTH = 2,                              // power of 2
    parameter int WIDTH = 256
)(
    input  logic                       clk,
    input  logic                       wr_en,
    input  logic [$clog2(DEPTH)-1:0]   wr_addr,
    input  logic [WIDTH-1:0]           wr_data,
    input  logic [$clog2(DEPTH)-1:0]   rd_addr,
    output logic [WIDTH-1:0]           rd_data
);

    logic [WIDTH-1:0] mem_q [0:DEPTH-1];

    assign rd_data = mem_q[rd_addr];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem_q[wr_addr] <= wr_data;
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
    input  logic [1:0]    act,        // user act selection (used when act_mode = USER)
    input  logic [1:0]    act_mode,   // 00=USER, 01=BYPASS (Q/K/V/score quant), 10=SPECIAL (SHA partial)
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

    // act/act_mode pipelined one cycle so stage 2 uses the same values that came in with the data.
    logic [1:0]    st1_act_q;
    logic [1:0]    st1_act_mode_q;

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
        input logic [1:0]    mode_sel,
        input logic          phase
    );
        integer idx;
        integer group;
        s40_t  sum [0:3];
        s40_t  threshold;
        s32_t  val;
        begin
            run_half = base_matrix;

            if (mode_sel == 2'b00) begin
                // USER mode: compute row/col/block threshold and apply act_sel
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
            else begin
                // BYPASS (01) or SPECIAL (10): sequential indexing, no threshold
                for (int lane = 0; lane < HALF_SIZE; lane++) begin
                    idx = (phase ? HALF_SIZE : 0) + lane;
                    val = get_i32(src_matrix, idx);
                    if (mode_sel == 2'b10) begin
                        // SPECIAL: SHA partial = (x < 0) ? x >>> 2 : x
                        run_half[2047 - (idx * 32) -: 32] = (val < 0) ? (val >>> 2) : val;
                    end
                    else begin
                        // BYPASS: pass src through unchanged
                        run_half[2047 - (idx * 32) -: 32] = val;
                    end
                end
            end
        end
    endfunction

    always_comb begin
        st0_matrix_next = run_half(in_data,    in_data, act,       act_mode,       1'b0);
        st1_matrix_next = run_half(st1_matrix, st1_src, st1_act_q, st1_act_mode_q, 1'b1);
    end

    // Pipeline act/act_mode for stage 2.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1_act_q      <= 2'd0;
            st1_act_mode_q <= 2'd0;
        end
        else if (in_valid) begin
            st1_act_q      <= act;
            st1_act_mode_q <= act_mode;
        end
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
