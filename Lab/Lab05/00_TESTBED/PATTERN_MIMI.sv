`define CYCLE_TIME 10.0

`ifndef SEED_NUMBER
  `define SEED_NUMBER 45137821
`endif

`ifndef PATTERN_NUMBER
  `define PATTERN_NUMBER 1000
`endif

// Color codes
`define C_RST     "\033[0m"
`define CX_BLUE   "\033[38;5;123m" // Light Sky Blue
`define CX_GREEN  "\033[38;5;121m" // Pale Green
`define CX_PURPLE "\033[38;5;183m" // Lavender
`define CX_YELLOW "\033[38;5;226m" // Yellow
`define CX_ORANGE "\033[38;5;215m" // Peach
`define CX_RED    "\033[38;5;196m" // Red

module PATTERN (
  // Output Signals
  output logic clk,
  output logic rst_n,

  output logic in_valid,
  output logic [3:0] in_digit,
  output logic enter,
  output logic change,
  output logic lock_reset,

  // Input Signals
  input  [2:0] state,
  input  unlocked,
  input  alarm
);

//================================================================
// clock
//================================================================
real CYCLE = `CYCLE_TIME;
initial begin
    clk = 1'b0;
    forever #(CYCLE/2.0) clk = ~clk;
end

//================================================================
// parameters & integer
//================================================================
integer PAT_NUM = `PATTERN_NUMBER;
integer SEED = `SEED_NUMBER;

logic [3:0] golden_pwd[0:3];
integer pat_cnt;

//================================================================
// initial
//================================================================
initial begin
    reset_task;
    for(integer i = 0; i < PAT_NUM; i++) begin
        input_task(i);
    end
end



task reset_task; begin
	rst_n = 1'b1; 
    
	force clk = 1'b0;
	#(1.0*CYCLE); rst_n = 1'b0;
	#(2.0*CYCLE); 
    
	if(state !== 3'b0 | unlocked !== 1'b0 | alarm !== 1'b0) begin
		fail; 
		$display ("--------------------------------------------------------------------------------------------------------------------------------------------");
		$display ("                                                     RESET FAIL!                                                            ");
        $display ("                                                      state : %3b                                                            ", state);
        $display ("                                                      unlocked : %b                                                            ", unlocked);
        $display ("                                                      alarm : %b                                                            ", alarm);
		$display ("                                                Output should be reset                                                            ");
		$display ("--------------------------------------------------------------------------------------------------------------------------------------------");
		#(3*CYCLE);
		$finish;
	end

	rst_n = 1'b1; 
	in_valid = 1'b0; 
	in_digit = 4'h0;
    enter = 1'b0;
    change = 1'b0;
    lock_reset = 1'b0;
    pat_cnt = 0;
    golden_pwd = '{4'h2, 4'h0, 4'h2, 4'h6};
	#(3.0*CYCLE); release clk; 
end endtask



endmodule