`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
    `include "DCSPI.sv"
`elsif GATE
    `include "DCSPI_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("DCSPI.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("DCSPI_SYN.fsdb");
		$sdf_annotate("DCSPI_SYN.sdf",I_DCSPI);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

logic clk, rst_n; 
logic in_valid;
logic in_data;
logic out_valid;
logic [15:0] out_data;

DCSPI I_DCSPI(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_data(in_data),
    .out_valid(out_valid),
    .out_data(out_data)
);

PATTERN I_PATTERN(
    .clk(clk), 
    .rst_n(rst_n), 
    .in_valid(in_valid),
    .in_data(in_data),
    .out_valid(out_valid),
    .out_data(out_data)
);

endmodule
