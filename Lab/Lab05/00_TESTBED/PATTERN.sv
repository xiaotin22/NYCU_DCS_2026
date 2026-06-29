`define CYCLE_TIME 10.0

module PATTERN (
    output logic clk,
    output logic rst_n,

    output logic in_valid,
    output logic [3:0] in_digit,
    output logic enter,
    output logic change,
    output logic lock_reset,

    input  [2:0] state,
    input  unlocked,
    input  alarm
);
//================================================================
// Clock
//================================================================
real CYCLE = `CYCLE_TIME;
always #(CYCLE/2.0) clk = ~clk;


//================================================================
// Declaration
//================================================================
localparam logic [2:0] LOCKED   = 3'b000, IN_D1    = 3'b001,
                       IN_D2    = 3'b010, IN_D3    = 3'b011,
                       IN_D4    = 3'b100, UNLOCKED = 3'b101,
                       CHANGE = 3'b110, ALARM  = 3'b111;

integer f_in, ret;
integer patnum, i, j;
integer lock_flag, in_type;
logic [3:0] in_d [0:3];
logic [3:0] ch_d [0:3];
integer nxt_char;


logic [3:0] golden_pwd [0:3];
logic pwd_is_correct;
integer wrong_cnt;

//================================================================
// main flow
//================================================================
initial begin
    
    rst_n = 1'b1;
    clk = 0;
    
    in_valid   = 1'b0;
    in_digit   = 4'bx;
    enter      = 1'b0;
    change     = 1'b0;
    lock_reset = 1'b0;
    pwd_is_correct   = 1'b0;

    reset_task();

    f_in = $fopen("../00_TESTBED/input.txt", "r");

    ret = $fscanf(f_in, "%d", patnum);

    for (i = 0; i < patnum; i = i + 1) begin
        Check_task();
    end

    $fclose(f_in);
    YOU_PASS_task();
end

//================================================================
// Task
//================================================================

task reset_task; begin
    rst_n      = 1'b1;
    in_valid   = 1'b0;
    in_digit   = 4'bx;
    enter      = 1'b0;
    change     = 1'b0;
    lock_reset = 1'b0;
    wrong_cnt = 0;
    golden_pwd = '{4'd2, 4'd0, 4'd2, 4'd6};
    
    force clk = 1'b0;
    #(2*CYCLE);
    rst_n = 1'b0;

    #(CYCLE);
    if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
        fail(0);
        #(5*CYCLE);
        $finish;
    end

    rst_n = 1'b1;
    #(2*CYCLE);
    release clk;

    repeat(3) @(negedge clk);
end endtask


task Check_task; begin
    
    lock_flag = 0;
    in_type   = 0;

    in_d = '{default: 4'b0};
    ch_d = '{default: 4'b0};

    ret = $fscanf(f_in, "%d", lock_flag);

    if (lock_flag == 1) begin
        nxt_char = $fgetc(f_in);
        while (nxt_char != 10 && nxt_char != -1) nxt_char = $fgetc(f_in);
    end
    else begin
        ret = $fscanf(f_in, "%d %d %d %d %d",
                      in_d[0], in_d[1], in_d[2], in_d[3], in_type);

        if (in_type == 0) begin
            ret = $fscanf(f_in, "%d %d %d %d",
                          ch_d[0], ch_d[1], ch_d[2], ch_d[3]);
        end
        // 吃掉這行剩下內容
        nxt_char = $fgetc(f_in);
        while (nxt_char != 10 && nxt_char != -1) nxt_char = $fgetc(f_in);
    end

    enter      = 1'b0;
    change     = 1'b0;
    lock_reset = 1'b0;
    in_valid   = 1'b0;
    in_digit   = 4'bx;

    if (lock_flag == 1) begin
        @(negedge clk);
        in_valid   = 1'b1;
        lock_reset = 1'b1;

        @(negedge clk);
        in_valid   = 1'b0;
        lock_reset = 1'b0;

        golden_pwd = '{4'd2, 4'd0, 4'd2, 4'd6};
        wrong_cnt     = 0;

        @(negedge clk);
        if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
            fail(4);
            #(5*CYCLE);
            $finish;
        end
        return;
    end
    // digit 1
    @(negedge clk);
    in_valid   = 1'b1;
    in_digit   = in_d[0];

    @(negedge clk);
    in_valid   = 1'b0;
    in_digit   = 4'bx;

    if (in_type == 1) begin
        @(negedge clk);
        in_valid   = 1'b1;
        enter      = 1'b1;

        @(negedge clk);
        in_valid   = 1'b0;
        enter      = 1'b0;

        if (wrong_cnt >= 3) begin
            if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                fail(4);
                #(5*CYCLE);
                $finish;
            end
        end else begin
            if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
                fail(1);
                #(5*CYCLE);
                $finish;
            end
        end
        return;
    end

    // digit 2
    @(negedge clk);
    in_valid   = 1'b1;
    in_digit   = in_d[1];

    @(negedge clk);
    in_valid   = 1'b0;
    in_digit   = 4'bx;

    if (in_type == 2) begin
        @(negedge clk);
        in_valid   = 1'b1;
        enter      = 1'b1;

        @(negedge clk);
        in_valid   = 1'b0;
        enter      = 1'b0;

        if (wrong_cnt >= 3) begin
            if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                fail(4);
                #(5*CYCLE);
                $finish;
            end
        end else begin
            if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
                fail(1);
                #(5*CYCLE);
                $finish;
            end
        end
        return;
    end

    // digit 3
    @(negedge clk);
    in_valid   = 1'b1;
    in_digit   = in_d[2];

    @(negedge clk);
    in_valid   = 1'b0;
    in_digit   = 4'bx;

    if (in_type == 3) begin
        @(negedge clk);
        in_valid   = 1'b1;
        enter      = 1'b1;

        @(negedge clk);
        in_valid   = 1'b0;
        enter      = 1'b0;

        if (wrong_cnt >= 3) begin
            if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                fail(4);
                #(5*CYCLE);
                $finish;
            end
        end else begin
            if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
                fail(1);
                #(5*CYCLE);
                $finish;
            end
        end
        return;
    end

    // digit 4
    @(negedge clk);
    in_valid   = 1'b1;
    in_digit   = in_d[3];

    @(negedge clk);
    in_valid   = 1'b0;
    in_digit   = 4'bx;

    @(negedge clk);

    pwd_is_correct = (in_d[0] == golden_pwd[0]) &&
                     (in_d[1] == golden_pwd[1]) &&
                     (in_d[2] == golden_pwd[2]) &&
                     (in_d[3] == golden_pwd[3]);

    if (wrong_cnt >= 3) begin
        if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
            fail(4);
            #(5*CYCLE);
            $finish;
        end

        if (pwd_is_correct) begin
            if (in_type == 4) begin
                @(negedge clk);
                in_valid   = 1'b1;
                enter      = 1'b1;

                @(negedge clk);
                in_valid   = 1'b0;
                enter      = 1'b0;

                if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                    fail(4);
                    #(5*CYCLE);
                    $finish;
                end
            end else if (in_type == 0) begin
                @(negedge clk);
                in_valid   = 1'b1;
                change     = 1'b1;

                @(negedge clk);
                in_valid   = 1'b0;
                change     = 1'b0;

                @(negedge clk);
                in_valid   = 1'b1;
                in_digit   = ch_d[0];
                @(negedge clk); in_digit = ch_d[1];
                @(negedge clk); in_digit = ch_d[2];
                @(negedge clk); in_digit = ch_d[3];

                @(negedge clk);
                in_valid   = 1'b0;
                in_digit   = 4'bx;

                @(negedge clk);
                if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                    fail(4);
                    #(5*CYCLE);
                    $finish;
                end
            end
        end
    end else begin
        if (!pwd_is_correct) begin
            wrong_cnt = wrong_cnt + 1;

            if (wrong_cnt < 3) begin
                if (state !== LOCKED || unlocked !== 1'b0 || alarm !== 1'b0) begin
                    fail(3);
                    #(5*CYCLE);
                    $finish;
                end
            end else begin
                if (state !== ALARM || unlocked !== 1'b0 || alarm !== 1'b1) begin
                    fail(4);
                    #(5*CYCLE);
                    $finish;
                end
            end
        end else begin
            wrong_cnt = 0;

            if (state !== UNLOCKED || unlocked !== 1'b1 || alarm !== 1'b0) begin
                fail(2);
                #(5*CYCLE);
                $finish;
            end

            if (in_type == 4) begin
                @(negedge clk);
                in_valid   = 1'b1;
                enter      = 1'b1;

                @(negedge clk);
                in_valid   = 1'b0;
                enter      = 1'b0;
            end else if (in_type == 0) begin
                @(negedge clk);
                in_valid   = 1'b1;
                change     = 1'b1;

                @(negedge clk);
                in_valid   = 1'b0;
                change     = 1'b0;

                @(negedge clk);
                in_valid   = 1'b1;
                in_digit   = ch_d[0];
                @(negedge clk); in_digit = ch_d[1];
                @(negedge clk); in_digit = ch_d[2];
                @(negedge clk); in_digit = ch_d[3];

                @(negedge clk);
                in_valid   = 1'b0;
                in_digit   = 4'bx;

                golden_pwd = {ch_d[0], ch_d[1], ch_d[2], ch_d[3]};
                @(negedge clk);
            end
        end
    end
end endtask




task YOU_PASS_task();
    $display("----------------------------------------------------------------------------------------------------------------------");
    $display("                                                  Congratulations!");
    $display("                                           You have passed all patterns!");
    $display("----------------------------------------------------------------------------------------------------------------------");
    $finish;
endtask

task fail(input int check_code = -1);
    case (check_code)
        0: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("                      CHECK 0                     ");
            $display("           output must be 0 after reset           ");
            $display("--------------------------------------------------");
        end
        1: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("                      CHECK 1                     ");
            $display("     state should be LOCKED after early enter     ");
            $display("--------------------------------------------------");
        end
        2: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("                      CHECK 2                     ");
            $display("    UNLOCKED mode not set after correct pwd    ");
            // $display("==================================================");
            // $display("             state = %3b, unlocked = %1b", state, unlocked);
            // $display("               golden password: %1d%1d%1d%1d", golden_pwd[0], golden_pwd[1], golden_pwd[2], golden_pwd[3]);
            $display("--------------------------------------------------");
        end
        3: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("                      CHECK 3                     ");
            $display("   state should be LOCKED after a wrong attempt   ");
            // $display("==================================================");
            // $display("               golden password: %1d%1d%1d%1d", golden_pwd[0], golden_pwd[1], golden_pwd[2], golden_pwd[3]);
            $display("--------------------------------------------------");
        end
        4: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("                      CHECK 4                     ");
            $display("    ALARM mode not set after 3 wrong attempts     ");
            $display("                        or                        ");
            $display("    ALARM mode early release before lock_reset    ");
            // $display("==================================================");
            // $display("              state = %3b, alarm = %1b", state, alarm);
            // $display("               golden password: %1d%1d%1d%1d", golden_pwd[0], golden_pwd[1], golden_pwd[2], golden_pwd[3]);
            $display("--------------------------------------------------");
        end
        default: begin
            $display("--------------------------------------------------");
            $display("                      FAIL!!!                     ");
            $display("--------------------------------------------------");
        end
    endcase
endtask

endmodule

