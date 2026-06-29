`timescale 1ns/1ps

`include "PATTERN.sv"
`ifdef RTL
  `include "ECTRL.sv"
`elsif GATE
  `include "ECTRL_SYN.v"
`endif

module TESTBED();

typedef enum logic [2:0] {
  IDLE = 3'b000, MOVING  = 3'b001, OPENING = 3'b010,
  OPEN = 3'b011, CLOSING = 3'b100
} status_t;

typedef enum logic [1:0] {
  NONE = 2'b00, UP = 2'b01, DOWN = 2'b10, INVALID = 2'b11
} dir_t;

logic [7:0]  car_req_0, car_req_1, car_req_2;
logic [3:0]  pax_cnt_0, pax_cnt_1, pax_cnt_2;
logic [2:0]  cur_floor_0, cur_floor_1, cur_floor_2;
status_t     lift_status_0, lift_status_1, lift_status_2;
dir_t        serve_dir_0, serve_dir_1, serve_dir_2;

logic clk;
logic rst_n;

logic [7:0]  up_req, down_req;
logic [23:0] car_req;
logic [2:0]  btn_open, btn_close;
logic [11:0] pax_cnt;

logic [8:0]  cur_floor;
logic [8:0]  lift_status;
logic [5:0]  serve_dir;
logic [2:0]  is_full;

initial begin
  `ifdef RTL
    $fsdbDumpfile("ECTRL.fsdb");
    $fsdbDumpvars("+mda");
  `elsif GATE
    $fsdbDumpfile("ECTRL_SYN.fsdb");
    $sdf_annotate("ECTRL_SYN.sdf", I_ECTRL);
    $fsdbDumpvars("+mda");
  `endif
end

PATTERN I_PATTERN(
  .clk(clk),
  .rst_n(rst_n),
  .up_req(up_req),
  .down_req(down_req),
  .car_req(car_req),
  .btn_open(btn_open),
  .btn_close(btn_close),
  .pax_cnt(pax_cnt),
  .cur_floor(cur_floor),
  .lift_status(lift_status),
  .serve_dir(serve_dir),
  .is_full(is_full)
);

ECTRL I_ECTRL(
  .clk(clk),
  .rst_n(rst_n),
  .up_req(up_req),
  .down_req(down_req),
  .car_req(car_req),
  .btn_open(btn_open),
  .btn_close(btn_close),
  .pax_cnt(pax_cnt),
  .cur_floor(cur_floor),
  .lift_status(lift_status),
  .serve_dir(serve_dir),
  .is_full(is_full)
);

assign {car_req_2, car_req_1, car_req_0} = car_req;
assign {pax_cnt_2, pax_cnt_1, pax_cnt_0} = pax_cnt;
assign {cur_floor_2, cur_floor_1, cur_floor_0} = cur_floor;
assign lift_status_2 = status_t'(lift_status[8:6]);
assign lift_status_1 = status_t'(lift_status[5:3]);
assign lift_status_0 = status_t'(lift_status[2:0]);
assign serve_dir_2 = dir_t'(serve_dir[5:4]);
assign serve_dir_1 = dir_t'(serve_dir[3:2]);
assign serve_dir_0 = dir_t'(serve_dir[1:0]);

endmodule
