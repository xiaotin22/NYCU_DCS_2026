module LongDiv(
    // Input signals
    clk, 
    rst_n, 
    in_valid,  
    in_num1, 
    in_num2, 
    // Output signals
    out_valid, 
    out_num1,
    out_num2
);
//---------------------------------------------------------------------
//   INPUT AND OUTPUT DECLARATION                         
//---------------------------------------------------------------------
input clk, rst_n;
input in_valid;
input [31:0] in_num1;
input [15:0] in_num2;
output logic out_valid;
output logic [16:0] out_num1;
output logic [15:0] out_num2;

//---------------------------------------------------------------------
//   LOGIC DECLARATION
//---------------------------------------------------------------------

logic [16:0] R_reg [0:16]; // Partial remainder (部分餘數)
logic [15:0] A_reg [0:15]; // Lower dividend bits (剩餘的被除數)
logic [16:0] Q_reg [0:16]; // Quotient (商數)
logic [15:0] D_reg [0:15]; // Divisor (除數傳遞)
logic valid_reg[0:16];      // in_valid 傳到最後變成out_valid

//---------------------------------------------------------------------
//   Your DESIGN                        
//---------------------------------------------------------------------

// 輸入暫存
logic [31:0] in_num1_reg;
logic [15:0] in_num2_reg;
logic in_valid_reg;

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		in_num1_reg <= 32'b0;
		in_num2_reg <= 16'b0;
		in_valid_reg <= 1'b0;
	end else begin
		in_num1_reg <= in_valid ? in_num1 : 32'b0;
		in_num2_reg <= in_valid ? in_num2 : 16'b0;
		in_valid_reg <= in_valid ? 1'b1 : 1'b0;
	end
end

genvar i;
generate
    // 總共需要 17 級來計算 17 bits 的商數
    for (i = 0; i < 17; i = i + 1) begin : pipe
        wire [16:0] R_cs;
        wire [15:0] D_cs;
        wire val_cs;
        wire Q_bit_cs;
        wire [16:0] R_ns;
        
        if (i == 0) begin  // 第0級：接上輸入
            
            assign R_cs = {1'b0, in_num1_reg[31:16]};
            assign D_cs = in_num2_reg;
            assign val_cs = in_valid_reg;
            
            assign Q_bit_cs = (R_cs >= {1'b0, D_cs}); 
            assign R_ns = Q_bit_cs ? (R_cs - {1'b0, D_cs}) : R_cs;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    R_reg[0] <= 17'b0;
                    A_reg[0] <= 16'b0;
                    Q_reg[0] <= 17'b0;
                    D_reg[0] <= 16'b0;
                    valid_reg[0] <= 1'b0;
                end else begin
                    // Shift left: 移入下一位被除數
                    R_reg[0] <= {R_ns[15:0], in_num1_reg[15]};
                    A_reg[0] <= {in_num1_reg[14:0], 1'b0};
                    Q_reg[0] <= {16'b0, Q_bit_cs}; // 紀錄第一個商數 bit
                    D_reg[0] <= D_cs;             
                    valid_reg[0] <= val_cs;
                end
            end
            
        end else if (i < 16)  begin // 第 1 到 15 級：串接上一級的 Register
            assign R_cs = R_reg[i-1];
            assign D_cs = D_reg[i-1];
            assign val_cs = valid_reg[i-1];
            
            assign Q_bit_cs = (R_cs >= {1'b0, D_cs});
            assign R_ns = Q_bit_cs ? (R_cs - {1'b0, D_cs}) : R_cs;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    R_reg[i] <= 17'b0;
                    A_reg[i] <= 16'b0;
                    Q_reg[i] <= 17'b0;	
                    D_reg[i] <= 16'b0;
                    valid_reg[i] <= 1'b0;
                end else begin
                    // Shift left: 移入下一位被除數
                    R_reg[i] <= {R_ns[15:0], A_reg[i-1][15]};
                    A_reg[i] <= {A_reg[i-1][14:0], 1'b0};
                    Q_reg[i] <= {Q_reg[i-1][15:0], Q_bit_cs}; // Shift left 商數
                    D_reg[i] <= D_cs;
                    valid_reg[i] <= val_cs;
                end
            end
            
        end else begin // (i == 16)：第 16 級：最後一級，不再 shift left
            assign R_cs = R_reg[15];
            assign D_cs = D_reg[15];
            assign val_cs = valid_reg[15];
            
            assign Q_bit_cs = (R_cs >= {1'b0, D_cs});
            assign R_ns = Q_bit_cs ? (R_cs - {1'b0, D_cs}) : R_cs;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    R_reg[16] <= 17'b0;
                    Q_reg[16] <= 17'b0;
                    valid_reg[16] <= 1'b0;
                end else begin
                    R_reg[16] <= R_ns; // 最終餘數
                    Q_reg[16] <= {Q_reg[15][15:0], Q_bit_cs};
                    valid_reg[16] <= val_cs;
                end
            end
        end
    end
endgenerate


//---------------------------------------------------------------------
//   OUTPUT ASSIGNMENT
//---------------------------------------------------------------------
assign out_valid = valid_reg[16];
assign out_num1  = out_valid ? Q_reg[16] : 17'b0;         
assign out_num2  = out_valid ? R_reg[16][15:0] : 16'b0;    

endmodule