`define CYCLE_TIME 10.0
module PATTERN(
	// Input signals
	clk,
	rst_n,
	in_valid_qk,
    in_valid_v,
    mode,
    in_data_q,
    in_data_k,
    in_data_v,
	// Output signals
    out_valid,
    out_data,
    get_value
);


//============================================================================================================
// PORT DECLARATION
//============================================================================================================
output logic clk, rst_n, in_valid_qk, in_valid_v, mode;
output logic signed [3:0] in_data_q;
output logic signed [3:0] in_data_k;
output logic signed [3:0] in_data_v;

input signed [19:0] out_data;
input get_value;
input out_valid;

//============================================================================================================
// clock
//============================================================================================================
real	CYCLE = `CYCLE_TIME;
always	#(CYCLE/2.0) clk = ~clk;

//============================================================================================================
// parameters & integer
//============================================================================================================
integer PATNUM = 500, pat_id;
integer seed = 0;

integer cnt;
integer act[8][8], wgt[8][8], ans[8][8], your[8][8], act_pad[10][10], fill[8][8];
integer total_latency, lat;
integer lat_v, lat_out;
integer start = 0;

int   get_value_high_cycles;
int   out_valid_high_cycles;

//============================================================================================================
// LOGIC DECLARATION
//============================================================================================================
// queries, keys, values
logic signed [3:0]  golden_q [0:7][0:7];
logic signed [3:0]  golden_k [0:7][0:7];
logic signed [3:0]  golden_v [0:7][0:7];

// single-head attention
// scores, probabilities, output
logic signed [10:0] golden_s [0:7][0:7];
logic signed [10:0] golden_p [0:7][0:7];
logic signed [19:0] golden_o [0:7][0:7];

// two-head attention
// scores, probabilities, output
logic signed [10:0] golden_s_1 [0:7][0:7];
logic signed [10:0] golden_s_2 [0:7][0:7];
logic signed [10:0] golden_p_1 [0:7][0:7];
logic signed [10:0] golden_p_2 [0:7][0:7];
logic signed [19:0] golden_o_1 [0:7][0:3];
logic signed [19:0] golden_o_2 [0:7][0:3];

// mode
logic golden_mode;

// capture output
logic signed [19:0] cap [0:7][0:7];

// spec signals
logic monitor_en;
logic seen_get_value;
logic seen_out_valid;

// ============================================================================================================
// initial
// ============================================================================================================
initial begin
	rst_n = 1'd1;
    in_valid_qk = 1'b0;
    in_valid_v = 1'b0;
	in_data_q = 'bx;
    in_data_k = 'bx;
    in_data_v = 'bx;
    mode = 'bx;
    total_latency = 0;

	force clk = 0;
	reset_task;
	
	for(pat_id = 0; pat_id < PATNUM; pat_id++) begin
        // initialize checker signals
        monitor_en = 1'b1;
        seen_get_value = 1'b0;
        seen_out_valid = 1'b0;
        get_value_high_cycles = 0;
        out_valid_high_cycles = 0;

        gen_data_task;
        fork
            begin
		        input_task;
                wait_out_valid;
                check_ans;
            end
            begin
                wait_get_v;
                input_v_task;                 // still streams V for 64 cycles
            end
        join

        monitor_en = 1'b0;
        repeat(($urandom % 3) + 5)  @(negedge clk);
	end
	YOU_PASS_task;
	$finish;
end

// ============================================================================================================
// MONITOR
// ============================================================================================================
always @(negedge clk) begin
    if (out_valid === 0 && out_data !== 0) begin
        $display ("-----------------------------------------------------------------------------------------------------------------------");
        $display ("ERROR: out_data should be 0 while out_valid is low.");
        $display ("-----------------------------------------------------------------------------------------------------------------------");
        $finish;
    end

    if (monitor_en) begin
        // ------------------------------------------------------------
        // (0) No overlap between out_valid and get_value
        // ------------------------------------------------------------
        if (out_valid === 1'b1 && get_value === 1'b1) begin
            $display ("-----------------------------------------------------------------------------------------------------------------------");
            $display ("ERROR: get_value must NOT be asserted while out_valid is high.");
            $display ("-----------------------------------------------------------------------------------------------------------------------");
            $finish;
        end

        // -----------------------------------------------------------------------
        // (A) get_value rules
        // only 1 pulse total per pattern
        // pulse width must be exactly 1 cycle (=> total high cycles must be 1)
        // cannot overlap with in_valid
        // -----------------------------------------------------------------------
        if (get_value === 1'b1) begin
            get_value_high_cycles++;
            if (get_value_high_cycles > 1) begin
                $display ("-----------------------------------------------------------------------------------------------------------------------");
                $display ("ERROR: get_value must be high for ONLY 1 cycle (one-cycle pulse).");
                $display ("-----------------------------------------------------------------------------------------------------------------------");
                $finish;
            end
            seen_get_value <= 1'b1;
        end

        // ------------------------------------------------------------
        // (B) out_valid rules BEFORE output starts:
        // out_valid must not glitch high before get_value happens
        // out_valid must not assert before get_value (protocol requirement)
        // ------------------------------------------------------------
        if (!seen_out_valid) begin
            // first time out_valid goes high: must have seen get_value already
            if (out_valid === 1'b1) begin
                if (!seen_get_value) begin
                    $display ("-----------------------------------------------------------------------------------------------------------------------");
                    $display ("ERROR: out_valid asserted before get_value (V request must happen first).");
                    $display ("-----------------------------------------------------------------------------------------------------------------------");
                    $finish;
                end
                seen_out_valid <= 1'b1;
                out_valid_high_cycles <= 1; // start counting high cycles
            end
        end
        // --------------------------------------------------------
        // (C) out_valid rules AFTER output starts:
        // -must be continuous and exactly 64 cycles total
        // (continuity will also be checked in check_ans, but monitor
        // can catch early glitches too)
        // --------------------------------------------------------
        else begin
            if (out_valid === 1'b1) begin
                out_valid_high_cycles++;
                if (out_valid_high_cycles > 64) begin
                    $display ("-----------------------------------------------------------------------------------------------------------------------");
                    $display ("ERROR: out_valid asserted for more than 64 cycles.");
                    $display ("-----------------------------------------------------------------------------------------------------------------------");
                    $finish;
                end
            end
        end
    end
end

// ============================================================================================================
// generate data
// ============================================================================================================
task gen_data_task; begin
    // generate mode
    golden_mode = $urandom_range(1, 0);

    // generate q, k, v
    for (int i = 0; i < 8; i++) begin
        for(int j = 0; j < 8; j++) begin
            golden_q[i][j] = $signed($urandom_range(15,0));
            golden_k[i][j] = $signed($urandom_range(15,0));
            golden_v[i][j] = $signed($urandom_range(15,0));
        end
    end
    // -----------------------------------------------------------
    // single-head attention
    // -----------------------------------------------------------
    if (golden_mode === 0) begin
        // S = Q x K^T
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_s[i][j] = 0;
                for(int k = 0; k < 8; k++) 
                    golden_s[i][j] += golden_q[i][k] * golden_k[j][k];
            end
        end

        // P = act(S)
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_p[i][j] = (golden_s[i][j] < 0)? (golden_s[i][j] / 4): golden_s[i][j];
            end
        end

        // O = P x V
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_o[i][j] = 0;
                for(int k = 0; k < 8; k++) 
                    golden_o[i][j] += golden_p[i][k] * golden_v[k][j];
            end
        end
    end
    // -----------------------------------------------------------
    // two-head attention
    // -----------------------------------------------------------
    else begin
        // S = Q x K^T
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_s_1[i][j] = 0;
                for(int k = 0; k < 4; k++) begin
                    golden_s_1[i][j] += golden_q[i][k] * golden_k[j][k];
                end
            end
        end
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_s_2[i][j] = 0;
                for(int k = 4; k < 8; k++) begin
                    golden_s_2[i][j] += golden_q[i][k] * golden_k[j][k];
                end
            end
        end

        // P = act(S)
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) begin
                golden_p_1[i][j] = (golden_s_1[i][j] < 0)? ($signed(golden_s_1[i][j]) / 4): golden_s_1[i][j];
                golden_p_2[i][j] = (golden_s_2[i][j] < 0)? ($signed(golden_s_2[i][j]) / 4): golden_s_2[i][j];
            end
        end

        // O = P x V
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 4; j++) begin
                golden_o_1[i][j] = 0;
                for(int k = 0; k < 8; k++) 
                    golden_o_1[i][j] += golden_p_1[i][k] * golden_v[k][j];
            end
        end
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 4; j++) begin
                golden_o_2[i][j] = 0;
                for(int k = 0; k < 8; k++) 
                    golden_o_2[i][j] += golden_p_2[i][k] * golden_v[k][j+4];
            end
        end

        // concatenate O_1 and O_2 to get O
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 4; j++) begin
                golden_o[i][j] = golden_o_1[i][j];
                golden_o[i][j+4] = golden_o_2[i][j];
            end
        end
    end
end endtask

// ============================================================================================================
// intput query and key
// ============================================================================================================
task input_task; begin
    lat_out = 0;
    in_valid_qk = 1'b1;
    for(int i = 0; i < 8; i++) begin
        for(int j = 0; j < 8; j++) begin
            mode = (i == 0 && j == 0)? golden_mode: 'bx;
            in_data_q = golden_q[i][j];
            in_data_k = golden_k[i][j];
            in_data_v = 'bx;
            @(negedge clk);
            lat_out = lat_out + 1;
        end
    end
    in_valid_qk = 1'b0;
    in_data_q = 'bx;
    in_data_k = 'bx;
end endtask

// ============================================================================================================
// wait get_value task
// ============================================================================================================
task wait_get_v; begin
    lat_v = 0;
    while(get_value !== 1'b1) begin
        lat_v = lat_v + 1;
        if(lat_v == 200) begin
            $display ("--------------------------------------------------------------------------------------------------");
            $display ("The latency of waiting for get_value are over 200 cycles                                               ");
            $display ("--------------------------------------------------------------------------------------------------");
            repeat(2)@(negedge clk);
            $finish;
        end
        @(negedge clk);
    end
    @(negedge clk);

end endtask

// ============================================================================================================
// input value
// ============================================================================================================
task input_v_task; begin
    in_valid_v = 1'b1;
    for(int i = 0; i < 8; i++) begin
        for(int j = 0; j < 8; j++) begin
            in_data_v = golden_v[i][j];
            // total_latency = total_latency + 1;
            @(negedge clk);
        end
    end
    in_valid_v = 1'b0;
    in_data_v = 'bx;
end endtask

// ============================================================================================================
// wait out_valid
// ============================================================================================================
task wait_out_valid; begin
    while(out_valid !== 1) begin
        lat_out = lat_out + 1;
        if(lat_out == 200) begin
            $display ("---------------------------------------------------------------------------------------");
            $display ("The execution latency are over 200 cycles                                               ");
            $display ("---------------------------------------------------------------------------------------");
            repeat(2)@(negedge clk);
            $finish;
        end
        @(negedge clk);
    end
end endtask

// ================================================================================================================
// check answer
// ================================================================================================================
task check_ans; begin
    cnt = 0;

    // out_valid should be continuous for 64 cycles
    for(int i = 0; i < 8; i++) begin
        for(int j = 0; j < 8; j++) begin
            lat_out = lat_out + 1;
            if (out_valid !== 1'b1) begin
                $display ("-----------------------------------------------------------------------------------------------------------------------");
                $display ("out_valid is NOT continuous! Drop detected at cnt=%0d (i=%0d, j=%0d).                                                  ", cnt, i, j);
                $display ("-----------------------------------------------------------------------------------------------------------------------");
                repeat(2)@(negedge clk);
                $finish;
            end

            // capture data
            cap[i][j] = out_data;
            cnt++;

            @(negedge clk);
        end
    end

    // after 64 cycles, out_valid must be low (no extra output)
    if (out_valid === 1) begin
        $display ("-----------------------------------------------------------------------------------------------------------------------");
        $display ("out_valid asserted for more than 64 cycles (extra output detected).");
        $display ("-----------------------------------------------------------------------------------------------------------------------");
        repeat(2) @(negedge clk);
        $finish;
    end

    // compare all captured outputs with golden_o
    for (int i = 0; i < 8; i++) begin
        for (int j = 0; j < 8; j++) begin
            if (cap[i][j] !== golden_o[i][j]) begin
                $display ("-------------------------------------------------------------------------------------------------------------------------");
                $display ("Wrong answer at (i=%0d, j=%0d). DUT=%0d, GOLDEN=%0d", i, j, cap[i][j], golden_o[i][j]);
                $display ("-------------------------------------------------------------------------------------------------------------------------");
                report;
                repeat(2) @(negedge clk);
                $finish;
            end
        end
    end
    $display("\033[0;32mPASS PATTERN NO.%3d, Latency: %3d \033[m", pat_id, lat_out);
    total_latency = total_latency + lat_out;
end endtask

// ============================================================================================================
// report
// ============================================================================================================
task report; begin
    $display ("----------------------------------------------------------------------------------------------------------------------");
    $display ("PATTERN No.%3d", pat_id);
    $display ("----------------------------------------------------------------------------------------------------------------------");

    if(golden_mode === 0) begin
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Operation: Single-head Attention");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Q[8x8]                     K^T[8x8]                   S[8x8] ");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%2d ", golden_q[i][j]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%2d ", golden_k[j][i]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%4d ", golden_s[i][j]); $write("   ");
            $display("");
        end

        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("P[8x8]                             V[8x8]");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%3d ", golden_p[i][j]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%2d ", golden_v[i][j]); $write("   ");
            $display("");
        end

        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Golden Output[8x8]                                 Your Output[8x8]");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%5d ", golden_o[i][j]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%5d ", cap[i][j]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
    end
    else begin
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Operation: Two-head Attention");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Q1[8x4]        Q2[8x4] ");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 4; j++) $write("%2d ", golden_q[i][j]); $write("   ");
            for(int j = 4; j < 8; j++) $write("%2d ", golden_q[i][j]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("K1^T[4x8]                  K2^T[4x8] ");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 4; i++) begin
            for(int j = 0; j < 8; j++) $write("%2d ", golden_k[j][i]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%2d ", golden_k[j][i+4]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("S1[8x8]                                     S2[8x8] ");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%4d ", golden_s_1[i][j]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%4d ", golden_s_2[i][j]); $write("   ");
            $display("");
        end

        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("P_1[8x8]                                   V_1[8x4]       O_1[8x4]");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%4d ", golden_p_1[i][j]); $write("   ");
            for(int j = 0; j < 4; j++) $write("%2d ", golden_v[i][j]); $write("   ");
            for(int j = 0; j < 4; j++) $write("%5d ", golden_o_1[i][j]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("P_2[8x8]                                   V_2[8x4]       O_2[8x4]");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%4d ", golden_p_2[i][j]); $write("   ");
            for(int j = 4; j < 8; j++) $write("%2d ", golden_v[i][j]); $write("   ");
            for(int j = 0; j < 4; j++) $write("%5d ", golden_o_2[i][j]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
        $display ("Golden Output[8x8]                                  Your Output[8x8]");
        $display ("----------------------------------------------------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            for(int j = 0; j < 8; j++) $write("%5d ", golden_o[i][j]); $write("   ");
            for(int j = 0; j < 8; j++) $write("%5d ", cap[i][j]); $write("   ");
            $display("");
        end
        $display ("----------------------------------------------------------------------------------------------------------------------");
    end
end endtask

// ============================================================================================================
// reset check
// ============================================================================================================
task reset_task; begin
	#(0.5); 
    rst_n = 0;

	#(10.0);
	if(out_valid !== 0 || out_data !== 0 || get_value !== 0) begin
		fail;
		$display ("-------------------------------------------------------------------------------");
		$display ("                                 ANSWER FAIL!                                  ");
		$display ( "                    output should be 0 after initial RESET                    ");
		$display ( "------------------------------------------------------------------------------");
		#(100);
	    $finish;
	end
	
	#(10.0);  rst_n = 1 ;
	#(30.0); release clk;

end endtask


// ============================================================================================================
// PASS
// ============================================================================================================
task YOU_PASS_task;begin
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
$display ("                                      Latency: %6d cycles, Cycle Time: %.1f ns        						         ", total_latency, `CYCLE_TIME);
$display ("                                           Total latency: %11.2f ns        						                     ", total_latency * `CYCLE_TIME);
$display ("----------------------------------------------------------------------------------------------------------------------");


$finish;	
end endtask


// ============================================================================================================
// FAIL
// ============================================================================================================
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
report;
$display ("----------------------------------------------------------------------------------------------------------------------");
$display ("                                                      YOU FAIL!!!                                                     ");
// case(code)
// 0: $display ("                                          out_valid should be reset to zero!                                          ");
// 1: $display ("                                         Unknown value detected in out_valid.                                         ");
// 2: $display ("                                     Latency should be no longer than 1000 cycles.                                    ");
// 3: $display ("                        Unknown value detected in out_idx or out_finish when out_valid is high.                       ");
// 4: $display ("                                  Your output isn't complete when out_finish is high.                                 ");
// 5: $display ("                                               You answer is incorrect.                                               ");

// endcase
$display ("----------------------------------------------------------------------------------------------------------------------");
$finish;
end endtask

endmodule

