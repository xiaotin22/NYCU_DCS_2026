// Area TBD, 134 latency, clk = 3.4ns
module MHA(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              mode,
    input  logic              in_valid_qk,
    input  logic signed [3:0] in_data_q,
    input  logic signed [3:0] in_data_k,
    input  logic              in_valid_v,
    input  logic signed [3:0] in_data_v,
    output logic              get_value,
    output logic              out_valid,
    output logic signed [19:0] out_data
);

    // Pipeline timeline (no input registers; direct-to-mem)
    //   cnt  0~55  : load Q/K/V directly into memories (cnt=0 in IDLE for beat-0)
    //   cnt 57~120 : Stage-1  MAC_S multiply  (S_mul registered)
    //   cnt 58~121 : Stage-2a register S1/S2 sums
    //   cnt 59~122 : Stage-2b round -> P_ns  (address = cnt[2:0]-3)
    //   cnt 66,74,...,122 : P_row commit  (cnt[2:0]==2)
    //   cnt 67~130 : Stage-3  MAC_O multiply  (o_mul registered)
    //   cnt 68~131 : Stage-4a register MAC_O partial sums
    //   cnt 69~132 : Stage-4b final add + output valid  (all 64 results)

    localparam logic       IDLE    = 1'b0, COMPUTE = 1'b1;
    localparam logic [7:0] S_START   = 8'd57;
    localparam logic [7:0] O_SUM_START = 8'd68;
    localparam logic [7:0] O_SUM_END   = 8'd131;
    localparam logic [7:0] OUT_END     = 8'd132;

    // 1. Control & Buffers
    logic       state, state_ns;
    logic [7:0] cnt, cnt_ns;
    logic       mode_reg, mode_reg_ns, get_value_ns;

    logic signed [3:0]  Q_mem[0:7][0:7], K_mem[0:7][0:7], VT_mem[0:7][0:7];

    logic signed [10:0] P1_ns[0:7], P1_row[0:7];
    logic signed [9:0]  P2_ns[0:7], P2_row[0:7];

    // 2. Stage 1: MAC_S Multiply (cnt 57..120)
    logic [2:0] S_Q_row, S_K_row;
    logic signed [7:0] S_mul[0:7];

    always_ff @(posedge clk) begin
        for (int c = 0; c < 8; c++)
            S_mul[c] <= Q_mem[S_Q_row][c] * K_mem[S_K_row][c];

        if (cnt == S_START - 1) begin
            S_Q_row <= 3'd0;
            S_K_row <= 3'd0;
        end else if (cnt >= S_START && cnt < S_START + 63) begin
            if (S_K_row == 3'd7) begin
                S_Q_row <= S_Q_row + 3'd1;
                S_K_row <= 3'd0;
            end else begin
                S_K_row <= S_K_row + 3'd1;
            end
        end
    end

    // 3. Stage 2a: Register sums (cnt 58..121)
    logic signed [9:0]  S1_sum_ns, S2_sum_ns;
    logic signed [9:0]  S1_sum, S2_sum;
    logic signed [10:0] S1_sum_ext, S2_sum_ext;

    assign S1_sum_ns = $signed({{2{S_mul[0][7]}}, S_mul[0]}) + $signed({{2{S_mul[1][7]}}, S_mul[1]}) +
                       $signed({{2{S_mul[2][7]}}, S_mul[2]}) + $signed({{2{S_mul[3][7]}}, S_mul[3]});
    assign S2_sum_ns = $signed({{2{S_mul[4][7]}}, S_mul[4]}) + $signed({{2{S_mul[5][7]}}, S_mul[5]}) +
                       $signed({{2{S_mul[6][7]}}, S_mul[6]}) + $signed({{2{S_mul[7][7]}}, S_mul[7]});
    assign S1_sum_ext = {S1_sum[9], S1_sum};
    assign S2_sum_ext = {S2_sum[9], S2_sum};

    always_ff @(posedge clk) begin
        S1_sum <= S1_sum_ns;
        S2_sum <= S2_sum_ns;
    end

    // 4. Stage 2b: Round -> P_ns (cnt 59..122)
    logic signed [10:0] S1_in, P1_val;
    logic signed [9:0]  P2_val;

    assign S1_in  = mode_reg ? S1_sum_ext : (S1_sum_ext + S2_sum_ext);
    assign P1_val = S1_in[10]  ? ((S1_in  + 11'sd3) >>> 2) : S1_in;
    assign P2_val = S2_sum[9] ? ((S2_sum + 10'sd3) >>> 2) : S2_sum;

    always_ff @(posedge clk) begin
        if (cnt >= S_START + 2 && cnt <= S_START + 65) begin  // cnt 59..122
            P1_ns[cnt[2:0] - 3'd3] <= P1_val;
            if (mode_reg) P2_ns[cnt[2:0] - 3'd3] <= P2_val;
        end
        // Commit P_ns -> P_row once all 8 k-cols are written (cnt[2:0]==2: cnt 66,74,...,122)
        if (cnt[6] && cnt[2:0] == 3'b010) begin
            for (int j = 0; j < 7; j++) begin
                P1_row[j] <= P1_ns[j];
                P2_row[j] <= P2_ns[j];
            end
            P1_row[7] <= P1_val;
            P2_row[7] <= P2_val;
        end
    end

    // 5. Stage 3: MAC_O Multiply (cnt 67..130)
    logic [2:0]         pre_col;
    logic               use_p2;
    logic               pre_new_row;
    logic signed [10:0] P_pre[0:7];
    logic signed [10:0] P_op[0:7];
    logic signed [3:0]  V_op[0:7];
    logic signed [12:0] o_mul[0:7];

    assign pre_col     = cnt[2:0] + 3'd1;
    assign use_p2      = ~(pre_col[2] ^ (pre_col[1] & pre_col[0]));
    assign pre_new_row = cnt[6] && cnt[2:0] == 3'b010;

    always_comb begin
        for (int i = 0; i < 7; i++) begin
            if (pre_new_row)
                P_pre[i] = (mode_reg && use_p2) ? $signed({P2_ns[i][9], P2_ns[i]}) : P1_ns[i];
            else
                P_pre[i] = (mode_reg && use_p2) ? $signed({P2_row[i][9], P2_row[i]}) : P1_row[i];
        end

        if (pre_new_row)
            P_pre[7] = (mode_reg && use_p2) ? $signed({P2_val[9], P2_val}) : P1_val;
        else
            P_pre[7] = (mode_reg && use_p2) ? $signed({P2_row[7][9], P2_row[7]}) : P1_row[7];
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) begin
            P_op[i]  <= P_pre[i];
            V_op[i]  <= VT_mem[pre_col][i];
            o_mul[i] <= P_op[i] * V_op[i];
        end
    end

    // 6. Stage 4: MAC_O Adder Pipeline + Output (cnt 68..132)
    logic signed [13:0] sum01, sum23, sum45, sum67;
    logic signed [14:0] sum03, sum47;
    logic signed [14:0] sum03_reg, sum47_reg;
    logic signed [15:0] out_sum;
    logic               can_output, out_sum_valid;

    assign sum01   = $signed({o_mul[0][12], o_mul[0]}) + $signed({o_mul[1][12], o_mul[1]});
    assign sum23   = $signed({o_mul[2][12], o_mul[2]}) + $signed({o_mul[3][12], o_mul[3]});
    assign sum45   = $signed({o_mul[4][12], o_mul[4]}) + $signed({o_mul[5][12], o_mul[5]});
    assign sum67   = $signed({o_mul[6][12], o_mul[6]}) + $signed({o_mul[7][12], o_mul[7]});
    assign sum03   = $signed({sum01[13], sum01}) + $signed({sum23[13], sum23});
    assign sum47   = $signed({sum45[13], sum45}) + $signed({sum67[13], sum67});
    assign out_sum = $signed({sum03_reg[14], sum03_reg}) + $signed({sum47_reg[14], sum47_reg});
    assign can_output = state && (cnt >= O_SUM_START) && (cnt <= O_SUM_END);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid     <= '0;
            out_data      <= '0;
            out_sum_valid <= '0;
            sum03_reg     <= '0;
            sum47_reg     <= '0;
        end else begin
            sum03_reg     <= sum03;
            sum47_reg     <= sum47;
            out_sum_valid <= can_output;
            out_valid     <= out_sum_valid;
            out_data      <= out_sum_valid ? {{4{out_sum[15]}}, out_sum} : 20'sd0;
        end
    end

    // 7. State Machine
    always_comb begin
        state_ns     = state;
        cnt_ns       = cnt;
        mode_reg_ns  = mode_reg;
        get_value_ns = 1'b0;

        case (state)
            IDLE: begin
                cnt_ns = '0;
                if (in_valid_qk) begin
                    state_ns     = COMPUTE;
                    mode_reg_ns  = mode;
                    get_value_ns = 1'b1;
                    cnt_ns       = 8'd1;   // beat-0 uses IDLE's cnt=0; next cycle cnt=1
                end
            end
            COMPUTE: begin
                if (cnt == OUT_END) begin
                    state_ns = IDLE;
                    cnt_ns   = '0;
                end else begin
                    cnt_ns = cnt + 8'd1;
                end
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            get_value <= '0;
            cnt       <= '0;
        end else begin
            state     <= state_ns;
            cnt       <= cnt_ns;
            mode_reg  <= mode_reg_ns;
            get_value <= get_value_ns;
        end
    end

    // 8. Memory Write (direct, no input registers)
    // IDLE holds cnt=0; beat-0 arrives at the IDLE->COMPUTE posedge and uses cnt=0.
    // Subsequent beats arrive at cnt=1,2,... (COMPUTE increments from 1).
    logic [5:0] v_cnt;
    logic [2:0] v_col_rot;
    assign v_cnt = cnt[5:0] - 6'd2;
    assign v_col_rot = v_cnt[2:0] + 3'd3;

    always_ff @(posedge clk) begin
        if (in_valid_qk) begin
            Q_mem[cnt[5:3]][cnt[2:0]] <= in_data_q;
            K_mem[cnt[5:3]][cnt[2:0]] <= in_data_k;
        end
        if (in_valid_v)
            VT_mem[v_col_rot][v_cnt[5:3]] <= in_data_v;
    end

endmodule
