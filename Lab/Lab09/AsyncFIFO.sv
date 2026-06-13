module AsyncFIFO #(
	parameter DATA_WIDTH = 8,
	parameter ADDR_WIDTH = 4
)(
	// TX Domain
    input  logic                        tx_clk,
    input  logic                        tx_rst_n,
    input  logic                        tx_valid,
    input  logic    [DATA_WIDTH-1:0]    tx_data,
    output logic                        tx_full,

    // RX Domain
    input  logic                        rx_clk,
    input  logic                        rx_rst_n,
    output logic                        rx_valid,
    output logic    [DATA_WIDTH-1:0]    rx_data,
    input  logic                        rx_ready
);
    localparam PTR_WIDTH = ADDR_WIDTH + 1;
    localparam MEM_DEPTH = 1 << ADDR_WIDTH;

    // --------------------------------------------------
    // Internal Signals
    // --------------------------------------------------
    logic   [DATA_WIDTH-1:0] 	mem 		[0:MEM_DEPTH-1];
    
    // Write Pointers
    logic   [PTR_WIDTH-1:0]     w_ptr_bin, w_ptr_gray;
    logic   [PTR_WIDTH-1:0]     w_ptr_bin_next, w_ptr_gray_next;
    
    // Read Pointers
    logic   [PTR_WIDTH-1:0]     r_ptr_bin, r_ptr_gray;
    logic   [PTR_WIDTH-1:0]     r_ptr_bin_next, r_ptr_gray_next;

    // Synchronizers (Double Flop)
    logic   [PTR_WIDTH-1:0]     w_ptr_gray_sync1, w_ptr_gray_sync2;
    logic   [PTR_WIDTH-1:0]     r_ptr_gray_sync1, r_ptr_gray_sync2;

    logic                       w_en;
    logic                       r_en;
    logic                       rx_empty;


    // ============================================================
    // Write Operation (TX Domain)
    // ============================================================
    // Write enable when User write && FIFO not full
    assign w_en = tx_valid & ~tx_full;

    // Binary Pointer Update
    assign w_ptr_bin_next = w_ptr_bin + w_en;

    // Gray Pointer Update
    assign w_ptr_gray_next = w_ptr_bin_next ^ (w_ptr_bin_next >> 1);

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            w_ptr_bin <= 0;
            w_ptr_gray <= 0;
        end else begin
            w_ptr_bin <= w_ptr_bin_next;
            w_ptr_gray <= w_ptr_gray_next;
        end
    end

    // Write tx_data into FIFO is w_en
    always @(posedge tx_clk) begin
        if (w_en) begin
            mem[w_ptr_bin[ADDR_WIDTH-1:0]] <= tx_data;
        end
    end


    // ============================================================
    // Read Operation
    // ============================================================
    // Read enable when User is ready && FIFO not empty
    assign r_en = rx_ready & ~rx_empty;

    // Binary Pointer Update
    assign r_ptr_bin_next = r_ptr_bin + r_en;

    // Gray Pointer Update
    assign r_ptr_gray_next = r_ptr_bin_next ^ (r_ptr_bin_next >> 1);

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            r_ptr_bin <= 0;
            r_ptr_gray <= 0;
        end else begin
            r_ptr_bin <= r_ptr_bin_next;
            r_ptr_gray <= r_ptr_gray_next;
        end
    end

    // Read data
    assign rx_data  = mem[r_ptr_bin[ADDR_WIDTH-1:0]];
    assign rx_valid = ~rx_empty;


    // ============================================================
    // Sync
    // ============================================================
    // Sync RX to TX Domain
    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            r_ptr_gray_sync1 <= 0;
            r_ptr_gray_sync2 <= 0;
        end else begin
            r_ptr_gray_sync1 <= r_ptr_gray;
            r_ptr_gray_sync2 <= r_ptr_gray_sync1;
        end
    end

    // Sync TX to RX Domain
    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            w_ptr_gray_sync1 <= 0;
            w_ptr_gray_sync2 <= 0;
        end else begin
            w_ptr_gray_sync1 <= w_ptr_gray;
            w_ptr_gray_sync2 <= w_ptr_gray_sync1;
        end
    end

    // ============================================================
    // Full / Empty
    // ============================================================
    assign tx_full = (w_ptr_gray == {~r_ptr_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2], r_ptr_gray_sync2[PTR_WIDTH-3:0]});

    assign rx_empty = (r_ptr_gray == w_ptr_gray_sync2);
    
endmodule