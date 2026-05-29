`timescale 1ns/1ps

`define CYCLE_TIME       5.2
`define DEBUG_EN         1
`define SEED             23
`define RAM_NUMBER       5
`define OP_SET_NUMBER    5
`define RAM_WIDTH        256
`define RAM_DEPTH        256
`define READ_LATENCY     50
`define WRITE_LATENCY    5
`define BURST_BIT        3
`define PRINT_LATENCY    1

// ============================================================
// TESTBED RAM interface hierarchy
// Change these names according to your TESTBED.sv
// ============================================================
`define TB_RD_EN      $root.TESTBED.rd_en
`define TB_RD_ADDR    $root.TESTBED.rd_addr
`define TB_RD_BURST   $root.TESTBED.rd_burst

`define TB_WR_EN      $root.TESTBED.wr_en
`define TB_WR_ADDR    $root.TESTBED.wr_addr
`define TB_WR_BURST   $root.TESTBED.wr_burst
`define TB_WR_DATA    $root.TESTBED.wr_data

`define TB_WR_READY   $root.TESTBED.wr_ready
`define TB_WR_VALID   $root.TESTBED.wr_valid


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

// ============================================================
// Parameter / type
// ============================================================
localparam int N        = 8;
localparam int MAX_WAIT = 10000;

typedef int signed mtx_t [0:N-1][0:N-1];

mtx_t golden_ram [0:`RAM_DEPTH-1];

mtx_t param_q;
mtx_t param_k;
mtx_t param_v;

logic [31:0] golden_out [0:`RAM_DEPTH-1];

logic [1:0] cur_op;
logic [1:0] cur_act;

int unsigned seed;
int dummy_rand;
int ram_idx;
int set_idx;

int total_latency;

// ============================================================
// Static drivers for force/procedural RAM preload.
// VCS does not allow automatic task variables on RHS of force,
// so force TESTBED signals to these module-level drivers only.
// ============================================================
logic         tb_rd_en_drv;
logic [7:0]   tb_rd_addr_drv;
logic [2:0]   tb_rd_burst_drv;

logic         tb_wr_en_drv;
logic [7:0]   tb_wr_addr_drv;
logic [2:0]   tb_wr_burst_drv;
logic [255:0] tb_wr_data_drv;

logic [255:0] dut_ram_word [0:`RAM_DEPTH-1];

// ============================================================
// Clock
// ============================================================
initial clk = 1'b0;
always #(`CYCLE_TIME/2.0) clk = ~clk;


// ============================================================
// Main
// ============================================================
initial begin
    seed = `SEED;
    dummy_rand = $urandom(seed);
    total_latency = 0;

    reset_task();

    // Correct RAM files: pat00_data.txt ~ pat04_data.txt
    for (ram_idx = 0; ram_idx < `RAM_NUMBER; ram_idx = ram_idx + 1) begin
        // Load original RAM file into PATTERN golden model once.
        // During the same RAM pattern, golden_ram will be updated after each op set.
        load_golden_ram_from_file_task(ram_idx);

        @(negedge clk);
        mem_set  = 1'b0;
        in_valid = 1'b0;
        op       = 2'd0;
        act      = 2'd0;
        param    = 256'd0;

        repeat (2) @(negedge clk);

        for (set_idx = 0; set_idx < `OP_SET_NUMBER; set_idx = set_idx + 1) begin
            if (set_idx == 0) begin
                // First op set of this RAM pattern:
                // DUT RAM is empty, so PATTERN actively writes the original
                // patXX file data in, then raises mem_set once RAM is ready.
                preload_dut_ram_from_current_golden_task(ram_idx, set_idx);

                @(negedge clk);
                mem_set = 1'b1;
                repeat (3) @(negedge clk);
            end
            else begin
                // Later op sets:
                // DUT already wrote its previous op set result back into RAM
                // (full 8x8 matrix at each address). check_all_outputs_task
                // already verified those results match golden, otherwise the
                // simulation would have stopped. So the DUT RAM equals
                // golden_ram and PATTERN does NOT write it back again.
                repeat ($urandom_range(1, 3)) @(negedge clk);
            end

            random_op_set_task(set_idx);

            // build_golden_task uses current golden_ram as input,
            // then updates golden_ram to this op set output.
            build_golden_task(cur_op, cur_act);

            send_op_set_task(cur_op, cur_act);
            check_all_outputs_task(ram_idx, set_idx);

            repeat ($urandom_range(1, 3)) @(negedge clk);
        end

        @(negedge clk);
        mem_set  = 1'b0;
        in_valid = 1'b0;
        op       = 2'd0;
        act      = 2'd0;
        param    = 256'd0;

        repeat ($urandom_range(2, 5)) @(negedge clk);
    end

    YOU_PASS_TASK();
    $display ("----------------------------------------------------------------------------------------------------------------------");
    $display ("                                                  Congratulations!                 					             ");
    $display ("                                           You have passed all patterns!          					             ");
    $display ("                                Cycle Time = %.1f ns , execution cycles = %6d cycles        					         ", `CYCLE_TIME ,total_latency);
    $display ("----------------------------------------------------------------------------------------------------------------------");
    $finish;
end


// ============================================================
// Reset
// ============================================================
task automatic reset_task();
begin
    rst_n    = 1'b1;
    mem_set  = 1'b0;
    in_valid = 1'b0;
    op       = 2'd0;
    act      = 2'd0;
    param    = 256'd0;
    cur_op   = 2'd0;
    cur_act  = 2'd0;

    #(0.5 * `CYCLE_TIME);
    rst_n = 1'b0;

    repeat (3) @(negedge clk);

    if (out_valid !== 1'b0 || out_data !== 32'd0) begin
        YOU_FAIL_TASK();
        $display("======================================================================================================================");
        $display(" Reset output is not zero.");
        $display(" out_valid = %b", out_valid);
        $display(" out_data  = %h", out_data);
        $display("======================================================================================================================");
        repeat (3) @(negedge clk);
        $finish;
    end

    rst_n = 1'b1;
    repeat (3) @(negedge clk);
end
endtask


// ============================================================
// New RAM pattern
// Kept for compatibility; main flow does not call this task now.
// RAM file index is pat00~pat04.
// ============================================================
task automatic new_ram_task(input int rid);
begin
    @(negedge clk);
    mem_set  = 1'b0;
    in_valid = 1'b0;
    op       = 2'd0;
    act      = 2'd0;
    param    = 256'd0;

    load_golden_ram_from_file_task(rid);
    preload_dut_ram_from_current_golden_task(rid, 0);

    @(negedge clk);
    mem_set = 1'b1;

    repeat ($urandom_range(2, 5)) @(negedge clk);

    if (`DEBUG_EN) begin
        $display("[RAM %0d] mem_set = 1 after DUT RAM preload", rid);
    end
end
endtask


task automatic load_golden_ram_from_file_task(input int rid);
    logic [255:0] ram_word [0:`RAM_DEPTH-1];
    string file_name;
    int fp;
    int a;
begin
    file_name = $sformatf("../00_TESTBED/ram/pat%02d_data.txt", rid);

    fp = $fopen(file_name, "r");
    if (fp == 0) begin
        YOU_FAIL_TASK();
        $display("======================================================================================================================");
        $display(" Cannot open RAM data file.");
        $display(" file_name = %s", file_name);
        $display("======================================================================================================================");
        $finish;
    end
    $fclose(fp);

    $readmemh(file_name, ram_word);

    for (a = 0; a < `RAM_DEPTH; a = a + 1) begin
        golden_ram[a] = unpack_word_to_mtx(ram_word[a]);
    end

    if (`DEBUG_EN) begin
        $display("[LOAD] %s", file_name);
    end
end
endtask


// ============================================================
// Sync current PATTERN golden RAM into real DUT RAM
//
// 256 words = two burst writes
// wr_burst = 7 => 2^7 = 128 words per burst
//
// This task is called ONLY for the first op set (set_idx == 0) of each
// RAM pattern, to load the original patXX file data into the empty DUT RAM.
// For later op sets the DUT carries its own write-back forward, so PATTERN
// does not force the RAM again.
// ============================================================
task automatic preload_dut_ram_from_current_golden_task(input int rid, input int sid);
    int a;
begin
    for (a = 0; a < `RAM_DEPTH; a = a + 1) begin
        dut_ram_word[a] = pack_mtx4(golden_ram[a]);
    end

    if (`DEBUG_EN) begin
        $display("[DUT RAM SYNC] PATTERN=%0d OP_SET=%0d word0=%h",
                 rid, sid, dut_ram_word[0]);
    end

    preload_dut_ram_by_burst_write_task(rid, sid);
end
endtask


task automatic preload_dut_ram_by_burst_write_task(input int rid, input int sid);
begin
    // Initialize module-level static drivers.
    tb_rd_en_drv    = 1'b0;
    tb_rd_addr_drv  = 8'd0;
    tb_rd_burst_drv = 3'd0;

    tb_wr_en_drv    = 1'b0;
    tb_wr_addr_drv  = 8'd0;
    tb_wr_burst_drv = 3'd0;
    tb_wr_data_drv  = 256'd0;

    // Take over CA -> RAM interface temporarily.
    // Because force RHS is static driver signal, this avoids VCS
    // automatic-variable force errors.
    force `TB_RD_EN    = tb_rd_en_drv;
    force `TB_RD_ADDR  = tb_rd_addr_drv;
    force `TB_RD_BURST = tb_rd_burst_drv;

    force `TB_WR_EN    = tb_wr_en_drv;
    force `TB_WR_ADDR  = tb_wr_addr_drv;
    force `TB_WR_BURST = tb_wr_burst_drv;
    force `TB_WR_DATA  = tb_wr_data_drv;

    repeat (2) @(posedge clk);

    // word 0 ~ 127
    ram_burst_write_128_task(8'd0);

    // word 128 ~ 255
    ram_burst_write_128_task(8'd128);

    tb_wr_en_drv    = 1'b0;
    tb_wr_addr_drv  = 8'd0;
    tb_wr_burst_drv = 3'd0;
    tb_wr_data_drv  = 256'd0;

    repeat (2) @(posedge clk);

    // Release RAM interface back to CA.
    release `TB_RD_EN;
    release `TB_RD_ADDR;
    release `TB_RD_BURST;

    release `TB_WR_EN;
    release `TB_WR_ADDR;
    release `TB_WR_BURST;
    release `TB_WR_DATA;

    repeat (2) @(posedge clk);

    if (`DEBUG_EN) begin
        $display("[DUT RAM SYNC DONE] PATTERN=%0d OP_SET=%0d", rid, sid);
    end
end
endtask


task automatic ram_burst_write_128_task(input logic [7:0] start_addr);
    int wait_cnt;
    int i;
    int base_addr;
begin
    base_addr = start_addr;
    wait_cnt  = 0;

    // Wait until RAM can accept write command.
    // Drive command/data at posedge; RAM itself is negedge-triggered.
    while (`TB_WR_READY !== 1'b1) begin
        @(posedge clk);
        wait_cnt = wait_cnt + 1;

        if (wait_cnt > MAX_WAIT) begin
            YOU_FAIL_TASK();
            $display("============================================================");
            $display(" Timeout while waiting wr_ready during RAM sync.");
            $display(" start_addr = %0d", base_addr);
            $display("============================================================");
            repeat (3) @(negedge clk);
            $finish;
        end
    end

    // Step 1: wr_ready=1, pull wr_en and give wr_addr/wr_burst.
    // Also put first data word on wr_data.
    @(posedge clk);
    tb_wr_addr_drv  = start_addr;
    tb_wr_burst_drv = 3'd7;
    tb_wr_data_drv  = dut_ram_word[base_addr];
    tb_wr_en_drv    = 1'b1;

    @(posedge clk);
    tb_wr_en_drv    = 1'b0;

    // Step 2: hold first wr_data until wr_valid=1.
    wait_cnt = 0;
    while (`TB_WR_VALID !== 1'b1) begin
        @(posedge clk);
        wait_cnt = wait_cnt + 1;

        if (wait_cnt > MAX_WAIT) begin
            YOU_FAIL_TASK();
            $display("======================================================================================================================");
            $display(" Timeout while waiting wr_valid during RAM sync.");
            $display(" start_addr = %0d", base_addr);
            $display(" first data = %h", dut_ram_word[base_addr]);
            $display("======================================================================================================================");
            repeat (3) @(negedge clk);
            $finish;
        end
    end

    // After wr_valid=1, switch to next write data every positive edge.
    // Data is updated at posedge and sampled by RAM at following negedge.
    for (i = 1; i < 128; i = i + 1) begin
        tb_wr_data_drv = dut_ram_word[base_addr + i];
        @(posedge clk);
    end

    // Clean command/data after the burst.
    tb_wr_addr_drv  = 8'd0;
    tb_wr_burst_drv = 3'd0;
    tb_wr_data_drv  = 256'd0;

    repeat (2) @(posedge clk);

    if (`DEBUG_EN) begin
        $display("[BURST WRITE] start_addr=%0d end_addr=%0d done",
                 base_addr, base_addr + 127);
    end
end
endtask


// ============================================================
// Random operation set
// ============================================================
task automatic random_op_set_task(input int sid);
begin
    // First four sets cover op = 0,1,2,3.
    // Remaining sets are random.
    if (sid < 4) cur_op = sid[1:0];
    else         cur_op = $urandom_range(0, 3);

    cur_act = $urandom_range(0, 3);

    random_mtx4_task(param_q);
    random_mtx4_task(param_k);
    random_mtx4_task(param_v);

    if (`DEBUG_EN) begin
        $display("[SET %0d] op=%0d act=%0d", sid, cur_op, cur_act);
    end
end
endtask


task automatic random_mtx4_task(output mtx_t m);
    int i;
    int j;
begin
    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            m[i][j] = rand_s4();
        end
    end
end
endtask


function automatic int signed rand_s4();
    int r;
begin
    r = $urandom_range(0, 15);

    if (r >= 8) rand_s4 = r - 16;
    else        rand_s4 = r;
end
endfunction


// ============================================================
// Send operation set
// FFN / Conv: in_valid high 1 cycle
// Attention: in_valid high 3 cycles, Q -> K -> V
// ============================================================
task automatic send_op_set_task(
    input logic [1:0] op_i,
    input logic [1:0] act_i
);
begin
    @(negedge clk);
    in_valid = 1'b1;
    op       = op_i;
    act      = act_i;
    param    = pack_mtx4(param_q);

    @(negedge clk);

    if (op_i == 2'b10 || op_i == 2'b11) begin
        in_valid = 1'b1;
        op       = op_i;
        act      = act_i;
        param    = pack_mtx4(param_k);

        @(negedge clk);

        in_valid = 1'b1;
        op       = op_i;
        act      = act_i;
        param    = pack_mtx4(param_v);

        @(negedge clk);
    end

    in_valid = 1'b0;
    op       = 2'd0;
    act      = 2'd0;
    param    = 256'd0;
end
endtask


// ============================================================
// Golden model
// ============================================================
task automatic build_golden_task(
    input logic [1:0] op_i,
    input logic [1:0] act_i
);
    int a;
    mtx_t comp_mtx;
    mtx_t act_mtx;
    mtx_t q_mtx;
begin
    for (a = 0; a < `RAM_DEPTH; a = a + 1) begin
        case (op_i)
            2'b00: comp_mtx = ffn_func(golden_ram[a], param_q);
            2'b01: comp_mtx = conv_func(golden_ram[a], param_q);
            2'b10: comp_mtx = attn_func(golden_ram[a], param_q, param_k, param_v, 1'b0);
            2'b11: comp_mtx = attn_func(golden_ram[a], param_q, param_k, param_v, 1'b1);
            default: comp_mtx = zero_mtx_func();
        endcase

        act_mtx = post_act_func(comp_mtx, act_i);
        q_mtx   = quantize_pot_func(act_mtx);

        golden_ram[a] = q_mtx;
        golden_out[a] = pack_last_token(q_mtx);
    end
end
endtask


// ============================================================
// Computation: FFN
// output[i][j] = sum input[i][k] * weight[k][j]
// ============================================================
function automatic mtx_t ffn_func(input mtx_t in_mtx, input mtx_t weight);
    mtx_t out_mtx;
    int i;
    int j;
    int k;
    int signed acc;
begin
    out_mtx = zero_mtx_func();

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            acc = 0;

            for (k = 0; k < N; k = k + 1) begin
                acc = acc + in_mtx[i][k] * weight[k][j];
            end

            out_mtx[i][j] = acc;
        end
    end

    return out_mtx;
end
endfunction


// ============================================================
// Computation: Convolution
// kernel size = 3x3, zero padding = 1, stride = 1
// param_q[0:2][0:2] is used as kernel
// ============================================================
function automatic mtx_t conv_func(input mtx_t in_mtx, input mtx_t kernel);
    mtx_t out_mtx;
    int i;
    int j;
    int ki;
    int kj;
    int ii;
    int jj;
    int signed acc;
begin
    out_mtx = zero_mtx_func();

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            acc = 0;

            for (ki = 0; ki < 3; ki = ki + 1) begin
                for (kj = 0; kj < 3; kj = kj + 1) begin
                    ii = i + ki - 1;
                    jj = j + kj - 1;

                    if (ii >= 0 && ii < N && jj >= 0 && jj < N) begin
                        // Kernel is packed as 9 contiguous nibbles (raster MSB->LSB),
                        // so tap (ki*3+kj) maps linearly into the 8-wide param matrix
                        // to match CA (get_s4(param, ki*3+kj)).
                        acc = acc + in_mtx[ii][jj] * kernel[(ki*3 + kj) / N][(ki*3 + kj) % N];
                    end
                end
            end

            out_mtx[i][j] = acc;
        end
    end

    return out_mtx;
end
endfunction


// ============================================================
// Computation: Single / Multi-head Attention
// Step 1: Q/K/V = Input * Wq/Wk/Wv
// Step 2: quantize Q/K/V to signed 4-bit
// Step 3: score = Q * K^T
// Step 4: score activation
// Step 5: output = partial * V
// ============================================================
function automatic mtx_t attn_func(
    input mtx_t in_mtx,
    input mtx_t wq,
    input mtx_t wk,
    input mtx_t wv,
    input bit multi_head
);
    mtx_t q_raw;
    mtx_t k_raw;
    mtx_t v_raw;
    mtx_t q_mtx;
    mtx_t k_mtx;
    mtx_t v_mtx;
    mtx_t score_1;
    mtx_t score_2;
    mtx_t part_1;
    mtx_t part_2;
    mtx_t ctx;

    int i;
    int j;
    int k;
    int signed acc;
begin
    q_raw = ffn_func(in_mtx, wq);
    k_raw = ffn_func(in_mtx, wk);
    v_raw = ffn_func(in_mtx, wv);

    q_mtx = quantize_pot_func(q_raw);
    k_mtx = quantize_pot_func(k_raw);
    v_mtx = quantize_pot_func(v_raw);

    score_1 = zero_mtx_func();
    score_2 = zero_mtx_func();
    ctx     = zero_mtx_func();

    if (!multi_head) begin
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                acc = 0;

                for (k = 0; k < N; k = k + 1) begin
                    acc = acc + q_mtx[i][k] * k_mtx[j][k];
                end

                score_1[i][j] = acc;
            end
        end

        part_1 = attn_act_func(score_1);

        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                acc = 0;

                for (k = 0; k < N; k = k + 1) begin
                    acc = acc + part_1[i][k] * v_mtx[k][j];
                end

                ctx[i][j] = acc;
            end
        end
    end
    else begin
        // Head 1: Q/K column 0~3
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                acc = 0;

                for (k = 0; k < 4; k = k + 1) begin
                    acc = acc + q_mtx[i][k] * k_mtx[j][k];
                end

                score_1[i][j] = acc;
            end
        end

        // Head 2: Q/K column 4~7
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                acc = 0;

                for (k = 4; k < 8; k = k + 1) begin
                    acc = acc + q_mtx[i][k] * k_mtx[j][k];
                end

                score_2[i][j] = acc;
            end
        end

        part_1 = attn_act_func(score_1);
        part_2 = attn_act_func(score_2);

        // Output column 0~3 uses head 1
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1) begin
                acc = 0;

                for (k = 0; k < N; k = k + 1) begin
                    acc = acc + part_1[i][k] * v_mtx[k][j];
                end

                ctx[i][j] = acc;
            end
        end

        // Output column 4~7 uses head 2
        for (i = 0; i < N; i = i + 1) begin
            for (j = 4; j < 8; j = j + 1) begin
                acc = 0;

                for (k = 0; k < N; k = k + 1) begin
                    acc = acc + part_2[i][k] * v_mtx[k][j];
                end

                ctx[i][j] = acc;
            end
        end
    end

    return ctx;
end
endfunction


// ============================================================
// Attention score activation
// if x >= 0: x
// else: x / 4, truncate toward zero
// ============================================================
function automatic mtx_t attn_act_func(input mtx_t in_mtx);
    mtx_t out_mtx;
    int i;
    int j;
begin
    out_mtx = zero_mtx_func();

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            if (in_mtx[i][j] >= 0) out_mtx[i][j] = in_mtx[i][j];
            else                   out_mtx[i][j] = in_mtx[i][j] >>> 2;  // CA uses arithmetic shift (floor)
        end
    end

    return out_mtx;
end
endfunction


// ============================================================
// Post activation
// act 00: ReLU
// act 01: RAT
// act 10: CAT
// act 11: BAT
// ============================================================
function automatic mtx_t post_act_func(input mtx_t in_mtx, input logic [1:0] act_i);
    mtx_t out_mtx;
    int i;
    int j;
    int bi;
    int bj;
    int ii;
    int jj;
    int signed sum;
    int signed threshold;
begin
    out_mtx = zero_mtx_func();

    case (act_i)
        2'b00: begin
            // ReLU
            for (i = 0; i < N; i = i + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    if (in_mtx[i][j] >= 0) out_mtx[i][j] = in_mtx[i][j];
                    else                   out_mtx[i][j] = 0;
                end
            end
        end

        2'b01: begin
            // RAT: threshold = row average
            for (i = 0; i < N; i = i + 1) begin
                sum = 0;

                for (j = 0; j < N; j = j + 1) begin
                    sum = sum + in_mtx[i][j];
                end

                threshold = sum >>> 3;

                for (j = 0; j < N; j = j + 1) begin
                    if (in_mtx[i][j] >= threshold) begin
                        out_mtx[i][j] = in_mtx[i][j];
                    end
                    else begin
                        // CA uses arithmetic shift right (floor), not truncate-toward-zero.
                        out_mtx[i][j] = in_mtx[i][j] >>> 3;
                    end
                end
            end
        end

        2'b10: begin
            // CAT: threshold = column average
            for (j = 0; j < N; j = j + 1) begin
                sum = 0;

                for (i = 0; i < N; i = i + 1) begin
                    sum = sum + in_mtx[i][j];
                end

                threshold = sum >>> 3;

                for (i = 0; i < N; i = i + 1) begin
                    if (in_mtx[i][j] >= threshold) begin
                        out_mtx[i][j] = in_mtx[i][j];
                    end
                    else begin
                        // CA uses arithmetic shift right (floor), not truncate-toward-zero.
                        out_mtx[i][j] = in_mtx[i][j] >>> 3;
                    end
                end
            end
        end

        default: begin
            // BAT: block size = 4x4, threshold = block average
            for (bi = 0; bi < N; bi = bi + 4) begin
                for (bj = 0; bj < N; bj = bj + 4) begin
                    sum = 0;

                    for (ii = bi; ii < bi + 4; ii = ii + 1) begin
                        for (jj = bj; jj < bj + 4; jj = jj + 1) begin
                            sum = sum + in_mtx[ii][jj];
                        end
                    end

                    threshold = sum >>> 4;

                    for (ii = bi; ii < bi + 4; ii = ii + 1) begin
                        for (jj = bj; jj < bj + 4; jj = jj + 1) begin
                            if (in_mtx[ii][jj] >= threshold) begin
                                out_mtx[ii][jj] = in_mtx[ii][jj];
                            end
                            else begin
                                // CA uses arithmetic shift right (floor), not truncate-toward-zero.
                                out_mtx[ii][jj] = in_mtx[ii][jj] >>> 3;
                            end
                        end
                    end
                end
            end
        end
    endcase

    return out_mtx;
end
endfunction


// ============================================================
// PoT Quantization
// OUT_WIDTH = signed 4-bit, range -8 ~ 7
// shift = max(floor(log2(max_abs)) - 2, 0)
// scaled = arithmetic shift right
// result = clamp(scaled, -8, 7)
// ============================================================
function automatic mtx_t quantize_pot_func(input mtx_t in_mtx);
    mtx_t out_mtx;
    int i;
    int j;
    int signed val;
    int signed scaled;
    int unsigned abs_val;
    int unsigned max_abs;
    int msb_pos;
    int shift;
begin
    out_mtx = zero_mtx_func();
    max_abs = 0;

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            val = in_mtx[i][j];

            if (val < 0) abs_val = -val;
            else         abs_val = val;

            if (abs_val > max_abs) max_abs = abs_val;
        end
    end

    shift = 0;

    if (max_abs > 0) begin
        msb_pos = floor_log2_func(max_abs);

        if (msb_pos > 2) shift = msb_pos - 2;
        else             shift = 0;
    end

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            val = in_mtx[i][j];

            if (shift == 0) scaled = val;
            else            scaled = val >>> shift;

            out_mtx[i][j] = clamp_s4_func(scaled);
        end
    end

    return out_mtx;
end
endfunction


function automatic int floor_log2_func(input int unsigned x);
    int pos;
    int unsigned y;
begin
    pos = 0;
    y = x;

    while (y > 1) begin
        y = y >> 1;
        pos = pos + 1;
    end

    return pos;
end
endfunction


function automatic int signed clamp_s4_func(input int signed x);
begin
    if (x > 7)       clamp_s4_func = 7;
    else if (x < -8) clamp_s4_func = -8;
    else             clamp_s4_func = x;
end
endfunction


// ============================================================
// Pack / unpack helpers
// RAM word format:
// MSB -> X[0][0], then raster scan, LSB -> X[7][7]
// ============================================================
function automatic mtx_t unpack_word_to_mtx(input logic [255:0] word);
    mtx_t mtx;
    logic signed [3:0] s4;
    int i;
    int j;
    int idx;
begin
    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            idx = i * N + j;
            s4 = word[255 - idx*4 -: 4];
            mtx[i][j] = s4;
        end
    end

    return mtx;
end
endfunction


function automatic logic [255:0] pack_mtx4(input mtx_t mtx);
    logic [255:0] word;
    logic signed [3:0] s4;
    int i;
    int j;
    int idx;
begin
    word = 256'd0;

    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            idx = i * N + j;
            s4 = clamp_s4_func(mtx[i][j]);
            word[255 - idx*4 -: 4] = s4;
        end
    end

    return word;
end
endfunction


function automatic logic [31:0] pack_last_token(input mtx_t mtx);
    logic [31:0] token;
    logic signed [3:0] s4;
    int j;
begin
    token = 32'd0;

    for (j = 0; j < N; j = j + 1) begin
        s4 = clamp_s4_func(mtx[7][j]);
        token[31 - j*4 -: 4] = s4;
    end

    return token;
end
endfunction


function automatic mtx_t zero_mtx_func();
    mtx_t z;
    int i;
    int j;
begin
    for (i = 0; i < N; i = i + 1) begin
        for (j = 0; j < N; j = j + 1) begin
            z[i][j] = 0;
        end
    end

    return z;
end
endfunction



// ============================================================
// Output checker + latency counter
// One operation set should generate 256 outputs.
// Output order is assumed to be addr 0 -> 255.
//
// Latency rule:
// Data 0:
//     in_valid fall -> out_valid rise
//
// Data 1~255:
//     out_valid fall -> out_valid rise + 1
//
// If out_valid keeps high continuously, next data latency = 1.
// ============================================================
task automatic check_all_outputs_task(input int rid, input int sid);
    int a;
    int word_latency;
    int opset_latency;
begin
    opset_latency = 0;

    for (a = 0; a < `RAM_DEPTH; a = a + 1) begin
        wait_one_output_task(
            rid,
            sid,
            a,
            golden_out[a],
            (a == 0),
            word_latency
        );

        opset_latency = opset_latency + word_latency;
        total_latency = total_latency + word_latency;
    end

    $display("--------------------------------------------------------------------------------------------------------------------------");
    $display("\033[33mOP SET DONE:\033[0m \033[35mPATTERN NO. %2d, OP SET NO. %1d \033[0m| op = %0d, act = %0d | opset latency = %0d | total latency = %0d",
             rid, sid, cur_op, cur_act, opset_latency, total_latency);
    $display("--------------------------------------------------------------------------------------------------------------------------");

    if (out_valid === 1'b1) begin
        YOU_FAIL_TASK();
        $display("======================================================================================================================");
        $display("Extra out_valid after 256 outputs.");
        $display("PATTERN NO. = %0d, OP SET NO. = %0d", rid, sid);
        $display("out_data = %h", out_data);
        $display("======================================================================================================================");
        repeat (3) @(negedge clk);
        $finish;
    end
end
endtask


task automatic wait_one_output_task(
    input int rid,
    input int sid,
    input int addr,
    input logic [31:0] golden_data,
    input bit is_first_word,
    output int word_latency
);
    int wait_cnt;
begin
    word_latency = 0;
    wait_cnt = 0;

    if (is_first_word) begin
        // First data:
        // called right after send_op_set_task() pulls in_valid low.
        // current point is treated as in_valid falling point.
        while (out_valid !== 1'b1) begin
            @(negedge clk);
            word_latency = word_latency + 1;

            if (word_latency > MAX_WAIT) begin
                YOU_FAIL_TASK();
                $display("============================================================");
                $display("Timeout: no output within %0d cycles.", MAX_WAIT);
                $display("PATTERN NO. = %0d, OP SET NO. = %0d, Data NO. = %0d",
                         rid, sid, addr);
                $display("op = %0d, act = %0d", cur_op, cur_act);
                $display("============================================================");
                repeat (3) @(negedge clk);
                $finish;
            end
        end
    end
    else begin
        // Data 1~255:
        // if out_valid is still high, it means continuous output.
        // latency = 1.
        if (out_valid === 1'b1) begin
            word_latency = 1;
        end
        else begin
            wait_cnt = 0;

            while (out_valid !== 1'b1) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;

                if (wait_cnt > MAX_WAIT) begin
                    YOU_FAIL_TASK();
                    $display("============================================================");
                    $display("Timeout: no output within %0d cycles.", MAX_WAIT);
                    $display("PATTERN NO. = %0d, OP SET NO. = %0d, Data NO. = %0d",
                             rid, sid, addr);
                    $display("op = %0d, act = %0d", cur_op, cur_act);
                    $display("============================================================");
                    repeat (3) @(negedge clk);
                    $finish;
                end
            end

            word_latency = wait_cnt + 1;
        end
    end

    if (out_data !== golden_data) begin
        YOU_FAIL_TASK();
        $display("============================================================");
        $display("Output mismatch.");
        $display("PATTERN NO. = %0d", rid);
        $display("OP SET NO.  = %0d", sid);
        $display("Data NO.    = %0d", addr);
        $display("op          = %0d", cur_op);
        $display("act         = %0d", cur_act);
        $display("DUT    out_data = %h", out_data);
        $display("Golden out_data = %h", golden_data);
        $display("============================================================");
        $finish;
    end

    // Print once every passed word.
    $display("\033[32mPASS\033[m \033[36mPATTERN NO. %2d, OP SET NO. %1d, Data NO. %3d\033[m | latency = %3d",
             rid, sid, addr, word_latency);

    @(negedge clk);
end
endtask



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