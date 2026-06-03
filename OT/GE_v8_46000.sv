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

logic st;
logic r1_bad_r, r2_bad_r;
logic signed [2:0] a0_r, b0_r, c0_r;
logic signed [6:0] d0_r;
logic signed [15:0] num2_r, num3_r;
logic signed [11:0] det2_r;

wire signed [2:0] a0 = in_data_eq0[2:0];
wire signed [2:0] b0 = in_data_eq0[5:3];
wire signed [2:0] c0 = in_data_eq0[8:6];
wire signed [6:0] d0 = in_data_eq0[15:9];
wire signed [2:0] a1 = in_data_eq1[2:0];
wire signed [2:0] b1 = in_data_eq1[5:3];
wire signed [2:0] c1 = in_data_eq1[8:6];
wire signed [6:0] d1 = in_data_eq1[15:9];
wire signed [2:0] a2 = in_data_eq2[2:0];
wire signed [2:0] b2 = in_data_eq2[5:3];
wire signed [2:0] c2 = in_data_eq2[8:6];
wire signed [6:0] d2 = in_data_eq2[15:9];

function automatic signed [5:0] mul3_3(input signed [2:0] k, input signed [2:0] v);
    mul3_3 = k * v;
endfunction

function automatic signed [9:0] mul3_7(input signed [2:0] k, input signed [6:0] v);
    mul3_7 = k * v;
endfunction

function automatic signed [8:0] mul3_6(input signed [2:0] k, input signed [5:0] v);
    mul3_6 = k * v;
endfunction

function automatic [5:0] ashr6(input signed [15:0] v, input [3:0] sh);
    begin
        case (sh)
            4'd0:  ashr6 = v[5:0];
            4'd1:  ashr6 = v[6:1];
            4'd2:  ashr6 = v[7:2];
            4'd3:  ashr6 = v[8:3];
            4'd4:  ashr6 = v[9:4];
            4'd5:  ashr6 = v[10:5];
            4'd6:  ashr6 = v[11:6];
            4'd7:  ashr6 = v[12:7];
            4'd8:  ashr6 = v[13:8];
            4'd9:  ashr6 = v[14:9];
            4'd10: ashr6 = v[15:10];
            4'd11: ashr6 = {v[15], v[15:11]};
            4'd12: ashr6 = {{2{v[15]}}, v[15:12]};
            4'd13: ashr6 = {{3{v[15]}}, v[15:13]};
            4'd14: ashr6 = {{4{v[15]}}, v[15:14]};
            default: ashr6 = {{5{v[15]}}, v[15]};
        endcase
    end
endfunction

function automatic [3:0] tz12(input signed [11:0] v);
    begin
        if (v[0])       tz12 = 4'd0;
        else if (v[1])  tz12 = 4'd1;
        else if (v[2])  tz12 = 4'd2;
        else if (v[3])  tz12 = 4'd3;
        else if (v[4])  tz12 = 4'd4;
        else if (v[5])  tz12 = 4'd5;
        else if (v[6])  tz12 = 4'd6;
        else if (v[7])  tz12 = 4'd7;
        else if (v[8])  tz12 = 4'd8;
        else if (v[9])  tz12 = 4'd9;
        else if (v[10]) tz12 = 4'd10;
        else if (v[11]) tz12 = 4'd11;
        else            tz12 = 4'd0;
    end
endfunction

function automatic [5:0] ashr6_12(input signed [11:0] v, input [3:0] sh);
    begin
        case (sh)
            4'd0:  ashr6_12 = v[5:0];
            4'd1:  ashr6_12 = v[6:1];
            4'd2:  ashr6_12 = v[7:2];
            4'd3:  ashr6_12 = v[8:3];
            4'd4:  ashr6_12 = v[9:4];
            4'd5:  ashr6_12 = v[10:5];
            4'd6:  ashr6_12 = v[11:6];
            4'd7:  ashr6_12 = {v[11], v[11:7]};
            4'd8:  ashr6_12 = {{2{v[11]}}, v[11:8]};
            4'd9:  ashr6_12 = {{3{v[11]}}, v[11:9]};
            4'd10: ashr6_12 = {{4{v[11]}}, v[11:10]};
            default: ashr6_12 = {{5{v[11]}}, v[11]};
        endcase
    end
endfunction

function automatic [5:0] mul_mod6(input [5:0] a, input [5:0] b);
    mul_mod6 = a * b;
endfunction

function automatic [5:0] inv_odd6(input [5:0] v);
    begin
        case (v)
            6'd1:  inv_odd6 = 6'd1;
            6'd3:  inv_odd6 = 6'd43;
            6'd5:  inv_odd6 = 6'd13;
            6'd7:  inv_odd6 = 6'd55;
            6'd9:  inv_odd6 = 6'd57;
            6'd11: inv_odd6 = 6'd35;
            6'd13: inv_odd6 = 6'd5;
            6'd15: inv_odd6 = 6'd47;
            6'd17: inv_odd6 = 6'd49;
            6'd19: inv_odd6 = 6'd27;
            6'd21: inv_odd6 = 6'd61;
            6'd23: inv_odd6 = 6'd39;
            6'd25: inv_odd6 = 6'd41;
            6'd27: inv_odd6 = 6'd19;
            6'd29: inv_odd6 = 6'd53;
            6'd31: inv_odd6 = 6'd31;
            6'd33: inv_odd6 = 6'd33;
            6'd35: inv_odd6 = 6'd11;
            6'd37: inv_odd6 = 6'd45;
            6'd39: inv_odd6 = 6'd23;
            6'd41: inv_odd6 = 6'd25;
            6'd43: inv_odd6 = 6'd3;
            6'd45: inv_odd6 = 6'd37;
            6'd47: inv_odd6 = 6'd15;
            6'd49: inv_odd6 = 6'd17;
            6'd51: inv_odd6 = 6'd59;
            6'd53: inv_odd6 = 6'd29;
            6'd55: inv_odd6 = 6'd7;
            6'd57: inv_odd6 = 6'd9;
            6'd59: inv_odd6 = 6'd51;
            6'd61: inv_odd6 = 6'd21;
            default: inv_odd6 = 6'd63;
        endcase
    end
endfunction

function automatic signed [5:0] div_a0_fast(input signed [9:0] num, input signed [2:0] den);
    begin
        case (den)
            3'b001: div_a0_fast = num[5:0];
            3'b111: div_a0_fast = -$signed(num[5:0]);
            3'b010: div_a0_fast = num[6:1];
            3'b110: div_a0_fast = -$signed(num[6:1]);
            3'b011: div_a0_fast = mul_mod6(num[5:0], 6'd43);
            3'b101: div_a0_fast = mul_mod6(num[5:0], 6'd21);
            default: div_a0_fast = -$signed(num[7:2]);
        endcase
    end
endfunction

wire signed [5:0] r1b = mul3_3(a0, b1) - mul3_3(a1, b0);
wire signed [5:0] r1c = mul3_3(a0, c1) - mul3_3(a1, c0);
wire signed [9:0] r1d = mul3_7(a0, d1) - mul3_7(a1, d0);
wire signed [5:0] r2b = mul3_3(a0, b2) - mul3_3(a2, b0);
wire signed [5:0] r2c = mul3_3(a0, c2) - mul3_3(a2, c0);
wire signed [9:0] r2d = mul3_7(a0, d2) - mul3_7(a2, d0);

wire signed [11:0] det2 = (r1b * r2c) - (r2b * r1c);
wire signed [15:0] num2 = (r1d * r2c) - (r2d * r1c);
wire signed [15:0] num3 = (r2d * r1b) - (r1d * r2b);

// Cycle 0: only the cheap rank flags (short compares, off the wide-mult tail)
wire r1_bad = (r1b == 6'sd0) && (r1c == 6'sd0) && (r1d != 10'sd0);
wire r2_bad = (r2b == 6'sd0) && (r2c == 6'sd0) && (r2d != 10'sd0);

// Cycle 1: exception classification from latched values (parallel to x1 chain)
wire infinite = (num2_r == 16'sd0) && (num3_r == 16'sd0) && !r1_bad_r && !r2_bad_r;
wire [1:0] ex_w = (det2_r == 12'sd0) ? (infinite ? 2'b01 : 2'b10) : 2'b00;

// Cycle 1: det_inv computed here from latched det2_r (off cycle-0 critical path)
wire [3:0] det_sh = tz12(det2_r);
wire [5:0] det_inv = inv_odd6(ashr6_12(det2_r, det_sh));
wire signed [5:0] x2_w = mul_mod6(ashr6(num2_r, det_sh), det_inv);
wire signed [5:0] x3_w = mul_mod6(ashr6(num3_r, det_sh), det_inv);
wire signed [9:0] x1_num = $signed({{3{d0_r[6]}}, d0_r}) - mul3_6(b0_r, x2_w) - mul3_6(c0_r, x3_w);
wire signed [5:0] x1_w = div_a0_fast(x1_num, a0_r);

assign exception = out_valid ? ex_w : 2'b00;
assign out_data0 = (out_valid && (ex_w == 2'b00)) ? x1_w : 6'sd0;
assign out_data1 = (out_valid && (ex_w == 2'b00)) ? x2_w : 6'sd0;
assign out_data2 = (out_valid && (ex_w == 2'b00)) ? x3_w : 6'sd0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= 1'b0;
        out_valid <= 1'b0;
    end else begin
        out_valid <= 1'b0;
        if (st) begin
            st <= 1'b0;
            out_valid <= 1'b1;
        end else if (in_valid) begin
            st <= 1'b1;
            a0_r <= a0;
            b0_r <= b0;
            c0_r <= c0;
            d0_r <= d0;
            num2_r <= num2;
            num3_r <= num3;
            det2_r <= det2;
            r1_bad_r <= r1_bad;
            r2_bad_r <= r2_bad;
        end
    end
end

endmodule
