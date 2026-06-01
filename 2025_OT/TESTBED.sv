`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
`include "LN.sv"
`elsif GATE
`include "LN_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("LN.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("LN_SYN.fsdb");
		$sdf_annotate("LN_SYN.sdf",I_LN);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

logic clk, rst_n; 
logic in_valid; 
logic [7:0] in_data;

logic out_valid;
logic [7:0] out_data;

LN I_LN
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
	.in_data(in_data),
	.out_data(out_data),
	.out_valid(out_valid)
);
        
PATTERN I_PATTERN
(
	.clk(clk), 
	.rst_n(rst_n), 
	.in_valid(in_valid), 
    .in_data(in_data),
	.out_data(out_data),
	.out_valid(out_valid)
);
endmodule