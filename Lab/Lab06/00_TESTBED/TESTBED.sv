`timescale 1ns/1ps

`include "PATTERN.sv"
`ifdef RTL
  `include "LOCK.sv"
`elsif GATE
  `include "LOCK_SYN.v"
`endif

module TESTBED();

typedef enum logic [2:0] {
  LOCKED = 3'b000, IN_D1    = 3'b001,
  IN_D2  = 3'b010, IN_D3    = 3'b011,
  IN_D4  = 3'b100, UNLOCKED = 3'b101,
  CHANGE = 3'b110, ALARM    = 3'b111
} state_t;
state_t state;

logic clk;
logic rst_n;

logic in_valid;
logic [3:0] in_digit;
logic enter;
logic change;
logic lock_reset;

logic [2:0] state_raw;
logic unlocked;
logic alarm;

initial begin
  `ifdef RTL
    $fsdbDumpfile("LOCK.fsdb");
    $fsdbDumpvars("+mda");
  `elsif GATE
    $fsdbDumpfile("LOCK_SYN.fsdb");
    $sdf_annotate("LOCK_SYN.sdf", I_LOCK);
    $fsdbDumpvars("+mda");
  `endif
end

PATTERN I_PATTERN(
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .in_digit(in_digit),
  .enter(enter),
  .change(change),
  .lock_reset(lock_reset),
  .state(state_raw),
  .unlocked(unlocked),
  .alarm(alarm)
);

LOCK I_LOCK(
  .clk(clk),
  .rst_n(rst_n),
  .in_valid(in_valid),
  .in_digit(in_digit),
  .enter(enter),
  .change(change),
  .lock_reset(lock_reset),
  .state(state_raw),
  .unlocked(unlocked),
  .alarm(alarm)
);

assign state = state_t'(state_raw);

endmodule
