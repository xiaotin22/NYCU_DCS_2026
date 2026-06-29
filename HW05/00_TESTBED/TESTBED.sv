`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
    `include "CPU.sv"
`elsif GATE
    `include "CPU_SYN.v"
`endif

module TESTBED();

logic clk,rst_n,in_valid;
logic in_ready,out_valid;
logic [1:0] bad_ins;

logic [31:0] instruction; 
logic [15:0] out_0, out_1,out_2,out_3,out_4, out_5;

initial begin
  `ifdef RTL
    $fsdbDumpfile("CPU.fsdb");
	  $fsdbDumpvars(0,"+mda");
  `elsif GATE
    $fsdbDumpfile("CPU_SYN.fsdb");
	  $sdf_annotate("CPU_SYN.sdf",I_design);
	  $fsdbDumpvars(0,"+mda");
  `endif
end

CPU I_design
(
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .instruction(instruction),

  .in_ready(in_ready),
  .out_valid(out_valid),
  .bad_ins(bad_ins),
  .out_0(out_0),
  .out_1(out_1),
  .out_2(out_2),
  .out_3(out_3),
  .out_4(out_4),
  .out_5(out_5)
);


PATTERN I_PATTERN
(   
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .instruction(instruction),
  
  .in_ready(in_ready),
  .out_valid(out_valid),
  .bad_ins(bad_ins),
  .out_0(out_0),
  .out_1(out_1),
  .out_2(out_2),
  .out_3(out_3),
  .out_4(out_4),
  .out_5(out_5)
);
endmodule
