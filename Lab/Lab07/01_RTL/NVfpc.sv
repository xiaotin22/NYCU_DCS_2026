module NVfpc(
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic [7:0] in_data,
    input  logic factor_valid,
    input  logic [7:0] factor,
    output logic out_valid,
    output logic [15:0] out_data
);

// ======================================================================
// LOGIC DECLARATION
// ======================================================================
logic [3:0]  in_a[0:3], in_a_ns[0:3], in_b[0:3], in_b_ns[0:3];
logic [7:0]  factor_ff, factor_ff_ns; 
logic [3:0]  factor_cnt, factor_cnt_ns;
logic [1:0]  input_cnt, input_cnt_ns;

logic [15:0] scale_global; 
assign scale_global = {1'b0, 7'b0111111, 8'b00000000}; // 0.5 BF16

logic input_done;



always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        factor_ff  <= '{default: 8'd0};
        factor_cnt <= 4'd0;
        input_cnt  <= 2'd0;
        in_a       <= '{default: 4'd0};
        in_b       <= '{default: 4'd0};
    end
    else begin
        factor_ff  <= factor_ff_ns;
        in_a       <= in_a_ns;
        in_b       <= in_b_ns;
        factor_cnt <= factor_cnt_ns;
        input_cnt  <= input_cnt_ns;
    end
end

always_comb begin
    in_a_ns       = in_a;
    in_b_ns       = in_b;
    factor_ff_ns  = factor_ff;
    factor_cnt_ns = factor_cnt;
    input_cnt_ns  = input_cnt;
    input_done = 0;

    // 處理 Factor 輸入
    if (factor_valid) begin
        factor_ff_ns = factor; 
        factor_cnt_ns = factor_cnt + 1;
    end

    // 處理 Data 輸入
    if (in_valid) begin
        in_a_ns[input_cnt] = in_data[7:4];
        in_b_ns[input_cnt] = in_data[3:0];
        
        if (input_cnt == 3)
            input_cnt_ns = 0;
        else
            input_cnt_ns = input_cnt + 1;
    end
end     


logic [15:0] in_a_bf16[0:3], in_a_bf16_ns[0:3], in_b_bf16[0:3], in_b_bf16_ns[0:3];
logic [15:0] factor_bf16, factor_bf16_ns;

always_comb begin
    in_a_bf16_ns = in_a_bf16;
    in_b_bf16_ns = in_b_bf16;
    
    for (int j = 0; j < 4; j = j + 1) begin
        in_a_bf16_ns[j] = FP4_TO_BF16(in_a_ns[j]);
        in_b_bf16_ns[j] = FP4_TO_BF16(in_b_ns[j]);
    end
    
    // 【修正】必須從 factor_ff 取值，而不是直接拿 input port
    factor_bf16_ns = FP8_TO_BF16(factor_ff); 
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_a_bf16 <= '{default: 16'd0};
        in_b_bf16 <= '{default: 16'd0};
        factor_bf16 <= 16'd0;
    end
    else begin
        in_a_bf16 <= in_a_bf16_ns;
        in_b_bf16 <= in_b_bf16_ns;
        factor_bf16 <= factor_bf16_ns;
    end
end

logic [15:0] in_as[0:3], in_bs[0:3];
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_as <= '{default: 16'd0};
        in_bs <= '{default: 16'd0};
    end
    else begin
        for (int m = 0; m < 4; m = m + 1) begin
            in_as[m] <= BF16_MUL(in_a_bf16[m], scale_global);
            in_bs[m] <= BF16_MUL(in_b_bf16[m], scale_global);
        end
    end
end

logic [15:0] in_ass[0:3], in_bss[0:3];
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        in_ass <= '{default: 16'd0};
        in_bss <= '{default: 16'd0};
    end
    else begin
        for (int m = 0; m < 4; m = m + 1) begin
            in_ass[m] <= BF16_MUL(in_as[m], factor_bf16);
            in_bss[m] <= in_bs[m];
        end
    end
end


logic [15:0] out_ab_ns[0:3], out_ab[0:3];
always_comb begin
    for (int k = 0; k < 4; k = k + 1) begin
        out_ab_ns[k] = BF16_MUL(in_ass[k], in_bss[k]);
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_ab <= '{default: 16'd0};
    end
    else begin
        out_ab <= out_ab_ns;
    end
end

logic [15:0] sum0, sum1, add_final_out;
always_comb begin
    sum0 = BF16_ADD(out_ab[0], out_ab[1]);
    sum1 = BF16_ADD(out_ab[2], out_ab[3]);
    add_final_out = BF16_ADD(sum0, sum1);
end

logic vld_s1, vld_s2, vld_s3, vld_s4;


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_data  <= 16'd0;
        out_valid <= 1'b0;
        vld_s1    <= 1'b0;
        vld_s2    <= 1'b0;
        vld_s3    <= 1'b0;
        vld_s4    <= 1'b0;
    end
    else begin
        // Pipeline Stage 1: 收滿 4 筆資料進入 in_a_bf16
        vld_s1    <= (in_valid && input_cnt == 2'd3);
        
        // Pipeline Stage 2: 進入 in_as / in_bs (乘 global_sf)
        vld_s2    <= vld_s1;
        
        // Pipeline Stage 3: 進入 out_ab (a*b 相乘)
        vld_s3    <= vld_s2;

        // Pipeline Stage 4: 進入加法樹，最後輸出結果
        vld_s4    <= vld_s3;
        
        // Pipeline Stage 5: 加法樹與最後乘 factor_bf16 完成，輸出！
        out_valid <= vld_s4;
        if (vld_s4)
            out_data <= add_final_out;
        else
            out_data <= 16'd0;
    end
end





    function automatic logic [15:0] FP4_TO_BF16 (
        input logic [3:0] fp4
    );
        logic sign;
        logic [1:0] exp_fp4;
        logic frac_fp4;
        logic [7:0] exp_bf16;
        logic [6:0] frac_bf16;
    begin
        sign     = fp4[3];
        exp_fp4  = fp4[2:1];
        frac_fp4 = fp4[0];

        exp_bf16  = {6'd0, exp_fp4} + 8'd126;
        frac_bf16 = {frac_fp4, 6'b0};

        FP4_TO_BF16 = {sign, exp_bf16, frac_bf16};
    end
    endfunction

    function automatic logic [15:0] FP8_TO_BF16 (
        input logic [7:0] fp8
    );
        logic sign;
        logic [3:0] exp_fp8;
        logic [2:0] frac_fp8;
        logic [7:0] exp_bf16;
        logic [6:0] frac_bf16;
    begin
        sign     = fp8[7];
        exp_fp8  = fp8[6:3];
        frac_fp8 = fp8[2:0];

        exp_bf16  = {4'd0, exp_fp8} + 8'd120;
        frac_bf16 = {frac_fp8, 4'b0};

        FP8_TO_BF16 = {sign, exp_bf16, frac_bf16};
    end
    endfunction

    // =========================================================
    // 3. bfloat16 乘法器 (Multiplier)
    // =========================================================
    function automatic logic [15:0] BF16_MUL (
        input logic [15:0] x,
        input logic [15:0] y
    );
        logic sign_x, sign_y, out_sign;
        logic [7:0] exp_x, exp_y, result_exp;
        logic [6:0] frac_x, frac_y;
        logic [8:0] exp_temp;
        logic [7:0] mant_x, mant_y, mant_norm;
        logic [15:0] mant_mul;
    begin
        sign_x = x[15];
        exp_x  = x[14:7];
        frac_x = x[6:0];
        sign_y = y[15];
        exp_y  = y[14:7];
        frac_y = y[6:0];

        out_sign = sign_x ^ sign_y;

        mant_x = {1'b1, frac_x};
        mant_y = {1'b1, frac_y};
        mant_mul = mant_x * mant_y;

        exp_temp = {1'b0, exp_x} + {1'b0, exp_y} - 9'd127;

        if (mant_mul[15]) begin
            mant_norm  = mant_mul[15:8];
            result_exp = exp_temp[7:0] + 8'd1;
        end else begin
            mant_norm  = mant_mul[14:7];
            result_exp = exp_temp[7:0];
        end

        BF16_MUL = {out_sign, result_exp, mant_norm[6:0]};
    end
    endfunction

    // =========================================================
    // 4. bfloat16 加法器 (Adder)
    // =========================================================
    function automatic logic [15:0] BF16_ADD (
        input logic [15:0] x,
        input logic [15:0] y
    );
        logic sign_x, sign_y, sign_big, sign_small, out_sign;
        logic [7:0] exp_x, exp_y, exp_big, exp_small, exp_diff, result_exp;
        logic [6:0] frac_x, frac_y;
        logic [8:0] mant_x, mant_y, mant_big, mant_small, mant_small_shift, result_mant;
        logic [9:0] mant_sum;
        integer i;
    begin
        sign_x = x[15];
        exp_x  = x[14:7];
        frac_x = x[6:0];
        sign_y = y[15];
        exp_y  = y[14:7];
        frac_y = y[6:0];

        mant_x = {1'b1, frac_x, 1'b0};
        mant_y = {1'b1, frac_y, 1'b0};

        if (exp_x > exp_y) begin
            exp_big = exp_x;  exp_small = exp_y;
            mant_big = mant_x; mant_small = mant_y;
            sign_big = sign_x; sign_small = sign_y;
        end else begin
            exp_big = exp_y;  exp_small = exp_x;
            mant_big = mant_y; mant_small = mant_x;
            sign_big = sign_y; sign_small = sign_x;
        end

        exp_diff = exp_big - exp_small;

        if (exp_diff >= 8'd9)
            mant_small_shift = 9'd0;
        else
            mant_small_shift = mant_small >> exp_diff;

        if (sign_big == sign_small) begin
            mant_sum    = {1'b0, mant_big} + {1'b0, mant_small_shift};
            out_sign = sign_big;
        end else begin
            if (mant_big >= mant_small_shift) begin
                mant_sum    = {1'b0, mant_big} - {1'b0, mant_small_shift};
                out_sign = sign_big;
            end else begin
                mant_sum    = {1'b0, mant_small_shift} - {1'b0, mant_big};
                out_sign = sign_small;
            end
        end

        if (mant_sum == 10'd0) begin
            BF16_ADD = 16'd0;
        end else begin
            if (mant_sum[9]) begin
                result_mant = mant_sum[9:1];
                result_exp  = exp_big + 8'd1;
            end else begin
                result_mant = mant_sum[8:0];
                result_exp  = exp_big;

                for (i = 0; i < 8; i = i + 1) begin
                    if (result_mant[8] == 1'b0 && result_mant != 9'd0) begin
                        result_mant = result_mant << 1;
                        result_exp  = result_exp - 8'd1;
                    end
                end
            end

            BF16_ADD = {out_sign, result_exp, result_mant[7:1]};
        end
    end
    endfunction

endmodule