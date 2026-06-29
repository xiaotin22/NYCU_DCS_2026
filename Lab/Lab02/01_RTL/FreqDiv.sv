module FreqDiv(
    // Input signals
	clk, 
	rst_n, 
	in_valid,  
	in_div, 
	in_rep, 
    // Output signals
	out_clk, 
	out_valid
);
//---------------------------------------------------------------------
//   INPUT AND OUTPUT DECLARATION                         
//---------------------------------------------------------------------
input clk, rst_n;
input in_valid; 
input [2:0] in_div; // 2,4,6 only
input [2:0] in_rep; // 1~7 only
output logic out_clk;
output logic out_valid;

//---------------------------------------------------------------------
//   LOGIC DECLARATION
//---------------------------------------------------------------------
logic busy_cs, busy_ns;

logic [2:0] in_div_cs, in_div_ns;
logic [2:0] in_rep_cs, in_rep_ns;
logic [2:0] rep_cnt_cs, rep_cnt_ns;
logic [2:0] div_cnt_cs, div_cnt_ns;

logic out_clk_ns;
logic out_valid_ns;


//---------------------------------------------------------------------
//   Your DESIGN                        
//---------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		// Async reset
		in_div_cs      <= 3'd0;
		in_rep_cs      <= 3'd0;
		rep_cnt_cs <= 3'd0;
		div_cnt_cs <= 3'd0;
		out_clk        <= 1'b0;
		out_valid      <= 1'b0;
		busy_cs <= 1'b0;
	end
	else begin
		in_div_cs	  <= in_div_ns;
		in_rep_cs	  <= in_rep_ns;
		rep_cnt_cs <= rep_cnt_ns;
		div_cnt_cs <= div_cnt_ns;
		out_clk       <= out_clk_ns;
		out_valid     <= out_valid_ns;
		busy_cs <= busy_ns;
	end
end

always_comb begin
	in_div_ns = in_div_cs;
	in_rep_ns = in_rep_cs;
	rep_cnt_ns = rep_cnt_cs;
	div_cnt_ns = div_cnt_cs;
	out_clk_ns = out_clk;
	out_valid_ns = out_valid;
	busy_ns = busy_cs;

	if (!busy_cs) begin
		out_clk_ns = 1'b0;
		out_valid_ns = 1'b0;
		if (in_valid) begin
			in_div_ns = in_div;
			in_rep_ns = in_rep;
			rep_cnt_ns = 3'd0;
			div_cnt_ns = 3'd0;
			busy_ns = 1'b1;
			out_clk_ns = 1'b0;
			out_valid_ns = 1'b0;
		end
	end
	else begin
		out_valid_ns = 1'b1;
		out_clk_ns = (div_cnt_cs < (in_div_cs >> 1));
		if (div_cnt_cs == in_div_cs - 1) begin
			div_cnt_ns = 3'd0;
			if (rep_cnt_cs == in_rep_cs - 1) begin
				rep_cnt_ns = 3'd0;
				busy_ns = 1'b0;
			end
			else begin
				rep_cnt_ns = rep_cnt_cs + 1;	
			end
		end	else begin
			div_cnt_ns = div_cnt_cs + 1;
		end
	end
end
endmodule
