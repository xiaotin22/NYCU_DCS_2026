module LOCK(
    
    // Input Signals
    input  clk,
    input  rst_n,

    input  in_valid,
    input  [3:0] in_digit,
    input  enter,
    input  change,
    input  lock_reset,

    // Output Signals
    output logic [2:0] state,
    output logic unlocked,
    output logic alarm
);
//----------------------------------------------------------------
//   Declaration
//----------------------------------------------------------------
localparam logic [2:0] LOCKED = 3'b000, IN_D1    = 3'b001,
                       IN_D2  = 3'b010, IN_D3    = 3'b011,
                       IN_D4  = 3'b100, UNLOCKED = 3'b101,
                       CHANGE = 3'b110, ALARM    = 3'b111;

// You may need 2 register arrays to save password (current and golden)
// and 2 counters (count error attempts & count CHANGE state in_digit)
logic [3:0] in_pwd_cs [0:3], in_pwd_ns [0:3];
logic [3:0] correct_pwd_cs [0:3] , correct_pwd_ns [0:3];

//two counter
logic [1:0] change_cnt_cs, change_cnt_ns;
logic [1:0] err_cnt_cs, err_cnt_ns;


logic [2:0] state_cs, state_ns;
assign state = state_cs;
logic unlocked_cs, unlocked_ns;
assign unlocked = unlocked_cs;
logic alarm_cs, alarm_ns;
assign alarm = alarm_cs;

logic pwd_is_correct;
assign pwd_is_correct = (in_pwd_cs[0] == correct_pwd_cs[0]) && (in_pwd_cs[1] == correct_pwd_cs[1]) &&
                    (in_pwd_cs[2] == correct_pwd_cs[2]) && (in_pwd_cs[3] == correct_pwd_cs[3]);

//----------------------------------------------------------------
//   Sequential Logic
//----------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        correct_pwd_cs <= {4'd2, 4'd0, 4'd2, 4'd6};
        state_cs <= LOCKED;
        unlocked_cs <= 1'b0;
        alarm_cs <= 1'b0;
        change_cnt_cs <= 2'd0;
        err_cnt_cs <= 2'd0;
        in_pwd_cs <= '{default: 4'd0};

    end else begin
        correct_pwd_cs <= correct_pwd_ns;
        in_pwd_cs <= in_pwd_ns;
        state_cs <= state_ns;
        unlocked_cs <= unlocked_ns;
        alarm_cs <= alarm_ns;
        err_cnt_cs <= err_cnt_ns;
        change_cnt_cs <= change_cnt_ns;
    end
end

//----------------------------------------------------------------
//   Combinational Logic
//----------------------------------------------------------------
always_comb begin
    state_ns = state_cs;
    unlocked_ns = unlocked_cs;
    alarm_ns = alarm_cs;
    change_cnt_ns = change_cnt_cs;
    err_cnt_ns = err_cnt_cs;
    correct_pwd_ns = correct_pwd_cs;
    in_pwd_ns = in_pwd_cs;

    case (state_cs)

        LOCKED: begin
            if(in_valid) begin
                in_pwd_ns[0] = in_digit;
                state_ns = IN_D1;
            end 
            if (in_valid && enter) begin
                state_ns = LOCKED;
            end
        end

        IN_D1: begin
            if (in_valid) begin 
                in_pwd_ns[1] = in_digit;
                state_ns = IN_D2;
            end
            if (in_valid && enter) begin
                state_ns = LOCKED;
            end
        end

        IN_D2: begin
            if (in_valid) begin 
                in_pwd_ns[2] = in_digit;
                state_ns = IN_D3;
            end
            if (in_valid && enter) begin
                state_ns = LOCKED;
            end
        end

        IN_D3: begin
            if (in_valid) begin 
                in_pwd_ns[3] = in_digit;
                state_ns = IN_D4;
            end
            if (in_valid && enter) begin
                state_ns = LOCKED;
            end
        end

        IN_D4: begin
            if (pwd_is_correct) begin
                state_ns = UNLOCKED;
                unlocked_ns = 1'b1;
                err_cnt_ns = 2'b0;
            end else if (err_cnt_cs < 2'd2) begin
                state_ns = LOCKED;
                err_cnt_ns = err_cnt_cs + 1;
            end else begin
                state_ns = ALARM;
                alarm_ns = 1'b1;
            end
        end

        UNLOCKED: begin
            unlocked_ns = 1'b1;
            if (in_valid && enter) begin
                state_ns = LOCKED;
                unlocked_ns = 1'b0;
            end else if (in_valid && change) begin
                state_ns = CHANGE;
                change_cnt_ns = 2'b0;  
                unlocked_ns = 1'b0;  
            end 
        end

        CHANGE: begin
            if (in_valid) begin
                correct_pwd_ns[change_cnt_cs] = in_digit;
                change_cnt_ns = change_cnt_cs + 1;
            end
            if (change_cnt_cs == 2'd3) begin
                state_ns = LOCKED;
            end
        end

        ALARM: begin
            alarm_ns = 1'b1;
            if (in_valid && lock_reset) begin
                correct_pwd_ns = {4'd2, 4'd0, 4'd2, 4'd6};
                state_ns = LOCKED;
                alarm_ns = 1'b0;
                err_cnt_ns = 2'b0;
            end
        end

        default : begin
            state_ns = state_cs;
            unlocked_ns = unlocked_cs;
            alarm_ns = alarm_cs;
            change_cnt_ns = change_cnt_cs;
            err_cnt_ns = err_cnt_cs;
        end
    endcase
end

endmodule