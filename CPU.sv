module CPU(
    clk, rst_n, in_valid, instruction,
    in_ready, out_valid, bad_ins,
    out_0, out_1, out_2, out_3, out_4, out_5
);

// ─── Ports ────────────────────────────────────────────────────────────────
input  logic        clk, rst_n, in_valid;
input  logic [31:0] instruction;
output logic        in_ready, out_valid;
output logic  [1:0] bad_ins;
output logic [15:0] out_0, out_1, out_2, out_3, out_4, out_5;

// ─── Register File ────────────────────────────────────────────────────────
// addr 10001 → r0 → out_0
// addr 10010 → r1 → out_1
// addr 01000 → r2 → out_2
// addr 10111 → r3 → out_3
// addr 11111 → r4 → out_4
// addr 10000 → r5 → out_5
logic [15:0] r0, r1, r2, r3, r4, r5;

// ─── Pipeline Stage Register ──────────────────────────────────────────────
logic [31:0] ins_r;    // instruction latched at fetch stage
logic        has_ins;  // execute stage has a valid instruction

// ═══════════════════════════════════════════════════════════════════════════
// HANDSHAKE — always ready, 1 instruction consumed per cycle
// ═══════════════════════════════════════════════════════════════════════════
assign in_ready = 1'b1;

// ─── Instruction Decode (combinational, operates on ins_r) ────────────────
logic [5:0]  opcode, funct;
logic [4:0]  rs_a, rt_a, rd_a, shamt;
logic [15:0] imm;

assign opcode = ins_r[31:26];
assign rs_a   = ins_r[25:21];
assign rt_a   = ins_r[20:16];
assign rd_a   = ins_r[15:11];
assign shamt  = ins_r[10:6];
assign funct  = ins_r[5:0];
assign imm    = ins_r[15:0];   // I-type immediate (same bits as rd/shamt/funct)

// ─── Register Read (combinational) ───────────────────────────────────────
logic [15:0] rs_v, rt_v;

always_comb begin
    case (rs_a)
        5'b10001: rs_v = r0;
        5'b10010: rs_v = r1;
        5'b01000: rs_v = r2;
        5'b10111: rs_v = r3;
        5'b11111: rs_v = r4;
        5'b10000: rs_v = r5;
        default:  rs_v = 16'h0;
    endcase
end

always_comb begin
    case (rt_a)
        5'b10001: rt_v = r0;
        5'b10010: rt_v = r1;
        5'b01000: rt_v = r2;
        5'b10111: rt_v = r3;
        5'b11111: rt_v = r4;
        5'b10000: rt_v = r5;
        default:  rt_v = 16'h0;
    endcase
end

// ─── Address Validity ─────────────────────────────────────────────────────
logic rs_ok, rt_ok, rd_ok;

assign rs_ok = (rs_a == 5'b10001) | (rs_a == 5'b10010) | (rs_a == 5'b01000) |
               (rs_a == 5'b10111) | (rs_a == 5'b11111) | (rs_a == 5'b10000);
assign rt_ok = (rt_a == 5'b10001) | (rt_a == 5'b10010) | (rt_a == 5'b01000) |
               (rt_a == 5'b10111) | (rt_a == 5'b11111) | (rt_a == 5'b10000);
assign rd_ok = (rd_a == 5'b10001) | (rd_a == 5'b10010) | (rd_a == 5'b01000) |
               (rd_a == 5'b10111) | (rd_a == 5'b11111) | (rd_a == 5'b10000);

// ─── Instruction Type / Funct Decode ─────────────────────────────────────
logic is_r_type, is_addi, is_ori;
logic is_add, is_mult, is_or, is_sla, is_sra, is_div;

assign is_r_type = (opcode == 6'b000000);
assign is_addi   = (opcode == 6'b001000);
assign is_ori    = (opcode == 6'b001101);

assign is_add  = is_r_type & (funct == 6'b100000);
assign is_mult = is_r_type & (funct == 6'b011000);
assign is_or   = is_r_type & (funct == 6'b011001);
assign is_sla  = is_r_type & (funct == 6'b000000);
assign is_sra  = is_r_type & (funct == 6'b000010);
assign is_div  = is_r_type & (funct == 6'b110001);

// ─── bad_ins = 2'b01: invalid opcode / funct / register ──────────────────
logic bad_op, bad_reg, ins_inv;

// unknown opcode or unknown funct for R-type
assign bad_op = !(is_add | is_mult | is_or | is_sla | is_sra | is_div |
                  is_addi | is_ori);

// invalid register address (rs,rt,rd all checked; rs still required for SLA/SRA)
assign bad_reg = !bad_op & (
    ( is_r_type             & (!rs_ok | !rt_ok | !rd_ok)) |
    ((is_addi | is_ori)     & (!rs_ok | !rt_ok))
);

assign ins_inv = bad_op | bad_reg;   // triggers bad_ins = 2'b01

// ═══════════════════════════════════════════════════════════════════════════
// ALU  (placeholder — fill in next step)
// ═══════════════════════════════════════════════════════════════════════════
logic [15:0] alu_result;
logic        div_zero;   // triggers bad_ins = 2'b10

assign alu_result = 16'h0; // TODO
assign div_zero   = 1'b0;  // TODO: (is_div & (rt_v == 16'h0))

// ─── Write Control ────────────────────────────────────────────────────────
logic        do_write;
logic [4:0]  wr_addr;

assign do_write = !ins_inv & !div_zero;
assign wr_addr  = is_r_type ? rd_a : rt_a;  // R-type writes rd, I-type writes rt

// ─── Per-Register Write Enable ───────────────────────────────────────────
logic wr0, wr1, wr2, wr3, wr4, wr5;

assign wr0 = do_write & (wr_addr == 5'b10001);
assign wr1 = do_write & (wr_addr == 5'b10010);
assign wr2 = do_write & (wr_addr == 5'b01000);
assign wr3 = do_write & (wr_addr == 5'b10111);
assign wr4 = do_write & (wr_addr == 5'b11111);
assign wr5 = do_write & (wr_addr == 5'b10000);

// ─── Next Register Value (bypass mux) ────────────────────────────────────
// Ensures outputs reflect the value *after* the current instruction writes.
logic [15:0] nx0, nx1, nx2, nx3, nx4, nx5;

assign nx0 = wr0 ? alu_result : r0;
assign nx1 = wr1 ? alu_result : r1;
assign nx2 = wr2 ? alu_result : r2;
assign nx3 = wr3 ? alu_result : r3;
assign nx4 = wr4 ? alu_result : r4;
assign nx5 = wr5 ? alu_result : r5;

// ─── bad_ins Output for Current Instruction ──────────────────────────────
// Priority: ins_inv (2'b01) > div_zero (2'b10) > clean (2'b00)
logic [1:0] cur_bad;
assign cur_bad = ins_inv  ? 2'b01 :
                 div_zero ? 2'b10 : 2'b00;

// ═══════════════════════════════════════════════════════════════════════════
// SEQUENTIAL LOGIC
// Stage 1 (Fetch):   on handshake, latch instruction → ins_r, set has_ins
// Stage 2 (Execute): decode + compute + update register file + drive outputs
// ═══════════════════════════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        has_ins   <= 1'b0;
        ins_r     <= 32'h0;
        r0 <= 16'h0; r1 <= 16'h0; r2 <= 16'h0;
        r3 <= 16'h0; r4 <= 16'h0; r5 <= 16'h0;
        out_valid <= 1'b0;  bad_ins <= 2'b00;
        out_0 <= 16'h0; out_1 <= 16'h0; out_2 <= 16'h0;
        out_3 <= 16'h0; out_4 <= 16'h0; out_5 <= 16'h0;
    end else begin
        // ── Stage 1: Fetch ─────────────────────────────────────────────
        has_ins <= in_valid;           // in_ready = 1, so handshake = in_valid
        if (in_valid)
            ins_r <= instruction;

        // ── Stage 2: Execute & Output ──────────────────────────────────
        if (has_ins) begin
            // Update register file (nx* already incorporates alu_result bypass)
            r0 <= nx0;  r1 <= nx1;  r2 <= nx2;
            r3 <= nx3;  r4 <= nx4;  r5 <= nx5;
            // Drive outputs
            out_valid <= 1'b1;
            bad_ins   <= cur_bad;
            out_0 <= nx0;  out_1 <= nx1;  out_2 <= nx2;
            out_3 <= nx3;  out_4 <= nx4;  out_5 <= nx5;
        end else begin
            // No instruction in execute stage → zero all outputs
            out_valid <= 1'b0;
            bad_ins   <= 2'b00;
            out_0 <= 16'h0; out_1 <= 16'h0; out_2 <= 16'h0;
            out_3 <= 16'h0; out_4 <= 16'h0; out_5 <= 16'h0;
        end
    end
end

endmodule
