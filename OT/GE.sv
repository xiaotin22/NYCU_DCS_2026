module GE(
    input clk,
    input rst_n,
    input in_valid,
    input [15:0] in_data_eq0,
    input [15:0] in_data_eq1,
    input [15:0] in_data_eq2,
    output logic out_valid,
    output logic signed [5:0] out_data0,
    output logic signed [5:0] out_data1,
    output logic signed [5:0] out_data2,
    output logic [1:0] exception
);


// exception codes
localparam [1:0] EXC_UNIQUE   = 2'b00;
localparam [1:0] EXC_INFINITE = 2'b01;
localparam [1:0] EXC_NONE     = 2'b10;

// FSM states
localparam S_LOAD = 1'b0;   // accept inputs, run beat 0
localparam S_OUT  = 1'b1;   // run beat 1, assert out_valid
logic state_cs;


logic signed [2:0] a0, b0, c0, a1, b1, c1, a2, b2, c2;
logic signed [2:0] a0_r, b0_r, c0_r;   

logic signed [6:0] d0, d1, d2;
logic signed [6:0] d0_r; 


logic signed [5:0] m11, m12; 
logic signed [5:0] m21, m22; 
logic signed [9:0] v1, v2;  

assign m11 = a0*b1 - a1*b0;
assign m12 = a0*c1 - a1*c0;
assign v1  = a0*d1 - a1*d0;
assign m21 = a0*b2 - a2*b0;
assign m22 = a0*c2 - a2*c0;
assign v2  = a0*d2 - a2*d0;

logic signed [11:0] det;
logic signed [15:0] num_x1, num_x2;

logic signed [11:0] det_r;             
logic signed [15:0] num_x1_r, num_x2_r; 

assign det    = m11*m22 - m21*m12;
assign num_x1 = v1*m22  - v2*m12;
assign num_x2 = v2*m11  - v1*m21;

logic row1_contra, row2_contra;
logic row1_contra_r, row2_contra_r; 
assign row1_contra = (m11 == 0) && (m12 == 0) && (v1 != 0);
assign row2_contra = (m21 == 0) && (m22 == 0) && (v2 != 0);


logic reduced_consistent;
logic [1:0] exc_w;

assign reduced_consistent = (num_x1_r == 0) && (num_x2_r == 0)
                            && !row1_contra_r && !row2_contra_r;
assign exc_w = (det_r != 12'sd0)  ? EXC_UNIQUE   :
               reduced_consistent ? EXC_INFINITE :
                                    EXC_NONE;

logic [3:0] det_tz;
logic [5:0] det_inv;
logic signed [5:0] sol1; // x1
logic signed [5:0] sol2; // x2

assign det_tz  = count_tz12(det_r);
assign det_inv = inv_mod64(arshift6_w12(det_r, det_tz));
assign sol1    = mul_mod64(arshift6_w16(num_x1_r, det_tz), det_inv);
assign sol2    = mul_mod64(arshift6_w16(num_x2_r, det_tz), det_inv);

logic signed [9:0] x0_num;
logic signed [5:0] sol0;

assign x0_num = $signed({{3{d0_r[6]}}, d0_r}) - b0_r*sol1 - c0_r*sol2;
assign sol0   = div_by_pivot(x0_num, a0_r);

assign a0 = in_data_eq0[2:0];
assign b0 = in_data_eq0[5:3];
assign c0 = in_data_eq0[8:6];
assign d0 = in_data_eq0[15:9];
assign a1 = in_data_eq1[2:0];
assign b1 = in_data_eq1[5:3];
assign c1 = in_data_eq1[8:6];
assign d1 = in_data_eq1[15:9];
assign a2 = in_data_eq2[2:0];
assign b2 = in_data_eq2[5:3];
assign c2 = in_data_eq2[8:6];
assign d2 = in_data_eq2[15:9];

// trailing-zero count of a 12-bit value (0..11)
function automatic [3:0] count_tz12(input signed [11:0] v);
    begin
        if      (v[0])  count_tz12 = 4'd0;
        else if (v[1])  count_tz12 = 4'd1;
        else if (v[2])  count_tz12 = 4'd2;
        else if (v[3])  count_tz12 = 4'd3;
        else if (v[4])  count_tz12 = 4'd4;
        else if (v[5])  count_tz12 = 4'd5;
        else if (v[6])  count_tz12 = 4'd6;
        else if (v[7])  count_tz12 = 4'd7;
        else if (v[8])  count_tz12 = 4'd8;
        else if (v[9])  count_tz12 = 4'd9;
        else if (v[10]) count_tz12 = 4'd10;
        else if (v[11]) count_tz12 = 4'd11;
        else            count_tz12 = 4'd0;
    end
endfunction

// (v >>> shift) truncated to 6 bits -- 16-bit source (Cramer numerators)
function automatic [5:0] arshift6_w16(input signed [15:0] v, input [3:0] shift);
    begin
        case (shift)
            4'd0:  arshift6_w16 = v[5:0];
            4'd1:  arshift6_w16 = v[6:1];
            4'd2:  arshift6_w16 = v[7:2];
            4'd3:  arshift6_w16 = v[8:3];
            4'd4:  arshift6_w16 = v[9:4];
            4'd5:  arshift6_w16 = v[10:5];
            4'd6:  arshift6_w16 = v[11:6];
            4'd7:  arshift6_w16 = v[12:7];
            4'd8:  arshift6_w16 = v[13:8];
            4'd9:  arshift6_w16 = v[14:9];
            4'd10: arshift6_w16 = v[15:10];
            4'd11: arshift6_w16 = {v[15], v[15:11]};
            4'd12: arshift6_w16 = {{2{v[15]}}, v[15:12]};
            4'd13: arshift6_w16 = {{3{v[15]}}, v[15:13]};
            4'd14: arshift6_w16 = {{4{v[15]}}, v[15:14]};
            default: arshift6_w16 = {{5{v[15]}}, v[15]};
        endcase
    end
endfunction


function automatic [5:0] arshift6_w12(input signed [11:0] v, input [3:0] shift);
    begin
        case (shift)
            4'd0:  arshift6_w12 = v[5:0];
            4'd1:  arshift6_w12 = v[6:1];
            4'd2:  arshift6_w12 = v[7:2];
            4'd3:  arshift6_w12 = v[8:3];
            4'd4:  arshift6_w12 = v[9:4];
            4'd5:  arshift6_w12 = v[10:5];
            4'd6:  arshift6_w12 = v[11:6];
            4'd7:  arshift6_w12 = {v[11], v[11:7]};
            4'd8:  arshift6_w12 = {{2{v[11]}}, v[11:8]};
            4'd9:  arshift6_w12 = {{3{v[11]}}, v[11:9]};
            4'd10: arshift6_w12 = {{4{v[11]}}, v[11:10]};
            default: arshift6_w12 = {{5{v[11]}}, v[11]};
        endcase
    end
endfunction

// (a * b) mod 64
function automatic [5:0] mul_mod64(input [5:0] a, input [5:0] b);
    mul_mod64 = a * b;
endfunction

// modular inverse mod 64 of an odd value (indexed by its low 6 bits)
function automatic [5:0] inv_mod64(input [5:0] v);
    begin
        case (v)
            6'd1:  inv_mod64 = 6'd1;
            6'd3:  inv_mod64 = 6'd43;
            6'd5:  inv_mod64 = 6'd13;
            6'd7:  inv_mod64 = 6'd55;
            6'd9:  inv_mod64 = 6'd57;
            6'd11: inv_mod64 = 6'd35;
            6'd13: inv_mod64 = 6'd5;
            6'd15: inv_mod64 = 6'd47;
            6'd17: inv_mod64 = 6'd49;
            6'd19: inv_mod64 = 6'd27;
            6'd21: inv_mod64 = 6'd61;
            6'd23: inv_mod64 = 6'd39;
            6'd25: inv_mod64 = 6'd41;
            6'd27: inv_mod64 = 6'd19;
            6'd29: inv_mod64 = 6'd53;
            6'd31: inv_mod64 = 6'd31;
            6'd33: inv_mod64 = 6'd33;
            6'd35: inv_mod64 = 6'd11;
            6'd37: inv_mod64 = 6'd45;
            6'd39: inv_mod64 = 6'd23;
            6'd41: inv_mod64 = 6'd25;
            6'd43: inv_mod64 = 6'd3;
            6'd45: inv_mod64 = 6'd37;
            6'd47: inv_mod64 = 6'd15;
            6'd49: inv_mod64 = 6'd17;
            6'd51: inv_mod64 = 6'd59;
            6'd53: inv_mod64 = 6'd29;
            6'd55: inv_mod64 = 6'd7;
            6'd57: inv_mod64 = 6'd9;
            6'd59: inv_mod64 = 6'd51;
            6'd61: inv_mod64 = 6'd21;
            default: inv_mod64 = 6'd63;
        endcase
    end
endfunction

function automatic signed [5:0] div_by_pivot(input signed [9:0] num, input signed [2:0] a0);
    begin
        case (a0)
            3'b001: div_by_pivot = num[5:0];                  // /(+1)
            3'b010: div_by_pivot = num[6:1];                  // /(+2)
            3'b011: div_by_pivot = mul_mod64(num[5:0], 6'd43);// /(+3)  (43 = 3^-1 mod 64)
            3'b101: div_by_pivot = mul_mod64(num[5:0], 6'd21);// /(-3)  (21 = -3^-1 mod 64)
            3'b110: div_by_pivot = -$signed(num[6:1]);        // /(-2)
            3'b111: div_by_pivot = -$signed(num[5:0]);        // /(-1)
            default: div_by_pivot = -$signed(num[7:2]);       // /(+-4)
        endcase
    end
endfunction



//-------------------------------------------------------------------------
// FSM + pipeline registers (single block: the structure DC optimizes best)
//-------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_cs  <= S_LOAD;
        out_valid <= 1'b0;
    end else begin
        out_valid <= 1'b0;
        if (state_cs == S_OUT) begin
            state_cs  <= S_LOAD;
            out_valid <= 1'b1;
        end else if (in_valid) begin
            state_cs      <= S_OUT;
            a0_r          <= a0;
            b0_r          <= b0;
            c0_r          <= c0;
            d0_r          <= d0;
            det_r         <= det;
            num_x1_r      <= num_x1;
            num_x2_r      <= num_x2;
            row1_contra_r <= row1_contra;
            row2_contra_r <= row2_contra;
        end
    end
end

assign exception = out_valid ? exc_w : EXC_UNIQUE;
assign out_data0 = out_valid ? sol0 : 6'sd0;
assign out_data1 = out_valid ? sol1 : 6'sd0;
assign out_data2 = out_valid ? sol2 : 6'sd0;


endmodule
