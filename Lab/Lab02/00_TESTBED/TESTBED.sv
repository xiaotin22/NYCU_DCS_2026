`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
`include "FreqDiv.sv"
`elsif GATE
`include "FreqDiv_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("FreqDiv.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("FreqDiv_SYN.fsdb");
		$sdf_annotate("FreqDiv_SYN.sdf",I_FreqDiv);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

logic clk, rst_n; 
logic in_valid; 
logic [2:0] in_div;
logic [2:0] in_rep;
logic out_clk;
logic out_valid;

FreqDiv I_FreqDiv
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
	.in_div(in_div),
	.in_rep(in_rep),  
	.out_clk(out_clk), 
	.out_valid(out_valid)
);

PATTERN I_PATTERN
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
	.in_div(in_div),
	.in_rep(in_rep),  
	.out_clk(out_clk), 
	.out_valid(out_valid)
);
endmodule