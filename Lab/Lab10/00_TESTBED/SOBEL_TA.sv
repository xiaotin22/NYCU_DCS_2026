module SOBEL (
    // output signals
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_valid,
    input  logic  [7:0]  in_data,

    // input signals
    output logic        out_valid,
    output logic        out_data
);
//======================================================================//
//                              Your Design                             //
//======================================================================//
logic [5:0] in_cnt;
logic [2:0] stall_cnt;
logic [7:0] in_buf [17:0];
logic signed [8:0] common_sum0, common_sum1;
logic signed [9:0] partial_sum0, partial_sum1;
logic signed [10:0] diffx, diffy;
logic [9:0] Gx, Gy;
logic wait_pixel;
logic out_fifo [35:0];
logic [5:0] out_fifo_tail;
logic [5:0] out_fifo_head;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_cnt <= 0;
    end else begin
        if (in_valid) begin
            in_cnt <= in_cnt + 1;
        end
        if(out_fifo_head > 35) begin
            in_cnt <= 0;
        end
    end
end

always_ff @(posedge clk) begin
    if (in_valid) begin
        in_buf <= {in_buf[16:0], in_data};
    end
end

assign common_sum0 = in_data - in_buf[17];
assign common_sum1 = in_buf[15] - in_buf[1];
assign partial_sum0 = (in_buf[7] << 1) - (in_buf[9] << 1);
assign partial_sum1 = (in_buf[0] << 1) - (in_buf[16] << 1);
assign diffx = common_sum0 + common_sum1 + partial_sum0;
assign diffy = common_sum0 - common_sum1 + partial_sum1;

assign Gx = diffx[10] ? -diffx : diffx;
assign Gy = diffy[10] ? -diffy : diffy;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stall_cnt <= 0;
    end else begin
        if(in_cnt > 0 & !in_valid) begin
            stall_cnt <= stall_cnt + 1;
        end
        if(out_fifo_head > 35) begin
            stall_cnt <= 0;
        end
    end
end

assign wait_pixel = in_cnt < 18 | in_cnt[2:0] < 2;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_fifo_head <= 0;
        out_fifo_tail <= 0;
    end else begin
        if(out_fifo_head > 35) begin
            out_fifo_head <= 0;
            out_fifo_tail <= 0;
        end
        if(in_valid) begin
            if(!wait_pixel) begin
                out_fifo_tail <= out_fifo_tail + 1;
            end
        end else begin
            if(((stall_cnt < 7) | out_fifo_tail > 35) & (out_fifo_tail != out_fifo_head)) begin
                out_fifo_head <= out_fifo_head + 1;
            end
        end
    end
end

always_ff @(posedge clk) begin
    if(!wait_pixel & in_valid) begin
        out_fifo[out_fifo_tail] <= (Gx + Gy > 128) ? 1'b1 : 1'b0;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 0;
    end else begin
        if(((!in_valid & stall_cnt < 7) | out_fifo_tail > 35) & (out_fifo_head != out_fifo_tail)) begin
            out_valid <= 1;
        end else begin
            out_valid <= 0;
        end
    end
end

assign out_data = out_valid ? out_fifo[out_fifo_head - 1] : 0;

endmodule