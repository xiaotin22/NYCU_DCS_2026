`timescale 1ns/1ps

`include "PATTERN.sv"
`include "RAM.sv"
`ifdef RTL
	`include "CA.sv"
`elsif GATE
	`include "CA_SYN.v"
`endif

module TESTBED;

    initial begin
        `ifdef RTL
            $fsdbDumpfile("CA.fsdb");
            $fsdbDumpvars(0,"+mda");
        `elsif GATE
            $fsdbDumpfile("CA_SYN.fsdb");
            $sdf_annotate("CA_SYN.sdf", u_dut);
            $fsdbDumpvars(0,"+mda");
        `endif
    end

    localparam RAM_WIDTH        = `RAM_WIDTH;
    localparam RAM_DEPTH        = `RAM_DEPTH;
    localparam READ_LATENCY     = `READ_LATENCY;
    localparam WRITE_LATENCY    = `WRITE_LATENCY;
    localparam BURST_BIT        = `BURST_BIT;

    // pattern
    logic                               clk;
    logic                               rst_n;
    logic                               mem_set;
    logic                               in_valid;
    logic [1:0]                         op;
    logic [1:0]                         act;
    logic [255:0]                       param;
    logic                               out_valid;
    logic [31:0]                        out_data;
    // ram
    logic                               rd_en;
    logic [$clog2(RAM_DEPTH)-1:0]       rd_addr;
    logic [BURST_BIT-1:0]               rd_burst;
    logic                               rd_valid;
    logic [RAM_WIDTH-1:0]               rd_data;
    logic                               rd_ready;
    logic                               wr_en;
    logic [$clog2(RAM_DEPTH)-1:0]       wr_addr;
    logic [BURST_BIT-1:0]               wr_burst;
    logic [RAM_WIDTH-1:0]               wr_data;
    logic                               wr_valid;
    logic                               wr_ready;

    
    CA #(
        .RAM_DEPTH (RAM_DEPTH),
        .RAM_WIDTH (RAM_WIDTH),
        .BURST_BIT (BURST_BIT)
    ) u_dut (
        // pattern
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_set        (mem_set),
        .in_valid       (in_valid),
        .op             (op),
        .act            (act),
        .param          (param),
        .out_valid      (out_valid),
        .out_data       (out_data),
        // RAM
        .rd_en          (rd_en),
        .rd_burst       (rd_burst),
        .rd_addr        (rd_addr),
        .rd_valid       (rd_valid),
        .rd_data        (rd_data),
        .rd_ready       (rd_ready),
        .wr_en          (wr_en),
        .wr_burst       (wr_burst),
        .wr_addr        (wr_addr),
        .wr_valid       (wr_valid),
        .wr_data        (wr_data),
        .wr_ready       (wr_ready)
    );

    PATTERN u_pat (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_set        (mem_set),
        .in_valid       (in_valid),
        .op             (op),
        .act            (act),
        .param          (param),
        .out_valid      (out_valid),
        .out_data       (out_data)
    );

    RAM #(
        .WIDTH          (RAM_WIDTH),
        .DEPTH          (RAM_DEPTH),
        .READ_LATENCY   (READ_LATENCY),
        .WRITE_LATENCY  (WRITE_LATENCY),
        .BURST_BIT      (BURST_BIT)
    ) u_data_ram (
        .clk            (clk),
        .rst_n          (rst_n),
        // READ
        .rd_en          (rd_en),
        .rd_addr        (rd_addr),
        .rd_burst       (rd_burst),
        .rd_valid       (rd_valid),
        .rd_data        (rd_data),
        .rd_ready       (rd_ready),
        // WRITE
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_burst       (wr_burst),
        .wr_data        (wr_data),
        .wr_valid       (wr_valid),
        .wr_ready       (wr_ready)
    );

endmodule