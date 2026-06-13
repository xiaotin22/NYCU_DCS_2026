module axis_wrapper #(
    parameter integer DATA_WIDTH = 32
)(
    // AXI Stream interface
    input  logic                   axis_aclk,
    input  logic                   axis_aresetn,

    input  logic [DATA_WIDTH-1:0]  s_axis_tdata,
    input  logic [(DATA_WIDTH/8)-1:0] s_axis_tkeep, 
    input  logic                   s_axis_tlast,    
    input  logic                   s_axis_tvalid,   
    output logic                   s_axis_tready,   

    output logic  [DATA_WIDTH-1:0] m_axis_tdata,
    output logic  [(DATA_WIDTH/8)-1:0] m_axis_tkeep, 
    output logic                   m_axis_tlast,    
    output logic                   m_axis_tvalid,   
    input  logic                   m_axis_tready,   

    // IP interface 
    output logic                   clk,
    output logic                   rst_n,
    output logic                   in_valid,
    output logic [8:0]             in_data,
    input  logic                   out_valid,
    input  logic                   out_data
);

enum logic [2:0] {
    IDLE,
    AXI_IN,
    WAIT0,
    SOBEL_IN,
    SOBEL_OUT,
    WAIT1,
    AXI_OUT
} state, state_nxt;

logic [5:0] in_cnt, in_cnt_nxt ;
logic [5:0] out_cnt, out_cnt_nxt;
logic [7:0] in_data_reg [63:0], in_data_reg_nxt [63:0];
logic out_data_reg [35:0], out_data_reg_nxt [35:0];

always_ff @(posedge axis_aclk or negedge axis_aresetn) begin
    if (!axis_aresetn) begin
        state <= IDLE;
    end else begin
        state <= state_nxt;
    end
end

always_comb begin
    state_nxt = state;
    case (state)
        IDLE: begin
            if (s_axis_tvalid) begin
                state_nxt = AXI_IN;
            end
        end
        AXI_IN: begin
            if (in_cnt == 63 && s_axis_tvalid) begin
                state_nxt = WAIT0;
            end
        end
        WAIT0: begin
            state_nxt = SOBEL_IN;
        end
        SOBEL_IN: begin
            if (in_cnt == 63) begin
                state_nxt = SOBEL_OUT;
            end
        end
        SOBEL_OUT: begin
            if (out_cnt == 35) begin
                state_nxt = WAIT1;
            end
        end
        WAIT1: begin
            state_nxt = AXI_OUT;
        end
        AXI_OUT: begin
            if (out_cnt == 35 && m_axis_tready) begin
                state_nxt = IDLE;
            end
        end
    endcase
end

//================================
// Signal assignments
//================================

assign clk = axis_aclk;
assign rst_n = axis_aresetn;
assign s_axis_tready = (state == IDLE) || (state == AXI_IN);
assign in_valid = (state == SOBEL_IN);

assign in_data  = in_data_reg[in_cnt];

always_ff @(posedge axis_aclk or negedge axis_aresetn) begin
    if (!axis_aresetn) begin
        in_cnt <= '0;
        in_data_reg <= '{default: '0};
    end else begin
        in_cnt <= in_cnt_nxt;
        in_data_reg <= in_data_reg_nxt;
    end
end

always_comb begin
    // 1. 先給預設值 (保持原值)
    in_cnt_nxt = in_cnt;
    in_data_reg_nxt = in_data_reg;

    if (state == WAIT0 || state == WAIT1) begin
        in_cnt_nxt = 0;
    end
    else if (s_axis_tvalid && s_axis_tready) begin
        in_data_reg_nxt[in_cnt] = s_axis_tdata[7:0];

        if (in_cnt != 63)
            in_cnt_nxt = in_cnt + 1;
    end
    else if (state == SOBEL_IN) begin
        if (in_cnt != 63)
            in_cnt_nxt = in_cnt + 1;
    end
end

always_ff @(posedge axis_aclk or negedge axis_aresetn) begin
    if (!axis_aresetn) begin
        out_cnt <= '0;
        out_data_reg <= '{default: '0};
    end else begin
        out_cnt <= out_cnt_nxt;
        out_data_reg <= out_data_reg_nxt;
    end
end

always_comb begin
    out_cnt_nxt = out_cnt;
    out_data_reg_nxt = out_data_reg;

    if (state == SOBEL_OUT && out_valid) begin
        out_data_reg_nxt[out_cnt] = out_data;

        if (out_cnt != 35)
            out_cnt_nxt = out_cnt + 1;
    end
    else if (state == WAIT1 || state == WAIT0) begin
        out_cnt_nxt = 0;
    end
    else if (m_axis_tvalid && m_axis_tready) begin
        if (out_cnt != 35)
            out_cnt_nxt = out_cnt + 1;
    end
end

assign m_axis_tvalid = (state == AXI_OUT);
assign m_axis_tdata = {31'd0, out_data_reg[out_cnt]};
assign m_axis_tlast = (state == AXI_OUT && out_cnt == 35);
assign m_axis_tkeep = 4'b1111;

endmodule

