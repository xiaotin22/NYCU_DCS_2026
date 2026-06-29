`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
	`include "SeqSort.sv"
`elsif GATE
	`include "SeqSort_SYN.v"
`endif

module TESTBED();

    initial begin
        `ifdef RTL
            $fsdbDumpfile("SeqSort.fsdb");
            $fsdbDumpvars(0,"+mda");
        `elsif GATE
            $fsdbDumpfile("SeqSort_SYN.fsdb");
            $sdf_annotate("SeqSort_SYN.sdf",u_sort);
            $fsdbDumpvars(0,"+mda");
        `endif
    end

    logic clk_wire;
    logic rst_n_wire;
    logic in_valid_wire;
    logic out_valid_wire;
    logic [5:0] in_data_wire;
    logic [5:0] out_data_wire;

    SeqSort u_sort
    (
        .clk      (clk_wire),
        .rst_n    (rst_n_wire),
        .in_valid (in_valid_wire),
        .in_data  (in_data_wire),
        .out_valid(out_valid_wire),
        .out_data (out_data_wire)
    );
    
    PATTERN u_PATTERN
    (
        .clk      (clk_wire),
        .rst_n    (rst_n_wire),
        .in_valid (in_valid_wire),
        .in_data  (in_data_wire),
        .out_valid(out_valid_wire),
        .out_data (out_data_wire)
    );
endmodule