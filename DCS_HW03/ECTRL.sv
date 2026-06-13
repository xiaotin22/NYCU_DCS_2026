module ECTRL (
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
    logic [7:0] car_req_e [0:2];
    logic [3:0] pax_cnt_e [0:2];
    logic [2:0] floor_e   [0:2];
    logic [2:0] state_e   [0:2];
    logic [1:0] dir_e     [0:2];
    logic [2:0] is_full_ns;
    logic full_e [0:2];

    // Input unpacking
    assign car_req_e = '{car_req[7:0], car_req[15:8], car_req[23:16]};
    assign pax_cnt_e = '{pax_cnt[3:0], pax_cnt[7:4], pax_cnt[11:8]};

    // Output packing
    assign cur_floor   = {floor_e[2], floor_e[1], floor_e[0]};
    assign lift_status = {state_e[2], state_e[1], state_e[0]};
    assign serve_dir   = {dir_e[2], dir_e[1], dir_e[0]};
    assign is_full_ns  = {(pax_cnt_e[2] >= 4'd15), (pax_cnt_e[1] >= 4'd15), (pax_cnt_e[0] >= 4'd15)};
    assign {full_e[2], full_e[1], full_e[0]} = is_full;

    logic [7:0] up_req_e   [0:2];
    logic [7:0] down_req_e [0:2];

    logic can_up [0:2];
    logic can_dn [0:2];
    logic dir_is_up [0:2];
    logic dir_is_dn [0:2];

    always_comb begin
        case (dir_e[0])
            2'b00: begin dir_is_up[0] = 1'b1; dir_is_dn[0] = 1'b1; end 
            2'b01: begin dir_is_up[0] = 1'b1; dir_is_dn[0] = 1'b0; end
            2'b10: begin dir_is_up[0] = 1'b0; dir_is_dn[0] = 1'b1; end
            default: begin dir_is_up[0] = 1'b0; dir_is_dn[0] = 1'b0; end
        endcase
        case (dir_e[1])
            2'b00: begin dir_is_up[1] = 1'b1; dir_is_dn[1] = 1'b1; end
            2'b01: begin dir_is_up[1] = 1'b1; dir_is_dn[1] = 1'b0; end
            2'b10: begin dir_is_up[1] = 1'b0; dir_is_dn[1] = 1'b1; end
            default: begin dir_is_up[1] = 1'b0; dir_is_dn[1] = 1'b0; end
        endcase
        case (dir_e[2])
            2'b00: begin dir_is_up[2] = 1'b1; dir_is_dn[2] = 1'b1; end
            2'b01: begin dir_is_up[2] = 1'b1; dir_is_dn[2] = 1'b0; end
            2'b10: begin dir_is_up[2] = 1'b0; dir_is_dn[2] = 1'b1; end
            default: begin dir_is_up[2] = 1'b0; dir_is_dn[2] = 1'b0; end
        endcase
    end


    assign can_up[0] = !full_e[0] && dir_is_up[0];
    assign can_dn[0] = !full_e[0] && dir_is_dn[0];
    assign can_up[1] = !full_e[1] && dir_is_up[1];
    assign can_dn[1] = !full_e[1] && dir_is_dn[1];
    assign can_up[2] = !full_e[2] && dir_is_up[2];
    assign can_dn[2] = !full_e[2] && dir_is_dn[2];

    logic [7:0] up_mask;
    logic [7:0] down_mask;  
    

    assign up_mask   = (8'b11111111 << floor_e[0]) & 8'b01111111;  // bit[7]=0: 7F 無 up_req
    assign down_mask = ~(8'b11111110 << floor_e[0]) & 8'b11111110; // bit[0]=0: 0F 無 down_req

    //Hall_call UP_REQ_ALLOC (.hall_req(up_req), .can_run0(can_up[0]), .can_run1(can_up[1]), .can_run2(can_up[2]), .req_mask(up_mask), .assigned_req(up_req_e));

    //Hall_call DOWN_REQ_ALLOC (.hall_req(down_req), .can_run0(can_dn[0]), .can_run1(can_dn[1]), .can_run2(can_dn[2]), .req_mask(down_mask), .assigned_req(down_req_e));

    assign up_req_e[0] = can_up[0] ? (up_req & 8'b10010010) : 8'b0;
    assign up_req_e[1] = can_up[1] ? (up_req & 8'b00100100) : 8'b0;
    assign up_req_e[2] = can_up[2] ? (up_req & 8'b01001001) : 8'b0;

    assign down_req_e[0] = can_dn[0] ? (down_req & 8'b10010010) : 8'b0;
    assign down_req_e[1] = can_dn[1] ? (down_req & 8'b00100100) : 8'b0;
    assign down_req_e[2] = can_dn[2] ? (down_req & 8'b01001001) : 8'b0;

    Elevator_core E0 (.clk(clk), .rst_n(rst_n), .up_req(up_req_e[0]), .down_req(down_req_e[0]), .car_req(car_req_e[0]), .btn_open(btn_open[0]), .btn_close(btn_close[0]), .cur_floor(floor_e[0]), .lift_status(state_e[0]), .serve_dir(dir_e[0]));

    Elevator_core E1 (.clk(clk), .rst_n(rst_n), .up_req(up_req_e[1]), .down_req(down_req_e[1]), .car_req(car_req_e[1]), .btn_open(btn_open[1]), .btn_close(btn_close[1]), .cur_floor(floor_e[1]), .lift_status(state_e[1]), .serve_dir(dir_e[1]));

    Elevator_core E2 (.clk(clk), .rst_n(rst_n), .up_req(up_req_e[2]), .down_req(down_req_e[2]), .car_req(car_req_e[2]), .btn_open(btn_open[2]), .btn_close(btn_close[2]), .cur_floor(floor_e[2]), .lift_status(state_e[2]), .serve_dir(dir_e[2]));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_full <= 3'b000;
        end else begin
            is_full <= is_full_ns;
        end
    end
    
endmodule


module Hall_call (
    input  logic [7:0] hall_req,
    input  logic       can_run0,
    input  logic       can_run1,
    input  logic       can_run2,
    input  logic [7:0] req_mask,
    output logic [7:0] assigned_req [0:2]
);
    assign assigned_req[0] = can_run0 ? (hall_req & 8'b10010010) : 8'b0;
    assign assigned_req[1] = can_run1 ? (hall_req & 8'b00100100) : 8'b0;
    assign assigned_req[2] = can_run2 ? (hall_req & 8'b01001001) : 8'b0;
endmodule


module Hall_call1 (
    input  logic [7:0] hall_req,
    input  logic       can_run0,
    input  logic       can_run1,
    input  logic       can_run2,
    input  logic [7:0] req_mask,
    output logic [7:0] assigned_req [0:2]
);
    logic [7:0] remaining_req;

    always_comb begin
        remaining_req = hall_req;

        assigned_req[0] = can_run0 ? (hall_req & req_mask) : 8'b0;
        remaining_req = remaining_req & ~assigned_req[0];

        assigned_req[1] = can_run1 ? (remaining_req) : 8'b0;
        remaining_req = remaining_req & ~assigned_req[1];

        assigned_req[2] = can_run2 ? (remaining_req) : 8'b0;
    end
endmodule



module Elevator_core (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] up_req,
    input  logic [7:0] down_req,
    input  logic [7:0] car_req,
    input  logic       btn_open,
    input  logic       btn_close,
    output logic [2:0] cur_floor,
    output logic [2:0] lift_status,
    output logic [1:0] serve_dir
);
    localparam logic [2:0] IDLE    = 3'b000;
    localparam logic [2:0] MOVING  = 3'b001;
    localparam logic [2:0] OPENING = 3'b010;
    localparam logic [2:0] OPEN    = 3'b011;
    localparam logic [2:0] CLOSING = 3'b100;

    localparam logic [1:0] NONE = 2'b00;
    localparam logic [1:0] UP   = 2'b01;
    localparam logic [1:0] DOWN = 2'b10;

    logic [2:0] state_cs, state_ns;
    logic [2:0] floor_cs, floor_ns;
    logic [4:0] timer_cs, timer_ns;
    logic [1:0] dir_cs, dir_ns;

    logic [2:0] floor_lookahead;
    logic st_idle, st_moving, st_opening, st_open, st_closing;
    logic t_lt10, t_ge4, t_lt4, close_timeout;

    assign lift_status = state_cs;
    assign cur_floor   = floor_cs;
    assign serve_dir   = dir_cs;

    // Lookahead logic: 判斷下一個時間點會到哪一樓

    always_comb begin
        floor_lookahead = floor_cs;
        if (state_cs == MOVING && timer_cs[3] && timer_cs[0]) begin
            if (dir_cs == UP) begin
                floor_lookahead = floor_cs + 3'd1;
            end else  begin
                floor_lookahead = floor_cs - 3'd1;
            end
        end
    end

    logic [7:0] total_req;
    logic need_stop;
    assign total_req = up_req | down_req | car_req;
    assign need_stop = total_req[floor_ns];

    // 狀態判斷邏輯 (使用 case 語句)
    always_comb begin
        st_idle    = 1'b0;
        st_moving  = 1'b0;
        st_opening = 1'b0;
        st_open    = 1'b0;
        st_closing = 1'b0;
        
        case (state_cs)
            IDLE:    st_idle    = 1'b1;
            MOVING:  st_moving  = 1'b1;
            OPENING: st_opening = 1'b1;
            OPEN:    st_open    = 1'b1;
            CLOSING: st_closing = 1'b1;
            default: /* all remain 0 */;
        endcase
    end

    assign t_lt10 = (timer_cs <  5'd10);
    assign t_ge4  = (timer_cs[2]); // greater or equal
    assign t_lt4  = (!timer_cs[2]); //less than
    assign close_timeout = (timer_cs >= 5'd19); // 16 + 2 + 1 = 19 cycles

    // State FSM (永遠保持 MOVING)
    always_comb begin
        state_ns = state_cs;
        floor_ns = floor_cs;

        if (st_idle) begin
            state_ns = MOVING; // 避免意外進入 IDLE，直接強制喚醒
        end else if (st_moving) begin
            floor_ns = floor_lookahead;
            if (!t_lt10) begin
                if (need_stop) state_ns = OPENING;
                else state_ns = MOVING; // 沒遇到人，不進入 IDLE，繼續前進！
            end
        end else if (st_opening) begin
            if (t_ge4) state_ns = OPEN;
        end else if (st_open) begin
            if (!btn_open && (btn_close || close_timeout)) state_ns = CLOSING;
        end else if (st_closing) begin
            if (btn_open) state_ns = OPENING;
            else if (t_ge4) state_ns = MOVING; // 關門後直接回 MOVING，繼續巡迴
        end
    end


    // DIR FSM (撞牆反彈邏輯)
    always_comb begin
        dir_ns = dir_cs; 
        // 根據下個樓層狀態提早切換方向，確保到達頂/底樓時方向已經改變
        if (floor_ns >= 3'd7) begin
            dir_ns = DOWN;
        end else if (floor_ns <= 3'd0) begin
            dir_ns = UP;
        end
    end

    // Timer Counter Logic
    always_comb begin
        timer_ns = timer_cs;

        if (st_idle) begin
            timer_ns = 5'd0;
        end else if (st_moving) begin
            // 若不需要停，timer 從 1 重新開始算下一層樓的時間
            timer_ns = t_lt10 ? (timer_cs + 5'd1) : (need_stop ? 5'd0 : 5'd1);
        end else if (st_opening) begin
            timer_ns = t_lt4 ? (timer_cs + 5'd1) : 5'd0;
        end else if (st_open) begin
            timer_ns = (btn_open || btn_close || close_timeout) ? 5'd0 : (timer_cs + 5'd1);
        end else begin
            timer_ns = btn_open ? 5'd0 : (t_lt4 ? (timer_cs + 5'd1) : 5'd0);
        end
    end

    // Sequential state update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_cs <= IDLE; 
            floor_cs <= 3'd0;
            dir_cs   <= NONE;   
        end else begin
            state_cs <= state_ns;
            floor_cs <= floor_ns;
            dir_cs   <= dir_ns;
        end
    end

    // timer 不用 rst_n，因為在 IDLE 和 MOVING 狀態會被自動重置
    always_ff @(posedge clk) timer_cs <= timer_ns;

endmodule
