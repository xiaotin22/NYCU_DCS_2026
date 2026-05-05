module CPU(
    //INPUT
    clk,
    rst_n,
    in_valid,
    instruction,

    //OUTPUT
    in_ready,
    out_valid,
    bad_ins,
    out_0,
    out_1,
    out_2,
    out_3,
    out_4,
    out_5
);
// INPUT
input clk;
input rst_n;
input in_valid;
input [31:0] instruction;

// OUTPUT
output logic in_ready, out_valid;
output logic [1:0] bad_ins;
output logic [15:0] out_0, out_1, out_2, out_3, out_4, out_5;



endmodule