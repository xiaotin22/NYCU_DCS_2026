`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
    `include "GE.sv"
`elsif GATE
    `include "GE_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("GE.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("GE_SYN.fsdb");
		$sdf_annotate("GE_SYN.sdf",I_GE);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

logic clk, rst_n; 
logic in_valid;
logic [15:0] in_data_eq0, in_data_eq1, in_data_eq2;
logic out_valid;
logic [5:0] out_data0, out_data1, out_data2;
logic [1:0] exception;

GE I_GE(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_data_eq0(in_data_eq0),
    .in_data_eq1(in_data_eq1),
    .in_data_eq2(in_data_eq2),
    .out_valid(out_valid),
    .out_data0(out_data0),
    .out_data1(out_data1),
    .out_data2(out_data2),
    .exception(exception)
);

PATTERN I_PATTERN(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_data_eq0(in_data_eq0),
    .in_data_eq1(in_data_eq1),
    .in_data_eq2(in_data_eq2),
    .out_valid(out_valid),
    .out_data0(out_data0),
    .out_data1(out_data1),
    .out_data2(out_data2),
    .exception(exception)
);

endmodule
