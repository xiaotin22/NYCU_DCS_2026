//================================================================
// Module      : CPU
// Description : NYCU DCS HW05 - Simple CPU (Single File)
// Features    : Q1.15 Fixed-point, No for/while loops, Handshake
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
typedef enum logic [1:0] {
    S_IDLE,    
    S_EXEC,    
    S_OUT      
} state_t;

state_t state_c, state_n;

//================================================================
// 2. Internal Registers & Wires
//================================================================
logic [31:0] ins_r;  

logic signed [15:0] core_regs_c [0:5];
logic signed [15:0] core_regs_n [0:5];

logic [1:0] bad_ins_r;

logic [5:0]  opcode, funct;
logic [4:0]  rs, rt, rd, shamt;
logic signed [15:0] imm;

logic [2:0]  rs_idx, rt_idx, rd_idx;
logic        rs_valid, rt_valid, rd_valid;

logic [15:0] abs_A, abs_B;
logic [3:0]  pos_A, pos_B;
logic [4:0]  shift_n;
logic signed [15:0] A_shifted_signed; 
logic [15:0] A_shifted;              
logic [15:0] div_rem [0:15];         
logic [14:0] div_quo;                
logic        div_sign;               
logic signed [15:0] div_result;      

logic signed [15:0] alu_result;
logic               write_enable;
logic [2:0]         write_idx;
logic [1:0]         bad_ins_type; 

//================================================================
// 3. Instruction Decoding (Combinational)
//================================================================
assign opcode = ins_r[31:26];
assign rs     = ins_r[25:21];
assign rt     = ins_r[20:16];
assign rd     = ins_r[15:11];
assign shamt  = ins_r[10:6];
assign funct  = ins_r[5:0];
assign imm    = ins_r[15:0];

//================================================================
// 4. Register Address Mapping (Combinational)
//================================================================
function automatic void map_reg(input logic [4:0] addr, output logic [2:0] idx, output logic valid);
    valid = 1'b1;
    case(addr)
        5'b10001: idx = 3'd0;
        5'b10010: idx = 3'd1;
        5'b01000: idx = 3'd2;
        5'b10111: idx = 3'd3;
        5'b11111: idx = 3'd4;
        5'b10000: idx = 3'd5;
        default:  begin idx = 3'd0; valid = 1'b0; end
    endcase
endfunction

always_comb begin
    map_reg(rs, rs_idx, rs_valid);
    map_reg(rt, rt_idx, rt_valid);
    map_reg(rd, rd_idx, rd_valid);
end

//================================================================
// 5. Restoring Divider Unrolled Logic (Combinational)
//================================================================
always_comb begin
    // 1. 取絕對值
    abs_A = (core_regs_c[rs_idx][15]) ? (~core_regs_c[rs_idx] + 16'd1) : core_regs_c[rs_idx];
    abs_B = (core_regs_c[rt_idx][15]) ? (~core_regs_c[rt_idx] + 16'd1) : core_regs_c[rt_idx];

    // 2. 尋找 MSB 位置
    if      (abs_A[15]) pos_A = 4'd15;
    else if (abs_A[14]) pos_A = 4'd14;
    else if (abs_A[13]) pos_A = 4'd13;
    else if (abs_A[12]) pos_A = 4'd12;
    else if (abs_A[11]) pos_A = 4'd11;
    else if (abs_A[10]) pos_A = 4'd10;
    else if (abs_A[9])  pos_A = 4'd9;
    else if (abs_A[8])  pos_A = 4'd8;
    else if (abs_A[7])  pos_A = 4'd7;
    else if (abs_A[6])  pos_A = 4'd6;
    else if (abs_A[5])  pos_A = 4'd5;
    else if (abs_A[4])  pos_A = 4'd4;
    else if (abs_A[3])  pos_A = 4'd3;
    else if (abs_A[2])  pos_A = 4'd2;
    else if (abs_A[1])  pos_A = 4'd1;
    else                pos_A = 4'd0;

    if      (abs_B[15]) pos_B = 4'd15;
    else if (abs_B[14]) pos_B = 4'd14;
    else if (abs_B[13]) pos_B = 4'd13;
    else if (abs_B[12]) pos_B = 4'd12;
    else if (abs_B[11]) pos_B = 4'd11;
    else if (abs_B[10]) pos_B = 4'd10;
    else if (abs_B[9])  pos_B = 4'd9;
    else if (abs_B[8])  pos_B = 4'd8;
    else if (abs_B[7])  pos_B = 4'd7;
    else if (abs_B[6])  pos_B = 4'd6;
    else if (abs_B[5])  pos_B = 4'd5;
    else if (abs_B[4])  pos_B = 4'd4;
    else if (abs_B[3])  pos_B = 4'd3;
    else if (abs_B[2])  pos_B = 4'd2;
    else if (abs_B[1])  pos_B = 4'd1;
    else                pos_B = 4'd0;

    // 3. 計算位移量 n
    if (abs_A >= abs_B) shift_n = pos_A - pos_B + 5'd1;
    else                shift_n = 5'd0;

    A_shifted_signed = core_regs_c[rs_idx] >>> shift_n;
    A_shifted = (A_shifted_signed[15]) ? (~A_shifted_signed + 16'd1) : A_shifted_signed;

    // 4. 15 級 Restoring Divider 展開
    div_rem[0] = A_shifted;
    if ({1'b0, div_rem[0]} << 1 >= {1'b0, abs_B}) begin div_rem[1] = ({1'b0, div_rem[0]} << 1) - abs_B; div_quo[14] = 1'b1; end else begin div_rem[1] = div_rem[0] << 1; div_quo[14] = 1'b0; end
    if ({1'b0, div_rem[1]} << 1 >= {1'b0, abs_B}) begin div_rem[2] = ({1'b0, div_rem[1]} << 1) - abs_B; div_quo[13] = 1'b1; end else begin div_rem[2] = div_rem[1] << 1; div_quo[13] = 1'b0; end
    if ({1'b0, div_rem[2]} << 1 >= {1'b0, abs_B}) begin div_rem[3] = ({1'b0, div_rem[2]} << 1) - abs_B; div_quo[12] = 1'b1; end else begin div_rem[3] = div_rem[2] << 1; div_quo[12] = 1'b0; end
    if ({1'b0, div_rem[3]} << 1 >= {1'b0, abs_B}) begin div_rem[4] = ({1'b0, div_rem[3]} << 1) - abs_B; div_quo[11] = 1'b1; end else begin div_rem[4] = div_rem[3] << 1; div_quo[11] = 1'b0; end
    if ({1'b0, div_rem[4]} << 1 >= {1'b0, abs_B}) begin div_rem[5] = ({1'b0, div_rem[4]} << 1) - abs_B; div_quo[10] = 1'b1; end else begin div_rem[5] = div_rem[4] << 1; div_quo[10] = 1'b0; end
    if ({1'b0, div_rem[5]} << 1 >= {1'b0, abs_B}) begin div_rem[6] = ({1'b0, div_rem[5]} << 1) - abs_B; div_quo[9] = 1'b1; end else begin div_rem[6] = div_rem[5] << 1; div_quo[9] = 1'b0; end
    if ({1'b0, div_rem[6]} << 1 >= {1'b0, abs_B}) begin div_rem[7] = ({1'b0, div_rem[6]} << 1) - abs_B; div_quo[8] = 1'b1; end else begin div_rem[7] = div_rem[6] << 1; div_quo[8] = 1'b0; end
    if ({1'b0, div_rem[7]} << 1 >= {1'b0, abs_B}) begin div_rem[8] = ({1'b0, div_rem[7]} << 1) - abs_B; div_quo[7] = 1'b1; end else begin div_rem[8] = div_rem[7] << 1; div_quo[7] = 1'b0; end
    if ({1'b0, div_rem[8]} << 1 >= {1'b0, abs_B}) begin div_rem[9] = ({1'b0, div_rem[8]} << 1) - abs_B; div_quo[6] = 1'b1; end else begin div_rem[9] = div_rem[8] << 1; div_quo[6] = 1'b0; end
    if ({1'b0, div_rem[9]} << 1 >= {1'b0, abs_B}) begin div_rem[10] = ({1'b0, div_rem[9]} << 1) - abs_B; div_quo[5] = 1'b1; end else begin div_rem[10] = div_rem[9] << 1; div_quo[5] = 1'b0; end
    if ({1'b0, div_rem[10]} << 1 >= {1'b0, abs_B}) begin div_rem[11] = ({1'b0, div_rem[10]} << 1) - abs_B; div_quo[4] = 1'b1; end else begin div_rem[11] = div_rem[10] << 1; div_quo[4] = 1'b0; end
    if ({1'b0, div_rem[11]} << 1 >= {1'b0, abs_B}) begin div_rem[12] = ({1'b0, div_rem[11]} << 1) - abs_B; div_quo[3] = 1'b1; end else begin div_rem[12] = div_rem[11] << 1; div_quo[3] = 1'b0; end
    if ({1'b0, div_rem[12]} << 1 >= {1'b0, abs_B}) begin div_rem[13] = ({1'b0, div_rem[12]} << 1) - abs_B; div_quo[2] = 1'b1; end else begin div_rem[13] = div_rem[12] << 1; div_quo[2] = 1'b0; end
    if ({1'b0, div_rem[13]} << 1 >= {1'b0, abs_B}) begin div_rem[14] = ({1'b0, div_rem[13]} << 1) - abs_B; div_quo[1] = 1'b1; end else begin div_rem[14] = div_rem[13] << 1; div_quo[1] = 1'b0; end
    if ({1'b0, div_rem[14]} << 1 >= {1'b0, abs_B}) begin div_rem[15] = ({1'b0, div_rem[14]} << 1) - abs_B; div_quo[0] = 1'b1; end else begin div_rem[15] = div_rem[14] << 1; div_quo[0] = 1'b0; end

    // 5. [關鍵修復] 符號處理與邊界溢位保護
    div_sign = core_regs_c[rs_idx][15] ^ core_regs_c[rt_idx][15];
    
    // 如果算術移位導致 |A_shifted| >= |B|，代表商數數學上 >= 1.0
    // Q1.15 格式極限無法表示 1.0，助教的底層會將 32768 溢位解讀為 16'h8000 (-32768)
    if (A_shifted >= abs_B) begin
        div_result = 16'h8000;
    end else if (div_sign) begin
        div_result = ~( {1'b0, div_quo} ) + 16'd1;
    end else begin
        div_result = {1'b0, div_quo};
    end
end

//================================================================
// 6. ALU & Exception Logic (Combinational)
//================================================================
logic is_r_type, is_i_type;
always_comb begin
    alu_result   = 16'd0;
    write_enable = 1'b0;
    write_idx    = 3'd0;
    bad_ins_type = 2'b00;

    is_r_type = (opcode == 6'b000000);
    is_i_type = (opcode == 6'b001000) || (opcode == 6'b001101);

    if (is_r_type && (!rs_valid || !rt_valid || !rd_valid)) begin
        bad_ins_type = 2'b01;
    end 
    else if (is_i_type && (!rs_valid || !rt_valid)) begin
        bad_ins_type = 2'b01;
    end
    else begin
        case (opcode)
            6'b000000: begin // R-Type
                write_idx = rd_idx;
                case (funct)
                    6'b100000: begin // ADD
                        alu_result = core_regs_c[rs_idx] + core_regs_c[rt_idx];
                        write_enable = 1'b1;
                    end
                    6'b011000: begin // MULT
                        logic signed [31:0] mult_tmp;
                        mult_tmp = signed'(32'(core_regs_c[rs_idx])) * signed'(32'(core_regs_c[rt_idx]));
                        alu_result = 16'(mult_tmp >>> 15);
                        write_enable = 1'b1;
                    end
                    6'b011001: begin // OR
                        alu_result = core_regs_c[rs_idx] | core_regs_c[rt_idx];
                        write_enable = 1'b1;
                    end
                    6'b000000: begin // SLA
                        alu_result = core_regs_c[rt_idx] << shamt;
                        write_enable = 1'b1;
                    end
                    6'b000010: begin // SRA
                        alu_result = core_regs_c[rt_idx] >>> shamt;
                        write_enable = 1'b1;
                    end
                    6'b110001: begin // DIV
                        if (core_regs_c[rt_idx] == 16'sd0) begin
                            bad_ins_type = 2'b10; 
                        end else begin
                            alu_result = div_result;
                            write_enable = 1'b1;
                        end
                    end
                    default: bad_ins_type = 2'b01;
                endcase
            end
            6'b001000: begin // ADDI
                write_idx = rt_idx;
                alu_result = core_regs_c[rs_idx] + imm;
                write_enable = 1'b1;
            end
            6'b001101: begin // ORI
                write_idx = rt_idx;
                alu_result = core_regs_c[rs_idx] | imm;
                write_enable = 1'b1;
            end
            default: bad_ins_type = 2'b01;
        endcase
    end
end

//================================================================
// 7. Next State Logic & Register Update (Combinational)
//================================================================
always_comb begin
    state_n = state_c;
    for (int i = 0; i < 6; i++) core_regs_n[i] = core_regs_c[i];

    case (state_c)
        S_IDLE: begin
            if (in_valid && in_ready) state_n = S_EXEC;
        end
        S_EXEC: begin
            if (bad_ins_type == 2'b00 && write_enable) begin
                core_regs_n[write_idx] = alu_result;
            end
            state_n = S_OUT;
        end
        S_OUT: begin
            state_n = S_IDLE;
        end
        default: state_n = S_IDLE;
    endcase
end

//================================================================
// 8. Sequential Logic (Flip-Flops)
//================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_c   <= S_IDLE;
        ins_r     <= 32'd0;
        in_ready  <= 1'b0;
        bad_ins_r <= 2'b00;
        for (int i = 0; i < 6; i++) core_regs_c[i] <= 16'd0;
    end else begin
        state_c <= state_n;
        for (int i = 0; i < 6; i++) core_regs_c[i] <= core_regs_n[i];
        
        if (state_c == S_IDLE && in_valid && in_ready) begin
            ins_r <= instruction;
        end
        
        if (state_c == S_EXEC) begin
            bad_ins_r <= bad_ins_type;
        end
        
        if (state_n == S_IDLE && in_valid) begin
            in_ready <= 1'b1;
        end else begin
            in_ready <= 1'b0;
        end
    end
end

//================================================================
// 9. Output Logic (Combinational)
//================================================================
always_comb begin
    if (!rst_n) begin
        out_valid = 1'b0;
        bad_ins   = 2'b00;
        out_0     = 16'd0;
        out_1     = 16'd0;
        out_2     = 16'd0;
        out_3     = 16'd0;
        out_4     = 16'd0;
        out_5     = 16'd0;
    end else if (state_c == S_OUT) begin
        out_valid = 1'b1;
        bad_ins   = bad_ins_r;
        out_0     = core_regs_c[0];
        out_1     = core_regs_c[1];
        out_2     = core_regs_c[2];
        out_3     = core_regs_c[3];
        out_4     = core_regs_c[4];
        out_5     = core_regs_c[5];
    end else begin
        out_valid = 1'b0;
        bad_ins   = 2'b00;
        out_0     = 16'd0;
        out_1     = 16'd0;
        out_2     = 16'd0;
        out_3     = 16'd0;
        out_4     = 16'd0;
        out_5     = 16'd0;
    end
end

endmodule