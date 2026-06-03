module GE(
    clk,
    rst_n,
    in_valid,
    in_data_eq0,
    in_data_eq1,
    in_data_eq2,
    out_valid,
    out_data0,
    out_data1,
    out_data2,
    exception
);

input clk;
input rst_n;
input in_valid;
input [15:0] in_data_eq0;
input [15:0] in_data_eq1;
input [15:0] in_data_eq2;
output logic out_valid;
output logic signed [5:0] out_data0;
output logic signed [5:0] out_data1;
output logic signed [5:0] out_data2;
output logic [1:0] exception;

localparam E_UNIQUE  = 2'b00;
localparam E_INF_SOL = 2'b01;
localparam E_NO_SOL  = 2'b10;

typedef enum logic {S_IDLE, S_OUT} state_t;
state_t state_cs;

logic signed [31:0] a00, a01, a02, b0;
logic signed [31:0] a10, a11, a12, b1;
logic signed [31:0] a20, a21, a22, b2;

// 2x2 minors of A
logic signed [31:0] m11_22, m12_21;
logic signed [31:0] m10_22, m12_20;
logic signed [31:0] m10_21, m11_20;
// 2x2 minors involving b (for det_x*)
logic signed [31:0] m_b1a22, m_a12_b2;
logic signed [31:0] m_b1a21, m_a11_b2;
logic signed [31:0] m_a10_b2, m_b1a20;

logic signed [31:0] det_a, det_x0, det_x1, det_x2;
logic signed [31:0] rx0, rx1, rx2;
logic [1:0] exc;

// All combinational, no nested function calls
assign m11_22 = a11 * a22;
assign m12_21 = a12 * a21;
assign m10_22 = a10 * a22;
assign m12_20 = a12 * a20;
assign m10_21 = a10 * a21;
assign m11_20 = a11 * a20;

assign m_b1a22 = b1  * a22;
assign m_a12_b2 = a12 * b2;
assign m_b1a21 = b1  * a21;
assign m_a11_b2 = a11 * b2;
assign m_a10_b2 = a10 * b2;
assign m_b1a20 = b1  * a20;

// det_a expanded along row 0
//   = a00*(a11*a22 - a12*a21) - a01*(a10*a22 - a12*a20) + a02*(a10*a21 - a11*a20)
assign det_a  =  a00 * (m11_22 - m12_21)
              - a01 * (m10_22 - m12_20)
              + a02 * (m10_21 - m11_20);

// det_x0 (b replaces col 0)
//   = b0*(a11*a22 - a12*a21) - a01*(b1*a22 - a12*b2) + a02*(b1*a21 - a11*b2)
assign det_x0 =  b0  * (m11_22  - m12_21 )
              - a01 * (m_b1a22 - m_a12_b2)
              + a02 * (m_b1a21 - m_a11_b2);

// det_x1 (b replaces col 1)
//   = a00*(b1*a22 - a12*b2) - b0*(a10*a22 - a12*a20) + a02*(a10*b2 - b1*a20)
assign det_x1 =  a00 * (m_b1a22 - m_a12_b2)
              - b0  * (m10_22  - m12_20 )
              + a02 * (m_a10_b2 - m_b1a20);

// det_x2 (b replaces col 2)
//   = a00*(a11*b2 - b1*a21) - a01*(a10*b2 - b1*a20) + b0*(a10*a21 - a11*a20)
assign det_x2 =  a00 * (m_a11_b2 - m_b1a21)
              - a01 * (m_a10_b2 - m_b1a20)
              + b0  * (m10_21   - m11_20 );

// Exception classification (rank-based)
logic any_a_nz;
logic any_2x2_nz;
logic any_2x2_aug_nz;
logic any_b_nz;

assign any_a_nz = (a00 != 0) | (a01 != 0) | (a02 != 0)
                | (a10 != 0) | (a11 != 0) | (a12 != 0)
                | (a20 != 0) | (a21 != 0) | (a22 != 0);

assign any_b_nz = (b0 != 0) | (b1 != 0) | (b2 != 0);

assign any_2x2_nz = ((a00*a11 - a01*a10) != 0) | ((a00*a12 - a02*a10) != 0) | ((a01*a12 - a02*a11) != 0)
                  | ((a00*a21 - a01*a20) != 0) | ((a00*a22 - a02*a20) != 0) | ((a01*a22 - a02*a21) != 0)
                  | ((a10*a21 - a11*a20) != 0) | ((a10*a22 - a12*a20) != 0) | ((a11*a22 - a12*a21) != 0);

assign any_2x2_aug_nz =
       any_2x2_nz
     | ((a00*b1 - b0*a10) != 0) | ((a01*b1 - b0*a11) != 0) | ((a02*b1 - b0*a12) != 0)
     | ((a00*b2 - b0*a20) != 0) | ((a01*b2 - b0*a21) != 0) | ((a02*b2 - b0*a22) != 0)
     | ((a10*b2 - b1*a20) != 0) | ((a11*b2 - b1*a21) != 0) | ((a12*b2 - b1*a22) != 0);

// rank computation
logic [1:0] rank_a, rank_aug;
always_comb begin
    if (det_a != 0)        rank_a = 2'd3;
    else if (any_2x2_nz)   rank_a = 2'd2;
    else if (any_a_nz)     rank_a = 2'd1;
    else                   rank_a = 2'd0;

    if ((det_a != 0) || (det_x0 != 0) || (det_x1 != 0) || (det_x2 != 0))
        rank_aug = 2'd3;
    else if (any_2x2_aug_nz)
        rank_aug = 2'd2;
    else if (any_a_nz || any_b_nz)
        rank_aug = 2'd1;
    else
        rank_aug = 2'd0;
end

always_comb begin
    if (det_a != 0) begin
        exc = E_UNIQUE;
        rx0 = det_x0 / det_a;
        rx1 = det_x1 / det_a;
        rx2 = det_x2 / det_a;
    end else begin
        exc = (rank_a == rank_aug) ? E_INF_SOL : E_NO_SOL;
        rx0 = 0;
        rx1 = 0;
        rx2 = 0;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_cs  <= S_IDLE;
        a00 <= 0; a01 <= 0; a02 <= 0; b0 <= 0;
        a10 <= 0; a11 <= 0; a12 <= 0; b1 <= 0;
        a20 <= 0; a21 <= 0; a22 <= 0; b2 <= 0;
        out_valid <= 0;
        out_data0 <= 0;
        out_data1 <= 0;
        out_data2 <= 0;
        exception <= 0;
    end else begin
        out_valid <= 0;
        out_data0 <= 0;
        out_data1 <= 0;
        out_data2 <= 0;
        exception <= 0;

        case (state_cs)
            S_IDLE: begin
                if (in_valid) begin
                    a00 <= {{29{in_data_eq0[2]}},  in_data_eq0[2:0]};
                    a01 <= {{29{in_data_eq0[5]}},  in_data_eq0[5:3]};
                    a02 <= {{29{in_data_eq0[8]}},  in_data_eq0[8:6]};
                    b0  <= {{25{in_data_eq0[15]}}, in_data_eq0[15:9]};
                    a10 <= {{29{in_data_eq1[2]}},  in_data_eq1[2:0]};
                    a11 <= {{29{in_data_eq1[5]}},  in_data_eq1[5:3]};
                    a12 <= {{29{in_data_eq1[8]}},  in_data_eq1[8:6]};
                    b1  <= {{25{in_data_eq1[15]}}, in_data_eq1[15:9]};
                    a20 <= {{29{in_data_eq2[2]}},  in_data_eq2[2:0]};
                    a21 <= {{29{in_data_eq2[5]}},  in_data_eq2[5:3]};
                    a22 <= {{29{in_data_eq2[8]}},  in_data_eq2[8:6]};
                    b2  <= {{25{in_data_eq2[15]}}, in_data_eq2[15:9]};
                    state_cs <= S_OUT;
                end
            end
            S_OUT: begin
                out_valid <= 1;
                exception <= exc;
                if (exc == E_UNIQUE) begin
                    out_data0 <= rx0[5:0];
                    out_data1 <= rx1[5:0];
                    out_data2 <= rx2[5:0];
                end
                state_cs <= S_IDLE;
            end
            default: state_cs <= S_IDLE;
        endcase
    end
end

endmodule
