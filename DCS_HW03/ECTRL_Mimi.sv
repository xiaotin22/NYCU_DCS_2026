module ECTRL(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  up_req,
    input  logic [7:0]  down_req,
    input  logic [23:0] car_req,
    input  logic [2:0]  btn_open,
    input  logic [2:0]  btn_close,
    input  logic [11:0] pax_cnt,

    output logic [8:0]  cur_floor,
    output logic [8:0]  lift_status,
    output logic [5:0]  serve_dir,
    output logic [2:0]  is_full
);



// ============================================================
// State / direction declaration
// ============================================================

localparam logic [2:0] IDLE = 3'b000, MOVING  = 3'b001, OPENING = 3'b010,
                       OPEN = 3'b011, CLOSING = 3'b100;

localparam logic [1:0] NONE = 2'b00, UP = 2'b01, DOWN = 2'b10;

// ============================================================
// Input unpack
// ============================================================
logic [7:0] car_req_e [0:2];
logic [3:0] pax_cnt_e [0:2];

assign car_req_e[0] = car_req[7:0];
assign car_req_e[1] = car_req[15:8];
assign car_req_e[2] = car_req[23:16];

assign pax_cnt_e[0] = pax_cnt[3:0];
assign pax_cnt_e[1] = pax_cnt[7:4];
assign pax_cnt_e[2] = pax_cnt[11:8];

// ============================================================
// Current / next state
// ============================================================
logic [2:0] floor_cs [0:2], floor_ns [0:2];
logic [2:0] state_cs [0:2], state_ns [0:2];
logic [1:0]  dir_cs   [0:2], dir_ns   [0:2];
logic [4:0]  timer_cs [0:2], timer_ns [0:2];

// ============================================================
// Output pack
// ============================================================
assign cur_floor   = {floor_cs[2], floor_cs[1], floor_cs[0]};
assign lift_status = {state_cs[2], state_cs[1], state_cs[0]};
assign serve_dir   = {
    (state_cs[2] == IDLE) ? NONE : dir_cs[2],
    (state_cs[1] == IDLE) ? NONE : dir_cs[1],
    (state_cs[0] == IDLE) ? NONE : dir_cs[0]
};

// ============================================================
// is_full
// ============================================================
logic is_full_e [0:2];

assign is_full_e[0] = (pax_cnt_e[0] == 4'd15);
assign is_full_e[1] = (pax_cnt_e[1] == 4'd15);
assign is_full_e[2] = (pax_cnt_e[2] == 4'd15);

assign is_full = {is_full_e[2], is_full_e[1], is_full_e[0]};

// ============================================================
// Request helper signals
// ============================================================
logic stop_here_e [0:2];
logic has_up_e    [0:2];
logic has_down_e  [0:2];
logic stop_next_e [0:2];

logic [2:0] next_floor_e [0:2];

// ---------------- E0 ----------------
assign stop_here_e[0] =
    car_req_e[0][floor_cs[0]] ||
    (!is_full_e[0] && (up_req[floor_cs[0]] || down_req[floor_cs[0]]));

assign has_up_e[0] =
    ((floor_cs[0] == 3'd0) && (|car_req_e[0][7:1])) ||
    ((floor_cs[0] == 3'd1) && (|car_req_e[0][7:2])) ||
    ((floor_cs[0] == 3'd2) && (|car_req_e[0][7:3])) ||
    ((floor_cs[0] == 3'd3) && (|car_req_e[0][7:4])) ||
    ((floor_cs[0] == 3'd4) && (|car_req_e[0][7:5])) ||
    ((floor_cs[0] == 3'd5) && (|car_req_e[0][7:6])) ||
    ((floor_cs[0] == 3'd6) && ( car_req_e[0][7]))   ||
    (!is_full_e[0] && (
        ((floor_cs[0] == 3'd0) && (|up_req[7:1]   || |down_req[7:1])) ||
        ((floor_cs[0] == 3'd1) && (|up_req[7:2]   || |down_req[7:2])) ||
        ((floor_cs[0] == 3'd2) && (|up_req[7:3]   || |down_req[7:3])) ||
        ((floor_cs[0] == 3'd3) && (|up_req[7:4]   || |down_req[7:4])) ||
        ((floor_cs[0] == 3'd4) && (|up_req[7:5]   || |down_req[7:5])) ||
        ((floor_cs[0] == 3'd5) && (|up_req[7:6]   || |down_req[7:6])) ||
        ((floor_cs[0] == 3'd6) && ( up_req[7]     ||  down_req[7]))
    ));

assign has_down_e[0] =
    ((floor_cs[0] == 3'd7) && (|car_req_e[0][6:0])) ||
    ((floor_cs[0] == 3'd6) && (|car_req_e[0][5:0])) ||
    ((floor_cs[0] == 3'd5) && (|car_req_e[0][4:0])) ||
    ((floor_cs[0] == 3'd4) && (|car_req_e[0][3:0])) ||
    ((floor_cs[0] == 3'd3) && (|car_req_e[0][2:0])) ||
    ((floor_cs[0] == 3'd2) && (|car_req_e[0][1:0])) ||
    ((floor_cs[0] == 3'd1) && ( car_req_e[0][0]))   ||
    (!is_full_e[0] && (
        ((floor_cs[0] == 3'd7) && (|up_req[6:0]   || |down_req[6:0])) ||
        ((floor_cs[0] == 3'd6) && (|up_req[5:0]   || |down_req[5:0])) ||
        ((floor_cs[0] == 3'd5) && (|up_req[4:0]   || |down_req[4:0])) ||
        ((floor_cs[0] == 3'd4) && (|up_req[3:0]   || |down_req[3:0])) ||
        ((floor_cs[0] == 3'd3) && (|up_req[2:0]   || |down_req[2:0])) ||
        ((floor_cs[0] == 3'd2) && (|up_req[1:0]   || |down_req[1:0])) ||
        ((floor_cs[0] == 3'd1) && ( up_req[0]     ||  down_req[0]))
    ));

assign next_floor_e[0] =
    (dir_cs[0] == UP)   ? ((floor_cs[0] == 3'd7) ? floor_cs[0] : floor_cs[0] + 3'd1) :
    (dir_cs[0] == DOWN) ? ((floor_cs[0] == 3'd0) ? floor_cs[0] : floor_cs[0] - 3'd1) :
                          floor_cs[0];

assign stop_next_e[0] =
    car_req_e[0][next_floor_e[0]] ||
    (!is_full_e[0] && (up_req[next_floor_e[0]] || down_req[next_floor_e[0]]));

// ---------------- E1 ----------------
assign stop_here_e[1] =
    car_req_e[1][floor_cs[1]] ||
    (!is_full_e[1] && (up_req[floor_cs[1]] || down_req[floor_cs[1]]));

assign has_up_e[1] =
    ((floor_cs[1] == 3'd0) && (|car_req_e[1][7:1])) ||
    ((floor_cs[1] == 3'd1) && (|car_req_e[1][7:2])) ||
    ((floor_cs[1] == 3'd2) && (|car_req_e[1][7:3])) ||
    ((floor_cs[1] == 3'd3) && (|car_req_e[1][7:4])) ||
    ((floor_cs[1] == 3'd4) && (|car_req_e[1][7:5])) ||
    ((floor_cs[1] == 3'd5) && (|car_req_e[1][7:6])) ||
    ((floor_cs[1] == 3'd6) && ( car_req_e[1][7]))   ||
    (!is_full_e[1] && (
        ((floor_cs[1] == 3'd0) && (|up_req[7:1]   || |down_req[7:1])) ||
        ((floor_cs[1] == 3'd1) && (|up_req[7:2]   || |down_req[7:2])) ||
        ((floor_cs[1] == 3'd2) && (|up_req[7:3]   || |down_req[7:3])) ||
        ((floor_cs[1] == 3'd3) && (|up_req[7:4]   || |down_req[7:4])) ||
        ((floor_cs[1] == 3'd4) && (|up_req[7:5]   || |down_req[7:5])) ||
        ((floor_cs[1] == 3'd5) && (|up_req[7:6]   || |down_req[7:6])) ||
        ((floor_cs[1] == 3'd6) && ( up_req[7]     ||  down_req[7]))
    ));

assign has_down_e[1] =
    ((floor_cs[1] == 3'd7) && (|car_req_e[1][6:0])) ||
    ((floor_cs[1] == 3'd6) && (|car_req_e[1][5:0])) ||
    ((floor_cs[1] == 3'd5) && (|car_req_e[1][4:0])) ||
    ((floor_cs[1] == 3'd4) && (|car_req_e[1][3:0])) ||
    ((floor_cs[1] == 3'd3) && (|car_req_e[1][2:0])) ||
    ((floor_cs[1] == 3'd2) && (|car_req_e[1][1:0])) ||
    ((floor_cs[1] == 3'd1) && ( car_req_e[1][0]))   ||
    (!is_full_e[1] && (
        ((floor_cs[1] == 3'd7) && (|up_req[6:0]   || |down_req[6:0])) ||
        ((floor_cs[1] == 3'd6) && (|up_req[5:0]   || |down_req[5:0])) ||
        ((floor_cs[1] == 3'd5) && (|up_req[4:0]   || |down_req[4:0])) ||
        ((floor_cs[1] == 3'd4) && (|up_req[3:0]   || |down_req[3:0])) ||
        ((floor_cs[1] == 3'd3) && (|up_req[2:0]   || |down_req[2:0])) ||
        ((floor_cs[1] == 3'd2) && (|up_req[1:0]   || |down_req[1:0])) ||
        ((floor_cs[1] == 3'd1) && ( up_req[0]     ||  down_req[0]))
    ));

assign next_floor_e[1] =
    (dir_cs[1] == UP)   ? ((floor_cs[1] == 3'd7) ? floor_cs[1] : floor_cs[1] + 3'd1) :
    (dir_cs[1] == DOWN) ? ((floor_cs[1] == 3'd0) ? floor_cs[1] : floor_cs[1] - 3'd1) :
                          floor_cs[1];

assign stop_next_e[1] =
    car_req_e[1][next_floor_e[1]] ||
    (!is_full_e[1] && (up_req[next_floor_e[1]] || down_req[next_floor_e[1]]));

// ---------------- E2 ----------------
assign stop_here_e[2] =
    car_req_e[2][floor_cs[2]] ||
    (!is_full_e[2] && (up_req[floor_cs[2]] || down_req[floor_cs[2]]));

assign has_up_e[2] =
    ((floor_cs[2] == 3'd0) && (|car_req_e[2][7:1])) ||
    ((floor_cs[2] == 3'd1) && (|car_req_e[2][7:2])) ||
    ((floor_cs[2] == 3'd2) && (|car_req_e[2][7:3])) ||
    ((floor_cs[2] == 3'd3) && (|car_req_e[2][7:4])) ||
    ((floor_cs[2] == 3'd4) && (|car_req_e[2][7:5])) ||
    ((floor_cs[2] == 3'd5) && (|car_req_e[2][7:6])) ||
    ((floor_cs[2] == 3'd6) && ( car_req_e[2][7]))   ||
    (!is_full_e[2] && (
        ((floor_cs[2] == 3'd0) && (|up_req[7:1]   || |down_req[7:1])) ||
        ((floor_cs[2] == 3'd1) && (|up_req[7:2]   || |down_req[7:2])) ||
        ((floor_cs[2] == 3'd2) && (|up_req[7:3]   || |down_req[7:3])) ||
        ((floor_cs[2] == 3'd3) && (|up_req[7:4]   || |down_req[7:4])) ||
        ((floor_cs[2] == 3'd4) && (|up_req[7:5]   || |down_req[7:5])) ||
        ((floor_cs[2] == 3'd5) && (|up_req[7:6]   || |down_req[7:6])) ||
        ((floor_cs[2] == 3'd6) && ( up_req[7]     ||  down_req[7]))
    ));

assign has_down_e[2] =
    ((floor_cs[2] == 3'd7) && (|car_req_e[2][6:0])) ||
    ((floor_cs[2] == 3'd6) && (|car_req_e[2][5:0])) ||
    ((floor_cs[2] == 3'd5) && (|car_req_e[2][4:0])) ||
    ((floor_cs[2] == 3'd4) && (|car_req_e[2][3:0])) ||
    ((floor_cs[2] == 3'd3) && (|car_req_e[2][2:0])) ||
    ((floor_cs[2] == 3'd2) && (|car_req_e[2][1:0])) ||
    ((floor_cs[2] == 3'd1) && ( car_req_e[2][0]))   ||
    (!is_full_e[2] && (
        ((floor_cs[2] == 3'd7) && (|up_req[6:0]   || |down_req[6:0])) ||
        ((floor_cs[2] == 3'd6) && (|up_req[5:0]   || |down_req[5:0])) ||
        ((floor_cs[2] == 3'd5) && (|up_req[4:0]   || |down_req[4:0])) ||
        ((floor_cs[2] == 3'd4) && (|up_req[3:0]   || |down_req[3:0])) ||
        ((floor_cs[2] == 3'd3) && (|up_req[2:0]   || |down_req[2:0])) ||
        ((floor_cs[2] == 3'd2) && (|up_req[1:0]   || |down_req[1:0])) ||
        ((floor_cs[2] == 3'd1) && ( up_req[0]     ||  down_req[0]))
    ));

assign next_floor_e[2] =
    (dir_cs[2] == UP)   ? ((floor_cs[2] == 3'd7) ? floor_cs[2] : floor_cs[2] + 3'd1) :
    (dir_cs[2] == DOWN) ? ((floor_cs[2] == 3'd0) ? floor_cs[2] : floor_cs[2] - 3'd1) :
                          floor_cs[2];

assign stop_next_e[2] =
    car_req_e[2][next_floor_e[2]] ||
    (!is_full_e[2] && (up_req[next_floor_e[2]] || down_req[next_floor_e[2]]));

// ============================================================
// E0 FSM
// ============================================================
always_comb begin
    floor_ns[0] = floor_cs[0];
    state_ns[0] = state_cs[0];
    dir_ns[0]   = dir_cs[0];
    timer_ns[0] = timer_cs[0];

    case (state_cs[0])
        IDLE: begin
            timer_ns[0] = 5'd0;
            if (stop_here_e[0]) begin
                state_ns[0] = OPENING;
                if (car_req_e[0][floor_cs[0]]) begin
                    dir_ns[0] = dir_cs[0];
                end
                else if (up_req[floor_cs[0]]) begin
                    dir_ns[0] = UP;
                end
                else if (down_req[floor_cs[0]]) begin
                    dir_ns[0] = DOWN;
                end
                else begin
                    dir_ns[0] = NONE;
                end
            end
            else if (has_up_e[0]) begin
                dir_ns[0]   = UP;
                state_ns[0] = MOVING;
            end
            else if (has_down_e[0]) begin
                dir_ns[0]   = DOWN;
                state_ns[0] = MOVING;
            end
            else begin
                dir_ns[0]   = NONE;
                state_ns[0] = IDLE;
            end
        end

        MOVING: begin
            if (timer_cs[0] == 5'd9) begin
                floor_ns[0] = next_floor_e[0];
                timer_ns[0] = 5'd0;
                if (stop_next_e[0]) begin
                    state_ns[0] = OPENING;
                end
                else begin
                    state_ns[0] = MOVING;
                end
            end
            else begin
                timer_ns[0] = timer_cs[0] + 5'd1;
            end
        end

        OPENING: begin
            if (timer_cs[0] == 5'd4) begin
                timer_ns[0] = 5'd0;
                state_ns[0] = OPEN;
            end
            else begin
                timer_ns[0] = timer_cs[0] + 5'd1;
            end
        end

        OPEN: begin
            if (btn_open[0]) begin
                timer_ns[0] = 5'd0;
            end
            else if (btn_close[0] || (timer_cs[0] == 5'd19)) begin
                timer_ns[0] = 5'd0;
                state_ns[0] = CLOSING;
            end
            else begin
                timer_ns[0] = timer_cs[0] + 5'd1;
            end
        end

        CLOSING: begin
            if (btn_open[0]) begin
                timer_ns[0] = 5'd0;
                state_ns[0] = OPENING;
            end
            else if (timer_cs[0] == 5'd4) begin
                timer_ns[0] = 5'd0;
                if (stop_here_e[0]) begin
                    state_ns[0] = OPENING;
                end
                else if ((dir_cs[0] == UP) && has_up_e[0]) begin
                    state_ns[0] = MOVING;
                end
                else if ((dir_cs[0] == DOWN) && has_down_e[0]) begin
                    state_ns[0] = MOVING;
                end
                else if (has_up_e[0]) begin
                    dir_ns[0]   = UP;
                    state_ns[0] = MOVING;
                end
                else if (has_down_e[0]) begin
                    dir_ns[0]   = DOWN;
                    state_ns[0] = MOVING;
                end
                else begin
                    dir_ns[0]   = NONE;
                    state_ns[0] = IDLE;
                end
            end
            else begin
                timer_ns[0] = timer_cs[0] + 5'd1;
            end
        end

        default: begin
            floor_ns[0] = floor_cs[0];
            state_ns[0] = IDLE;
            dir_ns[0]   = NONE;
            timer_ns[0] = 5'd0;
        end
    endcase
end

// ============================================================
// E1 FSM
// ============================================================
always_comb begin
    floor_ns[1] = floor_cs[1];
    state_ns[1] = state_cs[1];
    dir_ns[1]   = dir_cs[1];
    timer_ns[1] = timer_cs[1];

    case (state_cs[1])
        IDLE: begin
            timer_ns[1] = 5'd0;
            if (stop_here_e[1]) begin
                state_ns[1] = OPENING;
                if (car_req_e[1][floor_cs[1]]) begin
                    dir_ns[1] = dir_cs[1];
                end
                else if (up_req[floor_cs[1]]) begin
                    dir_ns[1] = UP;
                end
                else if (down_req[floor_cs[1]]) begin
                    dir_ns[1] = DOWN;
                end
                else begin
                    dir_ns[1] = NONE;
                end
            end
            else if (has_up_e[1]) begin
                dir_ns[1]   = UP;
                state_ns[1] = MOVING;
            end
            else if (has_down_e[1]) begin
                dir_ns[1]   = DOWN;
                state_ns[1] = MOVING;
            end
            else begin
                dir_ns[1]   = NONE;
                state_ns[1] = IDLE;
            end
        end

        MOVING: begin
            if (timer_cs[1] == 5'd9) begin
                floor_ns[1] = next_floor_e[1];
                timer_ns[1] = 5'd0;
                if (stop_next_e[1]) begin
                    state_ns[1] = OPENING;
                end
                else begin
                    state_ns[1] = MOVING;
                end
            end
            else begin
                timer_ns[1] = timer_cs[1] + 5'd1;
            end
        end

        OPENING: begin
            if (timer_cs[1] == 5'd4) begin
                timer_ns[1] = 5'd0;
                state_ns[1] = OPEN;
            end
            else begin
                timer_ns[1] = timer_cs[1] + 5'd1;
            end
        end

        OPEN: begin
            if (btn_open[1]) begin
                timer_ns[1] = 5'd0;
            end
            else if (btn_close[1] || (timer_cs[1] == 5'd19)) begin
                timer_ns[1] = 5'd0;
                state_ns[1] = CLOSING;
            end
            else begin
                timer_ns[1] = timer_cs[1] + 5'd1;
            end
        end

        CLOSING: begin
            if (btn_open[1]) begin
                timer_ns[1] = 5'd0;
                state_ns[1] = OPENING;
            end
            else if (timer_cs[1] == 5'd4) begin
                timer_ns[1] = 5'd0;
                if (stop_here_e[1]) begin
                    state_ns[1] = OPENING;
                end
                else if ((dir_cs[1] == UP) && has_up_e[1]) begin
                    state_ns[1] = MOVING;
                end
                else if ((dir_cs[1] == DOWN) && has_down_e[1]) begin
                    state_ns[1] = MOVING;
                end
                else if (has_up_e[1]) begin
                    dir_ns[1]   = UP;
                    state_ns[1] = MOVING;
                end
                else if (has_down_e[1]) begin
                    dir_ns[1]   = DOWN;
                    state_ns[1] = MOVING;
                end
                else begin
                    dir_ns[1]   = NONE;
                    state_ns[1] = IDLE;
                end
            end
            else begin
                timer_ns[1] = timer_cs[1] + 5'd1;
            end
        end

        default: begin
            floor_ns[1] = floor_cs[1];
            state_ns[1] = IDLE;
            dir_ns[1]   = NONE;
            timer_ns[1] = 5'd0;
        end
    endcase
end

// ============================================================
// E2 FSM
// ============================================================
always_comb begin
    floor_ns[2] = floor_cs[2];
    state_ns[2] = state_cs[2];
    dir_ns[2]   = dir_cs[2];
    timer_ns[2] = timer_cs[2];

    case (state_cs[2])
        IDLE: begin
            timer_ns[2] = 5'd0;
            if (stop_here_e[2]) begin
                state_ns[2] = OPENING;
                if (car_req_e[2][floor_cs[2]]) begin
                    dir_ns[2] = dir_cs[2];
                end
                else if (up_req[floor_cs[2]]) begin
                    dir_ns[2] = UP;
                end
                else if (down_req[floor_cs[2]]) begin
                    dir_ns[2] = DOWN;
                end
                else begin
                    dir_ns[2] = NONE;
                end
            end
            else if (has_up_e[2]) begin
                dir_ns[2]   = UP;
                state_ns[2] = MOVING;
            end
            else if (has_down_e[2]) begin
                dir_ns[2]   = DOWN;
                state_ns[2] = MOVING;
            end
            else begin
                dir_ns[2]   = NONE;
                state_ns[2] = IDLE;
            end
        end

        MOVING: begin
            if (timer_cs[2] == 5'd9) begin
                floor_ns[2] = next_floor_e[2];
                timer_ns[2] = 5'd0;
                if (stop_next_e[2]) begin
                    state_ns[2] = OPENING;
                end
                else begin
                    state_ns[2] = MOVING;
                end
            end
            else begin
                timer_ns[2] = timer_cs[2] + 5'd1;
            end
        end

        OPENING: begin
            if (timer_cs[2] == 5'd4) begin
                timer_ns[2] = 5'd0;
                state_ns[2] = OPEN;
            end
            else begin
                timer_ns[2] = timer_cs[2] + 5'd1;
            end
        end

        OPEN: begin
            if (btn_open[2]) begin
                timer_ns[2] = 5'd0;
            end
            else if (btn_close[2] || (timer_cs[2] == 5'd19)) begin
                timer_ns[2] = 5'd0;
                state_ns[2] = CLOSING;
            end
            else begin
                timer_ns[2] = timer_cs[2] + 5'd1;
            end
        end

        CLOSING: begin
            if (btn_open[2]) begin
                timer_ns[2] = 5'd0;
                state_ns[2] = OPENING;
            end
            else if (timer_cs[2] == 5'd4) begin
                timer_ns[2] = 5'd0;
                if (stop_here_e[2]) begin
                    state_ns[2] = OPENING;
                end
                else if ((dir_cs[2] == UP) && has_up_e[2]) begin
                    state_ns[2] = MOVING;
                end
                else if ((dir_cs[2] == DOWN) && has_down_e[2]) begin
                    state_ns[2] = MOVING;
                end
                else if (has_up_e[2]) begin
                    dir_ns[2]   = UP;
                    state_ns[2] = MOVING;
                end
                else if (has_down_e[2]) begin
                    dir_ns[2]   = DOWN;
                    state_ns[2] = MOVING;
                end
                else begin
                    dir_ns[2]   = NONE;
                    state_ns[2] = IDLE;
                end
            end
            else begin
                timer_ns[2] = timer_cs[2] + 5'd1;
            end
        end

        default: begin
            floor_ns[2] = floor_cs[2];
            state_ns[2] = IDLE;
            dir_ns[2]   = NONE;
            timer_ns[2] = 5'd0;
        end
    endcase
end




// ============================================================
// Sequential block
// ============================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        floor_cs[0] <= 3'd0;
        floor_cs[1] <= 3'd0;
        floor_cs[2] <= 3'd0;

        state_cs[0] <= IDLE;
        state_cs[1] <= IDLE;
        state_cs[2] <= IDLE;

        dir_cs[0] <= NONE;
        dir_cs[1] <= NONE;
        dir_cs[2] <= NONE;

        timer_cs[0] <= 5'd0;
        timer_cs[1] <= 5'd0;
        timer_cs[2] <= 5'd0;
    end
    else begin
        floor_cs[0] <= floor_ns[0];
        floor_cs[1] <= floor_ns[1];
        floor_cs[2] <= floor_ns[2];

        state_cs[0] <= state_ns[0];
        state_cs[1] <= state_ns[1];
        state_cs[2] <= state_ns[2];

        dir_cs[0] <= dir_ns[0];
        dir_cs[1] <= dir_ns[1];
        dir_cs[2] <= dir_ns[2];

        timer_cs[0] <= timer_ns[0];
        timer_cs[1] <= timer_ns[1];
        timer_cs[2] <= timer_ns[2];
    end
end

endmodule