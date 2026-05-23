module CA #(
    parameter RAM_DEPTH = 256,
    parameter RAM_WIDTH = 256,
    parameter BURST_BIT = 3
)(
    // ============================================= //
    //                    PATTERN                    //
    // ============================================= //
    // input signals
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            mem_set,
    input  logic                            in_valid,
    input  logic [1:0]                      op,
    input  logic [1:0]                      act,
    input  logic [255:0]                    param,

    // output signals
    output logic                            out_valid,
    output logic [31:0]                     out_data,

    // ============================================= //
    //                      RAM                      //
    // ============================================= //
    // READ
    output logic                            rd_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    rd_addr,
    output logic [BURST_BIT-1    :0]        rd_burst,
    input  logic                            rd_valid,
    input  logic [RAM_WIDTH-1:0]            rd_data,
    input  logic                            rd_ready,

    // WRITE
    output logic                            wr_en,
    output logic [$clog2(RAM_DEPTH)-1:0]    wr_addr,
    output logic [BURST_BIT-1    :0]        wr_burst,
    output logic [RAM_WIDTH-1:0]            wr_data,
    input  logic                            wr_valid,
    input  logic                            wr_ready
);
    // ======================================================================
    // Your Design
    // ======================================================================

    localparam int ADDR_WIDTH       = $clog2(RAM_DEPTH);
    localparam int BATCH_LEN        = 128;
    localparam int READ_WAIT_CYCLES = 50;
    localparam logic [BURST_BIT-1:0]   FULL_BURST  = 3'd7;
    localparam logic [ADDR_WIDTH-1:0]  BATCH0_ADDR = '0;
    localparam logic [ADDR_WIDTH-1:0]  BATCH1_ADDR = ADDR_WIDTH'(BATCH_LEN);

    localparam logic [1:0] OP_FFN  = 2'b00;
    localparam logic [1:0] OP_CONV = 2'b01;
    localparam logic [1:0] OP_SHA  = 2'b10;
    localparam logic [1:0] OP_MHA  = 2'b11;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RECV_P1,
        S_RECV_P2,
        S_RECV_P3,
        S_RD_REQ,
        S_RD_WAIT,
        S_RD_STREAM,
        S_COMPUTE,
        S_WR_REQ,
        S_WR_STREAM,
        S_BATCH_CHK,
        S_OP_DONE
    } state_t;

    state_t state_cs, state_ns;

    logic [1:0]            op_reg,       op_reg_ns;
    logic [1:0]            act_reg,      act_reg_ns;
    logic [255:0]          param_p1_reg, param_p1_reg_ns;
    logic [255:0]          param_p2_reg, param_p2_reg_ns;
    logic [255:0]          param_p3_reg, param_p3_reg_ns;
    logic [6:0]            mat_cnt,      mat_cnt_ns;
    logic [6:0]            wr_cnt,       wr_cnt_ns;
    logic                  batch_id,     batch_id_ns;
    logic [5:0]            rd_wait_cnt,  rd_wait_cnt_ns;

    // 128 × 256-bit buffer: stores one full batch of input matrices
    logic [RAM_WIDTH-1:0]  mat_buf [0:BATCH_LEN-1];

    logic [ADDR_WIDTH-1:0] batch_base_addr;
    assign batch_base_addr = batch_id ? BATCH1_ADDR : BATCH0_ADDR;

    // ------------------------------------------------------------------
    // Sequential registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_cs     <= S_IDLE;
            op_reg       <= 2'd0;
            act_reg      <= 2'd0;
            param_p1_reg <= 256'd0;
            param_p2_reg <= 256'd0;
            param_p3_reg <= 256'd0;
            mat_cnt      <= 7'd0;
            wr_cnt       <= 7'd0;
            batch_id     <= 1'b0;
            rd_wait_cnt  <= 6'd0;
        end else begin
            state_cs     <= state_ns;
            op_reg       <= op_reg_ns;
            act_reg      <= act_reg_ns;
            param_p1_reg <= param_p1_reg_ns;
            param_p2_reg <= param_p2_reg_ns;
            param_p3_reg <= param_p3_reg_ns;
            mat_cnt      <= mat_cnt_ns;
            wr_cnt       <= wr_cnt_ns;
            batch_id     <= batch_id_ns;
            rd_wait_cnt  <= rd_wait_cnt_ns;

            // mat_buf write: beat 0 in S_RD_WAIT, beats 1-127 in S_RD_STREAM
            if ((state_cs == S_RD_WAIT || state_cs == S_RD_STREAM) && rd_valid)
                mat_buf[mat_cnt] <= rd_data;
        end
    end

    // ------------------------------------------------------------------
    // Combinational control path
    // ------------------------------------------------------------------
    always_comb begin
        // ---- next-state defaults (hold current) ----
        state_ns        = state_cs;
        op_reg_ns       = op_reg;
        act_reg_ns      = act_reg;
        param_p1_reg_ns = param_p1_reg;
        param_p2_reg_ns = param_p2_reg;
        param_p3_reg_ns = param_p3_reg;
        mat_cnt_ns      = mat_cnt;
        wr_cnt_ns       = wr_cnt;
        batch_id_ns     = batch_id;
        rd_wait_cnt_ns  = rd_wait_cnt;

        // ---- output defaults (prevent latches) ----
        rd_en    = 1'b0;
        rd_addr  = '0;
        rd_burst = '0;

        wr_en    = 1'b0;
        wr_addr  = '0;
        wr_burst = '0;
        wr_data  = '0;

        out_valid = 1'b0;
        out_data  = 32'd0;

        case (state_cs)
            // ---- wait for this RAM round to begin ----
            S_IDLE: begin
                batch_id_ns    = 1'b0;
                mat_cnt_ns     = 7'd0;
                wr_cnt_ns      = 7'd0;
                rd_wait_cnt_ns = 6'd0;
                if (mem_set)
                    state_ns = S_RECV_P1;
            end

            // ---- capture op/act/param (1 cycle for FFN/Conv, 3 for SHA/MHA) ----
            S_RECV_P1: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    op_reg_ns       = op;
                    act_reg_ns      = act;
                    param_p1_reg_ns = param;
                    param_p2_reg_ns = 256'd0;
                    param_p3_reg_ns = 256'd0;
                    batch_id_ns     = 1'b0;
                    mat_cnt_ns      = 7'd0;
                    wr_cnt_ns       = 7'd0;
                    rd_wait_cnt_ns  = 6'd0;
                    if (op == OP_SHA || op == OP_MHA)
                        state_ns = S_RECV_P2;
                    else
                        state_ns = S_RD_REQ;
                end
            end

            S_RECV_P2: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    param_p2_reg_ns = param;  // W_K
                    state_ns        = S_RECV_P3;
                end
            end

            S_RECV_P3: begin
                if (!mem_set) begin
                    state_ns = S_IDLE;
                end else if (in_valid) begin
                    param_p3_reg_ns = param;  // W_V
                    state_ns        = S_RD_REQ;
                end
            end

            // ---- issue burst read request ----
            S_RD_REQ: begin
                rd_addr  = batch_base_addr;
                rd_burst = FULL_BURST;
                if (rd_ready) begin
                    rd_en          = 1'b1;
                    mat_cnt_ns     = 7'd0;
                    rd_wait_cnt_ns = 6'd0;
                    state_ns       = S_RD_WAIT;
                end
            end

            // ---- wait for RAM read latency (50 cycles) ----
            // beat 0 is captured here when rd_valid first fires
            S_RD_WAIT: begin
                if (rd_valid) begin
                    mat_cnt_ns = 7'd1;        // beat 0 stored via always_ff above
                    state_ns   = S_RD_STREAM;
                end else if (rd_wait_cnt == READ_WAIT_CYCLES - 1) begin
                    state_ns = S_RD_STREAM;   // rd_valid arrives in S_RD_STREAM
                end else begin
                    rd_wait_cnt_ns = rd_wait_cnt + 6'd1;
                end
            end

            // ---- receive remaining burst beats (1 to 127) ----
            S_RD_STREAM: begin
                if (rd_valid) begin
                    if (mat_cnt == BATCH_LEN - 1) begin
                        mat_cnt_ns = 7'd0;
                        state_ns   = S_COMPUTE;
                    end else begin
                        mat_cnt_ns = mat_cnt + 7'd1;
                    end
                end
            end

            // ---- compute placeholder: expand this state for FFN/Conv/SHA/MHA ----
            S_COMPUTE: begin
                wr_cnt_ns = 7'd0;
                state_ns  = S_WR_REQ;
            end

            // ---- issue burst write request ----
            // All write beats are handled exclusively in S_WR_STREAM.
            S_WR_REQ: begin
                wr_addr  = batch_base_addr;
                wr_burst = FULL_BURST;
                if (wr_ready) begin
                    wr_en    = 1'b1;
                    state_ns = S_WR_STREAM;
                end
            end

            // ---- stream 128 write beats; pulse out_valid per beat ----
            S_WR_STREAM: begin
                wr_data = mat_buf[wr_cnt];
                if (wr_valid) begin
                    out_valid = 1'b1;
                    out_data  = mat_buf[wr_cnt][31:0];  // last row (row 7) of result
                    if (wr_cnt == BATCH_LEN - 1) begin
                        wr_cnt_ns = 7'd0;
                        state_ns  = S_BATCH_CHK;
                    end else begin
                        wr_cnt_ns = wr_cnt + 7'd1;
                    end
                end
            end

            // ---- after each 128-matrix batch, check if second batch needed ----
            S_BATCH_CHK: begin
                if (!batch_id) begin
                    batch_id_ns    = 1'b1;
                    mat_cnt_ns     = 7'd0;
                    wr_cnt_ns      = 7'd0;
                    rd_wait_cnt_ns = 6'd0;
                    state_ns       = S_RD_REQ;
                end else begin
                    batch_id_ns = 1'b0;
                    state_ns    = S_OP_DONE;
                end
            end

            // ---- 256 matrices done; wait for next op_set or end of RAM round ----
            S_OP_DONE: begin
                if (mem_set)
                    state_ns = S_RECV_P1;
                else
                    state_ns = S_IDLE;
            end

            default: state_ns = S_IDLE;
        endcase
    end


endmodule
