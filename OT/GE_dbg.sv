module GE(
    clk,
    rst_n,
    in_valid,
    in_data_eq0,
    in_data_eq1,
    in_data_eq2,
    out_valid,
    out_data0,
    out_data1,
    out_data2,
    exception
);

input clk;
input rst_n;
input in_valid;
input [15:0] in_data_eq0;
input [15:0] in_data_eq1;
input [15:0] in_data_eq2;
output logic out_valid;
output logic signed [5:0] out_data0;
output logic signed [5:0] out_data1;
output logic signed [5:0] out_data2;
output logic [1:0] exception;


endmodule
