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
// Pipeline Stage 1
logic flag, flag_next;
logic [2:0] counter, counter_next;
logic signed [7:0] reg_stage1 [0:7];
logic signed [7:0] reg_stage1_next [0:7];
logic signed [7:0] reg_stage4 [0:7];
logic signed [7:0] reg_stage4_next [0:7];
logic signed [15:0] sum_stage1, sum_stage1_next;
logic stage4_finish, stage4_finish_next;

// Pipeline Stage 2
logic signed [8:0] reg_stage2 [0:7];
logic signed [8:0] reg_stage2_next [0:7];
logic signed [7:0] mean, mean_next;
logic signed [15:0] abs_sum, abs_sum_next;
logic signed [7:0] std_approx, std_approx_next;
logic stage2_finish, stage2_finish_next;
logic [8:0] temp;

// Output Stage
logic signed [8:0] reg_stage3 [0:7];
logic signed [8:0] reg_stage3_next [0:7];
logic stage3_finish, stage3_finish_next;

// Control signals
logic next_out_valid;
logic signed [7:0] next_out_data;
logic [1:0] done, done_next;

//================================================================
// SEQUENTIAL LOGIC
//================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Stage 1 registers
        flag <= 0;
        counter <= 0;
        sum_stage1 <= 0;
        stage4_finish <= 0;
        
        // Stage 2 registers
        abs_sum <= 0;
        stage2_finish <= 0;
        std_approx <= 0;
        mean <= 0;
        
        // Output registers
        stage3_finish <= 0;
        out_valid <= 0;
        out_data <= 0;
        
        // Clear all shift registers
        for (int i = 0; i < 8; i++) begin
            reg_stage1[i] <= 0;
            reg_stage2[i] <= 0;
            reg_stage3[i] <= 0;
            reg_stage4[i] <= 0;
        end
        done <= 0;
    end
    else begin
        // Stage 1 registers
        flag <= flag_next;
        counter <= counter_next;
        sum_stage1 <= sum_stage1_next;
        stage4_finish <= stage4_finish_next;
        
        // Stage 2 registers
        abs_sum <= abs_sum_next;
        stage2_finish <= stage2_finish_next;
        std_approx <= std_approx_next;
        mean <= mean_next;
        
        // Output registers
        stage3_finish <= stage3_finish_next;
        out_valid <= next_out_valid;
        out_data <= next_out_data;
        
        // Update shift registers
        reg_stage1 <= reg_stage1_next;
        reg_stage2 <= reg_stage2_next;
        reg_stage3 <= reg_stage3_next;
        reg_stage4 <= reg_stage4_next;
        done <= done_next;
    end
end

//================================================================
// COMBINATIONAL LOGIC
//================================================================
always_comb begin
    flag_next = flag;
    counter_next = counter;
    sum_stage1_next = sum_stage1;
    done_next = done;
    stage4_finish_next = stage4_finish;
    
    mean_next = mean;
    abs_sum_next = abs_sum;
    std_approx_next = std_approx;
    stage2_finish_next = stage2_finish;
    
    stage3_finish_next = stage3_finish;
    next_out_valid = 0;
    next_out_data = 0;

    reg_stage1_next = reg_stage1;
    reg_stage2_next = reg_stage2;
    reg_stage3_next = reg_stage3;
    reg_stage4_next = reg_stage4;
    
    //================================================================
    // PIPELINE STAGE 1 & 4: Input Data and Mean Calculation
    //================================================================
    if (in_valid) begin
        flag_next = 1;
        reg_stage1_next[counter] = in_data;
        
        if (counter == 7) 
            sum_stage1_next = 0;
        else 
            sum_stage1_next = sum_stage1 + in_data;
        
    end
    else if (counter == 7) 
        done_next = 1;

    if (in_valid || flag) begin
        counter_next = counter + 1;
    end

    if (counter == 7) begin
        mean_next = $signed(sum_stage1 + in_data) / 8;
        reg_stage4_next[0] = reg_stage1[0];
        reg_stage4_next[1] = reg_stage1[1];
        reg_stage4_next[2] = reg_stage1[2];
        reg_stage4_next[3] = reg_stage1[3];
        reg_stage4_next[4] = reg_stage1[4];
        reg_stage4_next[5] = reg_stage1[5];
        reg_stage4_next[6] = reg_stage1[6];
        reg_stage4_next[7] = in_data;
        stage4_finish_next = 1;
        abs_sum_next = 0;

        if(stage4_finish) begin
            reg_stage2_next[0] = reg_stage4[0] - mean;
            reg_stage2_next[1] = reg_stage4[1] - mean;
            reg_stage2_next[2] = reg_stage4[2] - mean;
            reg_stage2_next[3] = reg_stage4[3] - mean;
            reg_stage2_next[4] = reg_stage4[4] - mean;
            reg_stage2_next[5] = reg_stage4[5] - mean;
            reg_stage2_next[6] = reg_stage4[6] - mean;
            reg_stage2_next[7] = reg_stage4[7] - mean;
            stage2_finish_next = 1;
            abs_sum_next = 0;
        end
    end

    //================================================================
    // PIPELINE STAGE 2: Standard Deviation and Normalization
    //================================================================
    if (stage2_finish) begin
        temp = (reg_stage2[counter] >= 0) ? reg_stage2[counter] : (0 - reg_stage2[counter]);
        abs_sum_next = abs_sum + temp;

        if (counter == 7) begin
            std_approx_next = abs_sum_next / 8;
            abs_sum_next = 0;
            reg_stage3_next = reg_stage2;
            stage3_finish_next = 1;
        end
    end
    
    //================================================================
    // OUTPUT STAGE
    //================================================================
    if (stage3_finish) begin
        next_out_valid = 1;
        next_out_data = reg_stage3[counter] / std_approx;
    end

    if (done == 1 && counter == 7) 
        done_next = 2;
    
    if (done == 2 && counter == 7) 
        done_next = 3;
    
    if (done == 3) begin
        next_out_valid = 0;
        next_out_data = 0;
    end

end
endmodule