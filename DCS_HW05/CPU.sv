//================================================================
// Module      : CPU
// Description : NYCU DCS HW05 - fixed-latency in-order CPU
// Features    : Q1.15 fixed-point, registered handshake, pipelined MULT/DIV
//================================================================
module CPU(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [31:0] instruction,
    output logic        in_ready,
    output logic        out_valid,
    output logic [1:0]  bad_ins,
    output logic [15:0] out_0,
    output logic [15:0] out_1,
    output logic [15:0] out_2,
    output logic [15:0] out_3,
    output logic [15:0] out_4,
    output logic [15:0] out_5
);

//================================================================
// 1. Parameters
//================================================================
localparam logic [5:0] OP_RTYPE = 6'b000000;
localparam logic [5:0] OP_ADDI  = 6'b001000;
localparam logic [5:0] OP_ORI   = 6'b001101;

localparam logic [5:0] FUNC_ADD  = 6'b100000;
localparam logic [5:0] FUNC_MULT = 6'b011000;
localparam logic [5:0] FUNC_OR   = 6'b011001;
localparam logic [5:0] FUNC_SLA  = 6'b000000;
localparam logic [5:0] FUNC_SRA  = 6'b000010;
localparam logic [5:0] FUNC_DIV  = 6'b110001;

localparam int FIFO_DEPTH      = 4;
localparam int FIFO_COUNT_W    = 3;
localparam logic [FIFO_COUNT_W-1:0] FIFO_READY_LIMIT = 3'd1;
localparam int PIPE_DEPTH      = 7;
localparam int PIPE_LAST       = PIPE_DEPTH - 1;
localparam int DIV_FINAL_STAGE = PIPE_DEPTH;
localparam int TAG_W           = 8;

//================================================================
// 2. Internal Registers & Wires
//================================================================
logic [31:0] fifo_ins_r [0:FIFO_DEPTH-1];
logic [FIFO_COUNT_W-1:0] fifo_count_r;
logic [FIFO_COUNT_W-1:0] fifo_count_after_issue;
logic [FIFO_COUNT_W-1:0] fifo_push_idx;
logic                    fifo_has_ins;

logic signed [15:0] core_regs_cs [0:5];
logic signed [15:0] core_regs_ns [0:5];
logic signed [15:0] issue_regs_r [0:5];
logic               pending_r [0:5];
logic [TAG_W-1:0]   reg_tag_r [0:5];
logic [TAG_W-1:0]   tag_counter_r;
logic [TAG_W-1:0]   issue_tag;

logic out_valid_r;
logic [1:0] bad_ins_r;
logic [15:0] out_0_r, out_1_r, out_2_r, out_3_r, out_4_r, out_5_r;

logic                    pipe_valid_r [0:PIPE_LAST];
logic [1:0]              pipe_bad_r [0:PIPE_LAST];
logic                    pipe_write_en_r [0:PIPE_LAST];
logic [2:0]              pipe_write_idx_r [0:PIPE_LAST];
logic [TAG_W-1:0]        pipe_tag_r [0:PIPE_LAST];
logic                    pipe_is_mult_r [0:PIPE_LAST];
logic                    pipe_is_div_r [0:PIPE_LAST];
logic signed [15:0]      pipe_result_r [0:PIPE_LAST];
logic signed [15:0]      pipe_mult_rs_r;
logic signed [15:0]      pipe_mult_rt_r;
logic signed [15:0]      pipe_div_a_raw_r;
logic signed [15:0]      pipe_div_b_raw_r;
logic [15:0]             pipe_div_b_r [0:PIPE_LAST];
logic [15:0]             pipe_div_rem_r [0:PIPE_LAST];
logic [14:0]             pipe_div_quo_r [0:PIPE_LAST];
logic                    pipe_div_sign_r [0:PIPE_LAST];
logic                    pipe_div_overflow_r [0:PIPE_LAST];

logic [31:0] issue_ins;
logic [5:0]  issue_opcode, issue_funct;
logic [4:0]  issue_rs, issue_rt, issue_rd, issue_shamt;
logic signed [15:0] issue_imm;
logic [2:0] issue_rs_idx, issue_rt_idx, issue_rd_idx;
logic       issue_rs_valid, issue_rt_valid, issue_rd_valid;
logic       issue_is_r_type, issue_is_i_type;
logic       issue_is_add, issue_is_mult, issue_is_or;
logic       issue_is_sla, issue_is_sra, issue_is_div;
logic       issue_supported, issue_addr_valid;
logic       issue_read_rs, issue_read_rt;
logic       issue_source_stall;
logic       issue_fire;
logic       issue_new_slow_pending;
logic       accept_ins;
logic       in_ready_n;

logic signed [15:0] issue_rs_value, issue_rt_value;
logic signed [15:0] issue_fast_result;
logic               issue_write_en;
logic [2:0]         issue_write_idx;
logic [1:0]         issue_bad;

logic commit_valid;
logic [1:0] commit_bad;
logic commit_write_en;
logic [2:0] commit_write_idx;
logic signed [15:0] commit_result;

logic                    div_tail_valid;
logic [18:0]             div_tail_pair;
logic [14:0]             div_tail_quo_next;
logic                    div_tail_overflow_next;
logic signed [15:0]      div_tail_result;

//================================================================
// 3. Helper Functions
//================================================================
function automatic void map_reg(input logic [4:0] addr, output logic [2:0] idx, output logic valid);
    valid = 1'b1;
    case (addr)
        5'b10001: idx = 3'd0;
        5'b10010: idx = 3'd1;
        5'b01000: idx = 3'd2;
        5'b10111: idx = 3'd3;
        5'b11111: idx = 3'd4;
        5'b10000: idx = 3'd5;
        default: begin
            idx   = 3'd0;
            valid = 1'b0;
        end
    endcase
endfunction

function automatic logic [15:0] abs16(input logic signed [15:0] value);
    if (value[15]) abs16 = ~value + 16'd1;
    else           abs16 = value;
endfunction

function automatic logic [1:0] msb4_pos(input logic [3:0] v);
    begin
        unique case (v)
            4'h0, 4'h1:                         msb4_pos = 2'd0;
            4'h2, 4'h3:                         msb4_pos = 2'd1;
            4'h4, 4'h5, 4'h6, 4'h7:             msb4_pos = 2'd2;
            default:                            msb4_pos = 2'd3; // 8~F
        endcase
    end
endfunction

function automatic logic [3:0] msb_pos(input logic [15:0] value);
    logic [3:0] nz;
    logic [1:0] p0, p1, p2, p3;
    logic s0, s1, s2, s3;

    begin
        p0 = msb4_pos(value[3:0]);
        p1 = msb4_pos(value[7:4]);
        p2 = msb4_pos(value[11:8]);
        p3 = msb4_pos(value[15:12]);

        nz = {
            |value[15:12],
            |value[11:8],
            |value[7:4],
            |value[3:0]
        };

        s3 =  nz[3];
        s2 = ~nz[3] &  nz[2];
        s1 = ~nz[3] & ~nz[2] &  nz[1];
        s0 = ~nz[3] & ~nz[2] & ~nz[1] & nz[0];

        msb_pos = ({4{s3}} & {2'd3, p3}) |
                  ({4{s2}} & {2'd2, p2}) |
                  ({4{s1}} & {2'd1, p1}) |
                  ({4{s0}} & {2'd0, p0});
    end
endfunction


function automatic logic [16:0] div_step(input logic [15:0] rem_i, input logic [15:0] divisor_i);
    logic [16:0] shifted;
    logic [16:0] subtracted;
    begin
        shifted = {1'b0, rem_i} << 1;
        if (shifted >= {1'b0, divisor_i}) begin
            subtracted = shifted - {1'b0, divisor_i};
            div_step   = {1'b1, subtracted[15:0]};
        end else begin
            div_step   = {1'b0, shifted[15:0]};
        end
    end
endfunction

function automatic logic [18:0] div_three_steps(input logic [15:0] rem_i, input logic [15:0] divisor_i);
    logic [16:0] step0;
    logic [16:0] step1;
    logic [16:0] step2;
    begin
        step0 = div_step(rem_i, divisor_i);
        step1 = div_step(step0[15:0], divisor_i);
        step2 = div_step(step1[15:0], divisor_i);
        div_three_steps = {step0[16], step1[16], step2[16], step2[15:0]};
    end
endfunction

function automatic logic signed [15:0] mult_q15(input logic signed [15:0] a, input logic signed [15:0] b);
    logic signed [31:0] product;
    begin
        product  = a * b;
        mult_q15 = product[30:15];
    end
endfunction

function automatic logic signed [15:0] div_apply_sign(
    input logic        overflow_i,
    input logic        sign_i,
    input logic [14:0] quo_i
);
    begin
        if (overflow_i) begin
            div_apply_sign = 16'sh8000;
        end else if (sign_i) begin
            div_apply_sign = $signed((~{1'b0, quo_i}) + 16'd1);
        end else begin
            div_apply_sign = $signed({1'b0, quo_i});
        end
    end
endfunction

//================================================================
// 4. Issue Decode
//================================================================
assign fifo_has_ins = (fifo_count_r != {FIFO_COUNT_W{1'b0}});
assign issue_ins    = fifo_ins_r[0];

assign issue_opcode = issue_ins[31:26];
assign issue_rs     = issue_ins[25:21];
assign issue_rt     = issue_ins[20:16];
assign issue_rd     = issue_ins[15:11];
assign issue_shamt  = issue_ins[10:6];
assign issue_funct  = issue_ins[5:0];
assign issue_imm    = issue_ins[15:0];

always_comb begin
    map_reg(issue_rs, issue_rs_idx, issue_rs_valid);
    map_reg(issue_rt, issue_rt_idx, issue_rt_valid);
    map_reg(issue_rd, issue_rd_idx, issue_rd_valid);
end

assign issue_is_r_type = (issue_opcode == OP_RTYPE);
assign issue_is_i_type = (issue_opcode == OP_ADDI) || (issue_opcode == OP_ORI);
assign issue_is_add    = issue_is_r_type && (issue_funct == FUNC_ADD);
assign issue_is_mult   = issue_is_r_type && (issue_funct == FUNC_MULT);
assign issue_is_or     = issue_is_r_type && (issue_funct == FUNC_OR);
assign issue_is_sla    = issue_is_r_type && (issue_funct == FUNC_SLA);
assign issue_is_sra    = issue_is_r_type && (issue_funct == FUNC_SRA);
assign issue_is_div    = issue_is_r_type && (issue_funct == FUNC_DIV);

always_comb begin
    issue_supported  = 1'b0;
    issue_addr_valid = 1'b0;
    issue_read_rs    = 1'b0;
    issue_read_rt    = 1'b0;

    case (issue_opcode)
        OP_RTYPE: begin
            issue_addr_valid = issue_rs_valid && issue_rt_valid && issue_rd_valid;
            case (issue_funct)
                FUNC_ADD, FUNC_MULT, FUNC_OR, FUNC_DIV: begin
                    issue_supported = 1'b1;
                    issue_read_rs   = 1'b1;
                    issue_read_rt   = 1'b1;
                end
                FUNC_SLA, FUNC_SRA: begin
                    issue_supported = 1'b1;
                    issue_read_rt   = 1'b1;
                end
                default: begin
                    issue_supported = 1'b0;
                end
            endcase
        end
        OP_ADDI, OP_ORI: begin
            issue_supported  = 1'b1;
            issue_addr_valid = issue_rs_valid && issue_rt_valid;
            issue_read_rs    = 1'b1;
        end
        default: begin
            issue_supported = 1'b0;
        end
    endcase
end

assign issue_source_stall = fifo_has_ins && issue_supported && issue_addr_valid &&
                            ((issue_read_rs && issue_rs_valid && pending_r[issue_rs_idx]) ||
                             (issue_read_rt && issue_rt_valid && pending_r[issue_rt_idx]));
assign issue_fire = fifo_has_ins && !issue_source_stall;
assign issue_new_slow_pending = issue_fire && issue_bad == 2'b00 && issue_write_en &&
                                (issue_is_mult || issue_is_div);
assign accept_ins = in_valid && in_ready;

assign issue_rs_value = issue_rs_valid ? issue_regs_r[issue_rs_idx] : 16'sd0;
assign issue_rt_value = issue_rt_valid ? issue_regs_r[issue_rt_idx] : 16'sd0;

always_comb begin
    issue_write_en     = 1'b0;
    issue_write_idx    = 3'd0;
    issue_bad          = 2'b00;
    issue_fast_result  = 16'sd0;

    if (issue_is_r_type && (!issue_rs_valid || !issue_rt_valid || !issue_rd_valid)) begin
        issue_bad = 2'b01;
    end else if (issue_is_i_type && (!issue_rs_valid || !issue_rt_valid)) begin
        issue_bad = 2'b01;
    end else begin
        case (issue_opcode)
            OP_RTYPE: begin
                issue_write_idx = issue_rd_idx;
                case (issue_funct)
                    FUNC_ADD: begin
                        issue_fast_result = issue_rs_value + issue_rt_value;
                        issue_write_en    = 1'b1;
                    end
                    FUNC_MULT: begin
                        issue_write_en = 1'b1;
                    end
                    FUNC_OR: begin
                        issue_fast_result = issue_rs_value | issue_rt_value;
                        issue_write_en    = 1'b1;
                    end
                    FUNC_SLA: begin
                        issue_fast_result = issue_rt_value << issue_shamt;
                        issue_write_en    = 1'b1;
                    end
                    FUNC_SRA: begin
                        issue_fast_result = issue_rt_value >>> issue_shamt;
                        issue_write_en    = 1'b1;
                    end
                    FUNC_DIV: begin
                        if (issue_rt_value == 16'sd0) begin
                            issue_bad = 2'b10;
                        end else begin
                            issue_write_en = 1'b1;
                        end
                    end
                    default: issue_bad = 2'b01;
                endcase
            end
            OP_ADDI: begin
                issue_write_idx   = issue_rt_idx;
                issue_fast_result = issue_rs_value + issue_imm;
                issue_write_en    = 1'b1;
            end
            OP_ORI: begin
                issue_write_idx   = issue_rt_idx;
                issue_fast_result = issue_rs_value | issue_imm;
                issue_write_en    = 1'b1;
            end
            default: issue_bad = 2'b01;
        endcase
    end
end

assign issue_tag = tag_counter_r + {{(TAG_W-1){1'b0}}, 1'b1};

//================================================================
// 5. Handshake, FIFO, and Commit Control
//================================================================
assign fifo_count_after_issue = fifo_count_r - {{(FIFO_COUNT_W-1){1'b0}}, issue_fire};
assign fifo_push_idx = fifo_count_after_issue;
assign in_ready_n = (fifo_count_after_issue < FIFO_READY_LIMIT);

assign commit_valid     = pipe_valid_r[PIPE_LAST];
assign commit_bad       = pipe_bad_r[PIPE_LAST];
assign commit_write_en  = pipe_write_en_r[PIPE_LAST];
assign commit_write_idx = pipe_write_idx_r[PIPE_LAST];
assign commit_result    = pipe_result_r[PIPE_LAST];

always_comb begin
    div_tail_pair = div_three_steps(pipe_div_rem_r[PIPE_LAST-1], pipe_div_b_r[PIPE_LAST-1]);
    div_tail_quo_next = (pipe_div_quo_r[PIPE_LAST-1] << 3) |
                        {12'd0, div_tail_pair[18], div_tail_pair[17], div_tail_pair[16]};
    div_tail_overflow_next = pipe_div_overflow_r[PIPE_LAST-1];
    div_tail_result = div_apply_sign(
        div_tail_overflow_next,
        pipe_div_sign_r[PIPE_LAST-1],
        div_tail_quo_next
    );
end

assign div_tail_valid = pipe_valid_r[PIPE_LAST-1] &&
                        pipe_bad_r[PIPE_LAST-1] == 2'b00 &&
                        pipe_write_en_r[PIPE_LAST-1] &&
                        pipe_is_div_r[PIPE_LAST-1];

always_comb begin
    core_regs_ns = core_regs_cs;

    if (commit_valid && commit_bad == 2'b00 && commit_write_en) begin
        core_regs_ns[commit_write_idx] = commit_result;
    end
end

//================================================================
// 6. Sequential Logic
//================================================================
always_ff @(posedge clk or negedge rst_n) begin
    logic signed [15:0] mult_ready_result;
    logic signed [15:0] div_ready_result;
    logic [2:0] mult_ready_idx;
    logic [2:0] div_ready_idx;

    if (!rst_n) begin
        fifo_count_r <= {FIFO_COUNT_W{1'b0}};
        tag_counter_r <= {TAG_W{1'b0}};
        in_ready <= 1'b0;
        out_valid_r <= 1'b0;
        bad_ins_r <= 2'b00;
        out_0_r <= 16'd0;
        out_1_r <= 16'd0;
        out_2_r <= 16'd0;
        out_3_r <= 16'd0;
        out_4_r <= 16'd0;
        out_5_r <= 16'd0;

        core_regs_cs <= '{default: 16'sd0};
        issue_regs_r <= '{default: 16'sd0};
        pending_r <= '{default: 1'b0};
        pipe_valid_r <= '{default: 1'b0};

    end else begin
        in_ready <= in_ready_n;
        out_valid_r <= commit_valid;
        bad_ins_r <= commit_valid ? commit_bad : 2'b00;
        core_regs_cs <= core_regs_ns;

        if (commit_valid) begin
            out_0_r <= core_regs_ns[0];
            out_1_r <= core_regs_ns[1];
            out_2_r <= core_regs_ns[2];
            out_3_r <= core_regs_ns[3];
            out_4_r <= core_regs_ns[4];
            out_5_r <= core_regs_ns[5];
        end

        if (pipe_valid_r[0] && pipe_bad_r[0] == 2'b00 &&
            pipe_write_en_r[0] && pipe_is_mult_r[0]) begin
            mult_ready_idx = pipe_write_idx_r[0];
            mult_ready_result = mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
            if (pending_r[mult_ready_idx] &&
                reg_tag_r[mult_ready_idx] == pipe_tag_r[0]) begin
                issue_regs_r[mult_ready_idx] <= mult_ready_result;
                pending_r[mult_ready_idx] <= 1'b0;
            end
        end

        if (pipe_valid_r[DIV_FINAL_STAGE-1] &&
            pipe_bad_r[DIV_FINAL_STAGE-1] == 2'b00 &&
            pipe_write_en_r[DIV_FINAL_STAGE-1] &&
            pipe_is_div_r[DIV_FINAL_STAGE-1]) begin
            div_ready_idx = pipe_write_idx_r[DIV_FINAL_STAGE-1];
            div_ready_result = pipe_result_r[DIV_FINAL_STAGE-1];
            if (pending_r[div_ready_idx] &&
                reg_tag_r[div_ready_idx] == pipe_tag_r[DIV_FINAL_STAGE-1]) begin
                issue_regs_r[div_ready_idx] <= div_ready_result;
                pending_r[div_ready_idx] <= 1'b0;
            end
        end

        if (div_tail_valid) begin
            div_ready_idx = pipe_write_idx_r[PIPE_LAST-1];
            div_ready_result = div_tail_result;
            if (pending_r[div_ready_idx] &&
                reg_tag_r[div_ready_idx] == pipe_tag_r[PIPE_LAST-1]) begin
                issue_regs_r[div_ready_idx] <= div_ready_result;
                pending_r[div_ready_idx] <= 1'b0;
            end
        end

        if (issue_fire && issue_bad == 2'b00 && issue_write_en) begin
            if (issue_is_mult || issue_is_div) begin
                pending_r[issue_write_idx] <= 1'b1;
            end else begin
                issue_regs_r[issue_write_idx] <= issue_fast_result;
                pending_r[issue_write_idx] <= 1'b0;
            end
        end

        if (issue_fire) begin
            tag_counter_r <= issue_tag;
        end

        pipe_valid_r[6] <= pipe_valid_r[5];
        pipe_valid_r[5] <= pipe_valid_r[4];
        pipe_valid_r[4] <= pipe_valid_r[3];
        pipe_valid_r[3] <= pipe_valid_r[2];
        pipe_valid_r[2] <= pipe_valid_r[1];
        pipe_valid_r[1] <= pipe_valid_r[0];

        pipe_valid_r[0] <= issue_fire;

        fifo_count_r <= fifo_count_r + {{(FIFO_COUNT_W-1){1'b0}}, accept_ins} -
                        {{(FIFO_COUNT_W-1){1'b0}}, issue_fire};
    end
end

always_ff @(posedge clk) begin
    logic [18:0] div_pair;
    logic [14:0] div_quo_next;
    logic        div_overflow_next;
    logic [15:0] div_init_abs_a;
    logic [15:0] div_init_abs_b;
    logic [3:0]  div_init_pos_a;
    logic [3:0]  div_init_pos_b;
    logic [4:0]  div_init_shift_n;
    logic signed [15:0] div_init_shifted;

    if (issue_fire && issue_bad == 2'b00 && issue_write_en) begin
        reg_tag_r[issue_write_idx] <= issue_tag;
    end

    pipe_bad_r[6] <= pipe_bad_r[5];
    pipe_bad_r[5] <= pipe_bad_r[4];
    pipe_bad_r[4] <= pipe_bad_r[3];
    pipe_bad_r[3] <= pipe_bad_r[2];
    pipe_bad_r[2] <= pipe_bad_r[1];
    pipe_bad_r[1] <= pipe_bad_r[0];

    pipe_write_en_r[6] <= pipe_write_en_r[5];
    pipe_write_en_r[5] <= pipe_write_en_r[4];
    pipe_write_en_r[4] <= pipe_write_en_r[3];
    pipe_write_en_r[3] <= pipe_write_en_r[2];
    pipe_write_en_r[2] <= pipe_write_en_r[1];
    pipe_write_en_r[1] <= pipe_write_en_r[0];

    pipe_write_idx_r[6] <= pipe_write_idx_r[5];
    pipe_write_idx_r[5] <= pipe_write_idx_r[4];
    pipe_write_idx_r[4] <= pipe_write_idx_r[3];
    pipe_write_idx_r[3] <= pipe_write_idx_r[2];
    pipe_write_idx_r[2] <= pipe_write_idx_r[1];
    pipe_write_idx_r[1] <= pipe_write_idx_r[0];

    pipe_tag_r[6] <= pipe_tag_r[5];
    pipe_tag_r[5] <= pipe_tag_r[4];
    pipe_tag_r[4] <= pipe_tag_r[3];
    pipe_tag_r[3] <= pipe_tag_r[2];
    pipe_tag_r[2] <= pipe_tag_r[1];
    pipe_tag_r[1] <= pipe_tag_r[0];

    pipe_is_mult_r[6] <= pipe_is_mult_r[5];
    pipe_is_mult_r[5] <= pipe_is_mult_r[4];
    pipe_is_mult_r[4] <= pipe_is_mult_r[3];
    pipe_is_mult_r[3] <= pipe_is_mult_r[2];
    pipe_is_mult_r[2] <= pipe_is_mult_r[1];
    pipe_is_mult_r[1] <= pipe_is_mult_r[0];

    pipe_is_div_r[6] <= pipe_is_div_r[5];
    pipe_is_div_r[5] <= pipe_is_div_r[4];
    pipe_is_div_r[4] <= pipe_is_div_r[3];
    pipe_is_div_r[3] <= pipe_is_div_r[2];
    pipe_is_div_r[2] <= pipe_is_div_r[1];
    pipe_is_div_r[1] <= pipe_is_div_r[0];

    pipe_result_r[6] <= pipe_result_r[5];
    pipe_result_r[5] <= pipe_result_r[4];
    pipe_result_r[4] <= pipe_result_r[3];
    pipe_result_r[3] <= pipe_result_r[2];
    pipe_result_r[2] <= pipe_result_r[1];
    pipe_result_r[1] <= pipe_result_r[0];

    pipe_div_b_r[6] <= pipe_div_b_r[5];
    pipe_div_b_r[5] <= pipe_div_b_r[4];
    pipe_div_b_r[4] <= pipe_div_b_r[3];
    pipe_div_b_r[3] <= pipe_div_b_r[2];
    pipe_div_b_r[2] <= pipe_div_b_r[1];
    pipe_div_b_r[1] <= pipe_div_b_r[0];

    pipe_div_rem_r[6] <= pipe_div_rem_r[5];
    pipe_div_rem_r[5] <= pipe_div_rem_r[4];
    pipe_div_rem_r[4] <= pipe_div_rem_r[3];
    pipe_div_rem_r[3] <= pipe_div_rem_r[2];
    pipe_div_rem_r[2] <= pipe_div_rem_r[1];
    pipe_div_rem_r[1] <= pipe_div_rem_r[0];

    pipe_div_quo_r[6] <= pipe_div_quo_r[5];
    pipe_div_quo_r[5] <= pipe_div_quo_r[4];
    pipe_div_quo_r[4] <= pipe_div_quo_r[3];
    pipe_div_quo_r[3] <= pipe_div_quo_r[2];
    pipe_div_quo_r[2] <= pipe_div_quo_r[1];
    pipe_div_quo_r[1] <= pipe_div_quo_r[0];

    pipe_div_sign_r[6] <= pipe_div_sign_r[5];
    pipe_div_sign_r[5] <= pipe_div_sign_r[4];
    pipe_div_sign_r[4] <= pipe_div_sign_r[3];
    pipe_div_sign_r[3] <= pipe_div_sign_r[2];
    pipe_div_sign_r[2] <= pipe_div_sign_r[1];
    pipe_div_sign_r[1] <= pipe_div_sign_r[0];

    pipe_div_overflow_r[6] <= pipe_div_overflow_r[5];
    pipe_div_overflow_r[5] <= pipe_div_overflow_r[4];
    pipe_div_overflow_r[4] <= pipe_div_overflow_r[3];
    pipe_div_overflow_r[3] <= pipe_div_overflow_r[2];
    pipe_div_overflow_r[2] <= pipe_div_overflow_r[1];
    pipe_div_overflow_r[1] <= pipe_div_overflow_r[0];

    if (pipe_valid_r[0] && pipe_bad_r[0] == 2'b00) begin
        if (pipe_is_mult_r[0] && 1 == 1) begin
            pipe_result_r[1] <= mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
        end

        if (pipe_is_div_r[0]) begin
            div_init_abs_a = abs16(pipe_div_a_raw_r);
            div_init_abs_b = abs16(pipe_div_b_raw_r);
            div_init_pos_a = msb_pos(div_init_abs_a);
            div_init_pos_b = msb_pos(div_init_abs_b);
            div_init_shift_n = (div_init_abs_a >= div_init_abs_b) ?
                               (div_init_pos_a - div_init_pos_b + 5'd1) : 5'd0;
            div_init_shifted = pipe_div_a_raw_r >>> div_init_shift_n;

            pipe_div_b_r[1] <= div_init_abs_b;
            pipe_div_rem_r[1] <= abs16(div_init_shifted);
            pipe_div_quo_r[1] <= 15'd0;
            pipe_div_sign_r[1] <= pipe_div_a_raw_r[15] ^ pipe_div_b_raw_r[15];
            pipe_div_overflow_r[1] <= 1'b0;
        end
    end

    if (pipe_valid_r[1] && pipe_bad_r[1] == 2'b00) begin
        if (pipe_is_mult_r[1] && 2 == 1) begin
            pipe_result_r[2] <= mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
        end

        if (pipe_is_div_r[1]) begin
            div_pair = div_three_steps(pipe_div_rem_r[1], pipe_div_b_r[1]);
            div_quo_next = (pipe_div_quo_r[1] << 3) |
                           {12'd0, div_pair[18], div_pair[17], div_pair[16]};
            div_overflow_next = (pipe_div_rem_r[1] >= pipe_div_b_r[1]);
            pipe_div_rem_r[2] <= div_pair[15:0];
            pipe_div_quo_r[2] <= div_quo_next;
            pipe_div_overflow_r[2] <= div_overflow_next;
        end
    end

    if (pipe_valid_r[2] && pipe_bad_r[2] == 2'b00) begin
        if (pipe_is_mult_r[2] && 3 == 1) begin
            pipe_result_r[3] <= mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
        end

        if (pipe_is_div_r[2]) begin
            div_pair = div_three_steps(pipe_div_rem_r[2], pipe_div_b_r[2]);
            div_quo_next = (pipe_div_quo_r[2] << 3) |
                           {12'd0, div_pair[18], div_pair[17], div_pair[16]};
            div_overflow_next = pipe_div_overflow_r[2];
            pipe_div_rem_r[3] <= div_pair[15:0];
            pipe_div_quo_r[3] <= div_quo_next;
            pipe_div_overflow_r[3] <= div_overflow_next;
        end
    end

    if (pipe_valid_r[3] && pipe_bad_r[3] == 2'b00) begin
        if (pipe_is_mult_r[3] && 4 == 1) begin
            pipe_result_r[4] <= mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
        end

        if (pipe_is_div_r[3]) begin
            div_pair = div_three_steps(pipe_div_rem_r[3], pipe_div_b_r[3]);
            div_quo_next = (pipe_div_quo_r[3] << 3) |
                           {12'd0, div_pair[18], div_pair[17], div_pair[16]};
            div_overflow_next = pipe_div_overflow_r[3];
            pipe_div_rem_r[4] <= div_pair[15:0];
            pipe_div_quo_r[4] <= div_quo_next;
            pipe_div_overflow_r[4] <= div_overflow_next;
        end
    end

    if (pipe_valid_r[4] && pipe_bad_r[4] == 2'b00) begin
        if (pipe_is_mult_r[4] && 5 == 1) begin
            pipe_result_r[5] <= mult_q15(pipe_mult_rs_r, pipe_mult_rt_r);
        end

        if (pipe_is_div_r[4]) begin
            div_pair = div_three_steps(pipe_div_rem_r[4], pipe_div_b_r[4]);
            div_quo_next = (pipe_div_quo_r[4] << 3) |
                           {12'd0, div_pair[18], div_pair[17], div_pair[16]};
            div_overflow_next = pipe_div_overflow_r[4];
            pipe_div_rem_r[5] <= div_pair[15:0];
            pipe_div_quo_r[5] <= div_quo_next;
            pipe_div_overflow_r[5] <= div_overflow_next;
        end
    end

    if (pipe_valid_r[5] && pipe_bad_r[5] == 2'b00) begin
        if (pipe_is_div_r[5]) begin
            div_pair = div_three_steps(pipe_div_rem_r[5], pipe_div_b_r[5]);
            div_quo_next = (pipe_div_quo_r[5] << 3) |
                           {12'd0, div_pair[18], div_pair[17], div_pair[16]};
            div_overflow_next = pipe_div_overflow_r[5];
            pipe_div_rem_r[6] <= div_pair[15:0];
            pipe_div_quo_r[6] <= div_quo_next;
            pipe_div_overflow_r[6] <= div_overflow_next;

            pipe_result_r[6] <= div_tail_result;
        end
    end

    pipe_bad_r[0] <= issue_fire ? issue_bad : 2'b00;
    pipe_write_en_r[0] <= issue_fire && issue_bad == 2'b00 && issue_write_en;
    pipe_write_idx_r[0] <= issue_write_idx;
    pipe_tag_r[0] <= issue_tag;
    pipe_is_mult_r[0] <= issue_fire && issue_bad == 2'b00 && issue_is_mult;
    pipe_is_div_r[0] <= issue_fire && issue_bad == 2'b00 && issue_is_div;
    pipe_result_r[0] <= (issue_fire && issue_bad == 2'b00 &&
                         issue_write_en && !issue_is_mult && !issue_is_div) ?
                        issue_fast_result : 16'sd0;
    pipe_mult_rs_r <= issue_rs_value;
    pipe_mult_rt_r <= issue_rt_value;
    pipe_div_a_raw_r <= issue_rs_value;
    pipe_div_b_raw_r <= issue_rt_value;
    pipe_div_b_r[0] <= 16'd0;
    pipe_div_rem_r[0] <= 16'd0;
    pipe_div_quo_r[0] <= 15'd0;
    pipe_div_sign_r[0] <= 1'b0;
    pipe_div_overflow_r[0] <= 1'b0;

    if (issue_fire) begin
        fifo_ins_r[0] <= fifo_ins_r[1];
        fifo_ins_r[1] <= fifo_ins_r[2];
        fifo_ins_r[2] <= fifo_ins_r[3];
    end

    if (accept_ins) begin
        fifo_ins_r[fifo_push_idx] <= instruction;
    end
end

//================================================================
// 7. Output Logic
//================================================================
assign out_valid = out_valid_r;
assign bad_ins   = (out_valid_r) ? bad_ins_r : 2'b00;
assign out_0     = (out_valid_r) ? out_0_r   : 16'd0;
assign out_1     = (out_valid_r) ? out_1_r   : 16'd0;
assign out_2     = (out_valid_r) ? out_2_r   : 16'd0;
assign out_3     = (out_valid_r) ? out_3_r   : 16'd0;
assign out_4     = (out_valid_r) ? out_4_r   : 16'd0;
assign out_5     = (out_valid_r) ? out_5_r   : 16'd0;

endmodule
