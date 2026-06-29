`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
`include "LongDiv.sv"
`elsif GATE
`include "LongDiv_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("LongDiv.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("LongDiv_SYN.fsdb");
		$sdf_annotate("LongDiv_SYN.sdf",I_LongDiv);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

logic clk, rst_n;
logic in_valid;
logic [31:0] in_num1;
logic [15:0] in_num2;
logic out_valid;
logic [16:0] out_num1;
logic [15:0] out_num2;

LongDiv I_LongDiv
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
	.in_num1(in_num1),  
	.in_num2(in_num2),  
	.out_valid(out_valid),
	.out_num1(out_num1), 
	.out_num2(out_num2)
);

PATTERN I_PATTERN
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
	.in_num1(in_num1),  
	.in_num2(in_num2),  
	.out_valid(out_valid),
	.out_num1(out_num1), 
	.out_num2(out_num2)
);
endmodule