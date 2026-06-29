module LP(
    // Input signals
	clk,
	rst_n,
	in_valid,
    in_a1,
	in_a2,
	in_b,
    // Output signals
    out_valid,
    out_max_value
);

//---------------------------------------------------------------------
//   INPUT AND OUTPUT DECLARATION                         
//---------------------------------------------------------------------
input clk, rst_n, in_valid;
input signed [5:0] in_a1,in_a2;
input signed [11:0] in_b;

output logic out_valid;
output logic signed [11:0] out_max_value;

//---------------------------------------------------------------------
//   LOGIC DECLARATION
//---------------------------------------------------------------------

logic signed [5:0] C_reg [0:1];

logic [3:0] in_cnt;

logic signed [11:0] box_max_x1, box_max_x2;

logic signed [11:0] box_min_x1, box_min_x2;

logic signed [11:0] boundv [0:1];
logic signed [5:0] boundx1 [0:1], boundx2 [0:1];

logic first_bound;
//---------------------------------------------------------------------
//   Your design                        
//---------------------------------------------------------------------

// input reg
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        first_bound <= 0;
    end else if (in_valid) begin 
        if (in_cnt == 0) begin
            C_reg[0] <= in_a1;
            C_reg[1] <= in_a2;
        end
        else if (in_a1 == -1 && in_a2 == 0) begin
            box_min_x1 <= -in_b;
        end else if (in_a1 == 0 && in_a2 == 1) begin
            box_max_x2 <= in_b;
        end else if (in_a1 == 1 && in_a2 == 0) begin
            box_max_x1 <= in_b;
        end else if (in_a1 == 0 && in_a2 == -1) begin
            box_min_x2 <= -in_b;
        end else if (!first_bound) begin
            boundv[0] <= in_b;
            boundx1[0] <= in_a1;
            boundx2[0] <= in_a2;
            first_bound <= 1;
        end else begin
            boundv[1] <= in_b;
            boundx1[1] <= in_a1;
            boundx2[1] <= in_a2;
            first_bound <= 0;
        end
    end
end
logic out_finish;
logic input_done;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)  input_done <= 0;
    else if (in_cnt == 6)
        input_done <= 1;
    else if (out_finish)
        input_done <= 0;
end
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_cnt <= 0;
    end
    else if (in_valid) begin
        in_cnt <= in_cnt + 1;
    end else
        in_cnt <= 0;
end


logic signed [11:0] max_v_cs;

logic signed [11:0] x1, x2;
logic out_ok;
assign out_ok = (x1 * boundx1[0] + x2 * boundx2[0] <= boundv[0]) && (x1 * boundx1[1] + x2 * boundx2[1] <= boundv[1]);


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        x1 <= 0;
        x2 <= 0;
        max_v_cs <= -2047; 
        out_finish <= 0;
        out_valid <= 0;
        out_max_value <= 0;
    end else begin
        
        out_valid <= 0; 
        
        if (in_valid && in_cnt == 6) begin 
            x1 <= (in_a1 == -1 && in_a2 == 0) ? -in_b : box_min_x1;
            x2 <= (in_a1 == 0 && in_a2 == -1) ? -in_b : box_min_x2;
            max_v_cs <= -2047; 
        end 
        
        else if (input_done) begin

            if (out_ok) begin
                max_v_cs <= (C_reg[0] * x1 + C_reg[1] * x2 > max_v_cs) ? (C_reg[0] * x1 + C_reg[1] * x2) : max_v_cs;
            end
            
           
            if (x1 == box_max_x1 && x2 == box_max_x2) begin
                out_finish <= 1;
            end else begin
                x1 <= (x1 == box_max_x1) ? box_min_x1 : x1 + 1;
                x2 <= (x1 == box_max_x1) ? x2 + 1 : x2;
            end
              
            if (out_finish) begin
                out_finish <= 0;
                out_valid <= 1;
                out_max_value <= max_v_cs; 
            end 
        end
    end
end


endmodule