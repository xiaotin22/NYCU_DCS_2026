`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
`include "NVfpc.sv"
`elsif GATE
`include "NVfpc_SYN.v"
`endif

module TESTBED();

logic clk, rst_n, in_valid, factor_valid;
logic [7:0] in_data, factor;
logic out_valid;
logic [15:0] out_data;

initial begin
    `ifdef RTL
      $fsdbDumpfile("NVfpc.fsdb");
      $fsdbDumpvars("+mda");
    `elsif GATE
      $fsdbDumpfile("NVfpc_SYN.fsdb");
      $sdf_annotate("NVfpc_SYN.sdf",I_design);
      $fsdbDumpvars();
    `endif 
end

NVfpc I_design
(
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .in_data(in_data),
  .factor_valid(factor_valid),
  .factor(factor),
  .out_valid(out_valid),
  .out_data(out_data)
);


PATTERN I_PATTERN
(
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .in_data(in_data),
  .factor_valid(factor_valid),
  .factor(factor),
  .out_valid(out_valid),
  .out_data(out_data)
);


endmodule

