`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
`include "MHA.sv"
`elsif GATE
`include "MHA_SYN.v"
`endif

module TESTBED();

logic clk, rst_n, in_valid_qk, in_valid_v, mode, get_value, out_valid;
logic signed [3:0] in_data_q;
logic signed [3:0] in_data_k;
logic signed [3:0] in_data_v;
logic signed [19:0] out_data;


initial begin
  `ifdef RTL
	$fsdbDumpfile("MHA.fsdb");		
	$fsdbDumpvars(0,"+mda");
  `elsif GATE
    $fsdbDumpfile("MHA_SYN.fsdb");
	$sdf_annotate("MHA_SYN.sdf",I_MHA);	
	$fsdbDumpvars(0,"+mda");
  `endif
end

MHA I_MHA(
	.clk(clk),
	.rst_n(rst_n),
	.in_valid_qk(in_valid_qk),
	.in_valid_v(in_valid_v),
	.mode(mode),
	.in_data_q(in_data_q),
	.in_data_k(in_data_k),
	.in_data_v(in_data_v),
	.out_valid(out_valid),
	.out_data(out_data),
	.get_value(get_value)
);

PATTERN I_PATTERN(
	.clk(clk),
	.rst_n(rst_n),
	.in_valid_qk(in_valid_qk),
	.in_valid_v(in_valid_v),
	.mode(mode),
	.in_data_q(in_data_q),
	.in_data_k(in_data_k),
	.in_data_v(in_data_v),
	.out_valid(out_valid),
	.out_data(out_data),
	.get_value(get_value)
);
endmodule

