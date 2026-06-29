`timescale 1ns/1ps

`include "PATTERN.sv"
`ifdef RTL
	`include "SOBEL.sv"
`elsif GATE
	`include "SOBEL_SYN.v"
`endif

module TESTBED;

    initial begin
        `ifdef RTL
            $fsdbDumpfile("SOBEL.fsdb");
            $fsdbDumpvars(0,"+mda");
        `elsif GATE
            $fsdbDumpfile("SOBEL_SYN.fsdb");
            $sdf_annotate("SOBEL_SYN.sdf",dut);
            $fsdbDumpvars(0,"+mda");
        `endif
    end

    logic         clk;
    logic         rst_n;
    logic         in_valid;
    logic  [7:0]  in_data;
    logic         out_valid;
    logic         out_data;

    
    SOBEL dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    PATTERN pat (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_data(out_data)
    );

endmodule