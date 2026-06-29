module LN(
    clk,
    rst_n,
    in_valid,
    in_data,

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
logic [2:0] cnt_cs, cnt_ns;

logic signed [8:0] diff_mean_cs [0:7];
logic signed [8:0] diff_mean_ns [0:7];

logic [10:0] std_reg_cs, std_reg_ns;

logic out_valid_cs, out_valid_ns;
logic signed [7:0] out_data_cs, out_data_ns;

assign out_data = out_data_cs;
assign out_valid = out_valid_cs;

logic signed [8:0] mean_now, mean_now_next;
logic [7:0] std_now, std_now_next;

logic [15:0] pipe_valid;
logic signed [8:0] diff_now;
logic [8:0] abs_diff_now;

assign diff_now = in_buf_cs[7] - mean_now;
assign abs_diff_now = abs(diff_now);


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
        cnt_cs <= 3'd0;
        mean_reg_cs <= 12'd0;
        std_reg_cs <= 11'd0;
        out_data_cs <= 8'sd0;
        out_valid_cs <= 1'd0;
        pipe_valid <= '{default: 1'b0};

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
        
        pipe_valid <= {pipe_valid[14:0], in_valid};
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

        diff_mean_ns[0] = diff_now;
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
        if (cnt_cs != 3'd7) begin
            mean_reg_ns = mean_reg_cs + in_data;
            std_reg_ns = std_reg_cs + abs_diff_now;
        end else begin
            mean_reg_ns = 0; 
            mean_now_next = div8_trunc(mean_reg_cs + in_data); 
            std_reg_ns = 0;
            std_now_next = (std_reg_cs + abs_diff_now) >> 3;
        end
    end
end

always_comb begin
    cnt_ns = cnt_cs;
    if (in_valid || |pipe_valid) begin
        if (cnt_cs != 3'd7) begin
            cnt_ns = cnt_cs + 1'b1;
        end else begin
            cnt_ns = 3'd0;
        end
    end
end 


always_comb begin
    out_valid_ns = out_valid_cs;
    out_data_ns = out_data_cs;

    if (pipe_valid[15]) begin
        out_valid_ns = 1'b1;
        out_data_ns = norm_div_limited(diff_mean_cs[7], std_now);
    end else begin
        out_valid_ns = 1'b0;
        out_data_ns = 8'sd0;
    end
end


function automatic logic signed [8:0] div8_trunc(input logic signed [11:0] in);
    logic [11:0] mag;
    logic signed [8:0] quot;
begin
    mag = in[11] ? (~in + 12'd1) : in;
    quot = $signed({1'b0, mag[11:3]});
    return in[11] ? -quot : quot;
end
endfunction


function automatic logic signed [7:0] norm_div_limited(
    input logic signed [8:0] numer,
    input logic [7:0] denom
);
    logic sign;
    logic [8:0] numer_mag;
    logic [11:0] rem;
    logic [3:0] quot;
    logic [11:0] denom_ext;
begin
    sign = numer[8];
    numer_mag = sign ? -numer : numer;
    rem = {3'd0, numer_mag};
    quot = 4'd0;
    denom_ext = {4'd0, denom};

    if (rem >= (denom_ext << 3)) begin
        quot[3] = 1'b1;
        rem = rem - (denom_ext << 3);
    end
    if (rem >= (denom_ext << 2)) begin
        quot[2] = 1'b1;
        rem = rem - (denom_ext << 2);
    end
    if (rem >= (denom_ext << 1)) begin
        quot[1] = 1'b1;
        rem = rem - (denom_ext << 1);
    end
    if (rem >= denom_ext) begin
        quot[0] = 1'b1;
    end

    return sign ? -$signed({4'd0, quot}) : $signed({4'd0, quot});
end
endfunction


function automatic logic [8:0] abs(input logic signed [8:0] in);
    if (in[8]) begin
        return -in;
    end else begin
        return in;
    end
endfunction


endmodule
