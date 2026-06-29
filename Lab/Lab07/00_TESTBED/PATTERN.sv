`define CYCLE_TIME 20.0

////synopsys translate_off

`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_dp2.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_mac.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_add.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_mult.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_sub.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_div.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_cmp.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_i2flt.v"
`include "/usr/cad/synopsys/synthesis/cur/dw/sim_ver/DW_fp_addsub.v"

////synopsys translate_on

module PATTERN(
    // output signals
    clk,
    rst_n,
    in_valid,
    in_data,
    factor_valid,
    factor,

    // input signals
    out_valid,
    out_data
);

//============================================================================================================
// PORT DECLARATION
//============================================================================================================
output logic clk, rst_n, in_valid, factor_valid;
output logic [7:0] in_data, factor;
input out_valid;
input [15:0] out_data;

// generate in_data & factor
logic       golden_s;
logic [1:0] golden_exp_fp4;
logic [3:0] golden_exp_fp8;
logic       golden_frac_fp4;
logic [2:0] golden_frac_fp8;

// translate fp4/fp8 to bf16
logic [7:0] golden_exp_fp4_to_bf16;
logic [6:0] golden_frac_fp4_to_bf16;
logic [7:0] golden_exp_fp8_to_bf16;
logic [6:0] golden_frac_fp8_to_bf16;

// temp signals
logic [3:0] in_a, in_b;

// golden input signals
logic [3:0] golden_fp4_a [0:3];
logic [3:0] golden_fp4_b [0:3];
logic [7:0] golden_fp8_factor;

logic [15:0] golden_data_a [0:3];
logic [15:0] golden_data_b [0:3];
logic [15:0] golden_factor;

// signals for golden answer calculation
logic [15:0] golden_product [0:3];
logic [15:0] golden_sum [0:3];
logic [15:0] golden_temp;
logic [15:0] golden_result;
logic [7:0]  st [0:24];

// check the result
logic [15:0] diff, ratio;
logic altb, agtb, aeqb, unordered, zctr;
logic [15:0] z0, z1, out_z;


//============================================================================================================
// clock
//============================================================================================================
real	CYCLE = `CYCLE_TIME;
always	#(CYCLE/2.0) clk = ~clk;

//============================================================================================================
// parameters & integer
//============================================================================================================
integer PATNUM = 500;
integer position = 120;
integer i, j, k, cnt;
integer patcount;
integer gap;
integer lat, total_latency;
integer int_ratio = 10; // 10

integer fd_in, fd_fac;
integer r_in, r_fac;

integer in_byte;     // read as int then cast to [7:0]
integer fac_byte;

integer in_idx;      // 0 .. PATNUM*4-1
integer fac_idx;     // 0 .. PATNUM-1

//============================================================================================================
// HardWare IP
// # (Fraction_width, Exponent_width, IEEE_compliance)
//============================================================================================================

genvar gi;
generate
    // product = ai * bi, i from 0 to 3
    for (gi = 0; gi < 4; gi = gi + 1) begin : GEN_MAC
        DW_fp_mult #(7, 8, 0) mac (.a(golden_data_a[gi]), .b(golden_data_b[gi]), .z(golden_product[gi]), .rnd(3'b000), .status(st[gi]));
    end

    // sum[3] = p0 + p1 + p2 + p3
    for (gi = 0; gi < 4; gi = gi + 1) begin : GEN_ADD
        if (gi == 0) begin
            DW_fp_add #(7, 8, 0) add (.a(golden_product[0]), .b(16'b0), .z(golden_sum[0]), .rnd(3'b000), .status(st[gi+4]));
        end
        else begin
            DW_fp_add #(7, 8, 0) add (.a(golden_sum[gi-1]), .b(golden_product[gi]), .z(golden_sum[gi]), .rnd(3'b000), .status(st[gi+8]));
        end
    end
endgenerate

// final result = sum[3] * factor[0]
DW_fp_mult #(7, 8, 0) sf_mult0 (.a(golden_sum[3]), .b(golden_factor), .z(golden_temp), .rnd(3'b000), .status(st[12]));

// scaling factor of bf16 = 0.5
logic [7:0] golden_exp;
assign golden_exp = golden_temp[14:7] - 2;

assign golden_result = {golden_temp[15], golden_exp, golden_temp[6:0]};

// check the result
DW_fp_sub #(7, 8, 0) ssub1(.a(out_data), .b(golden_result), .z(diff), .rnd(3'b000), .status(st[13]));
DW_fp_div #(7, 8, 0) sdiv1(.a({1'b0, golden_result[14:0]}), .b({1'b0, diff[14:0]}), .z(ratio), .rnd(3'b000), .status(st[14]));
DW_fp_i2flt #(7, 8, 32, 1) si2flt1(.a(int_ratio), .z(out_z), .rnd(3'b000), .status(st[15]));
DW_fp_cmp #(7, 8, 0) scmp1(.a(ratio), .b(out_z), .zctr(zctr), .altb(altb), .agtb(agtb), .aeqb(aeqb), .unordered(unordered), .z0(z0), .z1(z1), .status0(st[16]), .status1(st[17]));

// ============================================================================================================
// initial
// ============================================================================================================
initial begin
	rst_n = 1'd1;
    in_valid = 1'b0;
	in_data = 'bx;
	factor_valid = 1'b0;
    factor = 'bx;
    total_latency = 0;

	force clk = 0;
	reset_task;
	
    // open stimulus files
    fd_in  = $fopen("../00_TESTBED/in_data.hex", "r");
    if(fd_in == 0) begin
        $display("ERROR: cannot open in_data.hex");
        $finish;
    end

    fd_fac = $fopen("../00_TESTBED/factor.hex", "r");
    if(fd_fac == 0) begin
        $display("ERROR: cannot open factor.hex");
        $finish;
    end

    in_idx  = 0;
    fac_idx = 0;

	for(patcount=0; patcount<PATNUM; patcount=patcount+1) begin	
		input_task;
        WAIT_OUT_VALID;

	    check_ans;
	    $display("\033[0;32mPASS PATTERN NO.%3d \033[m", patcount);
	    $display ("                                                      S E        F       ");
        $display ("                                          your output:%1b %8b %7b", out_data[15], out_data[14:7], out_data[6:0]);
        $display ("                                        golden answer:%1b %8b %7b", golden_result[15], golden_result[14:7], golden_result[6:0]);
        
        @(negedge clk);
	    delay_gen;	
	end

	YOU_PASS_task;
	$finish;
end


// ============================================================================================================
// input
// ============================================================================================================

task input_task; begin
    // --------------------------
    // read 1 factor for this pattern
    // --------------------------
    r_fac = $fscanf(fd_fac, "%h\n", fac_byte);
    if (r_fac != 1) begin
        $display("ERROR: factor.hex EOF or bad format at pattern %0d (fac_idx=%0d)", patcount, fac_idx);
        $finish;
    end
    fac_idx = fac_idx + 1;

    // drive factor on i==0 only (1 cycle)
    factor_valid = 1'b1;
    factor       = fac_byte[7:0];
    golden_fp8_factor = factor;

    // translate fp8 factor to bf16 (same as your original rule)
    golden_s        = factor[7];
    golden_exp_fp8  = factor[6:3];
    golden_frac_fp8 = factor[2:0];

    golden_exp_fp8_to_bf16  = golden_exp_fp8 + 8'd120;
    golden_frac_fp8_to_bf16 = {golden_frac_fp8, 4'b0};
    golden_factor           = {golden_s, golden_exp_fp8_to_bf16, golden_frac_fp8_to_bf16};

    // --------------------------
    // send 4 in_data bytes
    // --------------------------
    for (i = 0; i < 4; i = i + 1) begin
        // read in_data byte
        r_in = $fscanf(fd_in, "%h\n", in_byte);
        if (r_in != 1) begin
            $display("ERROR: in_data.hex EOF or bad format at pattern %0d (in_idx=%0d)", patcount, in_idx);
            $finish;
        end
        in_idx = in_idx + 1;

        in_valid = 1'b1;
        in_data  = in_byte[7:0];

        // split fp4 a/b from in_data
        in_a = in_data[7:4];
        in_b = in_data[3:0];
        golden_fp4_a[i] = in_a;
        golden_fp4_b[i] = in_b;

        // ---- fp4 a -> bf16 ----
        golden_s        = in_a[3];
        golden_exp_fp4  = in_a[2:1];
        golden_frac_fp4 = in_a[0];

        golden_exp_fp4_to_bf16  = golden_exp_fp4 + 8'd126;
        golden_frac_fp4_to_bf16 = {golden_frac_fp4, 6'b0};
        golden_data_a[i]        = {golden_s, golden_exp_fp4_to_bf16, golden_frac_fp4_to_bf16};

        // ---- fp4 b -> bf16 ----
        golden_s        = in_b[3];
        golden_exp_fp4  = in_b[2:1];
        golden_frac_fp4 = in_b[0];

        golden_exp_fp4_to_bf16  = golden_exp_fp4 + 8'd126;
        golden_frac_fp4_to_bf16 = {golden_frac_fp4, 6'b0};
        golden_data_b[i]        = {golden_s, golden_exp_fp4_to_bf16, golden_frac_fp4_to_bf16};

        @(negedge clk);

        // after first cycle, deassert factor_valid and drive X if you want
        if (i == 0) begin
            factor_valid = 1'b0;
            factor       = 'bx;
        end
    end

    // end of this input burst
    in_valid = 1'b0;
    in_data  = 'bx;
    factor   = 'bx;
end endtask


// ============================================================================================================
// wait out_valid
// ============================================================================================================
task WAIT_OUT_VALID; begin
    lat = 0;
    while(out_valid !== 1) begin
        lat = lat + 1;
        if(lat == 30) begin
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            $display ("                                                     The execution latency are over 30 cycles                                               ");
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            repeat(2)@(negedge clk);
            $finish;
        end
        @(negedge clk);
    end
    total_latency = total_latency + lat;
end endtask

// ============================================================================================================
// check answer 
// ============================================================================================================
task check_ans; begin
    if(out_data !== golden_result) begin
        if(altb !== 0) begin
            fail;
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            $display ("                                                            WRONG ANSWER FAIL!                                                                ");
            $display ("                                                             Pattern No. %3d                                                              ", patcount);
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            $display ("                                                        a0 = %1b %2b %1b | b0 = %1b %2b %1b", golden_fp4_a[0][3], golden_fp4_a[0][2:1], golden_fp4_a[0][0], 
                                                                                                                     golden_fp4_b[0][3], golden_fp4_b[0][2:1], golden_fp4_b[0][0]);
            $display ("                                                        a1 = %1b %2b %1b | b1 = %1b %2b %1b", golden_fp4_a[1][3], golden_fp4_a[1][2:1], golden_fp4_a[1][0], 
                                                                                                                     golden_fp4_b[1][3], golden_fp4_b[1][2:1], golden_fp4_b[1][0]);
            $display ("                                                        a2 = %1b %2b %1b | b2 = %1b %2b %1b", golden_fp4_a[2][3], golden_fp4_a[2][2:1], golden_fp4_a[2][0], 
                                                                                                                     golden_fp4_b[2][3], golden_fp4_b[2][2:1], golden_fp4_b[2][0]);
            $display ("                                                        a3 = %1b %2b %1b | b3 = %1b %2b %1b", golden_fp4_a[3][3], golden_fp4_a[3][2:1], golden_fp4_a[3][0], 
                                                                                                                     golden_fp4_b[3][3], golden_fp4_b[3][2:1], golden_fp4_b[3][0]);
            $display ("                                                        (FP8) factor = %1b %4b %3b", golden_factor[7], golden_factor[6:3], golden_factor[2:0]);
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            $display ("                                                 (BF16)   your output:%1b %8b %7b", out_data[15], out_data[14:7], out_data[6:0]);
            $display ("                                                 (BF16) golden answer:%1b %8b %7b", golden_result[15], golden_result[14:7], golden_result[6:0]);
            $display ("--------------------------------------------------------------------------------------------------------------------------------------------");
            #(100)
            $finish;
        end
	end
end endtask

// ============================================================================================================
// reset 
// ============================================================================================================
task reset_task; begin
	#(0.5); 
    rst_n = 0;

	#(5.0);
	if(out_valid !== 0 || out_data !== 0) begin
		fail;
		$display ("-------------------------------------------------------------------------------");
		$display ("                                 ANSWER FAIL!                                  ");
		$display ( "                    output should be 0 after initial RESET                    ");
		$display ( "------------------------------------------------------------------------------");
		#(100);
	  $finish;
	end
	
	#(1.0);  rst_n = 1 ;
	#(30.0); release clk;
    repeat(5) @(negedge clk);
    // repeat($random(SEED) % 'd6) @(negedge clk);

end endtask

// ============================================================================================================
// delay generator
// ============================================================================================================
task delay_gen; begin
	gap = $urandom_range(2,5);
	for(k = 0; k < gap; k = k + 1) begin
		if (out_valid !== 0) begin
			$display ("----------------------------------------------------------------------------------------------------------------------------------");
			$display ("                                                    ANSWER FAIL!                                                                  ");
			$display ("                 The out_valid is limited to be high for only 1 cycle when you want to output the result.                         ");
			$display ("----------------------------------------------------------------------------------------------------------------------------------");
			#(100);
			$finish;	
		end
		else if (out_valid === 0 && out_data !== 0) begin
			$display ("----------------------------------------------------------------------------------------------------------------------------------");
			$display ("                                                    ANSWER FAIL!                                                                  ");
			$display ("                            The out_data should be reset after your out_valid is pulled down.                                     ");
			$display ("----------------------------------------------------------------------------------------------------------------------------------");
			#(100);
			$finish;	
		end
		repeat(1)@(negedge clk);
	end
end endtask

// ============================================================================================================
// SHOW PASS or FAIL
// ============================================================================================================
task YOU_PASS_task; begin
$display("\033[37m                                                                                                                                          ");        
$display("\033[37m                                                                                \033[32m      :BBQvi.                                              ");        
$display("\033[37m                                                              .i7ssrvs7         \033[32m     BBBBBBBBQi                                           ");        
$display("\033[37m                        .:r7rrrr:::.        .::::::...   .i7vr:.      .B:       \033[32m    :BBBP :7BBBB.                                         ");        
$display("\033[37m                      .Kv.........:rrvYr7v7rr:.....:rrirJr.   .rgBBBBg  Bi      \033[32m    BBBB     BBBB                                         ");        
$display("\033[37m                     7Q  :rubEPUri:.       ..:irrii:..    :bBBBBBBBBBBB  B      \033[32m   iBBBv     BBBB       vBr                               ");        
$display("\033[37m                    7B  BBBBBBBBBBBBBBB::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB :R     \033[32m   BBBBBKrirBBBB.     :BBBBBB:                            ");        
$display("\033[37m                   Jd .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: Bi    \033[32m  rBBBBBBBBBBBR.    .BBBM:BBB                             ");        
$display("\033[37m                  uZ .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB .B    \033[32m  BBBB   .::.      EBBBi :BBU                             ");        
$display("\033[37m                 7B .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  B    \033[32m MBBBr           vBBBu   BBB.                             ");        
$display("\033[37m                .B  BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: JJ   \033[32m i7PB          iBBBBB.  iBBB                              ");        
$display("\033[37m                B. BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  Lu             \033[32m  vBBBBPBBBBPBBB7       .7QBB5i                ");        
$display("\033[37m               Y1 KBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBi XBBBBBBBi :B            \033[32m :RBBB.  .rBBBBB.      rBBBBBBBB7              ");        
$display("\033[37m              :B .BBBBBBBBBBBBBsRBBBBBBBBBBBrQBBBBB. UBBBRrBBBBBBr 1BBBBBBBBB  B.          \033[32m    .       BBBB       BBBB  :BBBB             ");        
$display("\033[37m              Bi BBBBBBBBBBBBBi :BBBBBBBBBBE .BBK.  .  .   QBBBBBBBBBBBBBBBBBB  Bi         \033[32m           rBBBr       BBBB    BBBU            ");        
$display("\033[37m             .B .BBBBBBBBBBBBBBQBBBBBBBBBBBB       \033[38;2;242;172;172mBBv \033[37m.LBBBBBBBBBBBBBBBBBBBBBB. B7.:ii:   \033[32m           vBBB        .BBBB   :7i.            ");        
$display("\033[37m            .B  PBBBBBBBBBBBBBBBBBBBBBBBBBBBBbYQB. \033[38;2;242;172;172mBB: \033[37mBBBBBBBBBBBBBBBBBBBBBBBBB  Jr:::rK7 \033[32m             .7  BBB7   iBBBg                  ");        
$display("\033[37m           7M  PBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  \033[38;2;242;172;172mBB. \033[37mBBBBBBBBBBBBBBBBBBBBBBB..i   .   v1                  \033[32mdBBB.   5BBBr                 ");        
$display("\033[37m          sZ .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  \033[38;2;242;172;172mBB. \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBB iD2BBQL.                 \033[32m ZBBBr  EBBBv     YBBBBQi     ");        
$display("\033[37m  .7YYUSIX5 .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  \033[38;2;242;172;172mBB. \033[37mBBBBBBBBBBBBBBBBBBBBBBBBY.:.      :B                 \033[32m  iBBBBBBBBD     BBBBBBBBB.   ");        
$display("\033[37m LB.        ..BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB. \033[38;2;242;172;172mBB: \033[37mBBBBBBBBBBBBBBBBBBBBBBBBMBBB. BP17si                 \033[32m    :LBBBr      vBBBi  5BBB   ");        
$display("\033[37m  KvJPBBB :BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: \033[38;2;242;172;172mZB: \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBsiJr .i7ssr:                \033[32m          ...   :BBB:   BBBu  ");        
$display("\033[37m i7ii:.   ::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBj \033[38;2;242;172;172muBi \033[37mQBBBBBBBBBBBBBBBBBBBBBBBBi.ir      iB                \033[32m         .BBBi   BBBB   iMBu  ");        
$display("\033[37mDB    .  vBdBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBg \033[38;2;242;172;172m7Bi \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBB rBrXPv.                \033[32m          BBBX   :BBBr        ");        
$display("\033[37m :vQBBB. BQBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBQ \033[38;2;242;172;172miB: \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBB .L:ii::irrrrrrrr7jIr   \033[32m          .BBBv  :BBBQ        ");        
$display("\033[37m :7:.   .. 5BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  \033[38;2;242;172;172mBr \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBB:            ..... ..YB. \033[32m           .BBBBBBBBB:        ");        
$display("\033[37mBU  .:. BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  \033[38;2;242;172;172mB7 \033[37mgBBBBBBBBBBBBBBBBBBBBBBBBBB. gBBBBBBBBBBBBBBBBBB. BL \033[32m             rBBBBB1.         ");        
$display("\033[37m rY7iB: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: \033[38;2;242;172;172mB7 \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBB. QBBBBBBBBBBBBBBBBBi  v5                                ");        
$display("\033[37m     us EBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \033[38;2;242;172;172mIr \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBgu7i.:BBBBBBBr Bu                                 ");        
$display("\033[37m      B  7BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB.\033[38;2;242;172;172m:i \033[37mBBBBBBBBBBBBBBBBBBBBBBBBBBBv:.  .. :::  .rr    rB                                  ");        
$display("\033[37m      us  .BBBBBBBBBBBBBQLXBBBBBBBBBBBBBBBBBBBBBBBBq  .BBBBBBBBBBBBBBBBBBBBBBBBBv  :iJ7vri:::1Jr..isJYr                                   ");        
$display("\033[37m      B  BBBBBBB  MBBBM      qBBBBBBBBBBBBBBBBBBBBBB: BBBBBBBBBBBBBBBBBBBBBBBBBB  B:           iir:                                       ");        
$display("\033[37m     iB iBBBBBBBL       BBBP. :BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  B.                                                       ");        
$display("\033[37m     P: BBBBBBBBBBB5v7gBBBBBB  BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: Br                                                        ");        
$display("\033[37m     B  BBBs 7BBBBBBBBBBBBBB7 :BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB .B                                                         ");        
$display("\033[37m    .B :BBBB.  EBBBBBQBBBBBJ .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB. B.                                                         ");        
$display("\033[37m    ij qBBBBBg          ..  .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB .B                                                          ");        
$display("\033[37m    UY QBBBBBBBBSUSPDQL...iBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBK EL                                                          ");        
$display("\033[37m    B7 BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB: B:                                                          ");        
$display("\033[37m    B  BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBYrBB vBBBBBBBBBBBBBBBBBBBBBBBB. Ls                                                          ");        
$display("\033[37m    B  BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBi_  /UBBBBBBBBBBBBBBBBBBBBBBBBB. :B:                                                        ");        
$display("\033[37m   rM .BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  ..IBBBBBBBBBBBBBBBBQBBBBBBBBBB  B                                                        ");        
$display("\033[37m   B  BBBBBBBBBdZBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBPBBBBBBBBBBBBEji:..     sBBBBBBBr Br                                                       ");        
$display("\033[37m  7B 7BBBBBBBr     .:vXQBBBBBBBBBBBBBBBBBBBBBBBBBQqui::..  ...i:i7777vi  BBBBBBr Bi                                                       ");        
$display("\033[37m  Ki BBBBBBB  rY7vr:i....  .............:.....  ...:rii7vrr7r:..      7B  BBBBB  Bi                                                       ");        
$display("\033[37m  B. BBBBBB  B:    .::ir77rrYLvvriiiiiiirvvY7rr77ri:..                 bU  iQBB:..rI                                                      ");        
$display("\033[37m.S: 7BBBBP  B.                                                          vI7.  .:.  B.                                                     ");        
$display("\033[37mB: ir:.   :B.                                                             :rvsUjUgU.                                                      ");        
$display("\033[37mrMvrrirJKur                                                                                                                               \033[m");
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
