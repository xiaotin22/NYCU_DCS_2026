module DCSPI (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic in_data,
    output logic out_valid,
    output logic [15:0] out_data
);

//---------------------------------------------------------------------
//   LOGIC DECLARATION
//---------------------------------------------------------------------
logic [15:0] out_adder_cs, out_adder_ns; 
logic [7:0]  input_ff;  
logic [2:0]  in_bit_cnt;      
logic        input_done;   

typedef enum logic [2:0]{
    IDLE, S0, S00, S01, STOP, OUTPUT
} state_t;

state_t state_cs, state_ns;

//---------------------------------------------------------------------
//   1. Input Sequential Logic
//---------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_ff   <= 8'b0;
        in_bit_cnt <= 3'd7; 
        input_done <= 1'b0;
    end else if (in_valid) begin
        input_ff[in_bit_cnt] <= in_data;
        
        if (in_bit_cnt == 3'd0) begin
            in_bit_cnt <= 3'd7;    
            input_done <= 1'b1;    
        end else begin
            in_bit_cnt <= in_bit_cnt - 3'd1;
            input_done <= 1'b0;
        end
    end else begin
        input_done <= 1'b0;
        in_bit_cnt <= 3'd7; 
    end
end

//---------------------------------------------------------------------
//   2. FSM & Output  Sequential Logic
//---------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_cs    <= IDLE;
        out_adder_cs  <= 16'b0;
        out_valid   <= 1'b0;
        out_data    <= 16'b0;
    end else begin
        state_cs    <= state_ns;
        out_adder_cs  <= out_adder_ns;
        
        if (state_ns == OUTPUT) begin
            out_valid <= 1'b1;
            out_data  <= out_adder_ns; 
        end else begin
            out_valid <= 1'b0;
            out_data  <= 16'b0;
        end
    end
end

// Combinational logic 
always_comb begin
    state_ns   = state_cs;
    out_adder_ns = out_adder_cs;

    case (state_cs)
        IDLE: begin
            if (input_done) begin
                out_adder_ns = out_adder_cs + input_ff; 
                if (input_ff % 3 == 0) state_ns = S0;
            end
        end

        S0: begin
            if (input_done) begin
                out_adder_ns = out_adder_cs + input_ff;
                if (input_ff % 3 == 0)      state_ns = S00;
                else if (input_ff % 3 == 1) state_ns = S01;
                else                        state_ns = IDLE;
            end
        end

        S00: begin
            if (input_done) begin
                out_adder_ns = out_adder_cs + input_ff;
                if (input_ff % 3 == 0)      state_ns = STOP;
                else if (input_ff % 3 == 1) state_ns = S01;
                else                        state_ns = IDLE;
            end
        end

        S01: begin
            if (input_done) begin
                out_adder_ns = out_adder_cs + input_ff;
                if (input_ff % 3 == 0)      state_ns = S0;
                else if (input_ff % 3 == 1) state_ns = IDLE;
                else                        state_ns = STOP;
            end
        end

        STOP: begin
            state_ns = OUTPUT;
        end

        OUTPUT: begin
            state_ns = IDLE;
            out_adder_ns = 16'b0; 
        end
        
        default: state_ns = IDLE;
    endcase
end

endmodule