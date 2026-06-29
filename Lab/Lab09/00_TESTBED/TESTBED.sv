`timescale 1ns/1ps

`include "PATTERN.sv"
`ifdef RTL
	`include "AsyncFIFO.sv"
`elsif GATE
	`include "AsyncFIFO_SYN.v"
`endif

module TESTBED;

    initial begin
        `ifdef RTL
            $fsdbDumpfile("AsyncFIFO.fsdb");
            $fsdbDumpvars(0,"+mda");
        `elsif GATE
            $fsdbDumpfile("AsyncFIFO_SYN.fsdb");
            $sdf_annotate("AsyncFIFO_SYN.sdf", u_dut);
            $fsdbDumpvars(0,"+mda");
        `endif
    end

    // FIFO parameters
    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 4;

    // connection logic
    logic                  tx_clk;
    logic                  tx_rst_n;
    logic                  tx_valid;
    logic [DATA_WIDTH-1:0] tx_data;
    logic                  tx_full;

    logic                  rx_clk;
    logic                  rx_rst_n;
    logic                  rx_valid;
    logic [DATA_WIDTH-1:0] rx_data;
    logic                  rx_ready;

    // --------------------------------------------------
    // clock generation
    // --------------------------------------------------
    logic clk_tx_gen, clk_rx_gen;
    logic clk_en;

    initial clk_tx_gen = 0;
    initial clk_rx_gen = 1;

    always #1.25 clk_tx_gen = ~clk_tx_gen;   // 2.5ns period
    always #7.05 clk_rx_gen = ~clk_rx_gen;   // 14.1ns period

    assign tx_clk = (clk_en)? clk_tx_gen : 1'b0;
    assign rx_clk = (clk_en)? clk_rx_gen : 1'b0;

    // ----------------------------------------------------
    // Instances
    // ----------------------------------------------------
    AsyncFIFO #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dut (
        .tx_clk   (tx_clk),
        .tx_rst_n (tx_rst_n),
        .tx_valid (tx_valid),
        .tx_data  (tx_data),
        .tx_full  (tx_full),

        .rx_clk   (rx_clk),
        .rx_rst_n (rx_rst_n),
        .rx_valid (rx_valid),
        .rx_data  (rx_data),
        .rx_ready (rx_ready)
    );

    PATTERN #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_pat (
        .tx_clk   (tx_clk),
        .tx_rst_n (tx_rst_n),
        .tx_valid (tx_valid),
        .tx_data  (tx_data),
        .tx_full  (tx_full),

        .rx_clk   (rx_clk),
        .rx_rst_n (rx_rst_n),
        .rx_valid (rx_valid),
        .rx_data  (rx_data),
        .rx_ready (rx_ready),

        .clk_en   (clk_en)
    );

endmodule