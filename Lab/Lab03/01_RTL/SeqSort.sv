module SeqSort (
    // input signals
    input clk,
    input rst_n,
    input in_valid,
    input [5:0] in_data,

    // output signals
    output logic out_valid,
    output logic [5:0] out_data
);
//======================================================================//
//                              Your Design                             //
//======================================================================//

reg out_valid_ns;
reg [5:0] out_data_ns;

reg [3:0] count_cs;
reg [3:0] count_ns;

reg [5:0] in_data_cs [0:4];
reg [5:0] in_data_ns [0:4];

reg [5:0] stage1_cs [0:4];
reg [5:0] stage1_ns [0:4];
reg [5:0] stage2_cs [0:4];
reg [5:0] stage2_ns [0:4];
reg [5:0] stage3_cs [0:4];
reg [5:0] stage3_ns [0:4];
reg [5:0] stage4_cs [0:4];
reg [5:0] stage4_ns [0:4];

reg [5:0] ready_data_cs [0:4];
reg [5:0] ready_data_ns [0:4];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 0;
        out_data <= 0;
        in_data_cs <= {0, 0, 0, 0, 0};
        stage1_cs <= {0, 0, 0, 0, 0};
        stage2_cs <= {0, 0, 0, 0, 0};
        stage3_cs <= {0, 0, 0, 0, 0};
        stage4_cs <= {0, 0, 0, 0, 0};
        ready_data_cs <= {0, 0, 0, 0, 0};
        count_cs <= 0;
    end else begin
        out_valid <= out_valid_ns;
        out_data <= out_data_ns;
        in_data_cs <= in_data_ns;
        stage1_cs <= stage1_ns;
        stage2_cs <= stage2_ns;
        stage3_cs <= stage3_ns;
        stage4_cs <= stage4_ns;
        ready_data_cs <= ready_data_ns;
        count_cs <= count_ns;
    end
end

always @(*) begin
    if (count_cs == 15) begin
        count_ns = 0;
    end else if (in_valid && count_cs == 0) begin
        count_ns = 1;
    end else if (count_cs > 0) begin
        count_ns = count_cs + 1;
    end else begin
        count_ns = 0;
    end
end

always @(*) begin
    in_data_ns = in_data_cs;
    if (in_valid) in_data_ns[count_cs] = in_data;
end

CMP CMP1_1(.in1(in_data_cs[0]), .in2(in_data_cs[1]), .out1(stage1_ns[0]), .out2(stage1_ns[1]));
CMP CMP1_2(.in1(in_data_cs[2]), .in2(in_data_cs[3]), .out1(stage1_ns[2]), .out2(stage1_ns[3]));
assign stage1_ns[4] = in_data_cs[4];

CMP CMP2_1(.in1(stage1_cs[1]), .in2(stage1_cs[2]), .out1(stage2_ns[1]), .out2(stage2_ns[2]));
CMP CMP2_2(.in1(stage1_cs[3]), .in2(stage1_cs[4]), .out1(stage2_ns[3]), .out2(stage2_ns[4]));
assign stage2_ns[0] = stage1_cs[0];

CMP CMP3_1(.in1(stage2_cs[0]), .in2(stage2_cs[1]), .out1(stage3_ns[0]), .out2(stage3_ns[1]));
CMP CMP3_2(.in1(stage2_cs[2]), .in2(stage2_cs[3]), .out1(stage3_ns[2]), .out2(stage3_ns[3]));
assign stage3_ns[4] = stage2_cs[4];

CMP CMP4_1(.in1(stage3_cs[1]), .in2(stage3_cs[2]), .out1(stage4_ns[1]), .out2(stage4_ns[2]));
CMP CMP4_2(.in1(stage3_cs[3]), .in2(stage3_cs[4]), .out1(stage4_ns[3]), .out2(stage4_ns[4]));
assign stage4_ns[0] = stage3_cs[0];

CMP CMP5_1(.in1(stage4_cs[0]), .in2(stage4_cs[1]), .out1(ready_data_ns[0]), .out2(ready_data_ns[1]));
CMP CMP5_2(.in1(stage4_cs[2]), .in2(stage4_cs[3]), .out1(ready_data_ns[2]), .out2(ready_data_ns[3]));
assign ready_data_ns[4] = stage4_cs[4];
    
always @(*) begin
    if (count_cs >= 10 && count_cs <= 14) begin
        out_valid_ns = 1;
        out_data_ns = ready_data_cs[count_cs - 10];
    end else begin
        out_valid_ns = 0;
        out_data_ns = 0;
    end
end

endmodule

module CMP (
    input [5:0] in1,
    input [5:0] in2,
    output [5:0] out1,
    output [5:0] out2
);

assign out1 = (in1 > in2) ? (in1) : (in2);
assign out2 = (in1 > in2) ? (in2) : (in1);
    
endmodule