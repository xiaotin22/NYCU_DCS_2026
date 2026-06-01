module LN(
    //OUTPUT 
    clk,
    rst_n,
    in_valid,
    in_data,

    //INPUT
    out_valid,
    out_data
);

// INPUT
input clk;
input rst_n;
input in_valid;
input signed [7:0] in_data;

// OUTPUT
output logic out_valid;
output logic signed [7:0] out_data;

//================================================================
// DESIGN
//================================================================

logic signed [7:0] in_buf_cs [0:7];
logic signed [7:0] in_buf_ns [0:7];

logic signed [11:0] mean_reg_cs, mean_reg_ns;
logic [3:0] cnt_cs, cnt_ns;

logic signed [8:0] diff_mean_cs [0:7];
logic signed [8:0] diff_mean_ns [0:7];

logic signed [12:0] std_reg_cs, std_reg_ns;

logic out_valid_cs, out_valid_ns;
logic [7:0] out_data_cs, out_data_ns;

assign out_data = out_data_cs;
assign out_valid = out_valid_cs;

logic signed [8:0] mean_now, mean_now_next;
logic signed [8:0] std_now, std_now_next;

logic [16:0] pipe_valid;


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
        cnt_cs <= 4'd0;
        mean_reg_cs <= 12'd0;
        std_reg_cs <= 13'd0;
        out_data_cs <= 8'd0;
        out_valid_cs <= 1'd0;
        pipe_valid <= '{default: 1'b0};
        in_buf_cs <= '{default: 8'd0};
        diff_mean_cs <= '{default: 9'd0};

    end else begin
        in_buf_cs <= in_buf_ns;
        mean_reg_cs <= mean_reg_ns;
        diff_mean_cs <= diff_mean_ns;
        std_reg_cs <= std_reg_ns;
        cnt_cs <= cnt_ns;
        out_valid_cs <= out_valid_ns;
        out_data_cs <= out_data_ns;
        
        
        mean_now <= mean_now_next;
        std_now <= std_now_next;
        
        pipe_valid <= {pipe_valid[15:0], in_valid};
    end
end

always_comb begin
    in_buf_ns = in_buf_cs;
    diff_mean_ns = diff_mean_cs;

    if (in_valid || |pipe_valid) begin
        in_buf_ns[0] = in_data;
        in_buf_ns[1] = in_buf_cs[0];
        in_buf_ns[2] = in_buf_cs[1];
        in_buf_ns[3] = in_buf_cs[2];
        in_buf_ns[4] = in_buf_cs[3];
        in_buf_ns[5] = in_buf_cs[4];
        in_buf_ns[6] = in_buf_cs[5];
        in_buf_ns[7] = in_buf_cs[6];

        diff_mean_ns[0] = in_buf_cs[7] - mean_now;
        diff_mean_ns[1] = diff_mean_cs[0];
        diff_mean_ns[2] = diff_mean_cs[1];
        diff_mean_ns[3] = diff_mean_cs[2];
        diff_mean_ns[4] = diff_mean_cs[3];
        diff_mean_ns[5] = diff_mean_cs[4];
        diff_mean_ns[6] = diff_mean_cs[5];
        diff_mean_ns[7] = diff_mean_cs[6];
    end
end

always_comb begin
    mean_reg_ns = mean_reg_cs;
    std_reg_ns = std_reg_cs;

    mean_now_next = mean_now;
    std_now_next = std_now;

    if (in_valid || |pipe_valid) begin
        if (cnt_cs != 4'd7) begin
            mean_reg_ns = mean_reg_cs + in_data;
            std_reg_ns = std_reg_cs + abs(in_buf_cs[7] - mean_now);
        end else begin
            mean_reg_ns = 0; 
            mean_now_next = (mean_reg_cs + in_data) / 8; 
            std_reg_ns = 0;
            std_now_next = (std_reg_cs + abs(in_buf_cs[7] - mean_now)) / 8;
        end
    end
end

always_comb begin
    cnt_ns = cnt_cs;
    if (in_valid || |pipe_valid) begin
        if (cnt_cs != 4'd7) begin
            cnt_ns = cnt_cs + 1'b1;
        end else begin
            cnt_ns = 4'd0;
        end
    end
end 


always_comb begin
    out_valid_ns = out_valid_cs;
    out_data_ns = out_data_cs;

    if (pipe_valid[15]) begin
        out_valid_ns = 1'b1;
        out_data_ns = (diff_mean_cs[7]) / std_now;
    end else begin
        out_valid_ns = 1'b0;
        out_data_ns = 8'd0;
    end
end


function automatic logic [8:0] abs(input logic signed [8:0] in);
    if (in[8]) begin
        return -in;
    end else begin
        return in;
    end
endfunction


endmodule