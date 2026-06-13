module SOBEL (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       in_valid,
    input  logic [7:0] in_data,
    output logic       out_valid,
    output logic       out_data
);

// ---------------------------------------------------------------------
// 1. 暫存器宣告
// ---------------------------------------------------------------------
logic [6:0] in_cnt_cs,      in_cnt_ns; 
logic [5:0] queue_len_cs,       queue_len_ns; 
logic [2:0] stall_cnt_cs,   stall_cnt_ns;
logic [7:0] in_buff_cs [0:17], in_buff_ns [0:17];
logic [35:0] out_queue_cs,      out_queue_ns;
logic       out_valid_cs,       out_valid_ns;
logic       out_data_cs,       out_data_ns;

assign out_valid = out_valid_cs;
assign out_data  = out_data_cs;

logic      can_push;
logic      input_done;
logic      can_pop;
logic      has_queue;
logic      stall_not_max;

assign can_push = (in_cnt_cs[5:3] >= 3'd2 && in_cnt_cs[2:0] >= 3'd2 && in_valid);
assign can_pop = ((!in_valid) && has_queue) && (input_done || stall_not_max);
assign input_done = (in_cnt_cs == 64); 
assign has_queue = (queue_len_cs != 0);
assign stall_not_max = (stall_cnt_cs < 7); 


// ---------------------------------------------------------------------
//  Combinational Logic
// ---------------------------------------------------------------------


// Sobel Combinational Logic
logic [9:0] gx_pos, gx_neg, gy_pos, gy_neg;
logic [9:0] abs_gx, abs_gy;
logic [10:0] gx_diff, gy_diff;
logic [10:0] grad_sum;
logic     sobel_result;


assign gx_pos = in_buff_cs[15] + (in_buff_cs[7] << 1) + in_data;
assign gx_neg = in_buff_cs[17] + (in_buff_cs[9] << 1) + in_buff_cs[1];
assign gy_pos = in_buff_cs[1]  + (in_buff_cs[0] << 1) + in_data;
assign gy_neg = in_buff_cs[17] + (in_buff_cs[16] << 1) + in_buff_cs[15];

assign gx_diff = $signed({1'b0, gx_pos}) - $signed({1'b0, gx_neg});
assign gy_diff = $signed({1'b0, gy_pos}) - $signed({1'b0, gy_neg});

assign abs_gx = gx_diff[10] ? (~gx_diff[9:0] + 1'b1) : gx_diff[9:0];
assign abs_gy = gy_diff[10] ? (~gy_diff[9:0] + 1'b1) : gy_diff[9:0];
assign grad_sum = abs_gx + abs_gy;
assign sobel_result = grad_sum > 11'd128;



// in_buff and Output queue Control Combinational Logic
always_comb begin
    // Default assignments
    in_buff_ns = in_buff_cs;
    out_queue_ns  = out_queue_cs;
    out_valid_ns  = can_pop;
    out_data_ns   = can_pop ? out_queue_cs[queue_len_cs-1] : 1'b0;

    // --- 核心邏輯控制 ---
    if (in_valid) begin
        // in_buff 移位 (固定路徑，面積最小)
        in_buff_ns[0] = in_data;
        in_buff_ns[1] = in_buff_cs[0];
        in_buff_ns[2] = in_buff_cs[1];
        in_buff_ns[3] = in_buff_cs[2];
        in_buff_ns[4] = in_buff_cs[3];
        in_buff_ns[5] = in_buff_cs[4];
        in_buff_ns[6] = in_buff_cs[5];
        in_buff_ns[7] = in_buff_cs[6];
        in_buff_ns[8] = in_buff_cs[7];
        in_buff_ns[9] = in_buff_cs[8];
        in_buff_ns[10] = in_buff_cs[9];
        in_buff_ns[11] = in_buff_cs[10];
        in_buff_ns[12] = in_buff_cs[11];
        in_buff_ns[13] = in_buff_cs[12];
        in_buff_ns[14] = in_buff_cs[13];
        in_buff_ns[15] = in_buff_cs[14];
        in_buff_ns[16] = in_buff_cs[15];
        in_buff_ns[17] = in_buff_cs[16];
    end 

    if (can_push) begin
        out_queue_ns = {out_queue_cs[34:0], sobel_result}; 
    end
end


// Counter and queue Length Control Combinational Logic
always_comb begin
    // input cnt
    in_cnt_ns = in_cnt_cs;
    if (in_valid) begin
        if(!input_done)  in_cnt_ns = in_cnt_cs + 7'd1;
        else in_cnt_ns = 1; 
    end

    //stall_cnt
    stall_cnt_ns  = stall_cnt_cs;
    if (in_valid) stall_cnt_ns = 3'd0; 
    else if(stall_not_max) stall_cnt_ns = stall_cnt_cs + 3'd1; 

    //queue_len
    queue_len_ns  = queue_len_cs;
    if (can_push) queue_len_ns = queue_len_cs + 6'd1;     
    if (can_pop) queue_len_ns = queue_len_cs - 6'd1;     
end


// ---------------------------------------------------------------------
// Sequeueuential Logic
// ---------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_cnt_cs    <= 0;
        queue_len_cs     <= 0;
        stall_cnt_cs <= 0;
        out_valid_cs     <= 0;
        out_data_cs     <= 0;
        
    end else begin
        in_cnt_cs    <= in_cnt_ns;
        queue_len_cs     <= queue_len_ns;
        stall_cnt_cs <= stall_cnt_ns;
        in_buff_cs    <= in_buff_ns;
        out_queue_cs     <= out_queue_ns;
        out_valid_cs     <= out_valid_ns;
        out_data_cs     <= out_data_ns;
    end
end

endmodule
