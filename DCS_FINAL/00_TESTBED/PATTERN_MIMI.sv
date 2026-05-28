`define CYCLE_TIME       20.0
`define DEBUG_EN         1
`define SEED             23
`define RAM_NUMBER       5
`define OP_SET_NUMBER    5
`define RAM_WIDTH        256
`define RAM_DEPTH        256
`define READ_LATENCY     50
`define WRITE_LATENCY    5
`define BURST_BIT        3


module PATTERN(
    output logic clk,
    output logic rst_n,

    output logic mem_set,
    output logic in_valid,
    output logic [1:0] op,
    output logic [1:0] act,
    output logic [255:0] param,

    input logic out_valid,
    input logic [31:0] out_data
);

    localparam int RAM_DEPTH       = 256;
    localparam int MAT_SIZE        = 64;
    localparam int ROW_SIZE        = 8;
    localparam int MAX_WAIT_CYCLE  = 10000;
    typedef logic [255:0] word_t;

    word_t ram_model [0:RAM_DEPTH-1];
    logic ram_init_wr_en;
    logic [7:0] ram_init_wr_addr;
    logic [2:0] ram_init_wr_burst;
    word_t ram_init_wr_data;
    logic count_enable;
    logic count_started;
    int unsigned cycle_count;

    always begin
        #(`CYCLE_TIME / 2.0) clk = ~clk;
    end

    always @(posedge clk) begin
        if (count_enable) begin
            cycle_count <= cycle_count + 1;
        end
    end

    logic prev_ov;
    initial prev_ov = 0;
    int ov_log_count;
    initial ov_log_count = 0;
    int rd_log_count;
    initial rd_log_count = 0;
    always @(negedge clk) begin
        if (ov_log_count < 12) begin
            if (out_valid !== prev_ov) begin
                $display("[OV] cycle=%0d edge: out_valid %b -> %b out_data=%08h", cycle_count, prev_ov, out_valid, out_data);
                ov_log_count++;
            end else if (out_valid === 1'b1) begin
                $display("[OV] cycle=%0d out_valid=1 out_data=%08h", cycle_count, out_data);
                ov_log_count++;
            end
            prev_ov = out_valid;
        end
        if (TESTBED.rd_valid === 1'b1 && rd_log_count < 135) begin
            $display("[RD] cycle=%0d rd_valid=1 rd_data[255:240]=%h", cycle_count, TESTBED.rd_data[255:240]);
            rd_log_count++;
        end
    end

    function automatic int signed s4_to_int(input logic [3:0] value);
        s4_to_int = $signed(value);
    endfunction

    function automatic logic [3:0] clamp_to_s4(input int signed value);
        int signed clipped;
        begin
            if (value > 7) begin
                clipped = 7;
            end
            else if (value < -8) begin
                clipped = -8;
            end
            else begin
                clipped = value;
            end

            clamp_to_s4 = clipped[3:0];
        end
    endfunction

    function automatic int abs_int(input int signed value);
        abs_int = (value < 0) ? -value : value;
    endfunction

    // Mirror CA.sv 的 bit-width 截斷，確保 reference model 與硬體 bit-exact。
    // matmul/conv 累加器在 CA.sv 中是 s16_t (見 Mult_2Stage_Parallel.sum_q)。
    function automatic int signed sat_s16(input int signed value);
        sat_s16 = $signed(value[15:0]);
    endfunction

    // score buf 在 CA.sv 為 SCORE_ELEM_W=11 bit signed (見 pack_score / unpack_score)。
    function automatic int signed sat_s11(input int signed value);
        logic [10:0] lo;
        begin
            lo = value[10:0];
            sat_s11 = $signed({{21{lo[10]}}, lo});
        end
    endfunction

    // MHA head0 buf 在 CA.sv 為 MHA_OUT_ELEM_W=15 bit signed (見 pack_mha_out / unpack_mha_out)。
    function automatic int signed sat_s15(input int signed value);
        logic [14:0] lo;
        begin
            lo = value[14:0];
            sat_s15 = $signed({{17{lo[14]}}, lo});
        end
    endfunction

    function automatic int avg_src_idx(
        input logic [1:0] act_sel,
        input int group,
        input int elem
    );
        int row;
        int col;
        begin
            case (act_sel)
                2'b01: begin
                    avg_src_idx = (group * ROW_SIZE) + elem;
                end
                2'b10: begin
                    avg_src_idx = (elem * ROW_SIZE) + group;
                end
                2'b11: begin
                    row = ((group / 2) * 4) + (elem / 4);
                    col = ((group % 2) * 4) + (elem % 4);
                    avg_src_idx = (row * ROW_SIZE) + col;
                end
                default: begin
                    avg_src_idx = 0;
                end
            endcase
        end
    endfunction

    function automatic int value_group(input logic [1:0] act_sel, input int idx);
        int row;
        int col;
        begin
            row = idx / ROW_SIZE;
            col = idx % ROW_SIZE;

            case (act_sel)
                2'b01: value_group = row;
                2'b10: value_group = col;
                2'b11: value_group = ((row / 4) * 2) + (col / 4);
                default: value_group = 0;
            endcase
        end
    endfunction

    task automatic stop_with_msg(input string msg);
        begin
            YOU_FAIL_TASK();
            $display ("----------------------------------------------------------------------------------------------------------------------");
            $display("FAIL: %s", msg);
            $display ("----------------------------------------------------------------------------------------------------------------------");
            repeat (5) @(negedge clk);
            $finish;
        end
    endtask

    task automatic unpack_word(input word_t src, output int signed dst [0:MAT_SIZE-1]);
        begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                dst[i] = s4_to_int(src[255 - (i * 4) -: 4]);
            end
        end
    endtask

    function automatic word_t pack_quantized(input int signed src [0:MAT_SIZE-1]);
        int unsigned max_abs;
        int unsigned mag;
        int shift;
        int signed scaled;
        begin
            max_abs = 0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                mag = abs_int(src[i]);
                if (mag > max_abs) begin
                    max_abs = mag;
                end
            end

            shift = 0;
            for (int b = 0; b < 31; b++) begin
                if (max_abs[b]) begin
                    shift = b;
                end
            end
            shift = (shift > 2) ? (shift - 2) : 0;

            pack_quantized = '0;
            for (int i = 0; i < MAT_SIZE; i++) begin
                scaled = src[i] >>> shift;
                pack_quantized[255 - (i * 4) -: 4] = clamp_to_s4(scaled);
            end
        end
    endfunction

    task automatic matmul_8x8(
        input int signed a [0:MAT_SIZE-1],
        input int signed b [0:MAT_SIZE-1],
        input bit b_transpose,
        input int head_sel,
        output int signed y [0:MAT_SIZE-1]
    );
        int signed acc;
        int b_idx;
        begin
            for (int r = 0; r < ROW_SIZE; r++) begin
                for (int c = 0; c < ROW_SIZE; c++) begin
                    acc = 0;
                    for (int k = 0; k < ROW_SIZE; k++) begin
                        if ((head_sel == 0) && (k >= 4)) begin
                            continue;
                        end
                        if ((head_sel == 1) && (k < 4)) begin
                            continue;
                        end

                        b_idx = b_transpose ? ((c * ROW_SIZE) + k) :
                                              ((k * ROW_SIZE) + c);
                        acc += a[(r * ROW_SIZE) + k] * b[b_idx];
                    end
                    y[(r * ROW_SIZE) + c] = sat_s16(acc);
                end
            end
        end
    endtask

    task automatic conv_3x3(
        input int signed src [0:MAT_SIZE-1],
        input int signed kernel [0:MAT_SIZE-1],
        output int signed y [0:MAT_SIZE-1]
    );
        int signed acc;
        int rr;
        int cc;
        begin
            for (int r = 0; r < ROW_SIZE; r++) begin
                for (int c = 0; c < ROW_SIZE; c++) begin
                    acc = 0;
                    for (int kr = 0; kr < 3; kr++) begin
                        for (int kc = 0; kc < 3; kc++) begin
                            rr = r + kr - 1;
                            cc = c + kc - 1;
                            if ((rr >= 0) && (rr < ROW_SIZE) &&
                                (cc >= 0) && (cc < ROW_SIZE)) begin
                                acc += src[(rr * ROW_SIZE) + cc] *
                                       kernel[(kr * 3) + kc];
                            end
                        end
                    end
                    y[(r * ROW_SIZE) + c] = sat_s16(acc);
                end
            end
        end
    endtask

    task automatic activate_matrix(
        input int signed src [0:MAT_SIZE-1],
        input logic [1:0] act_sel,
        output int signed dst [0:MAT_SIZE-1]
    );
        int signed avg [0:ROW_SIZE-1];
        int signed sum;
        int group_count;
        begin
            for (int g = 0; g < ROW_SIZE; g++) begin
                avg[g] = 0;
            end

            case (act_sel)
                2'b01,
                2'b10: begin
                    for (int g = 0; g < ROW_SIZE; g++) begin
                        sum = 0;
                        for (int i = 0; i < ROW_SIZE; i++) begin
                            sum += src[avg_src_idx(act_sel, g, i)];
                        end
                        avg[g] = sum >>> 3;
                    end
                end
                2'b11: begin
                    for (int g = 0; g < 4; g++) begin
                        sum = 0;
                        for (int i = 0; i < 16; i++) begin
                            sum += src[avg_src_idx(act_sel, g, i)];
                        end
                        avg[g] = sum >>> 4;
                    end
                end
                default: begin
                end
            endcase

            for (int i = 0; i < MAT_SIZE; i++) begin
                if (act_sel == 2'b00) begin
                    dst[i] = (src[i] < 0) ? 0 : src[i];
                end
                else begin
                    group_count = value_group(act_sel, i);
                    dst[i] = (src[i] < avg[group_count]) ? (src[i] >>> 3) : src[i];
                end
            end
        end
    endtask

    task automatic attention_score_act(
        input int signed src [0:MAT_SIZE-1],
        output int signed dst [0:MAT_SIZE-1]
    );
        int signed tmp;
        begin
            for (int i = 0; i < MAT_SIZE; i++) begin
                tmp    = (src[i] < 0) ? (src[i] >>> 2) : src[i];
                // CA.sv 在 ACT_SPECIAL 之後，把結果存進 11-bit signed score_buf，
                // 之後做 score x V 時再 sign-extend 回 s16。對應到 reference 就是
                // 在這裡把值收斂到 s11。
                dst[i] = sat_s11(tmp);
            end
        end
    endtask

    task automatic calc_normal_word(
        input word_t src_word,
        input word_t param_word,
        input logic [1:0] op_sel,
        input logic [1:0] act_sel,
        output word_t dst_word
    );
        int signed src [0:MAT_SIZE-1];
        int signed par [0:MAT_SIZE-1];
        int signed comp [0:MAT_SIZE-1];
        int signed act_out [0:MAT_SIZE-1];
        begin
            unpack_word(src_word, src);
            unpack_word(param_word, par);

            if (op_sel == 2'b01) begin
                conv_3x3(src, par, comp);
            end
            else begin
                matmul_8x8(src, par, 1'b0, -1, comp);
            end

            activate_matrix(comp, act_sel, act_out);
            dst_word = pack_quantized(act_out);
        end
    endtask

    task automatic calc_attention_word(
        input word_t src_word,
        input word_t wq_word,
        input word_t wk_word,
        input word_t wv_word,
        input logic [1:0] op_sel,
        input logic [1:0] act_sel,
        output word_t dst_word
    );
        int signed src [0:MAT_SIZE-1];
        int signed wq [0:MAT_SIZE-1];
        int signed wk [0:MAT_SIZE-1];
        int signed wv [0:MAT_SIZE-1];
        int signed q_comp [0:MAT_SIZE-1];
        int signed k_comp [0:MAT_SIZE-1];
        int signed v_comp [0:MAT_SIZE-1];
        int signed q [0:MAT_SIZE-1];
        int signed k [0:MAT_SIZE-1];
        int signed v [0:MAT_SIZE-1];
        int signed score [0:MAT_SIZE-1];
        int signed score_act [0:MAT_SIZE-1];
        int signed score0 [0:MAT_SIZE-1];
        int signed score1 [0:MAT_SIZE-1];
        int signed score0_act [0:MAT_SIZE-1];
        int signed score1_act [0:MAT_SIZE-1];
        int signed final0 [0:MAT_SIZE-1];
        int signed final1 [0:MAT_SIZE-1];
        int signed combined [0:MAT_SIZE-1];
        int signed act_out [0:MAT_SIZE-1];
        word_t q_word;
        word_t k_word;
        word_t v_word;
        begin
            unpack_word(src_word, src);
            unpack_word(wq_word, wq);
            unpack_word(wk_word, wk);
            unpack_word(wv_word, wv);

            matmul_8x8(src, wq, 1'b0, -1, q_comp);
            matmul_8x8(src, wk, 1'b0, -1, k_comp);
            matmul_8x8(src, wv, 1'b0, -1, v_comp);

            q_word = pack_quantized(q_comp);
            k_word = pack_quantized(k_comp);
            v_word = pack_quantized(v_comp);
            unpack_word(q_word, q);
            unpack_word(k_word, k);
            unpack_word(v_word, v);

            if (op_sel == 2'b11) begin
                matmul_8x8(q, k, 1'b1, 0, score0);
                matmul_8x8(q, k, 1'b1, 1, score1);
                attention_score_act(score0, score0_act);
                attention_score_act(score1, score1_act);
                matmul_8x8(score0_act, v, 1'b0, -1, final0);
                matmul_8x8(score1_act, v, 1'b0, -1, final1);

                // CA.sv 把 head0 的全結果存進 15-bit signed mha_out0_buf 後再合併，
                // 對應到 reference 就是 head0 那半邊先 sat_s15。head1 走的是 mult_data
                // 直接合併，所以右半邊保留 s16 不截斷。
                for (int r = 0; r < ROW_SIZE; r++) begin
                    for (int c = 0; c < ROW_SIZE; c++) begin
                        combined[(r * ROW_SIZE) + c] =
                            (c < 4) ? sat_s15(final0[(r * ROW_SIZE) + c]) :
                                      final1[(r * ROW_SIZE) + c];
                    end
                end
            end
            else begin
                matmul_8x8(q, k, 1'b1, -1, score);
                attention_score_act(score, score_act);
                matmul_8x8(score_act, v, 1'b0, -1, combined);
            end

            activate_matrix(combined, act_sel, act_out);
            dst_word = pack_quantized(act_out);
        end
    endtask

    function automatic word_t random_param(input bit kernel_only);
        int limit;
        begin
            random_param = '0;
            limit = kernel_only ? 9 : MAT_SIZE;

            for (int i = 0; i < limit; i++) begin
                random_param[255 - (i * 4) -: 4] = $urandom_range(0, 15);
            end
        end
    endfunction

    function automatic logic [3:0] op_set_id(input int ram_idx, input int op_idx);
        begin
            case (ram_idx)
                0: begin
                    case (op_idx)
                        0: op_set_id = 4'b0000;
                        1: op_set_id = 4'b0101;
                        2: op_set_id = 4'b1010;
                        3: op_set_id = 4'b1111;
                        default: op_set_id = 4'b0001;
                    endcase
                end
                1: begin
                    case (op_idx)
                        0: op_set_id = 4'b0110;
                        1: op_set_id = 4'b1011;
                        2: op_set_id = 4'b1100;
                        3: op_set_id = 4'b0001;
                        default: op_set_id = 4'b0111;
                    endcase
                end
                2: begin
                    case (op_idx)
                        0: op_set_id = 4'b1000;
                        1: op_set_id = 4'b1101;
                        2: op_set_id = 4'b0010;
                        3: op_set_id = 4'b0111;
                        default: op_set_id = 4'b1001;
                    endcase
                end
                3: begin
                    case (op_idx)
                        0: op_set_id = 4'b1110;
                        1: op_set_id = 4'b0011;
                        2: op_set_id = 4'b0100;
                        3: op_set_id = 4'b1001;
                        default: op_set_id = 4'b1100;
                    endcase
                end
                default: begin
                    case (op_idx)
                        0: op_set_id = 4'b0010;
                        1: op_set_id = 4'b0111;
                        2: op_set_id = 4'b1000;
                        3: op_set_id = 4'b1101;
                        default: op_set_id = 4'b0011;
                    endcase
                end
            endcase
        end
    endfunction

    task automatic load_ram_model(input int ram_idx);
        string file_name;
        int fd;
        begin
            $sformat(file_name, "../00_TESTBED/ram/pat%02d_data.txt", ram_idx);
            fd = $fopen(file_name, "r");
            if (fd == 0) begin
                $sformat(file_name, "ram/pat%02d_data.txt", ram_idx);
                fd = $fopen(file_name, "r");
            end
            if (fd == 0) begin
                $sformat(file_name, "00_TESTBED/ram/pat%02d_data.txt", ram_idx);
                fd = $fopen(file_name, "r");
            end

            if (fd != 0) begin
                $fclose(fd);
                $readmemh(file_name, ram_model);
`ifdef MIMI_DIRECT_RAM_INIT
`ifndef MIMI_RAM_ARRAY
                $display("FAIL: MIMI_DIRECT_RAM_INIT needs +define+MIMI_RAM_ARRAY=<hierarchical_ram_array>");
                $finish;
`else
                $readmemh(file_name, `MIMI_RAM_ARRAY);
`endif
`endif
            end
            else begin
                for (int i = 0; i < RAM_DEPTH; i++) begin
                    ram_model[i] = random_param(1'b0);
                end
            end
        end
    endtask

    task automatic write_ram_burst(input int base_addr);
        int data_idx;
        begin
            while (TESTBED.wr_ready !== 1'b1) begin
                @(negedge clk);
            end

            ram_init_wr_addr  = base_addr[7:0];
            ram_init_wr_burst = 3'd7;
            ram_init_wr_data  = ram_model[base_addr];
            ram_init_wr_en    = 1'b1;

            force TESTBED.wr_en    = ram_init_wr_en;
            force TESTBED.wr_addr  = ram_init_wr_addr;
            force TESTBED.wr_burst = ram_init_wr_burst;
            force TESTBED.wr_data  = ram_init_wr_data;
            @(negedge clk);

            ram_init_wr_en = 1'b0;

            data_idx = 0;
            while (data_idx < 128) begin
                if (TESTBED.wr_valid === 1'b1) begin
                    if (base_addr == 0 && data_idx < 5)
                        $display("[DBG] sample %0d at wr_valid: wr_data[255:240]=%h expected ram[%0d][255:240]=%h",
                                 data_idx, TESTBED.wr_data[255:240], data_idx, ram_model[data_idx][255:240]);
                    data_idx++;
                    if (data_idx < 128) begin
                        ram_init_wr_data = ram_model[base_addr + data_idx];
                    end
                end
                @(negedge clk);
            end

            release TESTBED.wr_en;
            release TESTBED.wr_addr;
            release TESTBED.wr_burst;
            release TESTBED.wr_data;
            @(negedge clk);
        end
    endtask

    task automatic init_ram_from_model;
        begin
`ifndef MIMI_DIRECT_RAM_INIT
            write_ram_burst(0);
            write_ram_burst(128);
`endif
        end
    endtask

    task automatic idle_cycles(input int num_cycles);
        begin
            for (int i = 0; i < num_cycles; i++) begin
                @(negedge clk);
                if (out_valid === 1'b1) begin
                    stop_with_msg("Unexpected out_valid during idle period.");
                end
            end
        end
    endtask

    task automatic reset_task;
        begin
            rst_n       = 1'b1;
            mem_set     = 1'b0;
            in_valid    = 1'b0;
            op          = 2'bx;
            act         = 2'bx;
            param       = 'x;
            ram_init_wr_en    = 1'b0;
            ram_init_wr_addr  = 8'd0;
            ram_init_wr_burst = 3'd0;
            ram_init_wr_data  = '0;
            count_enable      = 1'b0;
            count_started     = 1'b0;
            clk         = 1'b0;
            cycle_count = 0;

            #(0.1);
            rst_n = 1'b0;
            repeat (4) @(negedge clk);

            if (out_valid !== 1'b0 || out_data !== 32'd0) begin
                stop_with_msg("Output signals are not reset to zero.");
            end

            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic drive_operation(
        input logic [1:0] op_sel,
        input logic [1:0] act_sel,
        input word_t p0,
        input word_t p1,
        input word_t p2
    );
        begin
            idle_cycles($urandom_range(0, 3));

            if (!count_started) begin
                cycle_count   = 0;
                count_started = 1'b1;
                count_enable  = 1'b1;
            end

            in_valid = 1'b1;
            op       = op_sel;
            act      = act_sel;
            param    = p0;
            @(negedge clk);

            if (op_sel[1]) begin
                param = p1;
                @(negedge clk);
                param = p2;
                @(negedge clk);
            end

            in_valid = 1'b0;
            op       = 2'bx;
            act      = 2'bx;
            param    = 'x;
        end
    endtask

    task automatic wait_and_check_word(input int idx, input word_t expected_word);
        int wait_count;
        begin
            wait_count = 0;
            while (out_valid !== 1'b1) begin
                wait_count++;
                if (wait_count > MAX_WAIT_CYCLE) begin
                    YOU_FAIL_TASK();
                    $display ("----------------------------------------------------------------------------------------------------------------------");
                    $display("  FAIL: out_valid did not rise within %0d cycles.", MAX_WAIT_CYCLE);
                    $display("  waiting output word index = %0d", idx);
                    repeat (5) @(negedge clk);
                    $finish;
                end
                @(negedge clk);
            end

            if (idx < 5) begin
                $display("[CHK] idx=%0d expected=%08h got=%08h ram_model[%0d][31:0]=%08h",
                         idx, expected_word[31:0], out_data, idx, ram_model[idx][31:0]);
            end

            if (out_data !== expected_word[31:0]) begin
                $display("  FAIL_NOEXIT: word %0d expected=%08h got=%08h", idx, expected_word[31:0], out_data);
                // YOU_FAIL_TASK();
                // repeat (5) @(negedge clk);
                // $finish;
            end

            @(negedge clk);
        end
    endtask

    task automatic wait_out_valid_low;
        int wait_count;
        begin
            wait_count = 0;
            while (out_valid === 1'b1) begin
                wait_count++;
                if (wait_count > MAX_WAIT_CYCLE) begin
                    YOU_FAIL_TASK();
                    $display ("----------------------------------------------------------------------------------------------------------------------");
                    $display("  FAIL: out_valid did not fall within %0d cycles.", MAX_WAIT_CYCLE);
                    $display ("----------------------------------------------------------------------------------------------------------------------");
                    repeat (5) @(negedge clk);
                    $finish;
                end
                @(negedge clk);
            end
        end
    endtask

    task automatic run_operation(input int ram_idx, input int op_idx);
        logic [1:0] op_sel;
        logic [1:0] act_sel;
        word_t p0;
        word_t p1;
        word_t p2;
        word_t next_model [0:RAM_DEPTH-1];
        logic [3:0] op_act_id;
        begin
            op_act_id = op_set_id(ram_idx, op_idx);
            op_sel    = op_act_id[3:2];
            act_sel   = op_act_id[1:0];

            if (op_sel == 2'b01) begin
                p0 = random_param(1'b1);
            end
            else begin
                p0 = random_param(1'b0);
            end
            p1 = random_param(1'b0);
            p2 = random_param(1'b0);

            for (int i = 0; i < RAM_DEPTH; i++) begin
                if (op_sel[1]) begin
                    calc_attention_word(ram_model[i], p0, p1, p2,
                                        op_sel, act_sel, next_model[i]);
                end
                else begin
                    calc_normal_word(ram_model[i], p0, op_sel,
                                     act_sel, next_model[i]);
                end
            end

            if (`DEBUG_EN) begin
                $display("\033[32mPASS\033[0m \033[36m[MY_PATTERN] RAM NO.%0d OP SET NO.%0d \033[0m| op=%0d act=%0d",
                         ram_idx, op_idx, op_sel, act_sel);
            end

            drive_operation(op_sel, act_sel, p0, p1, p2);

            for (int i = 0; i < RAM_DEPTH; i++) begin
                wait_and_check_word(i, next_model[i]);
            end

            for (int i = 0; i < RAM_DEPTH; i++) begin
                ram_model[i] = next_model[i];
            end
        end
    endtask

    initial begin
        void'($urandom(`SEED));
        reset_task();

        for (int ram_idx = 0; ram_idx < `RAM_NUMBER; ram_idx++) begin
            if (`DEBUG_EN) begin
                $display("[PATTERN_MIMI] Load RAM set %0d", ram_idx);
            end

            mem_set = 1'b0;
            load_ram_model(ram_idx);
            init_ram_from_model();

            mem_set = 1'b1;
            idle_cycles(3);

            for (int op_idx = 0; op_idx < `OP_SET_NUMBER; op_idx++) begin
                run_operation(ram_idx, op_idx);
            end

            wait_out_valid_low();
            if (ram_idx == (`RAM_NUMBER - 1)) begin
                count_enable = 1'b0;
            end
            mem_set = 1'b0;
            idle_cycles($urandom_range(2, 6));
        end

        YOU_PASS_TASK();

        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("                                                  Congratulations!                						             ");
        $display ("                                           You have passed all patterns!          						             ");
        $display ("                                execution cycles = %6d cycles, Cycle Time = %.1f ns        						         ", cycle_count, `CYCLE_TIME);
        $display ("----------------------------------------------------------------------------------------------------------------------");
        repeat (5) @(negedge clk);
        $finish;
    end



task YOU_PASS_TASK; begin
    $display("\033[0m                                                                                \033[32m      :BBQvi.                                            \033[m");
    $display("\033[0m                                                                 \033[38;2;49;45;33m.\033[38;2;48;45;33m.\033[0m             \033[32m     BBBBBBBBQi                                          \033[m");
    $display("\033[0m      \033[38;2;31;30;27m.\033[38;2;35;33;28m.\033[0m                                                        \033[38;2;75;67;41m:\033[38;2;183;159;82m+\033[38;2;166;143;73m+\033[38;2;107;94;54m-\033[0m            \033[32m    :BBBP :7BBBB.                                        \033[m");
    $display("\033[0m     \033[38;2;54;49;33m.\033[38;2;187;161;83m+\033[38;2;201;173;88m*\033[38;2;86;76;45m:\033[0m                                                 \033[38;2;35;33;27m.\033[38;2;67;61;39m:\033[38;2;50;46;33m.\033[0m   \033[38;2;82;73;44m:\033[38;2;168;145;75m+\033[38;2;167;144;74m+\033[38;2;111;97;55m-\033[0m            \033[32m    BBBB     BBBB                                        \033[m");
    $display("\033[0m    \033[38;2;47;44;30m.\033[38;2;196;169;86m+\033[38;2;127;110;58m-\033[38;2;84;74;42m:\033[38;2;205;177;90m*\033[38;2;123;108;58m-\033[0m                                               \033[38;2;94;82;47m:\033[38;2;211;183;90m*\033[38;2;250;217;102m#\033[38;2;228;196;96m*\033[38;2;65;58;37m:\033[0m   \033[38;2;33;31;27m.\033[38;2;55;50;34m.\033[38;2;72;65;40m:\033[38;2;131;115;61m=\033[38;2;154;134;70m=\033[38;2;121;106;57m-\033[38;2;55;50;34m.\033[0m        \033[32m   iBBBv     BBBB        vBr                             \033[m");
    $display("\033[0m    \033[38;2;74;66;41m:\033[38;2;220;190;96m*\033[38;2;131;114;60m=\033[38;2;60;53;32m.\033[38;2;200;173;87m*\033[38;2;156;135;71m=\033[0m   \033[38;2;29;28;26m.\033[38;2;31;30;27m.\033[0m     \033[38;2;33;31;27m.\033[38;2;64;58;38m:\033[38;2;55;50;34m.\033[0m                                 \033[38;2;54;49;33m.\033[38;2;230;198;97m#\033[38;2;255;229;106m#\033[38;2;255;227;106m#\033[38;2;193;167;82m+\033[38;2;45;41;30m.\033[0m   \033[38;2;56;51;34m.\033[38;2;175;152;77m+\033[38;2;249;215;102m#\033[38;2;255;226;105m#\033[38;2;255;225;104m#\033[38;2;255;229;106m#\033[38;2;211;182;90m*\033[38;2;43;39;29m.\033[0m       \033[32m   BBBBBKrirBBBB.     :BBBBBB:                           \033[m");
    $display("\033[0m     \033[38;2;59;53;35m.\033[38;2;165;143;74m+\033[38;2;198;173;87m*\033[38;2;143;124;67m=\033[0m   \033[38;2;120;105;57m-\033[38;2;207;180;88m*\033[38;2;214;185;90m*\033[38;2;165;144;73m+\033[38;2;63;56;36m.\033[0m   \033[38;2;166;144;75m+\033[38;2;249;218;103m#\033[38;2;237;206;99m#\033[38;2;107;94;52m-\033[0m                                \033[38;2;95;84;48m:\033[38;2;255;221;107m#\033[38;2;224;194;93m*\033[38;2;135;117;62m=\033[38;2;39;36;28m.\033[0m   \033[38;2;85;75;44m:\033[38;2;225;195;95m*\033[38;2;255;226;105m#\033[38;2;255;219;101m#\033[38;2;255;218;101m#\033[38;2;255;223;103m#\033[38;2;255;225;105m#\033[38;2;182;158;79m+\033[38;2;37;35;27m.\033[0m       \033[32m  rBBBBBBBBBBBR.    .BBBM:BBB                            \033[m");
    $display("\033[0m       \033[38;2;34;32;27m.\033[0m   \033[38;2;36;34;27m.\033[38;2;211;182;91m*\033[38;2;255;234;108mO\033[38;2;255;225;103m#\033[38;2;255;227;105m#\033[38;2;230;200;97m#\033[38;2;85;75;44m:\033[0m  \033[38;2;121;106;57m-\033[38;2;247;214;102m#\033[38;2;255;233;109mO\033[38;2;147;128;67m=\033[0m \033[38;2;37;35;28m.\033[38;2;112;98;56m-\033[38;2;78;70;43m:\033[0m                            \033[38;2;49;45;32m.\033[38;2;97;86;51m-\033[38;2;44;41;30m.\033[0m    \033[38;2;103;90;50m-\033[38;2;237;206;98m#\033[38;2;255;223;103m#\033[38;2;255;219;101m#\033[38;2;255;224;104m#\033[38;2;255;223;104m#\033[38;2;214;185;90m*\033[38;2;119;104;56m-\033[38;2;34;32;26m.\033[0m        \033[32m  BBBB   .::.      EBBBi :BBU                            \033[m");
    $display("\033[0m            \033[38;2;71;64;39m:\033[38;2;177;154;77m+\033[38;2;241;208;99m#\033[38;2;255;225;104m#\033[38;2;255;230;106m#\033[38;2;235;203;98m#\033[38;2;83;73;43m:\033[0m  \033[38;2;74;66;41m:\033[38;2;117;103;58m-\033[38;2;51;47;33m.\033[0m \033[38;2;148;128;70m=\033[38;2;175;150;74m+\033[38;2;193;167;85m+\033[38;2;96;85;49m-\033[0m                        \033[38;2;33;27;25m.\033[38;2;50;36;31m.\033[38;2;71;55;49m:\033[38;2;61;44;40m.\033[0m     \033[38;2;95;84;47m:\033[38;2;246;213;102m#\033[38;2;255;227;105m#\033[38;2;255;225;105m#\033[38;2;247;213;100m#\033[38;2;191;165;82m+\033[38;2;107;94;52m-\033[38;2;35;33;27m.\033[0m          \033[32m MBBBr           vBBBu   BBB.                            \033[m");
    $display("\033[0m              \033[38;2;60;55;36m.\033[38;2;128;112;60m-\033[38;2;187;161;80m+\033[38;2;230;202;97m#\033[38;2;162;141;74m=\033[0m      \033[38;2;78;69;43m:\033[38;2;153;133;71m=\033[38;2;148;130;69m=\033[38;2;51;47;32m.\033[0m                \033[38;2;44;32;28m.\033[38;2;92;71;64m:\033[38;2;151;135;129m=\033[38;2;159;143;138m+\033[38;2;114;93;87m-\033[38;2;58;39;34m.\033[0m \033[38;2;41;31;27m.\033[38;2;99;76;67m:\033[38;2;203;192;189m*\033[38;2;237;232;231mO\033[38;2;225;218;216m#\033[38;2;166;150;145m+\033[38;2;80;58;51m:\033[38;2;36;29;26m.\033[0m \033[38;2;41;38;28m.\033[38;2;212;183;91m*\033[38;2;246;215;102m#\033[38;2;201;174;85m*\033[38;2;141;123;64m=\033[38;2;70;62;39m:\033[0m  \033[38;2;34;32;27m.\033[38;2;69;62;39m:\033[38;2;84;75;45m:\033[38;2;51;47;33m.\033[0m       \033[32m i7PB          iBBBBB.  iBBB                             \033[m");
    $display("\033[0m         \033[38;2;54;50;34m.\033[38;2;111;98;55m-\033[38;2;102;90;51m-\033[38;2;49;45;32m.\033[0m    \033[38;2;40;38;30m.\033[38;2;35;33;28m.\033[0m                         \033[38;2;40;31;26m.\033[38;2;103;78;69m-\033[38;2;231;225;223mO\033[38;2;255;255;255m@@\033[38;2;253;251;251mO\033[38;2;171;155;149m+\033[38;2;64;43;34m.\033[38;2;70;46;37m.\033[38;2;195;184;179m*\033[38;2;255;255;255m@@@@\033[38;2;211;201;198m#\033[38;2;86;61;53m:\033[38;2;35;28;26m.\033[38;2;32;31;27m.\033[38;2;80;72;44m:\033[38;2;61;56;37m.\033[0m   \033[38;2;43;40;30m.\033[38;2;135;118;62m=\033[38;2;218;189;92m*\033[38;2;252;216;102m#\033[38;2;255;225;105m#\033[38;2;235;202;99m#\033[38;2;70;63;39m:\033[0m      \033[32m             vBBBBPBBBBPBBB7       .7QBB5i               \033[m");
    $display("\033[0m         \033[38;2;174;151;78m+\033[38;2;255;235;111mO\033[38;2;255;230;107m#\033[38;2;237;206;99m#\033[38;2;114;100;55m-\033[0m                              \033[38;2;64;41;33m.\033[38;2;185;171;166m*\033[38;2;255;255;255m@@@@\033[38;2;254;254;253m@\033[38;2;136;115;108m=\033[38;2;90;61;51m:\033[38;2;235;231;229mO\033[38;2;255;255;255m@@@@@\033[38;2;166;150;144m+\033[38;2;57;37;30m.\033[0m     \033[38;2;63;57;37m:\033[38;2;216;186;92m*\033[38;2;255;227;107m#\033[38;2;254;218;102m#\033[38;2;241;207;98m#\033[38;2;218;189;91m*\033[38;2;162;141;72m=\033[38;2;46;42;30m.\033[0m      \033[32m            :RBBB.  .rBBBBB.      rBBBBBBBB7             \033[m");
    $display("\033[0m         \033[38;2;59;53;35m.\033[38;2;136;119;63m=\033[38;2;173;150;75m+\033[38;2;185;162;81m+\033[38;2;123;108;60m-\033[0m                             \033[38;2;32;27;26m.\033[38;2;83;58;51m:\033[38;2;223;217;214m#\033[38;2;255;255;255m@@@@@\033[38;2;193;182;178m*\033[38;2;91;62;52m:\033[38;2;234;229;227mO\033[38;2;255;255;255m@@@@@\033[38;2;228;222;220m#\033[38;2;88;63;54m:\033[38;2;34;28;26m.\033[0m    \033[38;2;39;37;29m.\033[38;2;90;80;47m:\033[38;2;86;76;45m:\033[38;2;67;60;38m:\033[38;2;53;48;34m.\033[38;2;29;29;25m.\033[0m        \033[32m               .       BBBB       BBBB  :BBBB            \033[m");
    $display("\033[0m                               \033[38;2;39;28;24m.\033[38;2;57;42;36m.\033[38;2;66;49;43m.\033[38;2;47;34;29m.\033[38;2;32;27;24m.\033[0m       \033[38;2;34;28;26m.\033[38;2;89;64;56m:\033[38;2;229;224;222mO\033[38;2;255;255;255m@@@@@\033[38;2;224;217;215m#\033[38;2;91;64;55m:\033[38;2;222;216;213m#\033[38;2;255;255;255m@@@@@\033[38;2;247;245;244mO\033[38;2;113;90;82m-\033[38;2;42;31;27m.\033[0m         \033[38;2;96;84;48m:\033[38;2;182;160;83m+\033[38;2;93;83;48m:\033[0m      \033[32m                      rBBBr       BBBB    BBBU           \033[m");
    $display("\033[0m             \033[38;2;34;27;25m.\033[38;2;59;41;35m.\033[38;2;97;78;72m:\033[38;2;95;76;69m:\033[38;2;63;44;38m.\033[38;2;37;27;23m.\033[0m          \033[38;2;51;35;29m.\033[38;2;105;84;77m-\033[38;2;176;161;156m+\033[38;2;221;214;210m#\033[38;2;233;227;225mO\033[38;2;188;175;171m*\033[38;2;104;80;72m-\033[38;2;49;33;27m.\033[0m      \033[38;2;34;28;26m.\033[38;2;87;62;54m:\033[38;2;227;221;219m#\033[38;2;255;255;255m@@@@@\033[38;2;244;241;240mO\033[38;2;101;75;66m:\033[38;2;197;186;183m*\033[38;2;255;255;255m@@@@@@\033[38;2;145;124;118m=\033[38;2;50;33;27m.\033[0m        \033[38;2;92;81;47m:\033[38;2;202;175;90m*\033[38;2;114;100;51m-\033[38;2;190;164;84m+\033[38;2;132;115;62m=\033[0m     \033[32m                      vBBB        .BBBB   :7i.           \033[m");
    $display("\033[0m            \033[38;2;46;32;27m.\033[38;2;104;80;72m-\033[38;2;205;195;191m#\033[38;2;250;247;247mO\033[38;2;248;246;245mO\033[38;2;217;209;206m#\033[38;2;152;134;129m=\033[38;2;91;70;63m:\033[38;2;50;34;29m.\033[0m      \033[38;2;39;26;22m.\033[38;2;87;64;56m:\033[38;2;183;170;165m*\033[38;2;248;246;245mO\033[38;2;255;255;255m@@@@\033[38;2;240;236;235mO\033[38;2;142;122;115m=\033[38;2;61;39;32m.\033[0m     \033[38;2;31;27;26m.\033[38;2;77;52;44m:\033[38;2;212;203;200m#\033[38;2;255;255;255m@@@@@\033[38;2;254;254;253m@\033[38;2;118;95;87m-\033[38;2;166;151;145m+\033[38;2;255;255;255m@@@@@@\033[38;2;179;165;160m*\033[38;2;56;31;23m.\033[0m        \033[38;2;134;117;63m=\033[38;2;187;161;83m+\033[38;2;39;35;25m.\033[38;2;136;118;61m=\033[38;2;209;180;92m*\033[38;2;41;38;28m.\033[0m    \033[32m                       .7   BBB7   iBBBg                 \033[m");
    $display("\033[0m           \033[38;2;47;33;27m.\033[38;2;111;86;79m-\033[38;2;231;225;224mO\033[38;2;255;255;255m@@@@@\033[38;2;244;240;239mO\033[38;2;198;186;182m*\033[38;2;131;113;107m=\033[38;2;100;83;77m-\033[38;2;106;88;82m-\033[38;2;124;108;101m-\033[38;2;143;126;120m=\033[38;2;159;144;138m+\033[38;2;170;155;150m+\033[38;2;226;219;218m#\033[38;2;255;255;255m@@@@@@@\033[38;2;253;252;252m@\033[38;2;173;157;152m+\033[38;2;73;49;40m.\033[38;2;34;28;25m.\033[0m    \033[38;2;55;31;23m.\033[38;2;177;162;157m+\033[38;2;255;255;255m@@@@@@\033[38;2;173;159;155m+\033[38;2;171;157;152m+\033[38;2;255;255;255m@@@@@@\033[38;2;233;229;227mO\033[38;2;150;132;126m=\033[38;2;116;98;91m-\033[38;2;79;60;53m:\033[38;2;50;36;31m.\033[38;2;35;26;23m.\033[0m    \033[38;2;30;29;25m.\033[38;2;123;107;59m-\033[38;2;189;164;83m+\033[38;2;192;166;85m+\033[38;2;64;57;36m:\033[0m     \033[32m                            ZBBBr  EBBBv     .BBBBQi     \033[m");
    $display("\033[0m          \033[38;2;42;31;28m.\033[38;2;94;67;59m:\033[38;2;224;217;215m#\033[38;2;255;255;255m@@@@@@@@@\033[38;2;254;253;252m@\033[38;2;255;254;253m@\033[38;2;255;255;255m@@@@@@@@@@@@@@\033[38;2;199;189;185m*\033[38;2;89;66;58m:\033[38;2;43;31;27m.\033[0m \033[38;2;58;43;37m.\033[38;2;92;74;68m:\033[38;2;135;116;110m=\033[38;2;213;205;202m#\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@\033[38;2;239;235;233mO\033[38;2;211;202;199m#\033[38;2;174;159;154m+\033[38;2;114;95;88m-\033[38;2;65;46;41m.\033[38;2;37;26;23m.\033[0m   \033[38;2;40;38;30m.\033[38;2;37;35;29m.\033[0m      \033[32m                             iBBBBBBBBD     rBBBBBBBB.   \033[m");
    $display("\033[0m          \033[38;2;69;45;36m.\033[38;2;190;178;173m*\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;245;243;242mO\033[38;2;146;126;120m=\033[38;2;95;67;58m:\033[38;2;156;139;134m+\033[38;2;219;211;208m#\033[38;2;249;246;245mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@\033[38;2;255;254;253m@\033[38;2;224;217;215m#\033[38;2;169;155;150m+\033[38;2;103;82;75m-\033[38;2;53;37;32m.\033[0m         \033[32m                               :LBBBr      :vBBi  5BBB   \033[m");
    $display("\033[0m         \033[38;2;58;37;30m.\033[38;2;140;121;114m=\033[38;2;253;252;252m@\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;192;181;177m*\033[38;2;115;91;84m-\033[38;2;158;142;137m+\033[38;2;234;230;229mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;249;247;246mO\033[38;2;201;191;187m*\033[38;2;106;85;77m-\033[38;2;47;32;27m.\033[0m       \033[32m                                           :BBB:   BBBu  \033[m");
    $display("\033[0m       \033[38;2;49;33;27m.\033[38;2;105;82;74m-\033[38;2;196;185;182m*\033[38;2;250;250;249mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;247;246;245mO\033[38;2;149;130;125m=\033[38;2;111;86;78m-\033[38;2;212;204;202m#\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;245;242;241mO\033[38;2;157;139;133m+\033[38;2;63;41;34m.\033[38;2;32;27;26m.\033[0m     \033[32m                                    .BBBi   :BBr         \033[m");
    $display("\033[0m      \033[38;2;57;37;30m.\033[38;2;145;126;119m=\033[38;2;243;239;238mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@\033[38;2;250;248;248mO\033[38;2;220;214;212m#\033[38;2;225;220;218m#\033[38;2;254;254;253m@\033[38;2;244;242;241mO\033[38;2;126;104;97m-\033[38;2;127;105;98m-\033[38;2;240;237;236mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;181;167;162m*\033[38;2;70;46;39m.\033[38;2;32;28;26m.\033[0m    \033[32m                                     BBBX   :BBBr        \033[m");
    $display("\033[0m     \033[38;2;56;36;30m.\033[38;2;139;118;111m=\033[38;2;249;248;247mO\033[38;2;255;255;255m@@@@@@@@@@\033[38;2;243;241;239mO\033[38;2;222;217;214m#\033[38;2;242;239;238mO\033[38;2;255;255;255m@@@@@@@@@\033[38;2;145;126;120m=\033[38;2;72;41;31m.\033[38;2;76;46;35m.\033[38;2;176;162;157m+\033[38;2;143;123;117m=\033[38;2;115;91;84m-\033[38;2;244;242;241mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@\033[38;2;237;234;233mO\033[38;2;179;166;162m*\033[38;2;174;160;156m+\033[38;2;230;225;224mO\033[38;2;255;255;255m@@@@\033[38;2;255;253;253m@\033[38;2;255;250;251mOO\033[38;2;255;253;253m@\033[38;2;255;255;255m@@@@\033[38;2;168;151;145m+\033[38;2;63;42;34m.\033[0m    \033[32m                                     .BBBv  :BBBQ        \033[m");
    $display("\033[0m    \033[38;2;42;31;27m.\033[38;2;103;77;69m:\033[38;2;237;233;232mO\033[38;2;255;255;255m@@@@@\033[38;2;255;252;252m@\033[38;2;255;250;251mO\033[38;2;255;251;252m@\033[38;2;255;254;254m@\033[38;2;255;255;255m@\033[38;2;228;225;223mO\033[38;2;102;77;68m:\033[38;2;73;42;32m.\033[38;2;105;80;71m-\033[38;2;235;231;229mO\033[38;2;255;255;255m@@@@@@\033[38;2;233;229;228mO\033[38;2;241;239;238mO\033[38;2;204;196;193m#\033[38;2;140;121;114m=\033[38;2;153;135;130m=\033[38;2;160;143;136m+\033[38;2;93;66;57m:\033[38;2;227;222;220m#\033[38;2;255;255;255m@@@@@@@@@@\033[38;2;239;236;236mO\033[38;2;174;160;155m+\033[38;2;156;139;133m+\033[38;2;214;206;204m#\033[38;2;255;255;255m@@@@@@@@\033[38;2;180;166;162m*\033[38;2;69;38;28m.\033[38;2;66;35;24m.\033[38;2;156;139;133m+\033[38;2;255;255;255m@\033[38;2;255;248;249mO\033[38;2;253;223;228mO\033[38;2;253;200;209m#\033[38;2;253;191;202m#\033[38;2;254;188;199m#\033[38;2;254;188;200m#\033[38;2;253;191;202m#\033[38;2;253;200;210m#\033[38;2;253;228;233mO\033[38;2;255;253;253m@\033[38;2;255;255;255m@\033[38;2;249;248;246mO\033[38;2;117;94;87m-\033[38;2;44;32;28m.\033[0m   \033[32m                                      .BBBBBBBBB:        \033[m");
    $display("\033[0m    \033[38;2;69;45;37m.\033[38;2;191;178;174m*\033[38;2;255;255;255m@@\033[38;2;255;254;254m@\033[38;2;254;237;240mO\033[38;2;253;212;219mO\033[38;2;254;199;208m#\033[38;2;253;189;201m#\033[38;2;253;186;198m#\033[38;2;253;188;200m#\033[38;2;253;193;204m#\033[38;2;253;208;217m#\033[38;2;243;226;228mO\033[38;2;170;156;151m+\033[38;2;142;123;116m=\033[38;2;177;164;160m+\033[38;2;247;245;245mO\033[38;2;248;247;246mO\033[38;2;167;152;148m+\033[38;2;189;178;174m*\033[38;2;245;243;242mO\033[38;2;255;254;254m@\033[38;2;187;175;171m*\033[38;2;110;86;78m-\033[38;2;220;214;213m#\033[38;2;255;255;255m@@@\033[38;2;121;98;90m-\033[38;2;156;139;133m+\033[38;2;255;255;255m@@@@\033[38;2;255;249;251mO\033[38;2;254;239;242mO\033[38;2;253;233;237mO\033[38;2;253;232;236mO\033[38;2;253;233;237mO\033[38;2;254;240;243mO\033[38;2;255;252;252m@\033[38;2;208;201;198m#\033[38;2;83;54;45m:\033[38;2;74;42;32m.\033[38;2;153;135;130m=\033[38;2;255;255;255m@\033[38;2;220;215;213m#\033[38;2;226;221;220m#\033[38;2;255;255;255m@@\033[38;2;253;252;252m@\033[38;2;171;157;152m+\033[38;2;181;169;165m*\033[38;2;249;248;248mO\033[38;2;212;204;202m#\033[38;2;205;197;194m#\033[38;2;242;240;239mO\033[38;2;255;255;255m@\033[38;2;252;205;214m#\033[38;2;254;171;186m#\033[38;2;255;174;188m#\033[38;2;255;175;189m#\033[38;2;255;176;189m#\033[38;2;255;175;189m##\033[38;2;255;172;187m#\033[38;2;252;178;191m#\033[38;2;254;238;241mO\033[38;2;255;255;255m@@\033[38;2;170;155;149m+\033[38;2;56;37;29m.\033[0m   \033[32m                                        rBBBBB1.         \033[m");
    $display("\033[0m   \033[38;2;38;30;27m.\033[38;2;96;72;63m:\033[38;2;236;232;230mO\033[38;2;255;255;255m@@\033[38;2;252;225;231mO\033[38;2;253;175;189m#\033[38;2;255;174;188m#\033[38;2;255;176;189m#\033[38;2;255;176;190m##\033[38;2;255;176;189m#\033[38;2;255;174;188m#\033[38;2;254;170;185m#\033[38;2;253;204;214m#\033[38;2;255;255;255m@@@@\033[38;2;254;254;254m@\033[38;2;221;215;212m#\033[38;2;157;141;136m+\033[38;2;141;122;116m=\033[38;2;142;123;117m=\033[38;2;134;114;108m=\033[38;2;221;216;213m#\033[38;2;255;255;255m@@@\033[38;2;226;221;218m#\033[38;2;96;69;60m:\033[38;2;213;205;202m#\033[38;2;255;255;255m@@\033[38;2;254;236;240mO\033[38;2;253;203;212m#\033[38;2;253;186;199m#\033[38;2;254;180;193m#\033[38;2;254;177;191m#\033[38;2;254;177;190m##\033[38;2;254;180;193m#\033[38;2;253;188;200m#\033[38;2;253;224;229mO\033[38;2;233;228;227mO\033[38;2;226;221;219m#\033[38;2;250;249;249mO\033[38;2;255;255;255m@\033[38;2;202;193;190m*\033[38;2;134;114;107m=\033[38;2;147;128;123m=\033[38;2;182;169;165m*\033[38;2;141;120;115m=\033[38;2;139;120;113m=\033[38;2;231;226;224mO\033[38;2;255;255;255m@@@@@\033[38;2;254;240;242mO\033[38;2;253;212;220mO\033[38;2;253;199;209m#\033[38;2;253;195;205m#\033[38;2;253;194;204m#\033[38;2;253;197;208m#\033[38;2;253;201;211m#\033[38;2;253;210;219m#\033[38;2;253;230;235mO\033[38;2;255;253;253m@\033[38;2;255;255;255m@@\033[38;2;205;195;191m#\033[38;2;68;45;36m.\033[0m   ");
    $display("\033[0m   \033[38;2;42;31;28m.\033[38;2;111;88;80m-\033[38;2;246;244;243mO\033[38;2;255;255;255m@@\033[38;2;254;243;245mO\033[38;2;253;205;213m#\033[38;2;254;191;202m#\033[38;2;254;185;198m#\033[38;2;253;186;198m#\033[38;2;253;188;200m#\033[38;2;253;193;203m#\033[38;2;253;203;212m#\033[38;2;253;222;229mO\033[38;2;255;248;249mO\033[38;2;255;255;255m@@@@@@@\033[38;2;247;245;245mO\033[38;2;234;231;230mO\033[38;2;254;254;254m@\033[38;2;255;255;255m@@@@\033[38;2;207;199;195m#\033[38;2;95;67;59m:\033[38;2;233;230;228mO\033[38;2;255;255;255m@\033[38;2;255;254;254m@\033[38;2;253;200;209m#\033[38;2;254;171;186m#\033[38;2;255;174;188m#\033[38;2;255;176;189m##\033[38;2;255;176;190m#\033[38;2;255;176;189m#\033[38;2;255;176;190m#\033[38;2;253;177;191m#\033[38;2;252;208;216m#\033[38;2;255;255;255m@@@@@\033[38;2;253;252;252m@\033[38;2;219;212;210m#\033[38;2;192;181;177m*\033[38;2;214;207;204m#\033[38;2;255;255;255m@@@@@@@@@@@\033[38;2;255;254;254m@\033[38;2;255;255;255m@@@@@@@\033[38;2;206;196;192m#\033[38;2;70;45;37m.\033[0m   ");
    $display("\033[0m   \033[38;2;43;31;28m.\033[38;2;111;87;79m-\033[38;2;246;243;242mO\033[38;2;255;255;255m@@@@\033[38;2;255;253;253m@\033[38;2;254;249;250mOO\033[38;2;254;251;252m@\033[38;2;255;253;254m@\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@\033[38;2;213;205;202m#\033[38;2;93;66;57m:\033[38;2;227;222;219m#\033[38;2;255;255;255m@@\033[38;2;254;246;247mO\033[38;2;253;223;229mO\033[38;2;253;210;218m#\033[38;2;253;205;214m#\033[38;2;253;208;216m#\033[38;2;253;213;220mO\033[38;2;254;218;225mO\033[38;2;254;227;232mO\033[38;2;254;241;243mO\033[38;2;255;254;254m@\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;166;150;144m+\033[38;2;57;37;30m.\033[0m   ");
    $display("\033[0m   \033[38;2;37;29;27m.\033[38;2;92;67;59m:\033[38;2;232;226;225mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;241;239;237mO\033[38;2;104;79;70m-\033[38;2;189;177;173m*\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;237;233;231mO\033[38;2;104;79;71m-\033[38;2;40;30;27m.\033[0m   ");
    $display("\033[0m    \033[38;2;61;39;32m.\033[38;2;166;149;143m+\033[38;2;255;255;255m@@@@@@@@@@\033[38;2;249;248;247mO\033[38;2;222;216;214m#\033[38;2;233;229;228mO\033[38;2;255;255;255m@@@@@@@@@@@@@@\033[38;2;188;176;171m*\033[38;2;107;82;74m-\033[38;2;234;230;229mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;241;238;237mO\033[38;2;187;175;171m*\033[38;2;166;151;147m+\033[38;2;203;194;191m#\033[38;2;255;255;255m@@@@@\033[38;2;235;231;229mO\033[38;2;122;100;92m-\033[38;2;49;34;28m.\033[0m    ");
    $display("\033[0m    \033[38;2;36;29;27m.\033[38;2;79;54;46m:\033[38;2;198;186;182m*\033[38;2;255;255;255m@@@@@@@@\033[38;2;206;196;193m#\033[38;2;124;102;94m-\033[38;2;145;126;120m=\033[38;2;122;99;91m-\033[38;2;158;142;136m+\033[38;2;252;251;251mO\033[38;2;255;255;255m@@@@@@@@@@@@@\033[38;2;147;129;123m=\033[38;2;121;98;91m-\033[38;2;239;235;234mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;248;246;245mO\033[38;2;120;97;89m-\033[38;2;166;151;145m+\033[38;2;203;193;190m*\033[38;2;111;87;79m-\033[38;2;174;160;155m+\033[38;2;255;255;255m@@\033[38;2;254;253;253m@\033[38;2;196;184;181m*\033[38;2;100;77;69m:\033[38;2;45;31;26m.\033[0m     ");
    $display("\033[0m     \033[38;2;36;28;26m.\033[38;2;75;52;44m:\033[38;2;169;153;147m+\033[38;2;247;244;243mO\033[38;2;255;255;255m@@@@@\033[38;2;252;250;250mO\033[38;2;108;84;75m-\033[38;2;166;150;144m+\033[38;2;255;255;255m@\033[38;2;213;205;202m#\033[38;2;88;60;51m:\033[38;2;142;122;116m=\033[38;2;177;164;160m+\033[38;2;241;239;238mO\033[38;2;255;255;255m@@@@@@@@@@@\033[38;2;250;249;249mO\033[38;2;160;144;138m+\033[38;2;116;92;84m-\033[38;2;192;180;176m*\033[38;2;250;249;248mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@@@@@\033[38;2;211;203;201m#\033[38;2;137;117;110m=\033[38;2;87;59;49m:\033[38;2;202;193;189m*\033[38;2;255;255;255m@\033[38;2;186;174;170m*\033[38;2;117;94;86m-\033[38;2;238;233;232mO\033[38;2;191;179;175m*\033[38;2;121;101;95m-\033[38;2;57;39;33m.\033[0m       ");
    $display("\033[0m       \033[38;2;48;33;28m.\033[38;2;103;82;74m-\033[38;2;183;170;165m*\033[38;2;238;234;232mO\033[38;2;255;255;255m@@@\033[38;2;240;237;236mO\033[38;2;96;69;61m:\033[38;2;197;186;183m*\033[38;2;255;255;255m@\033[38;2;248;247;247mO\033[38;2;227;222;220m#\033[38;2;219;212;210m#\033[38;2;138;117;111m=\033[38;2;117;94;86m-\033[38;2;244;242;241mO\033[38;2;255;255;255m@@@@@@@@@@@@\033[38;2;219;213;211m#\033[38;2;139;119;113m=\033[38;2;126;103;96m-\033[38;2;179;166;162m*\033[38;2;231;227;226mO\033[38;2;255;255;255m@@@@@@@@@@@@@@@@@@@\033[38;2;255;254;254m@\033[38;2;180;167;162m*\033[38;2;104;79;71m-\033[38;2;188;177;173m*\033[38;2;225;220;218m#\033[38;2;242;240;239mO\033[38;2;255;255;255m@\033[38;2;232;228;227mO\033[38;2;112;87;79m-\033[38;2;86;63;54m:\033[38;2;47;32;27m.\033[0m         ");
    $display("\033[0m         \033[38;2;39;27;24m.\033[38;2;74;56;52m:\033[38;2;120;103;101m-\033[38;2;173;162;162m+\033[38;2;220;214;213m#\033[38;2;159;142;136m+\033[38;2;127;106;98m-\033[38;2;249;247;247mO\033[38;2;255;255;255m@@@@\033[38;2;191;180;175m*\033[38;2;88;61;51m:\033[38;2;234;230;229mO\033[38;2;255;255;255m@@@@@@@@@@@@@@\033[38;2;222;216;214m#\033[38;2;163;146;141m+\033[38;2;130;109;102m=\033[38;2;143;124;118m=\033[38;2;180;167;163m*\033[38;2;212;204;201m#\033[38;2;230;225;223mO\033[38;2;244;241;240mO\033[38;2;254;253;252m@\033[38;2;255;255;255m@@@@@@@@@@@@@\033[38;2;253;252;252m@\033[38;2;117;94;86m-\033[38;2;170;155;150m+\033[38;2;255;255;255m@@@@@\033[38;2;194;183;178m*\033[38;2;66;43;35m.\033[0m          ");
    $display("\033[0m         \033[38;2;49;45;32m.\033[38;2;75;66;38m:\033[38;2;119;100;51m-\033[38;2;160;134;66m=\033[38;2;113;91;56m-\033[38;2;68;41;33m.\033[38;2;185;171;167m*\033[38;2;255;255;255m@@@@\033[38;2;252;251;251mO\033[38;2;156;138;133m+\033[38;2;101;75;66m:\033[38;2;245;243;242mO\033[38;2;255;255;255m@@@@@@@\033[38;2;252;252;251mO\033[38;2;246;245;244mO\033[38;2;255;255;255m@@@@@@\033[38;2;244;242;242mO\033[38;2;231;227;226mO\033[38;2;207;198;195m#\033[38;2;103;77;68m:\033[38;2;63;38;29m.\033[38;2;63;47;42m.\033[38;2;82;64;59m:\033[38;2;102;85;79m-\033[38;2;125;105;98m-\033[38;2;145;127;120m=\033[38;2;165;151;146m+\033[38;2;242;240;238mO\033[38;2;255;255;255m@@@@@@@@@@\033[38;2;191;179;175m*\033[38;2;112;88;80m-\033[38;2;220;214;211m#\033[38;2;255;255;255m@@@@\033[38;2;227;221;218m#\033[38;2;84;58;51m:\033[38;2;34;28;26m.\033[0m \033[38;2;55;49;33m.\033[38;2;159;138;73m=\033[38;2;147;128;68m=\033[38;2;59;53;35m.\033[0m    ");
    $display("\033[0m      \033[38;2;31;30;26m.\033[38;2;117;102;55m-\033[38;2;201;175;85m*\033[38;2;237;204;97m#\033[38;2;255;220;103m#\033[38;2;255;231;108mO\033[38;2;206;179;88m*\033[38;2;59;54;34m.\033[38;2;49;31;26m.\033[38;2;160;142;136m+\033[38;2;255;255;255m@@\033[38;2;251;249;249mO\033[38;2;175;162;158m+\033[38;2;139;120;113m=\033[38;2;129;107;101m=\033[38;2;208;200;197m#\033[38;2;255;255;255m@@@@@@@@\033[38;2;195;185;181m*\033[38;2;129;108;102m=\033[38;2;252;251;251mO\033[38;2;255;255;255m@@@@\033[38;2;254;254;254m@\033[38;2;129;108;101m=\033[38;2;166;151;146m+\033[38;2;255;255;255m@\033[38;2;229;224;222mO\033[38;2;118;97;91m-\033[38;2;52;36;30m.\033[0m  \033[38;2;54;31;25m.\033[38;2;158;140;133m+\033[38;2;238;236;235mO\033[38;2;253;252;252m@\033[38;2;255;255;255m@@@@\033[38;2;218;212;210m#\033[38;2;228;223;222mO\033[38;2;255;255;255m@@@@@\033[38;2;138;119;112m=\033[38;2;134;113;106m=\033[38;2;244;242;241mO\033[38;2;255;255;255m@@\033[38;2;243;240;239mO\033[38;2;156;138;132m+\033[38;2;74;45;36m.\033[38;2;38;28;26m.\033[0m \033[38;2;145;127;69m=\033[38;2;169;146;74m+\033[38;2;155;133;67m=\033[38;2;155;136;73m=\033[0m    ");
    $display("\033[0m      \033[38;2;68;61;38m:\033[38;2;251;216;105m#\033[38;2;255;233;107mO\033[38;2;255;229;105m#\033[38;2;244;211;101m#\033[38;2;148;128;67m=\033[38;2;39;37;28m.\033[0m  \033[38;2;61;42;37m.\033[38;2;157;138;133m+\033[38;2;234;229;227mO\033[38;2;255;255;255m@\033[38;2;251;250;249mO\033[38;2;247;246;245mO\033[38;2;255;255;255m@@@@@@@@@@\033[38;2;173;158;153m+\033[38;2;106;81;72m-\033[38;2;250;248;248mO\033[38;2;255;255;255m@@@@\033[38;2;228;223;221mO\033[38;2;91;64;55m:\033[38;2;211;203;200m#\033[38;2;255;255;255m@@\033[38;2;252;251;250mO\033[38;2;201;191;187m*\033[38;2;96;72;65m:\033[38;2;43;31;28m.\033[38;2;50;33;28m.\033[38;2;131;109;101m=\033[38;2;255;254;254m@\033[38;2;255;255;255m@@@@@\033[38;2;136;115;108m=\033[38;2;157;141;135m+\033[38;2;255;255;255m@@@@@\033[38;2;237;234;233mO\033[38;2;149;131;126m=\033[38;2;138;118;111m=\033[38;2;149;131;125m=\033[38;2;147;128;122m=\033[38;2;138;117;111m=\033[38;2;158;140;135m+\033[38;2;191;179;175m*\033[38;2;97;75;67m:\033[38;2;41;30;26m.\033[38;2;39;37;28m.\033[38;2;116;102;57m-\033[38;2;140;123;68m=\033[38;2;46;42;31m.\033[0m    ");
    $display("\033[0m      \033[38;2;31;31;27m.\033[38;2;99;87;50m-\033[38;2;149;130;68m=\033[38;2;133;117;62m=\033[38;2;69;61;39m:\033[0m  \033[38;2;54;49;33m.\033[38;2;160;141;73m=\033[38;2;117;101;56m-\033[38;2;38;26;22m.\033[38;2;78;58;52m:\033[38;2;137;120;114m=\033[38;2;175;162;157m+\033[38;2;201;191;188m*\033[38;2;214;205;202m#\033[38;2;212;202;199m#\033[38;2;220;213;211m#\033[38;2;251;250;249mO\033[38;2;255;255;255m@@@@@@\033[38;2;178;165;160m*\033[38;2;104;79;70m-\033[38;2;248;246;245mO\033[38;2;255;255;255m@@@@\033[38;2;182;169;165m*\033[38;2;107;83;75m-\033[38;2;248;246;245mO\033[38;2;255;255;255m@@@@\033[38;2;208;197;194m#\033[38;2;79;54;46m:\033[38;2;43;32;27m.\033[38;2;83;58;50m:\033[38;2;221;214;212m#\033[38;2;255;255;255m@@@@@\033[38;2;138;119;111m=\033[38;2;157;139;134m+\033[38;2;255;255;255m@@@@@@@\033[38;2;246;244;243mO\033[38;2;233;229;227mO\033[38;2;234;230;228mO\033[38;2;248;246;246mO\033[38;2;255;255;255m@@\033[38;2;231;225;223mO\033[38;2;105;80;72m-\033[38;2;38;29;27m.\033[0m       ");
    $display("\033[0m       \033[38;2;74;66;42m:\033[38;2;67;60;39m:\033[0m   \033[38;2;83;74;43m:\033[38;2;222;193;93m*\033[38;2;255;230;109m#\033[38;2;119;104;56m-\033[0m    \033[38;2;39;29;25m.\033[38;2;45;34;29m.\033[38;2;46;33;29m.\033[38;2;65;42;35m.\033[38;2;151;133;126m=\033[38;2;255;254;254m@\033[38;2;255;255;255m@@@@@\033[38;2;205;196;192m#\033[38;2;93;66;57m:\033[38;2;230;225;223mO\033[38;2;255;255;255m@@@\033[38;2;253;253;252m@\033[38;2;134;113;105m=\033[38;2;145;127;121m=\033[38;2;255;255;255m@@@@@\033[38;2;235;231;229mO\033[38;2;92;67;58m:\033[38;2;37;29;26m.\033[38;2;53;35;29m.\033[38;2;149;130;123m=\033[38;2;255;255;255m@@@@@\033[38;2;136;116;109m=\033[38;2;158;140;135m+\033[38;2;255;255;255m@@@@@@@@@@@@@@\033[38;2;163;145;139m+\033[38;2;55;35;27m.\033[0m       ");
    $display("\033[0m      \033[38;2;105;93;52m-\033[38;2;182;157;79m+\033[38;2;182;157;80m+\033[38;2;98;86;50m-\033[0m \033[38;2;59;53;34m.\033[38;2;231;199;97m#\033[38;2;255;231;106m#\033[38;2;225;194;95m*\033[38;2;49;45;30m.\033[0m       \033[38;2;32;27;26m.\033[38;2;67;44;36m.\033[38;2;172;156;151m+\033[38;2;255;255;255m@@@@@\033[38;2;253;250;250mO\033[38;2;146;127;121m=\033[38;2;211;202;199m#\033[38;2;255;255;255m@@@\033[38;2;240;236;234mO\033[38;2;118;94;86m-\033[38;2;222;215;212m#\033[38;2;255;255;255m@@@@@\033[38;2;172;157;151m+\033[38;2;64;42;34m.\033[0m \033[38;2;32;28;26m.\033[38;2;69;46;38m.\033[38;2;181;167;163m*\033[38;2;255;255;255m@@@@\033[38;2;128;106;99m-\033[38;2;167;150;145m+\033[38;2;255;255;255m@@@@@@@@@@@@@@\033[38;2;155;136;129m+\033[38;2;55;36;28m.\033[0m       ");
    $display("\033[0m      \033[38;2;74;66;41m:\033[38;2;151;131;69m=\033[38;2;156;135;71m=\033[38;2;62;56;36m.\033[0m \033[38;2;69;62;39m:\033[38;2;226;194;96m*\033[38;2;216;189;92m*\033[38;2;97;85;48m-\033[0m         \033[38;2;31;27;26m.\033[38;2;51;39;35m.\033[38;2;107;105;105m-\033[38;2;117;117;117m=\033[38;2;115;115;115m=\033[38;2;117;117;117m=\033[38;2;115;115;115m=\033[38;2;116;116;116m=\033[38;2;115;115;115m=\033[38;2;114;114;114m=\033[38;2;117;118;118m=\033[38;2;117;117;117m=\033[38;2;114;114;114m=\033[38;2;112;111;111m-\033[38;2;106;104;104m-\033[38;2;116;116;116m=\033[38;2;117;117;117m=\033[38;2;116;116;116m=\033[38;2;115;115;115m=\033[38;2;118;118;118m=\033[38;2;109;108;107m-\033[38;2;55;44;41m.\033[0m    \033[38;2;53;46;44m.\033[38;2;90;90;90m--\033[38;2;91;91;91m-\033[38;2;92;91;91m-\033[38;2;58;50;48m.\033[38;2;69;64;62m:\033[38;2;95;95;95m-\033[38;2;93;93;93m-\033[38;2;94;94;93m-\033[38;2;96;96;94m-\033[38;2;93;92;92m-\033[38;2;96;96;95m-\033[38;2;93;92;92m-\033[38;2;95;95;95m-\033[38;2;95;95;94m-\033[38;2;92;92;92m-\033[38;2;94;94;94m--\033[38;2;95;95;95m-\033[38;2;90;89;89m-\033[38;2;56;47;43m.\033[38;2;34;29;27m.\033[0m       ");
    $display("\033[0m       \033[38;2;29;28;26m.\033[38;2;31;30;27m.\033[0m   \033[38;2;47;43;32m.\033[38;2;39;37;29m.\033[0m                                                                  ");
end endtask

task YOU_FAIL_TASK; begin
    $display("\033[38;2;38;38;38m..........\033[38;2;37;37;37m.\033[38;2;36;37;37m.\033[38;2;49;50;51m.\033[38;2;56;57;58m:\033[38;2;40;40;41m.\033[38;2;36;36;35m.\033[38;2;38;38;38m.....\033[38;2;37;37;37m.\033[38;2;35;35;35m.\033[38;2;36;36;36m.\033[38;2;38;38;38m........................................................\033[0m");
    $display("\033[38;2;38;38;38m.........\033[38;2;37;37;37m.\033[38;2;40;40;40m.\033[38;2;101;100;100m-\033[38;2;150;144;143m+\033[38;2;145;136;132m=\033[38;2;135;132;130m=\033[38;2;59;60;59m:\033[38;2;36;36;36m.\033[38;2;36;37;37m.\033[38;2;38;38;38m..\033[38;2;36;36;36m.\033[38;2;45;45;45m.\033[38;2;63;64;64m:\033[38;2;54;54;54m.\033[38;2;37;38;37m.\033[38;2;38;37;37m.\033[38;2;38;38;38m.......................\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[38;2;37;37;37m.\033[38;2;36;36;36m..\033[38;2;38;38;38m.........................\033[0m");
    $display("\033[38;2;38;38;38m........\033[38;2;37;37;37m.\033[38;2;35;35;35m.\033[38;2;47;47;47m.\033[38;2;155;154;153m+\033[38;2;143;125;120m=\033[38;2;93;69;59m:\033[38;2;166;152;149m+\033[38;2;115;115;113m=\033[38;2;33;33;34m.\033[38;2;37;38;39m.\033[38;2;40;40;40m.\033[38;2;32;33;33m.\033[38;2;61;60;60m:\033[38;2;147;143;142m+\033[38;2;150;143;138m+\033[38;2;160;155;152m+\033[38;2;103;101;100m-\033[38;2;40;38;39m.\033[38;2;37;37;37m.\033[38;2;38;38;38m....................\033[38;2;37;37;37m.\033[38;2;35;35;35m.\033[38;2;37;37;38m.\033[38;2;36;36;37m.\033[38;2;33;33;33m.\033[38;2;40;40;40m.\033[38;2;56;57;58m:\033[38;2;53;54;54m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.......................\033[0m");
    $display("\033[38;2;38;38;38m......\033[38;2;37;37;37m.\033[38;2;34;35;35m.\033[38;2;37;38;37m.\033[38;2;37;38;38m.\033[38;2;39;40;41m.\033[38;2;138;137;136m=\033[38;2;145;129;125m=\033[38;2;90;65;56m:\033[38;2;145;129;125m=\033[38;2;135;134;132m=\033[38;2;88;88;88m-\033[38;2;136;132;130m=\033[38;2;138;134;132m=\033[38;2;96;95;95m-\033[38;2;102;102;101m-\033[38;2;166;157;153m+\033[38;2;94;71;64m:\033[38;2;138;122;116m=\033[38;2;157;154;153m+\033[38;2;49;49;50m.\033[38;2;35;36;36m.\033[38;2;38;38;38m...................\033[38;2;37;37;37m.\033[38;2;41;41;42m.\033[38;2;95;96;96m-\033[38;2;133;128;127m=\033[38;2;129;126;124m=\033[38;2;108;108;108m-\033[38;2;138;136;136m=\033[38;2;144;136;133m=\033[38;2;149;142;138m+\033[38;2;116;114;113m=\033[38;2;42;43;43m.\033[38;2;35;35;35m.\033[38;2;36;36;36m.\033[38;2;38;38;38m.....................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;37;37;37m.\033[38;2;39;39;39m.\033[38;2;80;80;80m:\033[38;2;135;132;129m=\033[38;2;137;134;132m=\033[38;2;102;102;100m-\033[38;2;130;130;128m=\033[38;2;150;137;134m+\033[38;2;91;66;59m:\033[38;2;131;112;106m=\033[38;2;152;150;148m+\033[38;2;159;158;158m+\033[38;2;136;119;113m=\033[38;2;111;89;84m-\033[38;2;166;158;155m+\033[38;2;133;135;133m=\033[38;2;160;153;149m+\033[38;2;98;75;68m:\033[38;2;123;107;99m-\033[38;2;161;159;157m+\033[38;2;59;57;60m:\033[38;2;35;35;35m.\033[38;2;38;38;38m..................\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;77;77;77m:\033[38;2;174;169;167m*\033[38;2;118;98;92m-\033[38;2;125;108;101m=\033[38;2;215;213;211m#\033[38;2;197;191;189m*\033[38;2;100;79;70m-\033[38;2;113;95;86m-\033[38;2;172;165;164m+\033[38;2;72;71;71m:\033[38;2;49;49;49m.\033[38;2;51;51;51m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m...................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;35;35;35m.\033[38;2;54;53;53m.\033[38;2;164;163;161m+\033[38;2;142;128;121m=\033[38;2;109;89;82m-\033[38;2;163;154;150m+\033[38;2;149;148;147m+\033[38;2;151;142;137m+\033[38;2;93;70;61m:\033[38;2;121;103;94m-\033[38;2;158;154;153m+\033[38;2;153;153;152m+\033[38;2;133;119;112m=\033[38;2;90;68;57m:\033[38;2;152;140;135m+\033[38;2;156;155;157m+\033[38;2;162;156;154m+\033[38;2;99;76;69m:\033[38;2;112;93;85m-\033[38;2;169;165;164m+\033[38;2;69;68;70m:\033[38;2;35;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;82;83;83m:\033[38;2;166;159;155m+\033[38;2;102;80;69m-\033[38;2;107;86;78m-\033[38;2;211;205;203m#\033[38;2;204;199;197m#\033[38;2;106;84;76m-\033[38;2;102;80;71m-\033[38;2;167;161;157m+\033[38;2;155;153;153m+\033[38;2;156;147;146m+\033[38;2;153;146;142m+\033[38;2;119;117;116m=\033[38;2;46;46;47m.\033[38;2;36;36;36m.\033[38;2;38;38;38m..................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;36;36;36m.\033[38;2;51;50;50m.\033[38;2;151;149;148m+\033[38;2;130;115;108m=\033[38;2;91;68;59m:\033[38;2;155;145;140m+\033[38;2;170;169;168m*\033[38;2;160;151;147m+\033[38;2;96;73;63m:\033[38;2;118;99;90m-\033[38;2;166;162;160m+\033[38;2;143;143;142m+\033[38;2;144;131;125m=\033[38;2;91;69;58m:\033[38;2;143;130;125m=\033[38;2;149;148;149m+\033[38;2;156;153;151m+\033[38;2;131;114;108m=\033[38;2;136;121;114m=\033[38;2;169;166;164m+\033[38;2;63;63;64m:\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.....\033[38;2;37;38;38m..\033[38;2;37;37;38m.\033[38;2;37;37;37m.....\033[38;2;37;38;37m.\033[38;2;38;38;38m.\033[38;2;38;37;38m.\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;79;80;80m:\033[38;2;165;158;154m+\033[38;2;101;79;68m-\033[38;2;106;84;76m-\033[38;2;194;188;187m*\033[38;2;197;192;190m*\033[38;2;117;95;89m-\033[38;2;94;69;60m:\033[38;2;172;163;159m+\033[38;2;217;213;212m#\033[38;2;123;105;98m-\033[38;2;103;81;73m-\033[38;2;169;162;158m+\033[38;2;85;86;86m-\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;36;36;36m.\033[38;2;47;47;47m.\033[38;2;146;144;145m+\033[38;2;141;126;121m=\033[38;2;90;68;56m:\033[38;2;148;135;130m=\033[38;2;170;168;169m*\033[38;2;161;152;150m+\033[38;2;99;76;68m:\033[38;2;115;94;86m-\033[38;2;163;158;156m+\033[38;2;136;136;135m=\033[38;2;147;134;129m=\033[38;2;91;69;57m:\033[38;2;142;128;121m=\033[38;2;135;132;132m=\033[38;2;74;73;71m:\033[38;2;109;107;106m-\033[38;2;110;110;109m-\033[38;2;75;75;75m:\033[38;2;39;39;39m.\033[38;2;37;37;37m.\033[38;2;38;38;38m....\033[38;2;37;37;37m.\033[38;2;36;37;37m..\033[38;2;38;37;38m.\033[38;2;38;38;38m.\033[38;2;39;40;39m.\033[38;2;42;41;40m.\033[38;2;44;42;41m.\033[38;2;45;43;41m..\033[38;2;44;42;40m.\033[38;2;43;41;39m.\033[38;2;41;40;39m.\033[38;2;38;37;38m.\033[38;2;37;37;38m.\033[38;2;35;35;36m.\033[38;2;57;57;57m:\033[38;2;153;150;148m+\033[38;2;143;129;123m=\033[38;2;135;122;116m=\033[38;2;177;173;172m*\033[38;2;179;177;175m*\033[38;2;122;104;98m-\033[38;2;91;67;58m:\033[38;2;166;155;148m+\033[38;2;216;213;213m#\033[38;2;122;107;97m-\033[38;2;93;71;61m:\033[38;2;164;154;150m+\033[38;2;98;98;97m-\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;36;36;36m.\033[38;2;41;41;41m.\033[38;2;134;133;134m=\033[38;2;149;135;131m=\033[38;2;87;64;53m:\033[38;2;138;123;118m=\033[38;2;164;162;163m+\033[38;2;157;148;146m+\033[38;2;99;78;69m:\033[38;2;111;89;81m-\033[38;2;160;155;152m+\033[38;2;137;137;137m=\033[38;2;154;141;136m+\033[38;2;89;65;55m:\033[38;2;142;128;120m=\033[38;2;140;139;137m=\033[38;2;41;40;40m.\033[38;2;32;33;31m.\033[38;2;32;33;32m.\033[38;2;35;35;35m.\033[38;2;38;38;38m.\033[38;2;39;38;38m.\033[38;2;39;37;38m.\033[38;2;37;37;38m.\033[38;2;35;36;37m.\033[38;2;38;39;38m.\033[38;2;44;41;40m.\033[38;2;53;47;45m.\033[38;2;61;52;48m.\033[38;2;69;56;51m:\033[38;2;76;59;53m:\033[38;2;81;62;53m:\033[38;2;82;64;56m:\033[38;2;86;67;59m:\033[38;2;87;67;59m:\033[38;2;88;67;59m:\033[38;2;86;65;58m:\033[38;2;83;64;57m:\033[38;2;78;61;54m:\033[38;2;75;60;53m:\033[38;2;69;57;53m:\033[38;2;61;51;49m.\033[38;2;51;44;42m.\033[38;2;64;61;61m:\033[38;2;96;95;94m-\033[38;2;93;92;93m-\033[38;2;81;80;80m:\033[38;2;163;160;159m+\033[38;2;128;112;105m=\033[38;2;90;67;58m:\033[38;2;163;151;146m+\033[38;2;215;211;210m#\033[38;2;123;106;97m-\033[38;2;95;72;63m:\033[38;2;164;155;151m+\033[38;2;98;98;97m-\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;37;37;37m..\033[38;2;112;112;112m=\033[38;2;171;162;159m+\033[38;2;116;97;89m-\033[38;2;156;144;141m+\033[38;2;155;154;155m+\033[38;2;162;154;151m+\033[38;2;103;82;73m-\033[38;2;109;87;78m-\033[38;2;162;156;153m+\033[38;2;105;105;105m-\033[38;2;151;147;144m+\033[38;2;143;132;127m=\033[38;2;161;154;152m+\033[38;2;107;107;108m-\033[38;2;39;39;39m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[38;2;37;38;38m.\033[38;2;35;37;37m.\033[38;2;38;39;38m.\033[38;2;49;44;42m.\033[38;2;62;53;50m.\033[38;2;75;61;55m:\033[38;2;84;66;58m:\033[38;2;93;71;63m:\033[38;2;104;82;75m-\033[38;2;119;99;92m-\033[38;2;136;118;111m=\033[38;2;152;139;132m+\033[38;2;164;152;146m+\033[38;2;173;163;159m+\033[38;2;177;167;164m**\033[38;2;172;162;159m+\033[38;2;162;151;146m+\033[38;2;150;136;130m=\033[38;2;133;117;110m=\033[38;2;117;97;89m-\033[38;2;101;80;71m-\033[38;2;91;69;60m:\033[38;2;81;62;54m:\033[38;2;67;54;49m:\033[38;2;48;42;38m.\033[38;2;56;54;54m.\033[38;2;168;163;163m+\033[38;2;131;114;108m=\033[38;2;86;62;54m:\033[38;2;164;151;148m+\033[38;2;214;209;207m#\033[38;2;119;99;92m-\033[38;2;97;73;65m:\033[38;2;164;155;151m+\033[38;2;95;95;95m-\033[38;2;36;36;37m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[0m");
    $display("\033[38;2;38;38;38m......\033[38;2;37;37;37m.\033[38;2;48;48;48m.\033[38;2;97;97;96m-\033[38;2;125;124;123m=\033[38;2;106;106;106m-\033[38;2;87;88;89m-\033[38;2;170;166;162m+\033[38;2;115;95;88m-\033[38;2;114;94;87m-\033[38;2;171;165;164m+\033[38;2;67;68;69m:\033[38;2;49;49;49m.\033[38;2;73;73;72m:\033[38;2;62;62;62m:\033[38;2;40;40;41m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;38;38;39m.\033[38;2;37;37;38m.\033[38;2;42;39;39m.\033[38;2;57;50;46m.\033[38;2;77;61;56m:\033[38;2;88;66;58m:\033[38;2;98;75;67m:\033[38;2;118;98;92m-\033[38;2;149;136;129m=\033[38;2;184;175;171m*\033[38;2;210;203;204m#\033[38;2;225;223;222m#\033[38;2;233;234;233mO\033[38;2;238;238;239mO\033[38;2;240;240;240mO\033[38;2;239;240;240mOO\033[38;2;239;241;241mOO\033[38;2;239;240;240mO\033[38;2;238;238;238mO\033[38;2;233;233;233mO\033[38;2;224;221;220m#\033[38;2;205;200;196m#\033[38;2;173;164;159m+\033[38;2;138;122;115m=\033[38;2;108;86;79m-\033[38;2;91;69;59m:\033[38;2;83;66;59m:\033[38;2;142;131;126m=\033[38;2;160;149;144m+\033[38;2;122;105;99m-\033[38;2;182;173;171m*\033[38;2;206;201;198m#\033[38;2;114;94;87m-\033[38;2;98;74;66m:\033[38;2;164;155;152m+\033[38;2;93;94;93m-\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m................\033[0m");
    $display("\033[38;2;38;38;38m.......\033[38;2;37;37;37m.\033[38;2;33;34;34m.\033[38;2;33;33;34m.\033[38;2;32;32;32m.\033[38;2;44;44;45m.\033[38;2;114;114;113m=\033[38;2;146;141;138m+\033[38;2;146;139;136m+\033[38;2;114;113;114m=\033[38;2;44;46;46m.\033[38;2;34;34;34m.\033[38;2;35;35;35m..\033[38;2;38;37;38m.\033[38;2;37;38;38m.\033[38;2;37;37;37m.\033[38;2;41;40;39m.\033[38;2;59;51;48m.\033[38;2;83;66;59m:\033[38;2;91;70;61m:\033[38;2;107;85;77m-\033[38;2;144;129;124m=\033[38;2;190;184;180m*\033[38;2;223;220;218m#\033[38;2;237;237;237mO\033[38;2;240;240;241mO\033[38;2;238;239;239mO\033[38;2;236;236;237mO\033[38;2;236;236;236mO\033[38;2;235;235;235mOO\033[38;2;235;236;236mOO\033[38;2;235;233;233mO\033[38;2;234;230;231mO\033[38;2;235;231;231mO\033[38;2;235;234;234mO\033[38;2;236;237;236mO\033[38;2;237;237;238mO\033[38;2;239;239;240mO\033[38;2;239;240;241mO\033[38;2;234;233;234mO\033[38;2;210;205;203m#\033[38;2;162;150;145m+\033[38;2;110;89;81m-\033[38;2;93;71;61m:\033[38;2;118;102;94m-\033[38;2;122;115;110m=\033[38;2;110;109;109m-\033[38;2;173;169;168m*\033[38;2;117;98;90m-\033[38;2;95;70;62m:\033[38;2;164;154;151m+\033[38;2;94;95;94m-\033[38;2;36;36;36m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[38;2;37;38;37m.\033[38;2;35;35;35m.\033[38;2;34;34;34m..\033[38;2;37;37;37m.\033[38;2;38;38;38m.........\033[0m");
    $display("\033[38;2;38;38;38m...........\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;47;47;47m..\033[38;2;36;36;36m.\033[38;2;37;37;37m.\033[38;2;37;38;37m.\033[38;2;38;38;38m..\033[38;2;38;37;39m.\033[38;2;37;37;36m.\033[38;2;50;45;41m.\033[38;2;78;62;57m:\033[38;2;93;70;62m:\033[38;2;104;82;74m-\033[38;2;150;135;131m=\033[38;2;209;202;199m#\033[38;2;236;235;234mO\033[38;2;239;240;241mO\033[38;2;237;237;237mO\033[38;2;235;235;235mOOOOOO\033[38;2;234;237;236mO\033[38;2;234;226;228mO\033[38;2;229;201;207m#\033[38;2;228;183;193m#\033[38;2;227;179;188m*\033[38;2;227;180;188m*\033[38;2;228;185;194m#\033[38;2;230;203;208m#\033[38;2;234;226;227mO\033[38;2;236;235;236mO\033[38;2;234;235;236mO\033[38;2;235;235;235mO\033[38;2;238;238;239mO\033[38;2;237;238;238mO\033[38;2;211;207;204m#\033[38;2;141;128;122m=\033[38;2;94;71;62m:\033[38;2;85;65;58m:\033[38;2;66;56;52m:\033[38;2;137;135;134m=\033[38;2;154;143;137m+\033[38;2;123;103;97m-\033[38;2;171;162;161m+\033[38;2;86;86;86m-\033[38;2;36;36;36m.\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;39;38;38m.\033[38;2;61;60;61m:\033[38;2;81;81;82m:\033[38;2;70;70;70m:\033[38;2;41;41;41m.\033[38;2;33;33;33m..\033[38;2;37;37;37m.\033[38;2;38;38;38m......\033[0m");
    $display("\033[38;2;38;38;38m...........\033[38;2;37;38;38m.\033[38;2;37;38;37m.\033[38;2;35;36;36m.\033[38;2;35;35;36m.\033[38;2;37;37;37m....\033[38;2;36;36;36m.\033[38;2;39;38;39m.\033[38;2;62;53;50m.\033[38;2;88;68;60m:\033[38;2;97;73;66m:\033[38;2;134;116;109m=\033[38;2;199;193;189m*\033[38;2;234;235;234mO\033[38;2;238;239;239mO\033[38;2;235;236;236mO\033[38;2;234;234;235mO\033[38;2;235;235;235mOOOO\033[38;2;234;234;234mO\033[38;2;235;235;236mO\033[38;2;234;235;236mO\033[38;2;231;218;220m#\033[38;2;228;182;192m#\033[38;2;225;168;180m*\033[38;2;225;167;178m*\033[38;2;226;168;179m*\033[38;2;225;168;178m*\033[38;2;225;167;178m*\033[38;2;225;168;179m*\033[38;2;227;185;194m#\033[38;2;235;224;226mO\033[38;2;234;236;236mO\033[38;2;235;235;235mO\033[38;2;234;234;234mO\033[38;2;236;235;235mO\033[38;2;239;239;240mO\033[38;2;227;229;225mO\033[38;2;158;146;141m+\033[38;2;98;74;67m:\033[38;2;93;70;61m:\033[38;2;79;70;66m:\033[38;2;101;102;100m-\033[38;2;113;112;109m-\033[38;2;88;87;87m-\033[38;2;44;44;44m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;39;39;39m.\033[38;2;37;37;37m..\033[38;2;89;88;88m-\033[38;2;163;155;153m+\033[38;2;137;123;118m=\033[38;2;164;154;151m+\033[38;2;135;135;134m=\033[38;2;81;82;80m:\033[38;2;75;76;76m:\033[38;2;47;48;47m.\033[38;2;37;37;36m.\033[38;2;38;37;37m.\033[38;2;38;38;38m....\033[0m");
    $display("\033[38;2;38;38;38m......\033[38;2;37;37;38m.\033[38;2;36;37;37m..\033[38;2;37;37;37m.\033[38;2;39;39;39m.\033[38;2;42;40;39m.\033[38;2;44;41;40m.\033[38;2;45;43;41m.\033[38;2;46;43;42m.\033[38;2;47;43;42m.\033[38;2;47;44;42m.\033[38;2;49;44;42m..\033[38;2;49;45;43m.\033[38;2;69;56;53m:\033[38;2;90;69;61m:\033[38;2;104;85;76m-\033[38;2;168;157;154m+\033[38;2;229;224;224mO\033[38;2;239;239;239mO\033[38;2;235;236;236mO\033[38;2;235;234;235mO\033[38;2;235;235;235mOOOOOOO\033[38;2;235;236;236mO\033[38;2;232;222;224mO\033[38;2;226;180;189m*\033[38;2;225;167;177m*\033[38;2;226;170;181m****\033[38;2;226;171;181m*\033[38;2;225;169;180m**\033[38;2;229;205;210m#\033[38;2;235;235;235mOOOO\033[38;2;234;235;235mO\033[38;2;236;238;237mO\033[38;2;230;228;228mO\033[38;2;163;152;147m+\033[38;2;100;76;68m:\033[38;2;92;71;62m:\033[38;2;55;48;45m.\033[38;2;34;33;32m.\033[38;2;33;34;34m.\033[38;2;36;37;37m.\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;121;120;120m=\033[38;2;155;142;137m+\033[38;2;87;63;55m:\033[38;2;139;122;116m=\033[38;2;205;198;194m#\033[38;2;141;127;121m=\033[38;2;154;144;142m+\033[38;2;144;141;140m+\033[38;2;52;51;51m.\033[38;2;35;36;36m.\033[38;2;38;38;38m....\033[0m");
    $display("\033[38;2;38;38;38m...\033[38;2;38;37;38m.\033[38;2;37;37;37m.\033[38;2;39;39;39m.\033[38;2;47;44;42m.\033[38;2;57;49;46m.\033[38;2;64;53;48m.\033[38;2;70;57;51m:\033[38;2;76;60;54m:\033[38;2;82;64;56m:\033[38;2;87;67;60m:\033[38;2;90;69;62m:\033[38;2;91;70;63m:\033[38;2;92;70;63m:\033[38;2;93;71;64m:\033[38;2;93;72;64m:\033[38;2;93;73;65m:\033[38;2;95;75;67m:\033[38;2;101;79;72m-\033[38;2;127;110;104m=\033[38;2;194;188;185m*\033[38;2;236;236;236mO\033[38;2;237;237;238mO\033[38;2;235;235;235mO\033[38;2;234;234;234mO\033[38;2;235;235;235mOOOOOOO\033[38;2;236;236;236mO\033[38;2;233;234;234mO\033[38;2;230;201;207m#\033[38;2;226;169;179m*\033[38;2;224;169;180m*\033[38;2;226;170;181m****\033[38;2;226;171;181m*\033[38;2;226;170;180m*\033[38;2;226;169;179m*\033[38;2;229;200;206m#\033[38;2;235;233;233mO\033[38;2;235;235;235mOOO\033[38;2;234;234;234mO\033[38;2;235;235;235mO\033[38;2;237;238;238mO\033[38;2;229;228;226mO\033[38;2;148;133;129m=\033[38;2;95;71;62m:\033[38;2;86;69;60m:\033[38;2;49;45;42m.\033[38;2;36;38;38m.\033[38;2;37;38;37m.\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;121;120;120m=\033[38;2;151;139;133m+\033[38;2;88;66;56m:\033[38;2;139;121;117m=\033[38;2;186;178;175m*\033[38;2;97;75;66m:\033[38;2;115;95;88m-\033[38;2;179;173;170m*\033[38;2;72;71;72m:\033[38;2;35;36;35m.\033[38;2;38;37;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;37;38;38m.\033[38;2;41;39;40m.\033[38;2;60;51;49m.\033[38;2;79;63;56m:\033[38;2;89;68;61m:\033[38;2;103;82;73m-\033[38;2;124;105;98m-\033[38;2;145;130;124m=\033[38;2;162;151;145m+\033[38;2;174;164;161m+\033[38;2;186;177;175m*\033[38;2;191;184;180m*\033[38;2;193;186;183m*\033[38;2;194;187;184m*\033[38;2;195;188;185m*\033[38;2;196;190;187m*\033[38;2;198;192;190m*\033[38;2;200;194;192m*\033[38;2;209;205;203m#\033[38;2;229;227;226mO\033[38;2;238;238;239mO\033[38;2;235;236;236mO\033[38;2;235;235;235mOOOOOOOOOO\033[38;2;236;236;236mO\033[38;2;233;231;231mO\033[38;2;229;191;200m#\033[38;2;226;167;178m*\033[38;2;225;169;179m*\033[38;2;226;170;181m****\033[38;2;226;171;182m*\033[38;2;226;169;180m*\033[38;2;226;169;179m*\033[38;2;230;203;208m#\033[38;2;235;234;234mO\033[38;2;235;235;235mOOOOOO\033[38;2;237;239;238mO\033[38;2;206;202;198m#\033[38;2;114;95;88m-\033[38;2;95;71;62m:\033[38;2;69;59;54m:\033[38;2;39;39;37m.\033[38;2;37;38;37m.\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;37;38;38m.\033[38;2;111;109;110m-\033[38;2;165;154;150m+\033[38;2;100;79;70m-\033[38;2;151;137;133m+\033[38;2;195;188;184m*\033[38;2;105;84;75m-\033[38;2;111;91;83m-\033[38;2;171;165;162m+\033[38;2;73;72;73m:\033[38;2;35;36;35m.\033[38;2;38;37;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;42;40;40m.\033[38;2;71;60;56m:\033[38;2;94;73;64m:\033[38;2;114;94;86m-\033[38;2;168;155;149m+\033[38;2;207;201;199m#\033[38;2;229;226;226mO\033[38;2;237;236;236mO\033[38;2;238;239;238mO\033[38;2;239;240;240mOOOOOOOOO\033[38;2;238;239;239mO\033[38;2;236;237;237mO\033[38;2;235;235;235mOOOOOOOOOOOO\033[38;2;236;236;236mO\033[38;2;233;232;232mO\033[38;2;229;193;201m#\033[38;2;226;167;180m*\033[38;2;224;169;178m*\033[38;2;226;170;181m*****\033[38;2;226;169;180m*\033[38;2;226;175;185m*\033[38;2;233;217;220m#\033[38;2;236;236;236mO\033[38;2;235;235;235mO\033[38;2;234;235;234mO\033[38;2;235;235;235mOOOO\033[38;2;236;237;237mO\033[38;2;233;230;231mO\033[38;2;156;142;137m+\033[38;2;96;72;63m:\033[38;2;84;68;62m:\033[38;2;47;44;41m.\033[38;2;38;38;38m.....\033[38;2;37;37;37m.\033[38;2;52;52;52m.\033[38;2;118;117;116m=\033[38;2;141;137;134m=\033[38;2;164;160;158m+\033[38;2;184;177;173m*\033[38;2;102;81;73m-\033[38;2;107;87;79m-\033[38;2;170;164;161m+\033[38;2;74;73;73m:\033[38;2;35;36;35m.\033[38;2;38;37;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[0m");
    $display("\033[38;2;37;37;37m..\033[38;2;53;47;45m.\033[38;2;90;71;63m:\033[38;2;100;76;67m:\033[38;2;178;168;165m*\033[38;2;242;244;244mO\033[38;2;240;242;242mO\033[38;2;237;238;237mO\033[38;2;235;235;235mOOOOOOOOOOOOOOOOOOOOOOOOO\033[38;2;236;236;236mO\033[38;2;236;237;236mO\033[38;2;235;215;219m#\033[38;2;228;174;186m*\033[38;2;224;167;178m*\033[38;2;226;170;180m*\033[38;2;226;170;181m*\033[38;2;227;170;181m*\033[38;2;226;170;181m*\033[38;2;224;167;178m*\033[38;2;225;170;181m*\033[38;2;230;201;208m#\033[38;2;236;232;232mO\033[38;2;235;236;236mO\033[38;2;235;235;235mOOOOOO\033[38;2;236;236;237mO\033[38;2;236;236;238mO\033[38;2;189;181;179m*\033[38;2;103;80;72m-\033[38;2;89;70;62m:\033[38;2;56;50;47m.\033[38;2;36;37;37m.\033[38;2;35;36;36m.\033[38;2;36;37;36m.\033[38;2;37;37;37m.\033[38;2;38;37;37m.\033[38;2;39;38;38m.\033[38;2;38;36;38m.\033[38;2;36;36;37m.\033[38;2;38;40;40m.\033[38;2;61;63;63m:\033[38;2;159;155;153m+\033[38;2;127;109;103m=\033[38;2;128;112;105m=\033[38;2;174;169;166m*\033[38;2;68;67;67m:\033[38;2;34;35;35m.\033[38;2;38;38;38m....\033[0m");
    $display("\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;47;43;41m.\033[38;2;82;66;60m:\033[38;2;97;75;67m:\033[38;2;134;118;110m=\033[38;2;199;193;191m*\033[38;2;229;227;226mO\033[38;2;238;237;237mO\033[38;2;239;239;239mO\033[38;2;240;240;240mO\033[38;2;239;240;240mOOOO\033[38;2;240;240;240mOO\033[38;2;239;240;240mO\033[38;2;240;240;240mO\033[38;2;238;239;239mO\033[38;2;236;236;236mO\033[38;2;235;235;235mOOOOOOOOOOOO\033[38;2;236;237;237mO\033[38;2;234;234;234mO\033[38;2;224;223;222m#\033[38;2;221;218;217m#\033[38;2;229;210;213m#\033[38;2;230;187;195m#\033[38;2;226;171;182m*\033[38;2;225;169;180m*\033[38;2;225;168;180m*\033[38;2;224;171;181m*\033[38;2;228;181;191m#\033[38;2;231;208;213m#\033[38;2;235;233;234mO\033[38;2;236;235;236mO\033[38;2;235;234;234mO\033[38;2;235;235;235mOOOOOO\033[38;2;235;235;236mO\033[38;2;236;237;238mO\033[38;2;214;208;207m#\033[38;2;119;100;93m-\033[38;2;87;64;55m:\033[38;2;79;61;55m:\033[38;2;65;53;49m:\033[38;2;62;51;45m.\033[38;2;62;51;46m.\033[38;2;67;54;48m:\033[38;2;72;56;51m:\033[38;2;75;58;52m:\033[38;2;77;59;54m:\033[38;2;75;58;52m:\033[38;2;71;55;49m:\033[38;2;68;55;49m:\033[38;2;98;89;85m-\033[38;2;131;124;122m=\033[38;2;127;124;123m=\033[38;2;88;88;88m-\033[38;2;40;41;41m.\033[38;2;36;37;37m.\033[38;2;38;38;38m....\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;37;38;37m.\033[38;2;47;44;43m.\033[38;2;76;63;55m:\033[38;2;93;71;64m:\033[38;2;97;76;70m:\033[38;2;117;98;91m-\033[38;2;138;123;118m=\033[38;2;158;146;140m+\033[38;2;170;160;154m+\033[38;2;176;167;163m*\033[38;2;180;170;168m*\033[38;2;182;173;170m*\033[38;2;183;175;172m*\033[38;2;185;178;174m*\033[38;2;186;179;176m*\033[38;2;188;180;176m*\033[38;2;188;181;178m*\033[38;2;199;194;191m*\033[38;2;226;224;223mO\033[38;2;235;236;236mO\033[38;2;235;235;235mOOOOOOOOOO\033[38;2;237;237;237mO\033[38;2;218;215;214m#\033[38;2;148;136;132m=\033[38;2;113;93;84m-\033[38;2;110;90;84m-\033[38;2;135;120;115m=\033[38;2;201;191;189m*\033[38;2;232;221;223mO\033[38;2;231;214;218m#\033[38;2;232;213;217m#\033[38;2;233;220;223mO\033[38;2;235;230;232mO\033[38;2;235;236;236mO\033[38;2;235;235;235mOOOOOOOOO\033[38;2;234;234;234mO\033[38;2;236;236;236mO\033[38;2;234;234;234mO\033[38;2;207;203;201m#\033[38;2;164;154;150m+\033[38;2;142;127;120m=\033[38;2;127;110;103m=\033[38;2;121;104;96m-\033[38;2;128;110;103m=\033[38;2;139;122;116m=\033[38;2;147;132;126m=\033[38;2;156;142;136m+\033[38;2;161;147;141m+\033[38;2;154;139;133m+\033[38;2;141;126;120m=\033[38;2;125;105;98m-\033[38;2;99;78;70m:\033[38;2;85;65;57m:\033[38;2;78;62;54m:\033[38;2;58;50;46m.\033[38;2;41;40;41m.\033[38;2;37;37;38m.\033[38;2;38;38;38m....\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;36;38;37m.\033[38;2;50;45;43m.\033[38;2;82;65;58m:\033[38;2;98;74;67m:\033[38;2;122;104;99m-\033[38;2;146;132;127m=\033[38;2;131;116;108m=\033[38;2;119;100;93m-\033[38;2;112;92;86m-\033[38;2;108;87;79m-\033[38;2;107;85;77m-\033[38;2;105;84;75m-\033[38;2;104;83;74m-\033[38;2;104;82;73m-\033[38;2;104;83;74m-\033[38;2;106;82;75m-\033[38;2;105;84;77m-\033[38;2;121;105;97m-\033[38;2;202;197;194m#\033[38;2;236;237;237mO\033[38;2;235;235;235mOOOOOOOOO\033[38;2;236;236;236mO\033[38;2;237;237;237mO\033[38;2;200;193;191m*\033[38;2;101;81;73m-\033[38;2;87;63;53m:\033[38;2;90;66;57m:\033[38;2;86;64;55m:\033[38;2;161;148;142m+\033[38;2;234;236;235mO\033[38;2;235;239;238mO\033[38;2;235;237;236mO\033[38;2;236;236;236mO\033[38;2;235;235;235mOOOOOOOOOOOOOO\033[38;2;237;239;239mO\033[38;2;239;240;240mO\033[38;2;237;236;236mO\033[38;2;230;229;229mO\033[38;2;227;226;227mO\033[38;2;231;230;230mO\033[38;2;236;235;235mO\033[38;2;237;237;237mO\033[38;2;238;239;239mOO\033[38;2;238;239;238mO\033[38;2;236;236;236mO\033[38;2;228;227;227mO\033[38;2;205;200;198m#\033[38;2;158;144;138m+\033[38;2;107;87;78m-\033[38;2;95;72;63m:\033[38;2;79;63;58m:\033[38;2;47;42;43m.\033[38;2;37;37;38m.\033[38;2;37;38;37m.\033[38;2;39;38;38m.\033[38;2;38;38;38m.\033[0m");
    $display("\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;41;40;39m.\033[38;2;75;62;58m:\033[38;2;95;71;63m:\033[38;2;131;113;106m=\033[38;2;220;215;214m#\033[38;2;240;241;241mO\033[38;2;235;235;235mO\033[38;2;229;228;228mO\033[38;2;226;223;224mO\033[38;2;222;219;219m#\033[38;2;220;217;216m#\033[38;2;218;215;214m#\033[38;2;216;214;211m#\033[38;2;215;213;210m#\033[38;2;216;213;210m#\033[38;2;217;214;211m#\033[38;2;219;216;214m#\033[38;2;226;224;223mO\033[38;2;234;233;233mO\033[38;2;235;235;235mOOOOOOOOOO\033[38;2;234;234;234mO\033[38;2;235;236;236mO\033[38;2;232;230;229mO\033[38;2;192;185;182m*\033[38;2;150;138;133m+\033[38;2;144;130;124m=\033[38;2;170;162;159m+\033[38;2;221;217;217m#\033[38;2;236;236;236mOO\033[38;2;235;235;235mOOOOOOOOOOOOOOOOOOO\033[38;2;236;236;236mO\033[38;2;237;237;237mO\033[38;2;236;236;236mO\033[38;2;235;235;235mOOOOOO\033[38;2;236;237;237mO\033[38;2;240;240;240mO\033[38;2;238;237;236mO\033[38;2;193;186;183m*\033[38;2;112;93;85m-\033[38;2;96;73;64m:\033[38;2;77;62;58m:\033[38;2;44;41;40m.\033[38;2;37;38;37m.\033[38;2;38;37;38m.\033[38;2;38;38;38m.\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;40;39;38m.\033[38;2;72;58;55m:\033[38;2;95;72;64m:\033[38;2;120;102;95m-\033[38;2;198;192;189m*\033[38;2;233;234;234mO\033[38;2;240;241;242mOO\033[38;2;240;242;242mO\033[38;2;241;241;242mO\033[38;2;241;242;242mO\033[38;2;240;241;241mO\033[38;2;240;242;241mOO\033[38;2;240;242;242mO\033[38;2;241;243;242mOO\033[38;2;240;242;242mO\033[38;2;238;239;239mO\033[38;2;235;235;235mOOOOOOOOOOOO\033[38;2;235;236;236mO\033[38;2;238;239;239mO\033[38;2;237;238;239mO\033[38;2;238;240;241mO\033[38;2;243;244;245mO\033[38;2;241;241;243mO\033[38;2;237;238;237mO\033[38;2;235;235;235mO\033[38;2;235;234;234mO\033[38;2;236;236;236mO\033[38;2;236;235;235mO\033[38;2;235;235;235mOOOOOOOOOOOOOOOOOOOOOOOOO\033[38;2;234;234;234mO\033[38;2;235;235;235mO\033[38;2;236;237;237mO\033[38;2;237;235;235mO\033[38;2;171;163;158m+\033[38;2;99;76;68m:\033[38;2;95;72;63m:\033[38;2;59;51;46m.\033[38;2;37;38;37m.\033[38;2;38;37;37m.\033[38;2;38;38;38m.\033[0m");
    $display("\033[38;2;38;38;38m..\033[38;2;37;37;40m.\033[38;2;45;43;40m.\033[38;2;71;61;54m:\033[38;2;90;71;64m:\033[38;2;105;83;77m-\033[38;2;136;119;113m=\033[38;2;164;152;147m+\033[38;2;184;174;171m*\033[38;2;198;191;189m*\033[38;2;203;198;196m#\033[38;2;206;201;199m#\033[38;2;208;203;201m#\033[38;2;210;206;204m#\033[38;2;209;205;203m#\033[38;2;203;198;196m#\033[38;2;191;185;182m*\033[38;2;184;177;174m*\033[38;2;191;183;180m*\033[38;2;208;203;201m#\033[38;2;230;229;228mO\033[38;2;236;235;236mO\033[38;2;235;235;235mOOOOOOOOOOOO\033[38;2;237;237;237mO\033[38;2;224;221;221m#\033[38;2;191;183;180m*\033[38;2;161;149;145m+\033[38;2;142;127;121m=\033[38;2;129;113;107m=\033[38;2;136;120;115m=\033[38;2;202;196;194m#\033[38;2;236;235;234mO\033[38;2;236;236;236mO\033[38;2;235;235;235mOOOOOOOOOOOOOOOOOOOOOOOO\033[38;2;234;234;234mO\033[38;2;235;235;235mOO\033[38;2;237;238;237mO\033[38;2;205;201;197m#\033[38;2;111;91;84m-\033[38;2;95;73;63m:\033[38;2;66;57;53m:\033[38;2;36;38;37m.\033[38;2;38;37;37m.\033[38;2;38;38;38m.\033[0m");
    $display("\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[38;2;48;44;42m.\033[38;2;63;54;50m:\033[38;2;74;59;53m:\033[38;2;80;62;54m:\033[38;2;87;67;59m:\033[38;2;94;73;65m:\033[38;2;95;75;68m:\033[38;2;98;78;70m:\033[38;2;102;79;72m-\033[38;2;101;79;70m-\033[38;2;98;77;67m:\033[38;2;98;77;68m:\033[38;2;102;80;72m-\033[38;2;104;82;73m-\033[38;2;103;81;72m-\033[38;2;121;102;97m-\033[38;2;202;196;193m#\033[38;2;236;237;237mO\033[38;2;235;236;237mO\033[38;2;234;234;234mO\033[38;2;235;235;235mOOOOOOOOO\033[38;2;237;236;237mO\033[38;2;207;204;203m#\033[38;2;124;107;100m-\033[38;2;96;72;63m:\033[38;2;117;99;92m-\033[38;2;140;126;120m=\033[38;2;154;141;136m+\033[38;2;176;165;161m+\033[38;2;218;214;213m#\033[38;2;236;235;233mO\033[38;2;235;236;234mO\033[38;2;235;235;235mO\033[38;2;234;235;235mO\033[38;2;235;235;236mO\033[38;2;237;237;237mO\033[38;2;238;238;238mO\033[38;2;238;238;239mO\033[38;2;237;238;238mO\033[38;2;235;235;235mOOOOOOOOOO\033[38;2;236;236;236mOOO\033[38;2;235;235;235mOOOO\033[38;2;234;234;234mO\033[38;2;235;235;235mOO\033[38;2;237;238;237mO\033[38;2;201;196;192m#\033[38;2;109;88;81m-\033[38;2;95;73;63m:\033[38;2;66;56;51m:\033[38;2;37;38;37m.\033[38;2;38;37;37m.\033[38;2;38;38;38m.\033[0m");
    $display("\033[38;2;38;38;38m.....\033[38;2;34;36;36m.\033[38;2;32;33;33m.\033[38;2;36;36;37m.\033[38;2;41;40;39m.\033[38;2;44;41;40m.\033[38;2;46;43;42m.\033[38;2;60;51;47m.\033[38;2;87;68;60m:\033[38;2;95;73;62m:\033[38;2;111;92;84m-\033[38;2;157;142;137m+\033[38;2;192;184;182m*\033[38;2;210;206;204m#\033[38;2;216;212;210m#\033[38;2;215;211;209m#\033[38;2;220;216;215m#\033[38;2;231;231;230mO\033[38;2;234;236;235mO\033[38;2;236;236;236mO\033[38;2;235;236;236mO\033[38;2;236;236;236mO\033[38;2;235;236;236mOOO\033[38;2;235;235;235mOO\033[38;2;236;237;237mO\033[38;2;238;239;239mOO\033[38;2;240;240;240mO\033[38;2;203;199;196m#\033[38;2;110;90;81m-\033[38;2;92;68;59m:\033[38;2;161;150;145m+\033[38;2;230;229;227mO\033[38;2;240;242;242mO\033[38;2;239;240;241mO\033[38;2;237;237;236mO\033[38;2;234;235;233mO\033[38;2;235;235;234mO\033[38;2;236;237;237mO\033[38;2;239;239;239mO\033[38;2;235;235;234mO\033[38;2;225;223;223m#\033[38;2;214;211;210m#\033[38;2;208;203;201m#\033[38;2;218;214;213m#\033[38;2;233;233;231mO\033[38;2;235;235;235mOOOOOO\033[38;2;236;236;236mO\033[38;2;238;239;240mO\033[38;2;239;239;240mO\033[38;2;236;235;235mO\033[38;2;233;232;232mO\033[38;2;234;234;234mO\033[38;2;235;235;235mOOOO\033[38;2;234;234;234mO\033[38;2;235;235;235mO\033[38;2;236;236;236mO\033[38;2;235;235;234mO\033[38;2;167;156;152m+\033[38;2;98;74;65m:\033[38;2;91;71;63m:\033[38;2;55;48;45m.\033[38;2;37;38;37m.\033[38;2;38;37;37m.\033[38;2;38;38;38m.\033[0m\033[31m  i:..::::::i.      :::::         ::::    .:::.          \033[m");
    $display("\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;48;47;48m.\033[38;2;97;95;94m-\033[38;2;123;121;118m=\033[38;2;125;120;118m=\033[38;2;125;119;117m=\033[38;2;119;114;112m=\033[38;2;97;84;77m-\033[38;2;93;69;60m:\033[38;2;124;105;98m-\033[38;2;209;203;202m#\033[38;2;240;238;238mO\033[38;2;240;240;240mO\033[38;2;238;238;239mO\033[38;2;237;238;238mO\033[38;2;238;238;238mO\033[38;2;237;239;239mO\033[38;2;236;237;237mO\033[38;2;236;234;234mO\033[38;2;234;230;231mO\033[38;2;233;227;228mO\033[38;2;233;225;227mO\033[38;2;234;225;227mO\033[38;2;234;227;228mO\033[38;2;234;231;231mO\033[38;2;234;236;235mO\033[38;2;235;237;237mO\033[38;2;227;225;223mO\033[38;2;209;206;203m#\033[38;2;207;203;201m#\033[38;2;221;220;219m#\033[38;2;235;235;234mO\033[38;2;193;187;184m*\033[38;2;119;101;95m-\033[38;2;90;69;59m:\033[38;2;136;121;115m=\033[38;2;217;214;211m#\033[38;2;236;236;237mO\033[38;2;235;235;235mO\033[38;2;234;235;235mO\033[38;2;238;238;238mO\033[38;2;230;227;227mO\033[38;2;188;180;176m*\033[38;2;141;124;118m=\033[38;2;113;92;83m-\033[38;2;104;83;75m-\033[38;2;105;85;77m-\033[38;2;145;131;127m=\033[38;2;221;219;217m#\033[38;2;236;237;239mO\033[38;2;235;235;236mO\033[38;2;234;234;234mO\033[38;2;235;235;235mOO\033[38;2;237;236;236mO\033[38;2;233;229;231mO\033[38;2;199;191;190m*\033[38;2;159;147;143m+\033[38;2;134;117;110m=\033[38;2;124;107;99m-\033[38;2;160;150;145m+\033[38;2;226;225;224mO\033[38;2;235;236;236mO\033[38;2;234;234;234mO\033[38;2;235;235;235mO\033[38;2;234;234;234mO\033[38;2;237;237;237mO\033[38;2;238;238;239mO\033[38;2;195;190;187m*\033[38;2;112;92;85m-\033[38;2;92;68;60m:\033[38;2;69;56;53m:\033[38;2;40;39;38m.\033[38;2;37;38;37m.\033[38;2;39;38;39m.\033[38;2;38;38;38m.\033[0m\033[31m  BBBBBBBBBBBi     iBBBBBL       .BBBB    7BBB7          \033[m");
    $display("\033[38;2;38;38;38m..\033[38;2;37;37;36m.\033[38;2;35;35;33m.\033[38;2;43;44;42m.\033[38;2;106;106;108m-\033[38;2;192;185;184m*\033[38;2;137;121;114m=\033[38;2;118;99;90m-\033[38;2;119;99;90m--\033[38;2;105;83;76m-\033[38;2;92;68;59m:\033[38;2;127;110;104m=\033[38;2;223;217;218m#\033[38;2;239;240;240mO\033[38;2;235;235;235mO\033[38;2;235;234;234mO\033[38;2;235;235;235mOO\033[38;2;233;231;231mO\033[38;2;231;209;214m#\033[38;2;228;190;197m#\033[38;2;228;180;189m*\033[38;2;226;175;185m*\033[38;2;225;174;184m*\033[38;2;226;173;184m*\033[38;2;226;176;186m*\033[38;2;227;182;190m#\033[38;2;230;195;201m#\033[38;2;202;182;183m*\033[38;2;124;105;100m-\033[38;2;100;79;71m-\033[38;2;99;78;68m:\033[38;2;111;92;84m-\033[38;2;183;175;171m*\033[38;2;237;237;236mO\033[38;2;222;218;217m#\033[38;2;176;167;164m*\033[38;2;173;164;159m+\033[38;2;222;219;217m#\033[38;2;236;236;236mO\033[38;2;235;235;236mO\033[38;2;236;237;238mO\033[38;2;215;210;209m#\033[38;2;139;125;120m=\033[38;2;93;71;62m:\033[38;2;102;80;72m-\033[38;2;148;134;128m=\033[38;2;189;181;177m*\033[38;2;209;206;203m#\033[38;2;224;223;222m#\033[38;2;233;234;233mO\033[38;2;235;235;235mOO\033[38;2;235;235;236mO\033[38;2;237;237;237mO\033[38;2;239;239;240mO\033[38;2;221;221;217m#\033[38;2;149;135;129m=\033[38;2;96;73;65m:\033[38;2;100;78;70m:\033[38;2;136;122;115m=\033[38;2;173;163;159m+\033[38;2;208;202;199m#\033[38;2;233;233;231mO\033[38;2;235;237;236mO\033[38;2;235;236;235mO\033[38;2;237;238;238mO\033[38;2;239;240;240mO\033[38;2;227;225;225mO\033[38;2;174;165;160m+\033[38;2;109;90;82m-\033[38;2;98;75;67m:\033[38;2;107;92;87m-\033[38;2;63;60;60m:\033[38;2;37;38;38m.\033[38;2;38;38;38m.\033[38;2;39;38;39m.\033[38;2;38;38;38m.\033[0m\033[31m  BBBB.::::ir.     BBB:BBB.      .BBBv    iBBB:          \033[m");
    $display("\033[38;2;37;37;37m..\033[38;2;49;51;49m.\033[38;2;123;121;118m=\033[38;2;142;134;132m=\033[38;2;142;132;128m=\033[38;2;161;149;145m+\033[38;2;154;140;135m+\033[38;2;145;131;124m=\033[38;2;143;129;122m=\033[38;2;144;130;123m=\033[38;2;146;131;125m=\033[38;2;109;89;81m-\033[38;2;92;68;61m:\033[38;2;141;125;120m=\033[38;2;215;211;207m#\033[38;2;239;239;240mO\033[38;2;240;239;240mO\033[38;2;237;236;236mO\033[38;2;235;230;231mO\033[38;2;229;191;199m#\033[38;2;224;167;178m*\033[38;2;225;167;179m*\033[38;2;227;169;181m*\033[38;2;226;169;180m*****\033[38;2;226;169;181m*\033[38;2;200;153;161m+\033[38;2;126;98;95m-\033[38;2;102;77;70m:\033[38;2;99;75;67m:\033[38;2;109;87;80m-\033[38;2;180;171;169m*\033[38;2;235;234;234mO\033[38;2;237;238;238mO\033[38;2;238;240;239mO\033[38;2;238;240;240mO\033[38;2;235;236;235mO\033[38;2;235;235;235mO\033[38;2;236;236;238mO\033[38;2;230;229;230mO\033[38;2;153;141;135m+\033[38;2;89;64;55m:\033[38;2;108;88;80m-\033[38;2;197;189;186m*\033[38;2;240;241;241mO\033[38;2;242;243;242mO\033[38;2;240;240;240mO\033[38;2;239;240;240mOOO\033[38;2;238;238;238mO\033[38;2;232;231;231mO\033[38;2;223;220;220m#\033[38;2;220;216;214m#\033[38;2;173;163;158m+\033[38;2;93;72;64m:\033[38;2;98;76;68m:\033[38;2;182;172;167m*\033[38;2;240;240;241mO\033[38;2;244;245;247mO\033[38;2;242;242;243mO\033[38;2;240;241;240mO\033[38;2;238;238;238mO\033[38;2;231;229;229mO\033[38;2;212;208;208m#\033[38;2;174;165;162m+\033[38;2;124;107;98m-\033[38;2;94;72;62m:\033[38;2;94;71;62m:\033[38;2;99;76;67m:\033[38;2;137;124;118m=\033[38;2;164;162;161m+\033[38;2;67;67;67m:\033[38;2;36;36;36m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[0m\033[31m  BBBQ            :BBY iBB7       BBB7    :BBB:          \033[m");
    $display("\033[38;2;37;37;37m.\033[38;2;36;36;36m.\033[38;2;56;58;59m:\033[38;2;154;153;151m+\033[38;2;152;140;136m+\033[38;2;126;109;103m=\033[38;2;122;105;99m-\033[38;2;124;107;101m-\033[38;2;129;112;105m=\033[38;2;127;110;104m=\033[38;2;133;116;109m=\033[38;2;175;166;161m*\033[38;2;167;161;155m+\033[38;2;110;92;86m-\033[38;2;95;70;62m:\033[38;2;114;95;87m-\033[38;2;164;153;150m+\033[38;2;211;205;204m#\033[38;2;232;232;231mO\033[38;2;236;232;234mO\033[38;2;231;191;200m#\033[38;2;229;170;182m*\033[38;2;229;172;184m*\033[38;2;229;172;183m*\033[38;2;228;171;182m*\033[38;2;227;170;182m**\033[38;2;226;170;181m**\033[38;2;227;170;181m*\033[38;2;227;172;182m*\033[38;2;220;168;178m*\033[38;2;205;156;164m*\033[38;2;200;154;160m*\033[38;2;213;165;174m*\033[38;2;232;207;212m#\033[38;2;237;236;236mO\033[38;2;235;237;237mO\033[38;2;237;237;237mO\033[38;2;238;238;238mO\033[38;2;238;239;239mO\033[38;2;239;240;240mO\033[38;2;240;241;242mO\033[38;2;234;234;233mO\033[38;2;162;150;143m+\033[38;2;93;71;61m:\033[38;2;103;82;76m-\033[38;2;169;159;153m+\033[38;2;214;212;210m#\033[38;2;223;220;219m#\033[38;2;219;217;215m#\033[38;2;209;206;203m#\033[38;2;194;187;184m*\033[38;2;173;162;159m+\033[38;2;150;136;131m=\033[38;2;126;110;103m=\033[38;2;111;91;84m-\033[38;2;106;87;77m-\033[38;2;101;81;71m-\033[38;2;96;73;64m:\033[38;2;96;73;65m:\033[38;2;136;119;113m=\033[38;2;184;174;172m*\033[38;2;198;192;190m*\033[38;2;192;184;181m*\033[38;2;175;164;160m+\033[38;2;150;137;131m+\033[38;2;125;109;101m=\033[38;2;105;84;76m-\033[38;2;92;69;60m:\033[38;2;103;81;73m-\033[38;2;135;118;112m=\033[38;2;145;131;123m=\033[38;2;145;129;124m=\033[38;2;173;163;161m+\033[38;2;165;164;163m+\033[38;2;60;60;60m:\033[38;2;36;36;36m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[0m\033[31m  BBBB            BBB. .BBB.      BBB7    :BBB:          \033[m");
    $display("\033[38;2;38;38;38m..\033[38;2;37;37;38m.\033[38;2;46;48;48m.\033[38;2;74;74;74m:\033[38;2;83;83;82m:\033[38;2;105;105;104m-\033[38;2;189;188;187m*\033[38;2;167;154;149m+\033[38;2;133;117;111m=\033[38;2;131;115;109m=\033[38;2;132;116;109m=\033[38;2;129;112;105m=\033[38;2;118;99;90m-\033[38;2;100;75;67m:\033[38;2;94;69;61m:\033[38;2;93;68;59m:\033[38;2;104;81;74m-\033[38;2;130;113;107m=\033[38;2;161;148;143m+\033[38;2;184;167;164m*\033[38;2;195;160;163m*\033[38;2;206;158;165m*\033[38;2;215;164;172m*\033[38;2;219;168;177m*\033[38;2;222;171;180m*\033[38;2;224;172;181m*\033[38;2;226;173;183m*\033[38;2;228;173;183m*\033[38;2;228;173;184m*\033[38;2;228;173;185m*\033[38;2;229;174;185m*\033[38;2;231;176;188m*\033[38;2;230;176;188m*\033[38;2;229;171;183m*\033[38;2;224;193;198m#\033[38;2;231;227;227mO\033[38;2;229;228;227mO\033[38;2;224;222;221m#\033[38;2;215;212;211m#\033[38;2;205;200;199m#\033[38;2;189;182;179m*\033[38;2;170;159;154m+\033[38;2;147;133;128m=\033[38;2;122;103;95m-\033[38;2;99;77;68m:\033[38;2;98;74;66m:\033[38;2;96;74;66m:\033[38;2;106;86;78m-\033[38;2;114;93;86m-\033[38;2;111;90;82m-\033[38;2;104;82;73m-\033[38;2;102;80;72m-\033[38;2;108;87;79m-\033[38;2;115;96;88m-\033[38;2;113;95;87m-\033[38;2;112;93;86m-\033[38;2;112;92;84m-\033[38;2;113;93;84m-\033[38;2;113;94;85m-\033[38;2;114;94;86m-\033[38;2;110;90;80m-\033[38;2;106;87;77m-\033[38;2;108;87;79m-\033[38;2;105;84;76m-\033[38;2;101;80;71m-\033[38;2;99;77;68m:\033[38;2;100;78;70m:\033[38;2;102;81;74m-\033[38;2;103;82;74m-\033[38;2;111;90;81m-\033[38;2;118;98;89m-\033[38;2;116;96;86m-\033[38;2;114;94;85m-\033[38;2;140;125;119m=\033[38;2;179;175;172m*\033[38;2;80;80;80m:\033[38;2;36;36;36m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.\033[0m\033[31m  BBBB:r7vvj:    :BBB   gBBs      BBB7    :BBB:          \033[m");
    $display("\033[38;2;38;38;38m...\033[38;2;37;37;37m.\033[38;2;34;34;34m.\033[38;2;32;32;32m.\033[38;2;51;50;50m.\033[38;2;130;127;128m=\033[38;2;140;131;128m=\033[38;2;131;120;116m=\033[38;2;138;128;124m=\033[38;2;136;125;122m=\033[38;2;135;124;121m=\033[38;2;136;126;122m=\033[38;2;138;127;124m=\033[38;2;138;128;124m=\033[38;2;139;128;124m=\033[38;2;121;108;104m-\033[38;2;83;67;61m:\033[38;2;79;60;53m:\033[38;2;87;67;58m:\033[38;2;93;72;63m:\033[38;2;99;76;68m:\033[38;2;109;82;76m-\033[38;2;116;88;83m-\033[38;2;121;93;88m-\033[38;2;128;99;94m-\033[38;2;135;104;99m=\033[38;2;139;106;102m=\033[38;2;140;106;103m=\033[38;2;140;106;104m===\033[38;2;138;104;103m=\033[38;2;134;103;100m-\033[38;2;128;106;101m=\033[38;2;125;106;99m-\033[38;2;118;99;93m-\033[38;2;111;91;85m-\033[38;2;104;82;75m-\033[38;2;98;76;67m:\033[38;2;92;69;59m:\033[38;2;90;66;57m::\033[38;2;91;69;60m:\033[38;2;94;71;62m:\033[38;2;94;71;63m:\033[38;2;93;70;62m:\033[38;2;92;68;60m:\033[38;2;90;67;58m:\033[38;2;92;69;60m:\033[38;2;98;75;66m:\033[38;2;111;91;83m-\033[38;2;126;110;102m=\033[38;2;135;119;113m=\033[38;2;136;120;114m==\033[38;2;137;122;115m=\033[38;2;138;123;117m=\033[38;2;143;127;122m=\033[38;2;148;135;128m=\033[38;2;149;136;129m=\033[38;2;147;134;126m=\033[38;2;146;132;126m=\033[38;2;149;134;129m=\033[38;2;148;133;129m=\033[38;2;146;132;128m=\033[38;2;146;133;128m=\033[38;2;155;141;136m+\033[38;2;187;178;175m*\033[38;2;158;153;151m+\033[38;2;121;116;114m=\033[38;2;122;117;116m=\033[38;2;122;118;118m=\033[38;2;119;117;117m=\033[38;2;89;88;88m-\033[38;2;45;45;45m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..\033[0m\033[31m  BBBBBBBBBB7    BBB:   .BBB.     BBB7    :BBB:          \033[m");
    $display("\033[38;2;38;38;38m.....\033[38;2;39;39;39m.\033[38;2;37;36;36m.\033[38;2;34;34;35m.\033[38;2;80;81;83m:\033[38;2;163;160;159m+\033[38;2;148;139;133m+\033[38;2;141;132;127m=\033[38;2;143;135;130m=\033[38;2;146;138;133m=\033[38;2;147;140;137m+\033[38;2;143;137;134m=\033[38;2;142;136;133m=\033[38;2;138;133;131m=\033[38;2;128;122;121m=\033[38;2;125;119;117m=\033[38;2;123;114;112m=\033[38;2;122;112;110m=\033[38;2;119;109;107m-\033[38;2;120;109;104m-\033[38;2;126;114;107m=\033[38;2;132;119;113m=\033[38;2;134;120;113m=\033[38;2;129;114;106m=\033[38;2;124;109;101m=\033[38;2;123;107;99m-\033[38;2;123;106;99m---\033[38;2;121;107;99m-\033[38;2;120;106;98m-\033[38;2;117;102;95m-\033[38;2;113;100;94m-\033[38;2;111;99;93m-\033[38;2;132;121;116m=\033[38;2;170;160;157m+\033[38;2;182;172;169m*\033[38;2;183;174;171m*\033[38;2;183;173;171m*\033[38;2;181;172;169m*\033[38;2;180;172;168m*\033[38;2;180;170;167m*\033[38;2;179;169;166m*\033[38;2;178;168;164m*\033[38;2;176;167;163m*\033[38;2;175;165;161m+\033[38;2;163;153;149m+\033[38;2;144;134;129m=\033[38;2;134;123;118m=\033[38;2;135;123;118m=\033[38;2;134;121;115m=\033[38;2;132;120;114m=\033[38;2;131;118;112m=\033[38;2;131;117;111m===\033[38;2;132;118;112m=\033[38;2;134;120;114m=\033[38;2;133;119;113m=\033[38;2;133;118;113m=\033[38;2;132;117;112m==\033[38;2;132;117;111m=\033[38;2;129;115;108m=\033[38;2;132;117;110m=\033[38;2;171;165;163m+\033[38;2;109;109;109m-\033[38;2;36;36;36m.\033[38;2;35;36;36m.\033[38;2;36;37;37m.\033[38;2;34;35;35m.\033[38;2;33;34;34m.\033[38;2;37;37;37m.\033[38;2;38;38;38m...\033[0m\033[31m  BBBB    ..    iBBBBBBBBBBBP     BBB7    :BBB:          \033[m");
    $display("\033[38;2;38;38;38m......\033[38;2;37;37;37m.\033[38;2;35;35;35m.\033[38;2;72;72;73m:\033[38;2;161;155;154m+\033[38;2;141;128;124m=\033[38;2;129;113;106m=\033[38;2;132;116;109m=\033[38;2;131;115;108m=\033[38;2;128;110;103m=\033[38;2;125;105;99m-\033[38;2;122;103;96m-\033[38;2;122;102;95m-\033[38;2;122;101;94m-\033[38;2;120;100;92m-\033[38;2;120;99;92m-\033[38;2;119;99;92m-\033[38;2;119;101;93m-\033[38;2;121;103;96m-\033[38;2;122;104;96m-\033[38;2;124;104;96m-\033[38;2;125;106;98m-\033[38;2;123;105;97m-\033[38;2;121;103;95m-\033[38;2;121;102;94m-\033[38;2;121;101;94m-\033[38;2;122;102;95m-\033[38;2;121;102;94m-\033[38;2;121;103;95m-\033[38;2;122;103;95m-\033[38;2;122;103;96m-\033[38;2;121;103;96m-\033[38;2;120;104;96m-\033[38;2;122;107;99m-\033[38;2;129;113;106m=\033[38;2;132;116;109m=\033[38;2;134;118;111m=\033[38;2;136;119;112m=\033[38;2;137;121;114m=\033[38;2;140;124;117m=\033[38;2;142;125;119m=\033[38;2;144;127;121m=\033[38;2;145;128;122m=\033[38;2;144;130;125m=\033[38;2;146;132;127m=\033[38;2;151;138;133m+\033[38;2;167;163;160m+\033[38;2;127;127;125m=\033[38;2;66;65;65m:\033[38;2;62;62;62m:\033[38;2;62;63;63m::\033[38;2;63;63;63m:\033[38;2;64;64;64m:\033[38;2;66;66;66m:\033[38;2;69;69;70m:\033[38;2;73;73;74m:\033[38;2;74;75;75m:\033[38;2;74;74;75m::\033[38;2;75;74;75m:\033[38;2;77;77;77m:\033[38;2;80;79;79m:\033[38;2;80;80;80m:\033[38;2;68;68;68m:\033[38;2;43;43;43m.\033[38;2;38;38;38m.\033[38;2;37;37;37m.\033[38;2;38;38;38m.......\033[0m\033[31m  BBBB          BBBBi7vviQBBB.    BBB7    :BBB.          \033[m");
    $display("\033[38;2;38;38;38m........\033[38;2;37;37;37m.\033[38;2;50;50;50m.\033[38;2;70;70;70m:\033[38;2;77;77;76m:\033[38;2;85;84;83m-\033[38;2;89;88;87m-\033[38;2;93;92;91m-\033[38;2;97;96;95m-\033[38;2;103;101;100m-\033[38;2;115;111;109m-\033[38;2;121;116;114m=\033[38;2;124;119;117m=\033[38;2;130;124;121m=\033[38;2;132;124;121m=\033[38;2;134;126;124m=\033[38;2;132;124;121m=\033[38;2;136;127;124m=\033[38;2;140;132;128m=\033[38;2;138;129;124m=\033[38;2;137;127;121m=\033[38;2;136;126;120m=\033[38;2;138;127;121m=\033[38;2;138;125;121m=\033[38;2;136;123;119m=\033[38;2;134;121;116m=\033[38;2;133;120;115m=\033[38;2;132;119;114m=\033[38;2;132;118;114m=\033[38;2;132;118;112m=\033[38;2;135;121;116m=\033[38;2;140;126;121m=\033[38;2;139;125;119m=\033[38;2;137;123;118m=\033[38;2;136;122;116m=\033[38;2;135;122;114m=\033[38;2;135;121;114m=\033[38;2;134;120;113m=\033[38;2;135;119;114m===\033[38;2;135;119;113m=\033[38;2;133;118;111m=\033[38;2;133;118;112m=\033[38;2;162;154;151m+\033[38;2;124;124;122m=\033[38;2;41;40;41m.\033[38;2;34;34;35m.\033[38;2;34;34;34m.\033[38;2;35;35;35m....\033[38;2;34;34;34m..........\033[38;2;37;37;37m.\033[38;2;38;38;38m.........\033[0m\033[31m  BBBB         rBBB.      BBBQ   .BBBv    iBBB2ir777L7   \033[m");
    $display("\033[38;2;38;38;38m.........\033[38;2;36;36;36m.\033[38;2;34;34;34m.\033[38;2;34;34;33m.\033[38;2;33;34;33m.\033[38;2;33;33;32m.\033[38;2;33;33;33m.\033[38;2;33;34;34m.\033[38;2;34;34;35m.\033[38;2;34;34;34m.\033[38;2;35;36;35m.\033[38;2;37;37;37m.\033[38;2;38;39;39m.\033[38;2;40;41;42m.\033[38;2;44;45;46m.\033[38;2;46;47;47m.\033[38;2;49;50;50m.\033[38;2;52;53;53m.\033[38;2;52;53;54m.\033[38;2;53;54;54m.\033[38;2;55;56;56m.\033[38;2;60;61;61m:\033[38;2;62;63;63m::\033[38;2;62;62;63m:::\033[38;2;62;63;63m:\033[38;2;64;64;65m:\033[38;2;71;71;72m:\033[38;2;81;81;82m:\033[38;2;83;83;83m:\033[38;2;83;83;84m:\033[38;2;82;82;83m:\033[38;2;82;83;82m:\033[38;2;82;82;82m:::\033[38;2;82;82;83m:\033[38;2;82;83;83m:\033[38;2;82;82;82m:\033[38;2;83;83;83m:\033[38;2;82;82;82m:\033[38;2;64;64;64m:\033[38;2;38;40;39m.\033[38;2;37;37;37m.\033[38;2;38;38;38m..........................\033[0m\033[31m .BBBB        :BBBB       BBBB7  .BBBB    7BBBBBBBBBBB   \033[m");
    $display("\033[38;2;38;38;38m...................\033[38;2;37;37;37m....\033[38;2;36;36;36m......\033[38;2;35;35;35m........\033[38;2;34;34;34m.\033[38;2;33;33;33m.....\033[38;2;33;33;34m..\033[38;2;33;33;33m...\033[38;2;33;33;34m.\033[38;2;33;33;33m..\033[38;2;34;35;35m.\033[38;2;37;37;37m.\033[38;2;38;38;38m...........................\033[0m\033[31m  . ..        ....         ...:   ....    ..   .......   \033[m");
end endtask

endmodule