//`timescale 1us/100ns
`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
	`include "ComplexCalc.sv"
`elsif GATE
	`include "ComplexCalc_SYN.v"
`endif

module TESTBENCH();

logic [2:0] in_opcode;

logic [7:0] in_seq0;
logic [7:0] in_seq1;
logic [7:0] in_seq2;
logic [7:0] in_seq3;

logic [6:0] out_ssd0;
logic [6:0] out_ssd1;
logic [6:0] out_ssd2;
logic [6:0] out_ssd3;
logic [6:0] out_ssd4;
logic [6:0] out_ssd5;
logic [6:0] out_ssd6;
logic [6:0] out_ssd7;

initial begin
	`ifdef RTL
		$fsdbDumpfile("ComplexCalc.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("ComplexCalc_SYN.fsdb");
		$sdf_annotate("ComplexCalc_SYN.sdf", I_ComplexCalc);
		$fsdbDumpvars(0,"+mda");
	`endif
end

ComplexCalc I_ComplexCalc
(
    .in_opcode(in_opcode),
    .in_seq0(in_seq0),
    .in_seq1(in_seq1),
    .in_seq2(in_seq2),
    .in_seq3(in_seq3),
    .out_ssd0(out_ssd0),
    .out_ssd1(out_ssd1),
    .out_ssd2(out_ssd2),
    .out_ssd3(out_ssd3),
    .out_ssd4(out_ssd4),
    .out_ssd5(out_ssd5),
    .out_ssd6(out_ssd6),
    .out_ssd7(out_ssd7)
);

PATTERN I_PATTERN
(
    .in_opcode(in_opcode),
    .in_seq0(in_seq0),
    .in_seq1(in_seq1),
    .in_seq2(in_seq2),
    .in_seq3(in_seq3),
    .out_ssd0(out_ssd0),
    .out_ssd1(out_ssd1),
    .out_ssd2(out_ssd2),
    .out_ssd3(out_ssd3),
    .out_ssd4(out_ssd4),
    .out_ssd5(out_ssd5),
    .out_ssd6(out_ssd6),
    .out_ssd7(out_ssd7)
);
endmodule

