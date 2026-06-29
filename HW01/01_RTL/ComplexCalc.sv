module ComplexCalc(
    // Input signals
    in_opcode,
    in_seq0,
    in_seq1,
    in_seq2,
    in_seq3,
    // Output signals
    out_ssd0,
    out_ssd1,
    out_ssd2,
    out_ssd3,
    out_ssd4,
    out_ssd5,
    out_ssd6,
    out_ssd7
);

//---------------------------------------------------------------------
//   Input and output declaration                         
//---------------------------------------------------------------------
input [2:0] in_opcode;

input [7:0] in_seq0;
input [7:0] in_seq1;
input [7:0] in_seq2;
input [7:0] in_seq3;

output logic [6:0] out_ssd0;
output logic [6:0] out_ssd1;
output logic [6:0] out_ssd2;
output logic [6:0] out_ssd3;
output logic [6:0] out_ssd4;
output logic [6:0] out_ssd5;
output logic [6:0] out_ssd6;
output logic [6:0] out_ssd7;

//---------------------------------------------------------------------
//   Logic declaration
//---------------------------------------------------------------------
logic [3:0] seq_real [0:3];
logic [3:0] seq_imag [0:3];


logic seq_bcd_err [0:3];
logic any_bcd_err;

logic [3:0] seq_norm [0:3];

logic [7:0] sorted_seq [0:3];
logic [3:0] sorted_norm0;
logic [3:0] sorted_norm2;
logic [1:0] sorted_idx [0:3];
logic signed [8:0] ans_real;
logic signed [8:0] ans_imag;

logic [6:0] calc_ssd [0:7];

//---------------------------------------------------------------------
//   Your design Step1 : BCD check and error detection
BCD_split_and_checker bcd_checker0(
    .in_seq(in_seq0),
    .real_part(seq_real[0]),
    .img_part(seq_imag[0]),
    .bcd_err(seq_bcd_err[0])
);
BCD_split_and_checker bcd_checker1(
    .in_seq(in_seq1),
    .real_part(seq_real[1]),
    .img_part(seq_imag[1]),
    .bcd_err(seq_bcd_err[1])
);
BCD_split_and_checker bcd_checker2(
    .in_seq(in_seq2),
    .real_part(seq_real[2]),
    .img_part(seq_imag[2]),
    .bcd_err(seq_bcd_err[2])
);
BCD_split_and_checker bcd_checker3(
    .in_seq(in_seq3),
    .real_part(seq_real[3]),
    .img_part(seq_imag[3]),
    .bcd_err(seq_bcd_err[3])
);
assign any_bcd_err = seq_bcd_err[0] | seq_bcd_err[1] | seq_bcd_err[2] | seq_bcd_err[3];
//--------------------------------------------------------------------- 

//   Your design Step2 & Step3 : Complex norm calculation via Newton-Raphson method 
complex_norm norm_calculator0(
    .real_part(seq_real[0]),
    .img_part(seq_imag[0]),
    .norm(seq_norm[0])
);
complex_norm norm_calculator1(
    .real_part(seq_real[1]),
    .img_part(seq_imag[1]),
    .norm(seq_norm[1])
);
complex_norm norm_calculator2(
    .real_part(seq_real[2]),
    .img_part(seq_imag[2]),
    .norm(seq_norm[2])
);
complex_norm norm_calculator3(
    .real_part(seq_real[3]),
    .img_part(seq_imag[3]),
    .norm(seq_norm[3])
);

// Step5: OPcode stable sort
StableSort norm_sorter(
    .in_norm0(seq_norm[0]),
    .in_norm1(seq_norm[1]),
    .in_norm2(seq_norm[2]),
    .in_norm3(seq_norm[3]),
    .in_opcode(in_opcode[2]),
    .out_idx0(sorted_idx[0]),
    .out_idx1(sorted_idx[1]),
    .out_idx2(sorted_idx[2]),
    .out_idx3(sorted_idx[3])
);

assign sorted_seq[0] = {seq_real[sorted_idx[0]], seq_imag[sorted_idx[0]]};
assign sorted_seq[1] = {seq_real[sorted_idx[1]], seq_imag[sorted_idx[1]]};
assign sorted_seq[2] = {seq_real[sorted_idx[2]], seq_imag[sorted_idx[2]]};
assign sorted_seq[3] = {seq_real[sorted_idx[3]], seq_imag[sorted_idx[3]]};
assign sorted_norm0 = seq_norm[sorted_idx[0]];
assign sorted_norm2 = seq_norm[sorted_idx[2]];


// Step5 result: run operator on sorted data.
Operator op_core(
    .seq0(sorted_seq[0]),
    .seq1(sorted_seq[1]),
    .seq2(sorted_seq[2]),
    .seq3(sorted_seq[3]),
    .norm0(sorted_norm0),
    //.norm1(sorted_norm[1]),
    .norm2(sorted_norm2),
    //.norm3(sorted_norm[3]),
    .opcode(in_opcode[1:0]),
    .ans_real(ans_real),
    .ans_imag(ans_imag)
);

DisplayFormatter disp_formatter(
    .ans_real(ans_real),
    .ans_imag(ans_imag),
    .calc_ssd0(calc_ssd[0]),
    .calc_ssd1(calc_ssd[1]),
    .calc_ssd2(calc_ssd[2]),
    .calc_ssd3(calc_ssd[3]),
    .calc_ssd4(calc_ssd[4]),
    .calc_ssd5(calc_ssd[5]),
    .calc_ssd6(calc_ssd[6]),
    .calc_ssd7(calc_ssd[7])
);

// Centralized error handling: any BCD error forces all SSD outputs to 'ERROR'.
assign out_ssd0 = any_bcd_err ? 7'b1111010 : calc_ssd[0];
assign out_ssd1 = any_bcd_err ? 7'b1100010 : calc_ssd[1];
assign out_ssd2 = any_bcd_err ? 7'b1111010 : calc_ssd[2];
assign out_ssd3 = any_bcd_err ? 7'b1111010 : calc_ssd[3];
assign out_ssd4 = any_bcd_err ? 7'b0110000 : calc_ssd[4];
assign out_ssd5 = any_bcd_err ? 7'b1111111 : calc_ssd[5];
assign out_ssd6 = any_bcd_err ? 7'b1111111 : calc_ssd[6];
assign out_ssd7 = any_bcd_err ? 7'b1111111 : calc_ssd[7];


endmodule



module BCD_split_and_checker(
    input [7:0] in_seq,
    output logic [3:0] real_part,
    output logic [3:0] img_part,
    output logic bcd_err
);
    // A valid BCD digit is in the range 0 to 9.
    assign real_part = in_seq[7:4];
    assign img_part = in_seq[3:0];
    assign bcd_err = (in_seq[7:4] > 4'd9 || in_seq[3:0] > 4'd9 || (in_seq[7:4] == 4'd0 && in_seq[3:0] == 4'd0));
endmodule


module complex_norm(
    input [3:0] real_part,
    input [3:0] img_part,
    output logic [3:0] norm
);
    logic [7:0] val;

    function automatic [7:0] square(input [3:0] x);
    begin
        case (x)
            4'd0:  square = 8'd0;
            4'd1:  square = 8'd1;
            4'd2:  square = 8'd4;
            4'd3:  square = 8'd9;
            4'd4:  square = 8'd16;
            4'd5:  square = 8'd25;
            4'd6:  square = 8'd36;
            4'd7:  square = 8'd49;
            4'd8:  square = 8'd64;
            4'd9:  square = 8'd81;
            default: square = 8'd0;
        endcase
    end
    endfunction

    always_comb begin
        // Floor(sqrt(real^2 + imag^2)) using compare thresholds, divider-free.
        val = square(real_part) + square(img_part);
        if (val >= 8'd144)      norm = 4'd12;
        else if (val >= 8'd121) norm = 4'd11;
        else if (val >= 8'd100) norm = 4'd10;
        else if (val >= 8'd81)  norm = 4'd9;
        else if (val >= 8'd64)  norm = 4'd8;
        else if (val >= 8'd49)  norm = 4'd7;
        else if (val >= 8'd36)  norm = 4'd6;
        else if (val >= 8'd25)  norm = 4'd5;
        else if (val >= 8'd16)  norm = 4'd4;
        else if (val >= 8'd9)   norm = 4'd3;
        else if (val >= 8'd4)   norm = 4'd2;
        else if (val >= 8'd1)   norm = 4'd1;
        else                    norm = 4'd0;
    end
endmodule

module StableSort(
    input [3:0] in_norm0,
    input [3:0] in_norm1,
    input [3:0] in_norm2,
    input [3:0] in_norm3,
    input in_opcode,
    output logic [1:0] out_idx0,
    output logic [1:0] out_idx1,
    output logic [1:0] out_idx2,
    output logic [1:0] out_idx3
);

logic [1:0] tmp_idx [0:3];
logic [2:0] idx;

always_comb begin

    if(in_opcode == 1'b0) begin
        // No sort, pass through.
        out_idx0 = 2'd0;
        out_idx1 = 2'd1;
        out_idx2 = 2'd2;
        out_idx3 = 2'd3;
    end
    else begin 
        // Keep defaults so if any compare becomes X, outputs still stay deterministic.
        idx = 3'd0;
        tmp_idx[0] = 2'd0;
        tmp_idx[1] = 2'd1;
        tmp_idx[2] = 2'd2;
        tmp_idx[3] = 2'd3;

        // Pass 1: place all norm < 7 entries in original order.
        if (in_norm0 < 4'd7) begin tmp_idx[idx] = 2'd0; idx = idx + 3'd1; end
        if (in_norm1 < 4'd7) begin tmp_idx[idx] = 2'd1; idx = idx + 3'd1; end
        if (in_norm2 < 4'd7) begin tmp_idx[idx] = 2'd2; idx = idx + 3'd1; end
        if (in_norm3 < 4'd7) begin tmp_idx[idx] = 2'd3; idx = idx + 3'd1; end

        // Pass 2: place all norm >= 7 entries in original order.
        if (!(in_norm0 < 4'd7)) begin tmp_idx[idx] = 2'd0; idx = idx + 3'd1; end
        if (!(in_norm1 < 4'd7)) begin tmp_idx[idx] = 2'd1; idx = idx + 3'd1; end
        if (!(in_norm2 < 4'd7)) begin tmp_idx[idx] = 2'd2; idx = idx + 3'd1; end
        if (!(in_norm3 < 4'd7)) begin tmp_idx[idx] = 2'd3; idx = idx + 3'd1; end

        out_idx0 = tmp_idx[0];
        out_idx1 = tmp_idx[1];
        out_idx2 = tmp_idx[2];
        out_idx3 = tmp_idx[3];
    end
end
endmodule


module Operator(
    input [7:0] seq0,
    input [7:0] seq1,
    input [7:0] seq2,
    input [7:0] seq3,
    input [3:0] norm0,
    input [3:0] norm2,
    input [1:0] opcode,
    output logic signed [8:0] ans_real,
    output logic signed [8:0] ans_imag
);

logic [3:0] A,C,E,G;
logic [3:0] B,D,F,H;
logic [7:0] div_denom;

function automatic [7:0] square(input [3:0] x);
begin
    case (x)
        4'd0:  square = 8'd0;
        4'd1:  square = 8'd1;
        4'd2:  square = 8'd4;
        4'd3:  square = 8'd9;
        4'd4:  square = 8'd16;
        4'd5:  square = 8'd25;
        4'd6:  square = 8'd36;
        4'd7:  square = 8'd49;
        4'd8:  square = 8'd64;
        4'd9:  square = 8'd81;
        default: square = 8'dx;
    endcase
end
endfunction


function automatic [3:0] floor_log2(input [3:0] val);
begin
    if (val[3]) floor_log2 = 4'd3;
    else if (val[2]) floor_log2 = 4'd2;
    else if (val[1]) floor_log2 = 4'd1;
    else floor_log2 = 4'd0;
end
endfunction

assign A = seq0[7:4];
assign B = seq0[3:0];
assign C = seq1[7:4];
assign D = seq1[3:0];
assign E = seq2[7:4];
assign F = seq2[3:0];
assign G = seq3[7:4];
assign H = seq3[3:0];

assign div_denom = square(A) + square(B);

// 先把乘法結果轉成 signed 9-bit，後面減法才不會炸掉


always_comb begin
    ans_real = 9'sdx;
    ans_imag = 9'sd0;

    case (opcode)
        2'b00: begin
            // (E + Fi) * (C + Di)
            ans_real = ($signed({1'b0,E}) * $signed({1'b0,C})) -
                       ($signed({1'b0,F}) * $signed({1'b0,D}));
            ans_imag = ($signed({1'b0,E}) * $signed({1'b0,D})) +
                       ($signed({1'b0,F}) * $signed({1'b0,C}));
        end

        2'b01: begin
            // (G + Hi) / (A + Bi)
            if (div_denom == 8'd0) begin
                ans_real = 9'sd0;
            end else begin
                ans_real = (($signed({1'b0,G}) * $signed({1'b0,A})) +
                            ($signed({1'b0,H}) * $signed({1'b0,B}))) /
                           $signed({1'b0, div_denom});
                ans_imag = (($signed({1'b0,H}) * $signed({1'b0,A})) -
                            ($signed({1'b0,G}) * $signed({1'b0,B}))) /
                           $signed({1'b0, div_denom});
            end
        end

        2'b10: begin
            ans_real = $signed({5'b0, floor_log2(norm0)+floor_log2(norm2)});
        end

        2'b11: begin
            ans_real = (($signed({1'b0,square(C)}) +
                         $signed({1'b0,square(D)})) -
                        ($signed({1'b0,square(G)}) +
                         $signed({1'b0,square(H)})));
        end
    endcase
end

endmodule

module DisplayFormatter(
    input logic signed [8:0] ans_real,
    input logic signed [8:0] ans_imag,
    output logic [6:0] calc_ssd0,
    output logic [6:0] calc_ssd1,
    output logic [6:0] calc_ssd2,
    output logic [6:0] calc_ssd3,
    output logic [6:0] calc_ssd4,
    output logic [6:0] calc_ssd5,
    output logic [6:0] calc_ssd6,
    output logic [6:0] calc_ssd7
);

logic real_neg, imag_neg;
logic [7:0] real_abs, imag_abs;
logic [3:0] real_hundreds, real_tens, real_ones;
logic [3:0] imag_hundreds, imag_tens, imag_ones;

function automatic [6:0] ssd_encode(input [3:0] sym);
begin
    case (sym)
        4'd0: ssd_encode = 7'b0000001;
        4'd1: ssd_encode = 7'b1001111;
        4'd2: ssd_encode = 7'b0010010;
        4'd3: ssd_encode = 7'b0000110;
        4'd4: ssd_encode = 7'b1001100;
        4'd5: ssd_encode = 7'b0100100;
        4'd6: ssd_encode = 7'b0100000;
        4'd7: ssd_encode = 7'b0001111;
        4'd8: ssd_encode = 7'b0000000;
        4'd9: ssd_encode = 7'b0000100;
        default: ssd_encode = 7'bx;
    endcase
end
endfunction

task automatic split_decimal_8b;
    input  logic [7:0] abs_val;
    output logic [3:0] hundreds;
    output logic [3:0] tens;
    output logic [3:0] ones;

    logic [7:0] rem1;
    logic [7:0] rem2;
begin
    hundreds = 4'd0;
    tens     = 4'dx;
    ones     = 4'dx;
    rem1    = abs_val;
    rem2    = 8'd0;


    if (abs_val >= 8'd100) begin
        hundreds = 4'd1;
        rem1 = abs_val - 8'd100;
    end

    if (rem1 >= 8'd90) begin tens = 4'd9; rem2 = rem1 - 8'd90; end
    else if (rem1 >= 8'd80) begin tens = 4'd8; rem2 = rem1 - 8'd80; end
    else if (rem1 >= 8'd70) begin tens = 4'd7; rem2 = rem1 - 8'd70; end
    else if (rem1 >= 8'd60) begin tens = 4'd6; rem2 = rem1 - 8'd60; end
    else if (rem1 >= 8'd50) begin tens = 4'd5; rem2 = rem1 - 8'd50; end
    else if (rem1 >= 8'd40) begin tens = 4'd4; rem2 = rem1 - 8'd40; end
    else if (rem1 >= 8'd30) begin tens = 4'd3; rem2 = rem1 - 8'd30; end
    else if (rem1 >= 8'd20) begin tens = 4'd2; rem2 = rem1 - 8'd20; end
    else if (rem1 >= 8'd10) begin tens = 4'd1; rem2 = rem1 - 8'd10; end
    else begin tens = 4'd0; rem2 = rem1; end

    ones = rem2[3:0];

end
endtask

task automatic format_4ssd;
    input  logic       neg;
    input  logic [3:0] hundreds;
    input  logic [3:0] tens;
    input  logic [3:0] ones;
    output logic [6:0] s3;
    output logic [6:0] s2;
    output logic [6:0] s1;
    output logic [6:0] s0;
    logic [6:0] blank_sym;
    logic [6:0] sign_sym; 
begin   
    blank_sym = 7'b1111111; // blank
    sign_sym  = neg ? 7'b1111110 : blank_sym;

    // Default: right-align ones, others blank; then overwrite by actual digit width.
    s3 = blank_sym;
    s2 = blank_sym;
    s1 = sign_sym;
    s0 = ssd_encode(ones);

    if (hundreds != 4'd0) begin
        s3 = sign_sym;
        s2 = ssd_encode(hundreds);
        s1 = ssd_encode(tens);
    end
    else if (tens != 4'd0) begin
        s2 = sign_sym;
        s1 = ssd_encode(tens);
    end
end
endtask

always_comb begin
    real_neg = ans_real[8];
    imag_neg = ans_imag[8];

    // Keep magnitude conversion in 8-bit domain to avoid extra 9-bit adder/truncation logic.
    real_abs = real_neg ? (~ans_real[7:0] + 8'd1) : ans_real[7:0];
    imag_abs = imag_neg ? (~ans_imag[7:0] + 8'd1) : ans_imag[7:0];

    split_decimal_8b(real_abs, real_hundreds, real_tens, real_ones);
    split_decimal_8b(imag_abs, imag_hundreds, imag_tens, imag_ones);

    format_4ssd(
        real_neg,
        real_hundreds, real_tens,real_ones,
        calc_ssd7, calc_ssd6, calc_ssd5, calc_ssd4
    );

    format_4ssd(
        imag_neg,
        imag_hundreds, imag_tens, imag_ones,
        calc_ssd3, calc_ssd2, calc_ssd1, calc_ssd0
    );
end

endmodule