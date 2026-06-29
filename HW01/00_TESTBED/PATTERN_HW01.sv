`define CYCLE_TIME 10.0
`define SEED 405
`define PATNUM 10000
//SEED 405

module PATTERN(
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
//   PORT DECLARATION
//---------------------------------------------------------------------
output logic [2:0] in_opcode;

output logic [7:0] in_seq0;
output logic [7:0] in_seq1;
output logic [7:0] in_seq2;
output logic [7:0] in_seq3;

input [6:0] out_ssd0;
input [6:0] out_ssd1;
input [6:0] out_ssd2;
input [6:0] out_ssd3;
input [6:0] out_ssd4;
input [6:0] out_ssd5;
input [6:0] out_ssd6;
input [6:0] out_ssd7;
//================================================================
// clock
//================================================================
logic clk;
real CYCLE = `CYCLE_TIME;
always #(CYCLE/2.0) clk = ~clk;
//================================================================
// parameters & integer
//================================================================
integer seed = `SEED;
integer patnum = `PATNUM;
integer patcount;
//================================================================
// register
//================================================================
integer error;
integer norm0;
integer norm1;
integer norm2;
integer norm3;

integer i, j;
reg [7:0] seq_arr [0:3];
integer norm_arr [0:3];
reg [7:0] temp_seq;
integer temp_norm;

integer a, b, c, d, e, f, g, h;
integer out_real;
integer out_imag;

integer real_abs;
integer imag_abs;

logic [6:0] golden_out_ssd0;
logic [6:0] golden_out_ssd1;
logic [6:0] golden_out_ssd2;
logic [6:0] golden_out_ssd3;
logic [6:0] golden_out_ssd4;
logic [6:0] golden_out_ssd5;
logic [6:0] golden_out_ssd6;
logic [6:0] golden_out_ssd7;
//================================================================
// initial
//================================================================
initial begin
	clk = 0;
	in_opcode = 3'bx;
	in_seq0 = 8'bx;
	in_seq1 = 8'bx;
	in_seq2 = 8'bx;
	in_seq3 = 8'bx;
	
	for (patcount=0; patcount<patnum; patcount=patcount+1) begin		
		input_task;
		calc_task;
        repeat(1) @(negedge clk);
		check_task;
		$display("\033[0;32mPASS PATTERN NO.%3d \033[m", patcount);
	end

	YOU_PASS_task;
	$finish;
end
//================================================================
// task
//================================================================

task input_task; begin
	in_opcode = {$random(seed)} % 7;
	in_seq0[7:4] = bcd();
	in_seq0[3:0] = bcd();
	in_seq1[7:4] = bcd();
	in_seq1[3:0] = bcd();
	in_seq2[7:4] = bcd();
	in_seq2[3:0] = bcd();
	in_seq3[7:4] = bcd();
	in_seq3[3:0] = bcd();
end endtask

task calc_task; begin
	error = check_error(in_seq0) || check_error(in_seq1) || check_error(in_seq2) || check_error(in_seq3);

	if (error) begin
		golden_out_ssd7 = encode_ssd(10); // Blank
		golden_out_ssd6 = encode_ssd(10); // Blank
		golden_out_ssd5 = encode_ssd(10); // Blank
		golden_out_ssd4 = encode_ssd(12); // E
		golden_out_ssd3 = encode_ssd(13); // r
		golden_out_ssd2 = encode_ssd(13); // r
		golden_out_ssd1 = encode_ssd(14); // o
		golden_out_ssd0 = encode_ssd(13); // r
	end else begin
		norm0 = calc_sqrt((in_seq0[7:4] * in_seq0[7:4]) + (in_seq0[3:0] * in_seq0[3:0]));
        norm1 = calc_sqrt((in_seq1[7:4] * in_seq1[7:4]) + (in_seq1[3:0] * in_seq1[3:0]));
        norm2 = calc_sqrt((in_seq2[7:4] * in_seq2[7:4]) + (in_seq2[3:0] * in_seq2[3:0]));
        norm3 = calc_sqrt((in_seq3[7:4] * in_seq3[7:4]) + (in_seq3[3:0] * in_seq3[3:0]));

        seq_arr[0] = in_seq0; 
		seq_arr[1] = in_seq1;
        seq_arr[2] = in_seq2; 
		seq_arr[3] = in_seq3;
        norm_arr[0] = norm0;  
		norm_arr[1] = norm1;
        norm_arr[2] = norm2;  
		norm_arr[3] = norm3;

        if (in_opcode[2]) begin
            for (i = 0; i < 3; i = i + 1) begin
                for (j = 0; j < 3 - i; j = j + 1) begin
                    if ((norm_arr[j] >= 7) && (norm_arr[j+1] < 7)) begin
                        temp_norm = norm_arr[j];
                        norm_arr[j] = norm_arr[j+1];
                        norm_arr[j+1] = temp_norm;

                        temp_seq = seq_arr[j];
                        seq_arr[j] = seq_arr[j+1];
                        seq_arr[j+1] = temp_seq;
                    end
                end
            end
        end
 
        a = seq_arr[0][7:4]; b = seq_arr[0][3:0];
        c = seq_arr[1][7:4]; d = seq_arr[1][3:0];
        e = seq_arr[2][7:4]; f = seq_arr[2][3:0];
        g = seq_arr[3][7:4]; h = seq_arr[3][3:0];

        case (in_opcode[1:0])
            2'b00: begin
                // (e+fi) * (c+di)
                out_real = (e * c) - (f * d);
                out_imag = (e * d) + (f * c);
            end
            2'b01: begin
                // (g+hi) / (a+bi)
                out_real = ((g * a) + (h * b)) / ((a * a) + (b * b));
                out_imag = ((h * a) - (g * b)) / ((a * a) + (b * b));
            end
            2'b10: begin
                // log2(||a+bi||) + log2(||e+fi||)
                out_real = calc_log2(norm_arr[0]) + calc_log2(norm_arr[2]);
                out_imag = 0;
            end
            2'b11: begin
                // (c+di)*(c+di)' - (g+hi)*(g+hi)'
                out_real = ((c * c) + (d * d)) - ((g * g) + (h * h));
                out_imag = 0;
            end
        endcase
        
        real_abs = (out_real < 0) ? -out_real : out_real;
        
        golden_out_ssd4 = encode_ssd(real_abs % 10);
        if (real_abs >= 100) begin
            golden_out_ssd5 = encode_ssd((real_abs / 10) % 10);
            golden_out_ssd6 = encode_ssd(real_abs / 100);
            golden_out_ssd7 = (out_real < 0) ? encode_ssd(11) : encode_ssd(10);
        end else if (real_abs >= 10) begin
            golden_out_ssd5 = encode_ssd(real_abs / 10);
            golden_out_ssd6 = (out_real < 0) ? encode_ssd(11) : encode_ssd(10);
            golden_out_ssd7 = encode_ssd(10);
        end else begin
            golden_out_ssd5 = (out_real < 0) ? encode_ssd(11) : encode_ssd(10);
            golden_out_ssd6 = encode_ssd(10);
            golden_out_ssd7 = encode_ssd(10);
        end

        imag_abs = (out_imag < 0) ? -out_imag : out_imag;
        
        golden_out_ssd0 = encode_ssd(imag_abs % 10);
        if (imag_abs >= 100) begin
            golden_out_ssd1 = encode_ssd((imag_abs / 10) % 10);
            golden_out_ssd2 = encode_ssd(imag_abs / 100);
            golden_out_ssd3 = (out_imag < 0) ? encode_ssd(11) : encode_ssd(10);
        end else if (imag_abs >= 10) begin
            golden_out_ssd1 = encode_ssd(imag_abs / 10);
            golden_out_ssd2 = (out_imag < 0) ? encode_ssd(11) : encode_ssd(10);
            golden_out_ssd3 = encode_ssd(10);
        end else begin
            golden_out_ssd1 = (out_imag < 0) ? encode_ssd(11) : encode_ssd(10);
            golden_out_ssd2 = encode_ssd(10);
            golden_out_ssd3 = encode_ssd(10);
        end
	end
end endtask

task check_task; 
    integer k;
    logic [6:0] g_ssd [0:7];
    logic [6:0] y_ssd [0:7];
begin
    if({out_ssd7, out_ssd6, out_ssd5, out_ssd4, out_ssd3, out_ssd2, out_ssd1, out_ssd0} !== 
       {golden_out_ssd7, golden_out_ssd6, golden_out_ssd5, golden_out_ssd4, golden_out_ssd3, golden_out_ssd2, golden_out_ssd1, golden_out_ssd0}) begin
        
        g_ssd[7] = golden_out_ssd7; g_ssd[6] = golden_out_ssd6; g_ssd[5] = golden_out_ssd5; g_ssd[4] = golden_out_ssd4;
        g_ssd[3] = golden_out_ssd3; g_ssd[2] = golden_out_ssd2; g_ssd[1] = golden_out_ssd1; g_ssd[0] = golden_out_ssd0;

        y_ssd[7] = out_ssd7; y_ssd[6] = out_ssd6; y_ssd[5] = out_ssd5; y_ssd[4] = out_ssd4;
        y_ssd[3] = out_ssd3; y_ssd[2] = out_ssd2; y_ssd[1] = out_ssd1; y_ssd[0] = out_ssd0;

        fail;
        $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
        $display ("                                                              ANSWER FAIL!                                                                  ");
        $display ("                                                             Pattern No. %3d                                                                ", patcount);
        $display ("============================================================= DEBUG INFO ===================================================================");
        $display (" [INPUTS]  in_opcode = %3b (Stable-Sort:%b, Calc-Mode:%2b)", in_opcode, in_opcode[2], in_opcode[1:0]);
        $display ("           in_seq0 = %2h (Real:%0d, Imag:%0d), in_seq1 = %2h (Real:%0d, Imag:%0d)", in_seq0, in_seq0[7:4], in_seq0[3:0], in_seq1, in_seq1[7:4], in_seq1[3:0]);
        $display ("           in_seq2 = %2h (Real:%0d, Imag:%0d), in_seq3 = %2h (Real:%0d, Imag:%0d)", in_seq2, in_seq2[7:4], in_seq2[3:0], in_seq3, in_seq3[7:4], in_seq3[3:0]);
        $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
        
        if (error) begin
            $display (" [DEBUG]   Error Detected! (Expecting ERROR output)");
        end else begin
            $display (" [DEBUG]   Sorted seq: A=%0d, B=%0d, C=%0d, D=%0d, E=%0d, F=%0d, G=%0d, H=%0d", a, b, c, d, e, f, g, h);
            $display (" [DEBUG]   Calculated: Real = %0d, Imag = %0d", out_real, out_imag);
        end
        
        $display ("============================================================================================================================================");
        $display (" [GOLDEN]  ssd7~0: %7b_%7b_%7b_%7b_%7b_%7b_%7b_%7b", golden_out_ssd7, golden_out_ssd6, golden_out_ssd5, golden_out_ssd4, golden_out_ssd3, golden_out_ssd2, golden_out_ssd1, golden_out_ssd0);
        
        $display (" [GOLDEN]  7-Segment Display:");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write("  SSD%0d   ", k);
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" +-----+ ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" |  %s  | ", ~g_ssd[k][6] ? "_" : " ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" | %s%s%s | ", ~g_ssd[k][1]?"|":" ", ~g_ssd[k][0]?"_":" ", ~g_ssd[k][5]?"|":" ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" | %s%s%s | ", ~g_ssd[k][2]?"|":" ", ~g_ssd[k][3]?"_":" ", ~g_ssd[k][4]?"|":" ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" +-----+ ");
        $display ("\n");

        $display (" [YOURS ]  ssd7~0: %7b_%7b_%7b_%7b_%7b_%7b_%7b_%7b", out_ssd7, out_ssd6, out_ssd5, out_ssd4, out_ssd3, out_ssd2, out_ssd1, out_ssd0);
        
        $display (" [YOURS ]  7-Segment Display:");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write("  SSD%0d   ", k);
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" +-----+ ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" |  %s  | ", ~y_ssd[k][6] ? "_" : " ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" | %s%s%s | ", ~y_ssd[k][1]?"|":" ", ~y_ssd[k][0]?"_":" ", ~y_ssd[k][5]?"|":" ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" | %s%s%s | ", ~y_ssd[k][2]?"|":" ", ~y_ssd[k][3]?"_":" ", ~y_ssd[k][4]?"|":" ");
        $display ("");
        $write   ("           ");
        for (k=7; k>=0; k=k-1) $write(" +-----+ ");
        $display ("\n");

        $display ("                                                              at %8t ns                                                                     ", $time);
        $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
        
        $finish;
    end
end endtask

//================================================================
// function
//================================================================

function [3:0] bcd;
    integer prob;
    begin
        prob = {$random(seed)} % 100; 
        if (prob < 99) begin
            bcd = {$random(seed)} % 10;
        end else begin
            bcd = {$random(seed)} % 6 + 10;
        end
    end
endfunction

function check_error;
    input [7:0] seq;
    begin
        if ((seq[7:4] > 9) || (seq[3:0] > 9) || (seq == 8'h00)) begin
            check_error = 1;
        end else begin
            check_error = 0;
        end
    end
endfunction

function integer calc_sqrt;
    input integer val;
    integer i;
    begin
        calc_sqrt = 0;
        for (i = 0; (i * i) <= val; i = i + 1) begin
            calc_sqrt = i;
        end
    end
endfunction

function integer calc_log2;
    input integer val;
    integer temp;
    begin
        calc_log2 = 0;
        temp = val;
        while (temp > 1) begin
            temp = temp >> 1;
            calc_log2 = calc_log2 + 1;
        end
    end
endfunction

function [6:0] encode_ssd;
    input integer val;
    reg [6:0] active_high_val;
    begin
        case(val)
            0: active_high_val = 7'b1111110; // 0
            1: active_high_val = 7'b0110000; // 1
            2: active_high_val = 7'b1101101; // 2
            3: active_high_val = 7'b1111001; // 3
            4: active_high_val = 7'b0110011; // 4
            5: active_high_val = 7'b1011011; // 5
            6: active_high_val = 7'b1011111; // 6
            7: active_high_val = 7'b1110000; // 7
            8: active_high_val = 7'b1111111; // 8
            9: active_high_val = 7'b1111011; // 9
            10: active_high_val = 7'b0000000; // Blank
            11: active_high_val = 7'b0000001; // -
            12: active_high_val = 7'b1001111; // E
            13: active_high_val = 7'b0000101; // r
            14: active_high_val = 7'b0011101; // o
            default: active_high_val = 7'b0000000;
        endcase
        encode_ssd = ~active_high_val;
    end
endfunction

//================================================================
// default
//================================================================

task YOU_PASS_task;begin
                                                          ");        
\033[32m      :BBQvi.                                              ");        
\033[32m     BBBBBBBBQi                                           ");        
\033[32m    :BBBP :7BBBB.                                         ");        
\033[32m    BBBB     BBBB                                         ");        
\033[32m   iBBBv     BBBB       vBr                               ");        
\033[32m   BBBBBKrirBBBB.     :BBBBBB:                            ");        
\033[32m  rBBBBBBBBBBBR.    .BBBM:BBB                             ");        
\033[32m  BBBB   .::.      EBBBi :BBU                             ");        
\033[32m MBBBr           vBBBu   BBB.                             ");        
\033[32m i7PB          iBBBBB.  iBBB                              ");        
           \033[32m  vBBBBPBBBBPBBB7       .7QBB5i                ");        
           \033[32m :RBBB.  .rBBBBB.      rBBBBBBBB7              ");        
.          \033[32m    .       BBBB       BBBB  :BBBB             ");        
Bi         \033[32m           rBBBr       BBBB    BBBU            ");        
3[37m.LBBBBBBBBBBBBBBBBBBBBBB. B7.:ii:   \033[32m           vBBB        .BBBB   :7i.            ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBB  Jr:::rK7 \033[32m             .7  BBB7   iBBBg                  ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBB..i   .   v1                  \033[32mdBBB.   5BBBr                 ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBB iD2BBQL.                 \033[32m ZBBBr  EBBBv     YBBBBQi     ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBY.:.      :B                 \033[32m  iBBBBBBBBD     BBBBBBBBB.   ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBMBBB. BP17si                 \033[32m    :LBBBr      vBBBi  5BBB   ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBsiJr .i7ssr:                \033[32m          ...   :BBB:   BBBu  ");        
3[37mQBBBBBBBBBBBBBBBBBBBBBBBBi.ir      iB                \033[32m         .BBBi   BBBB   iMBu  ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBB rBrXPv.                \033[32m          BBBX   :BBBr        ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBB .L:ii::irrrrrrrr7jIr   \033[32m          .BBBv  :BBBQ        ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBB:            ..... ..YB. \033[32m           .BBBBBBBBB:        ");        
3[37mgBBBBBBBBBBBBBBBBBBBBBBBBBB. gBBBBBBBBBBBBBBBBBB. BL \033[32m             rBBBBB1.         ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBB. QBBBBBBBBBBBBBBBBBi  v5                                ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBgu7i.:BBBBBBBr Bu                                 ");        
3[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBv:.  .. :::  .rr    rB                                  ");        
v  :iJ7vri:::1Jr..isJYr                                   ");        
  B:           iir:                                       ");        
 B.                                                       ");        
Br                                                        ");        
B                                                         ");        
.                                                         ");        
                                                          ");        
                                                          ");        
                                                          ");        
                                                          ");        
B:                                                        ");        
 B                                                        ");        
 Br                                                       ");        
 Bi                                                       ");        
 Bi                                                       ");        
..rI                                                      ");        
.  B.                                                     ");        
UgU.                                                      ");        
                                                          \033[m");
$display ("----------------------------------------------------------------------------------------------------------------------");
$display ("                                                  Congratulations!                						             ");
$display ("                                           You have passed all patterns!          						             ");
$display ("----------------------------------------------------------------------------------------------------------------------");

$finish;	
end endtask


task fail; begin
$display("\033[38;2;252;238;238m                                                                                                                                           ");      
$display("\033[38;2;252;238;238m                                                                                                :L777777v7.                                ");
$display("\033[31m  i:..::::::i.      :::::         ::::    .:::.       \033[38;2;252;238;238m                                       .vYr::::::::i7Lvi                             ");
$display("\033[31m  BBBBBBBBBBBi     iBBBBBL       .BBBB    7BBB7       \033[38;2;252;238;238m                                      JL..\033[38;2;252;172;172m:r777v777i::\033[38;2;252;238;238m.ijL                           ");
$display("\033[31m  BBBB.::::ir.     BBB:BBB.      .BBBv    iBBB:       \033[38;2;252;238;238m                                    :K: \033[38;2;252;172;172miv777rrrrr777v7:.\033[38;2;252;238;238m:J7                         ");
$display("\033[31m  BBBQ            :BBY iBB7       BBB7    :BBB:       \033[38;2;252;238;238m                                   :d \033[38;2;252;172;172m.L7rrrrrrrrrrrrr77v: \033[38;2;252;238;238miI.                       ");
$display("\033[31m  BBBB            BBB. .BBB.      BBB7    :BBB:       \033[38;2;252;238;238m                                  .B \033[38;2;252;172;172m.L7rrrrrrrrrrrrrrrrr7v..\033[38;2;252;238;238mBr                      ");
$display("\033[31m  BBBB:r7vvj:    :BBB   gBBs      BBB7    :BBB:       \033[38;2;252;238;238m                                  S:\033[38;2;252;172;172m v7rrrrrrrrrrrrrrrrrrr7v. \033[38;2;252;238;238mB:                     ");
$display("\033[31m  BBBBBBBBBB7    BBB:   .BBB.     BBB7    :BBB:       \033[38;2;252;238;238m                                 .D \033[38;2;252;172;172mi7rrrrrrr777rrrrrrrrrrr7v. \033[38;2;252;238;238mB.                    ");
$display("\033[31m  BBBB    ..    iBBBBBBBBBBBP     BBB7    :BBB:       \033[38;2;252;238;238m                                 rv\033[38;2;252;172;172m v7rrrrrr7rirv7rrrrrrrrrr7v \033[38;2;252;238;238m:I                    ");
$display("\033[31m  BBBB          BBBBi7vviQBBB.    BBB7    :BBB.       \033[38;2;252;238;238m                                 2i\033[38;2;252;172;172m.v7rrrrrr7i  :v7rrrrrrrrrrvi \033[38;2;252;238;238mB:                   ");
$display("\033[31m  BBBB         rBBB.      BBBQ   .BBBv    iBBB2ir777L7\033[38;2;252;238;238m                                 2i.\033[38;2;252;172;172mv7rrrrrr7v \033[38;2;252;238;238m:..\033[38;2;252;172;172mv7rrrrrrrrr77 \033[38;2;252;238;238mrX                   ");
$display("\033[31m .BBBB        :BBBB       BBBB7  .BBBB    7BBBBBBBBBBB\033[38;2;252;238;238m                                 Yv \033[38;2;252;172;172mv7rrrrrrrv.\033[38;2;252;238;238m.B \033[38;2;252;172;172m.vrrrrrrrrrrL.\033[38;2;252;238;238m:5                   ");
$display("\033[31m  . ..        ....         ...:   ....    ..   .......\033[38;2;252;238;238m                                 .q \033[38;2;252;172;172mr7rrrrrrr7i \033[38;2;252;238;238mPv \033[38;2;252;172;172mi7rrrrrrrrrv.\033[38;2;252;238;238m:S                   ");
$display("\033[38;2;252;238;238m                                                                                        Lr \033[38;2;252;172;172m77rrrrrr77 \033[38;2;252;238;238m:B. \033[38;2;252;172;172mv7rrrrrrrrv.\033[38;2;252;238;238m:S                   ");
$display("\033[38;2;252;238;238m                                                                                         B: \033[38;2;252;172;172m7v7rrrrrv. \033[38;2;252;238;238mBY \033[38;2;252;172;172mi7rrrrrrr7v \033[38;2;252;238;238miK                   ");
$display("\033[38;2;252;238;238m                                                                              .::rriii7rir7. \033[38;2;252;172;172m.r77777vi \033[38;2;252;238;238m7B  \033[38;2;252;172;172mvrrrrrrr7r \033[38;2;252;238;238m2r                   ");
$display("\033[38;2;252;238;238m                                                                       .:rr7rri::......    .     \033[38;2;252;172;172m.:i7s \033[38;2;252;238;238m.B. \033[38;2;252;172;172mv7rrrrr7L..\033[38;2;252;238;238mB                    ");
$display("\033[38;2;252;238;238m                                                        .::7L7rriiiirr77rrrrrrrr72BBBBBBBBBBBBvi:..  \033[38;2;252;172;172m.  \033[38;2;252;238;238mBr \033[38;2;252;172;172m77rrrrrvi \033[38;2;252;238;238mKi                    ");
$display("\033[38;2;252;238;238m                                                    :rv7i::...........    .:i7BBBBQbPPPqPPPdEZQBBBBBr:.\033[38;2;252;238;238m ii \033[38;2;252;172;172mvvrrrrvr \033[38;2;252;238;238mvs                     ");
$display("\033[38;2;252;238;238m                    .S77L.                      .rvi:. ..:r7QBBBBBBBBBBBgri.    .:BBBPqqKKqqqqPPPPPEQBBBZi  \033[38;2;252;172;172m:777vi \033[38;2;252;238;238mvI                      ");
$display("\033[38;2;252;238;238m                    B: ..Jv                   isi. .:rBBBBBQZPPPPqqqPPdERBBBBBi.    :BBRKqqqqqqqqqqqqPKDDBB:  \033[38;2;252;172;172m:7. \033[38;2;252;238;238mJr                       ");
$display("\033[38;2;252;238;238m                   vv SB: iu                rL: .iBBBQEPqqPPqqqqqqqqqqqqqPPPPbQBBB:   .EBQKqqqqqqPPPqqKqPPgBB:  .B:                        ");
$display("\033[38;2;252;238;238m                  :R  BgBL..s7            rU: .qBBEKPqqqqqqqqqqqqqqqqqqqqqqqqqPPPEBBB:   EBEPPPEgQBBQEPqqqqKEBB: .s                        ");
$display("\033[38;2;252;238;238m               .U7.  iBZBBBi :ji         5r .MBQqPqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPKgBB:  .BBBBBdJrrSBBQKqqqqKZB7  I:                      ");
$display("\033[38;2;252;238;238m              v2. :rBBBB: .BB:.ru7:    :5. rBQqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPPBB:  :.        .5BKqqqqqqBB. Kr                     ");
$display("\033[38;2;252;238;238m             .B .BBQBB.   .RBBr  :L77ri2  BBqPqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPbBB   \033[38;2;252;172;172m.irrrrri  \033[38;2;252;238;238mQQqqqqqqKRB. 2i                    ");
$display("\033[38;2;252;238;238m              27 :BBU  rBBBdB \033[38;2;252;172;172m iri::::: \033[38;2;252;238;238m.BQKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqKRBs\033[38;2;252;172;172mirrr7777L: \033[38;2;252;238;238m7BqqqqqqqXZB. BLv772i              ");
$display("\033[38;2;252;238;238m               rY  PK  .:dPMB \033[38;2;252;172;172m.Y77777r.\033[38;2;252;238;238m:BEqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPPBqi\033[38;2;252;172;172mirrrrrv: \033[38;2;252;238;238muBqqqqqqqqqgB  :.:. B:             ");
$display("\033[38;2;252;238;238m                iu 7BBi  rMgB \033[38;2;252;172;172m.vrrrrri\033[38;2;252;238;238mrBEqKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPQgi\033[38;2;252;172;172mirrrrv. \033[38;2;252;238;238mQQqqqqqqqqqXBb .BBB .s:.           ");
$display("\033[38;2;252;238;238m                i7 BBdBBBPqbB \033[38;2;252;172;172m.vrrrri\033[38;2;252;238;238miDgPPbPqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPQDi\033[38;2;252;172;172mirr77 \033[38;2;252;238;238m:BdqqqqqqqqqqPB. rBB. .:iu7         ");
$display("\033[38;2;252;238;238m                iX.:iBRKPqKXB.\033[38;2;252;172;172m 77rrr\033[38;2;252;238;238mi7QPBBBBPqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPB7i\033[38;2;252;172;172mrr7r \033[38;2;252;238;238m.vBBPPqqqqqqKqBZ  BPBgri: 1B        ");
$display("\033[38;2;252;238;238m                 ivr .BBqqKXBi \033[38;2;252;172;172mr7rri\033[38;2;252;238;238miQgQi   QZKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPEQi\033[38;2;252;172;172mirr7r.  \033[38;2;252;238;238miBBqPqqqqqqPB:.QPPRBBB LK        ");
$display("\033[38;2;252;238;238m                   :I. iBgqgBZ \033[38;2;252;172;172m:7rr\033[38;2;252;238;238miJQPB.   gRqqqqqqqqPPPPPPPPqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqPQ7\033[38;2;252;172;172mirrr7vr.  \033[38;2;252;238;238mUBqqPPgBBQPBBKqqqKB  B         ");
$display("\033[38;2;252;238;238m                     v7 .BBR: \033[38;2;252;172;172m.r7ri\033[38;2;252;238;238miggqPBrrBBBBBBBBBBBBBBBBBBQEPPqqPPPqqqqqqqqqqqqqqqqqqqqqqqqqPgPi\033[38;2;252;172;172mirrrr7v7  \033[38;2;252;238;238mrBPBBP:.LBbPqqqqqB. u.        ");
$display("\033[38;2;252;238;238m                      .j. . \033[38;2;252;172;172m :77rr\033[38;2;252;238;238miiBPqPbBB::::::.....:::iirrSBBBBBBBQZPPPPPqqqqqqqqqqqqqqqqqqqqEQi\033[38;2;252;172;172mirrrrrr7v \033[38;2;252;238;238m.BB:     :BPqqqqqDB .B        ");
$display("\033[38;2;252;238;238m                       YL \033[38;2;252;172;172m.i77rrrr\033[38;2;252;238;238miLQPqqKQJ. \033[38;2;252;172;172m ............       \033[38;2;252;238;238m..:irBBBBBBZPPPqqqqqqqPPBBEPqqqdRr\033[38;2;252;172;172mirrrrrr7v \033[38;2;252;238;238m.B  .iBB  dQPqqqqPBi Y:       ");
$display("\033[38;2;252;238;238m                     :U:.\033[38;2;252;172;172mrv7rrrrri\033[38;2;252;238;238miPgqqqqKZB.\033[38;2;252;172;172m.v77777777777777ri::..   \033[38;2;252;238;238m  ..:rBBBBQPPqqqqPBUvBEqqqPRr\033[38;2;252;172;172mirrrrrrvi\033[38;2;252;238;238m iB:RBBbB7 :BQqPqKqBR r7       ");
$display("\033[38;2;252;238;238m                    iI.\033[38;2;252;172;172m.v7rrrrrrri\033[38;2;252;238;238midgqqqqqKB:\033[38;2;252;172;172m 77rrrrrrrrrrrrr77777777ri:..   \033[38;2;252;238;238m .:1BBBEPPB:   BbqqPQr\033[38;2;252;172;172mirrrr7vr\033[38;2;252;238;238m .BBBZPqqDB  .JBbqKPBi vi       ");
$display("\033[38;2;252;238;238m                   :B \033[38;2;252;172;172miL7rrrrrrrri\033[38;2;252;238;238mibgqqqqqqBr\033[38;2;252;172;172m r7rrrrrrrrrrrrrrrrrrrrr777777ri:.  \033[38;2;252;238;238m .iBBBBi  .BbqqdRr\033[38;2;252;172;172mirr7v7: \033[38;2;252;238;238m.Bi.dBBPqqgB:  :BPqgB  B        ");
$display("\033[38;2;252;238;238m                   .K.i\033[38;2;252;172;172mv7rrrrrrrri\033[38;2;252;238;238miZgqqqqqqEB \033[38;2;252;172;172m.vrrrrrrrrrrrrrrrrrrrrrrrrrrr777vv7i.  \033[38;2;252;238;238m :PBBBBPqqqEQ\033[38;2;252;172;172miir77:  \033[38;2;252;238;238m:BB:  .rBPqqEBB. iBZB. Rr        ");
$display("\033[38;2;252;238;238m                    iM.:\033[38;2;252;172;172mv7rrrrrrrri\033[38;2;252;238;238mUQPqqqqqPBi\033[38;2;252;172;172m i7rrrrrrrrrrrrrrrrrrrrrrrrr77777i.   \033[38;2;252;238;238m.  :BddPqqqqEg\033[38;2;252;172;172miir7. \033[38;2;252;238;238mrBBPqBBP. :BXKqgB  BBB. 2r         ");
$display("\033[38;2;252;238;238m                     :U:.\033[38;2;252;172;172miv77rrrrri\033[38;2;252;238;238mrBPqqqqqqPB: \033[38;2;252;172;172m:7777rrrrrrrrrrrrrrr777777ri.   \033[38;2;252;238;238m.:uBBBBZPqqqqqqPQL\033[38;2;252;172;172mirr77 \033[38;2;252;238;238m.BZqqPB:  qMqqPB. Yv:  Ur          ");
$display("\033[38;2;252;238;238m                       1L:.\033[38;2;252;172;172m:77v77rii\033[38;2;252;238;238mqQPqqqqqPbBi \033[38;2;252;172;172m .ir777777777777777ri:..   \033[38;2;252;238;238m.:rBBBRPPPPPqqqqqqqgQ\033[38;2;252;172;172miirr7vr \033[38;2;252;238;238m:BqXQ: .BQPZBBq ...:vv.           ");
$display("\033[38;2;252;238;238m                         LJi..\033[38;2;252;172;172m::r7rii\033[38;2;252;238;238mRgKPPPPqPqBB:.  \033[38;2;252;172;172m ............     \033[38;2;252;238;238m..:rBBBBPPqqKKKKqqqPPqPbB1\033[38;2;252;172;172mrvvvvvr  \033[38;2;252;238;238mBEEDQBBBBBRri. 7JLi              ");
$display("\033[38;2;252;238;238m                           .jL\033[38;2;252;172;172m  777rrr\033[38;2;252;238;238mBBBBBBgEPPEBBBvri:::::::::irrrbBBBBBBDPPPPqqqqqqXPPZQBBBBr\033[38;2;252;172;172m.......\033[38;2;252;238;238m.:BBBBg1ri:....:rIr                 ");
$display("\033[38;2;252;238;238m                            vI \033[38;2;252;172;172m:irrr:....\033[38;2;252;238;238m:rrEBBBBBBBBBBBBBBBBBBBBBBBBBBBBBQQBBBBBBBBBBBBBQr\033[38;2;252;172;172mi:...:.   \033[38;2;252;238;238m.:ii:.. .:.:irri::                    ");
$display("\033[38;2;252;238;238m                             71vi\033[38;2;252;172;172m:::irrr::....\033[38;2;252;238;238m    ...:..::::irrr7777777777777rrii::....  ..::irvrr7sUJYv7777v7ii..                         ");
$display("\033[38;2;252;238;238m                               .i777i. ..:rrri77rriiiiiii:::::::...............:::iiirr7vrrr:.                                             ");
$display("\033[38;2;252;238;238m                                                      .::::::::::::::::::::::::::::::                                                      \033[m");

end endtask

endmodule


