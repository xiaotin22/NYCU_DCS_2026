//================================================================
// Module      : CPU
// Description : NYCU DCS HW05 - Variable-latency simple CPU
// Features    : Q1.15 Fixed-point, Handshake, Staged MULT/DIV paths
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
// 1. Parameters & State Machine Definitions
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

typedef enum logic [1:0] {
    S_IDLE,
    S_EXEC,
    S_OUT
} state_t;

state_t state_cs, state_ns;

//================================================================
// 2. Internal Registers & Wires
//================================================================
logic [31:0] ins_r;
logic [3:0]  exec_cycles_r;
logic [3:0]  exec_cycles_load;

logic signed [15:0] core_regs_cs [0:5];
logic signed [15:0] core_regs_ns [0:5];

logic [1:0] bad_ins_r;
logic [15:0] out_0_r;
logic [15:0] out_1_r;
logic [15:0] out_2_r;
logic [15:0] out_3_r;
logic [15:0] out_4_r;
logic [15:0] out_5_r;

logic [5:0]  opcode, funct;
logic [4:0]  rs, rt, rd, shamt;
logic signed [15:0] imm;

logic [5:0] opcode_in, funct_in;
logic [4:0] rs_in, rt_in, rd_in;

logic [2:0] rs_idx, rt_idx, rd_idx;
logic       rs_valid, rt_valid, rd_valid;
logic [2:0] rs_idx_in, rt_idx_in, rd_idx_in;
logic       rs_valid_in, rt_valid_in, rd_valid_in;

logic is_r_type, is_i_type, is_mult, is_div;
logic is_r_type_in, is_mult_in, is_div_in;
logic accept_ins;
logic ins_active_r;
logic finish_ins;

logic signed [15:0] fast_alu_result;
logic signed [15:0] alu_result;
logic               write_enable;
logic [2:0]         write_idx;
logic [1:0]         bad_ins_type;

logic signed [31:0] mult_product;
logic signed [31:0] mult_shifted;
logic signed [15:0] mult_result_r;

logic [15:0] div_abs_a;
logic [15:0] div_abs_b;
logic [3:0]  div_pos_a;
logic [3:0]  div_pos_b;
logic [4:0]  div_shift_n;
logic signed [15:0] div_a_shifted_signed;
logic [15:0] div_a_shifted_abs;
logic        div_sign_init;
logic        div_overflow_init;

logic [15:0] div_abs_b_r, div_abs_b_n;
logic [15:0] div_rem_r, div_rem_n;
logic [14:0] div_quo_r, div_quo_n;
logic        div_sign_r, div_sign_n;
logic        div_overflow_r, div_overflow_n;

logic [14:0] div_quo_final;
logic signed [15:0] div_result;

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

function automatic logic [3:0] msb_pos(input logic [15:0] value);
    if      (value[15]) msb_pos = 4'd15;
    else if (value[14]) msb_pos = 4'd14;
    else if (value[13]) msb_pos = 4'd13;
    else if (value[12]) msb_pos = 4'd12;
    else if (value[11]) msb_pos = 4'd11;
    else if (value[10]) msb_pos = 4'd10;
    else if (value[9])  msb_pos = 4'd9;
    else if (value[8])  msb_pos = 4'd8;
    else if (value[7])  msb_pos = 4'd7;
    else if (value[6])  msb_pos = 4'd6;
    else if (value[5])  msb_pos = 4'd5;
    else if (value[4])  msb_pos = 4'd4;
    else if (value[3])  msb_pos = 4'd3;
    else if (value[2])  msb_pos = 4'd2;
    else if (value[1])  msb_pos = 4'd1;
    else                msb_pos = 4'd0;
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

//================================================================
// 4. Instruction Decoding
//================================================================
assign opcode = ins_r[31:26];
assign rs     = ins_r[25:21];
assign rt     = ins_r[20:16];
assign rd     = ins_r[15:11];
assign shamt  = ins_r[10:6];
assign funct  = ins_r[5:0];
assign imm    = ins_r[15:0];

assign opcode_in = instruction[31:26];
assign rs_in     = instruction[25:21];
assign rt_in     = instruction[20:16];
assign rd_in     = instruction[15:11];
assign funct_in  = instruction[5:0];

always_comb begin
    map_reg(rs, rs_idx, rs_valid);
    map_reg(rt, rt_idx, rt_valid);
    map_reg(rd, rd_idx, rd_valid);

    map_reg(rs_in, rs_idx_in, rs_valid_in);
    map_reg(rt_in, rt_idx_in, rt_valid_in);
    map_reg(rd_in, rd_idx_in, rd_valid_in);
end

assign is_r_type = (opcode == OP_RTYPE);
assign is_i_type = (opcode == OP_ADDI) || (opcode == OP_ORI);
assign is_mult   = is_r_type && (funct == FUNC_MULT);
assign is_div    = is_r_type && (funct == FUNC_DIV);

assign is_r_type_in = (opcode_in == OP_RTYPE);
assign is_mult_in   = is_r_type_in && (funct_in == FUNC_MULT);
assign is_div_in    = is_r_type_in && (funct_in == FUNC_DIV);

//================================================================
// 5. Variable-Latency Control
//================================================================
assign accept_ins = in_valid && in_ready;
assign finish_ins = (state_cs == S_EXEC && exec_cycles_r == 4'd0 && ins_active_r);

always_comb begin
    exec_cycles_load = 4'd0;

    if (is_mult_in && rs_valid_in && rt_valid_in && rd_valid_in) begin
        exec_cycles_load = 4'd1;
    end else if (is_div_in && rs_valid_in && rt_valid_in && rd_valid_in &&
                 (core_regs_cs[rt_idx_in] != 16'sd0)) begin
        exec_cycles_load = 4'd4;
    end
end

always_comb begin
    state_ns = state_cs;

    case (state_cs)
        S_IDLE: begin
            if (accept_ins) state_ns = S_EXEC;
        end
        S_EXEC: begin
            if (exec_cycles_r == 4'd0) state_ns = S_OUT;
            else                       state_ns = S_EXEC;
        end
        S_OUT: begin
            if (accept_ins) state_ns = S_EXEC;
            else            state_ns = S_IDLE;
        end
        default: state_ns = S_IDLE;
    endcase
end

//================================================================
// 6. Fast ALU, MULT Result, and Exception Logic
//================================================================
always_comb begin
    fast_alu_result = 16'sd0;
    alu_result      = 16'sd0;
    write_enable    = 1'b0;
    write_idx       = 3'd0;
    bad_ins_type    = 2'b00;

    mult_product = $signed({{16{core_regs_cs[rs_idx][15]}}, core_regs_cs[rs_idx]}) *
                   $signed({{16{core_regs_cs[rt_idx][15]}}, core_regs_cs[rt_idx]});
    mult_shifted = mult_product >>> 15;

    if (is_r_type && (!rs_valid || !rt_valid || !rd_valid)) begin
        bad_ins_type = 2'b01;
    end else if (is_i_type && (!rs_valid || !rt_valid)) begin
        bad_ins_type = 2'b01;
    end else begin
        case (opcode)
            OP_RTYPE: begin
                write_idx = rd_idx;
                case (funct)
                    FUNC_ADD: begin
                        fast_alu_result = core_regs_cs[rs_idx] + core_regs_cs[rt_idx];
                        write_enable    = 1'b1;
                    end
                    FUNC_MULT: begin
                        write_enable = 1'b1;
                    end
                    FUNC_OR: begin
                        fast_alu_result = core_regs_cs[rs_idx] | core_regs_cs[rt_idx];
                        write_enable    = 1'b1;
                    end
                    FUNC_SLA: begin
                        fast_alu_result = core_regs_cs[rt_idx] << shamt;
                        write_enable    = 1'b1;
                    end
                    FUNC_SRA: begin
                        fast_alu_result = core_regs_cs[rt_idx] >>> shamt;
                        write_enable    = 1'b1;
                    end
                    FUNC_DIV: begin
                        if (core_regs_cs[rt_idx] == 16'sd0) begin
                            bad_ins_type = 2'b10;
                        end else begin
                            write_enable = 1'b1;
                        end
                    end
                    default: bad_ins_type = 2'b01;
                endcase
            end
            OP_ADDI: begin
                write_idx       = rt_idx;
                fast_alu_result = core_regs_cs[rs_idx] + imm;
                write_enable    = 1'b1;
            end
            OP_ORI: begin
                write_idx       = rt_idx;
                fast_alu_result = core_regs_cs[rs_idx] | imm;
                write_enable    = 1'b1;
            end
            default: bad_ins_type = 2'b01;
        endcase
    end

    if (is_div) begin
        alu_result = div_result;
    end else if (is_mult) begin
        alu_result = mult_result_r;
    end else begin
        alu_result = fast_alu_result;
    end
end

//================================================================
// 7. Staged Divider Data Path
//================================================================
always_comb begin
    div_abs_a = abs16(core_regs_cs[rs_idx]);
    div_abs_b = abs16(core_regs_cs[rt_idx]);
    div_pos_a = msb_pos(div_abs_a);
    div_pos_b = msb_pos(div_abs_b);

    if (div_abs_a >= div_abs_b) div_shift_n = div_pos_a - div_pos_b + 5'd1;
    else                        div_shift_n = 5'd0;

    div_a_shifted_signed = core_regs_cs[rs_idx] >>> div_shift_n;
    div_a_shifted_abs    = abs16(div_a_shifted_signed);
    div_sign_init        = div_a_shifted_signed[15] ^ core_regs_cs[rt_idx][15];
    div_overflow_init    = (div_a_shifted_abs >= div_abs_b);
end

always_comb begin
    logic [16:0] step0;
    logic [16:0] step1;
    logic [16:0] step2;
    logic [16:0] step3;

    div_abs_b_n    = div_abs_b_r;
    div_rem_n      = div_rem_r;
    div_quo_n      = div_quo_r;
    div_sign_n     = div_sign_r;
    div_overflow_n = div_overflow_r;

    step0 = 17'd0;
    step1 = 17'd0;
    step2 = 17'd0;
    step3 = 17'd0;

    if (state_cs == S_EXEC && is_div && exec_cycles_r > 4'd0) begin
        case (exec_cycles_r)
            4'd4: begin
                div_abs_b_n    = div_abs_b;
                div_rem_n      = div_a_shifted_abs;
                div_quo_n      = 15'd0;
                div_sign_n     = div_sign_init;
                div_overflow_n = div_overflow_init;
            end
            4'd3: begin
                step0 = div_step(div_rem_r, div_abs_b_r);
                step1 = div_step(step0[15:0], div_abs_b_r);
                step2 = div_step(step1[15:0], div_abs_b_r);
                step3 = div_step(step2[15:0], div_abs_b_r);

                div_rem_n      = step3[15:0];
                div_quo_n      = {step0[16], step1[16], step2[16], step3[16], 11'd0};
            end
            4'd2: begin
                step0 = div_step(div_rem_r, div_abs_b_r);
                step1 = div_step(step0[15:0], div_abs_b_r);
                step2 = div_step(step1[15:0], div_abs_b_r);
                step3 = div_step(step2[15:0], div_abs_b_r);

                div_rem_n = step3[15:0];
                div_quo_n = {div_quo_r[14:11], step0[16], step1[16], step2[16], step3[16], 7'd0};
            end
            4'd1: begin
                step0 = div_step(div_rem_r, div_abs_b_r);
                step1 = div_step(step0[15:0], div_abs_b_r);
                step2 = div_step(step1[15:0], div_abs_b_r);
                step3 = div_step(step2[15:0], div_abs_b_r);

                div_rem_n = step3[15:0];
                div_quo_n = {div_quo_r[14:7], step0[16], step1[16], step2[16], step3[16], 3'd0};
            end
            default: begin
                div_abs_b_n    = div_abs_b_r;
                div_rem_n      = div_rem_r;
                div_quo_n      = div_quo_r;
                div_sign_n     = div_sign_r;
                div_overflow_n = div_overflow_r;
            end
        endcase
    end
end

always_comb begin
    logic [16:0] step0;
    logic [16:0] step1;
    logic [16:0] step2;

    step0 = div_step(div_rem_r, div_abs_b_r);
    step1 = div_step(step0[15:0], div_abs_b_r);
    step2 = div_step(step1[15:0], div_abs_b_r);

    div_quo_final = {div_quo_r[14:3], step0[16], step1[16], step2[16]};

    if (div_overflow_r) begin
        div_result = 16'sh8000;
    end else if (div_sign_r) begin
        div_result = $signed((~{1'b0, div_quo_final}) + 16'd1);
    end else begin
        div_result = $signed({1'b0, div_quo_final});
    end
end

//================================================================
// 8. Register File Next Value
//================================================================
always_comb begin
    core_regs_ns = core_regs_cs;

    if (state_cs == S_EXEC && exec_cycles_r == 4'd0 &&
        bad_ins_type == 2'b00 && write_enable) begin
        core_regs_ns[write_idx] = alu_result;
    end
end

//================================================================
// 9. Sequential Logic
//================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_cs       <= S_IDLE;
        ins_r          <= 32'd0;
        exec_cycles_r  <= 4'd0;
        in_ready       <= 1'b0;
        out_valid      <= 1'b0;
        ins_active_r   <= 1'b0;
        bad_ins_r      <= 2'b00;
        out_0_r        <= 16'd0;
        out_1_r        <= 16'd0;
        out_2_r        <= 16'd0;
        out_3_r        <= 16'd0;
        out_4_r        <= 16'd0;
        out_5_r        <= 16'd0;
        mult_result_r  <= 16'sd0;
        div_abs_b_r    <= 16'd0;
        div_rem_r      <= 16'd0;
        div_quo_r      <= 15'd0;
        div_sign_r     <= 1'b0;
        div_overflow_r <= 1'b0;
        core_regs_cs <= 'default{16'sd0};

    end else begin
        state_cs <= state_ns;
        in_ready <= (state_ns != S_EXEC) && in_valid;
        out_valid <= finish_ins;
        core_regs_cs <= core_regs_ns;

        if (accept_ins) begin
            ins_r         <= instruction;
            exec_cycles_r <= exec_cycles_load;
            ins_active_r  <= 1'b1;
        end else if (state_cs == S_EXEC && exec_cycles_r > 4'd0) begin
            exec_cycles_r <= exec_cycles_r - 4'd1;
        end

        if (state_cs == S_EXEC && exec_cycles_r > 4'd0) begin
            if (is_mult) begin
                mult_result_r <= mult_shifted[15:0];
            end

            if (is_div) begin
                div_abs_b_r    <= div_abs_b_n;
                div_rem_r      <= div_rem_n;
                div_quo_r      <= div_quo_n;
                div_sign_r     <= div_sign_n;
                div_overflow_r <= div_overflow_n;
            end
        end

        if (finish_ins) begin
            bad_ins_r <= bad_ins_type;
            out_0_r   <= core_regs_ns[0];
            out_1_r   <= core_regs_ns[1];
            out_2_r   <= core_regs_ns[2];
            out_3_r   <= core_regs_ns[3];
            out_4_r   <= core_regs_ns[4];
            out_5_r   <= core_regs_ns[5];
            ins_active_r <= 1'b0;
        end
    end
end

//================================================================
// 10. Output Logic
//================================================================
assign bad_ins = out_valid ? bad_ins_r : 2'b00;
assign out_0   = out_valid ? out_0_r   : 16'd0;
assign out_1   = out_valid ? out_1_r   : 16'd0;
assign out_2   = out_valid ? out_2_r   : 16'd0;
assign out_3   = out_valid ? out_3_r   : 16'd0;
assign out_4   = out_valid ? out_4_r   : 16'd0;
assign out_5   = out_valid ? out_5_r   : 16'd0;

endmodule
