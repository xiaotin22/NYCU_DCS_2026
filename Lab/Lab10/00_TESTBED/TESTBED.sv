`timescale 1ns/1ps
`include "PATTERN.sv"
`ifdef RTL
    `include "axis_wrapper.sv"
`elsif GATE
    `include "axis_wrapper_SYN.v"
`endif

module TESTBED();

initial begin
	`ifdef RTL
		$fsdbDumpfile("axis_wrapper.fsdb");
		$fsdbDumpvars(0,"+mda");
	`elsif GATE
		$fsdbDumpfile("axis_wrapper_SYN.fsdb");
		$sdf_annotate("axis_wrapper_SYN.sdf",I_axis_wrapper);      
		$fsdbDumpvars(0,"+mda");
	`endif
end

parameter DATA_WIDTH = 32;

logic                   axis_aclk;
logic                   axis_aresetn;
logic  [DATA_WIDTH-1:0] s_axis_tdata;
logic  [(DATA_WIDTH/8)-1:0] s_axis_tkeep; 
logic                   s_axis_tlast;    
logic                   s_axis_tvalid;   
logic                   s_axis_tready;   
logic  [DATA_WIDTH-1:0] m_axis_tdata;
logic  [(DATA_WIDTH/8)-1:0] m_axis_tkeep; 
logic                   m_axis_tlast;    
logic                   m_axis_tvalid;   
logic                   m_axis_tready;   

logic                   clk;
logic                   rst_n;
logic                   in_valid;
logic  [7:0]            in_data;
logic                   out_valid;
logic                   out_data;

axis_wrapper #(.DATA_WIDTH(DATA_WIDTH)) I_axis_wrapper(
    // AXI Stream interface
    .axis_aclk(axis_aclk),
    .axis_aresetn(axis_aresetn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    // IP interface
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_data(in_data),
    .out_valid(out_valid),
    .out_data(out_data)
);

PATTERN #(.DATA_WIDTH(DATA_WIDTH)) I_PATTERN(
    // AXI Stream interface
    .axis_aclk(axis_aclk),
    .axis_aresetn(axis_aresetn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    // IP interface
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_data(in_data),
    .out_valid(out_valid),
    .out_data(out_data)
);

endmodule
