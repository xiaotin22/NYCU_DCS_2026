module Comb(
	// Input signals
	in_num0,
	in_num1,
	in_num2,
	in_num3,
	// Output signals
	out_num0,
	out_num1
);
// ---------------------------------------------------------------------
// INPUT AND OUTPUT DECLARATION                         
// ---------------------------------------------------------------------
input [6:0] in_num0, in_num1, in_num2, in_num3;
output logic [7:0] out_num0, out_num1;

// ---------------------------------------------------------------------
// LOGIC DECLARATION
logic [6:0]	num_xnor, num_and, num_xor, num_or;
logic [7:0] num_adder;
logic [6:0] max_xnor_and, min_xnor_and, max_xor_or, min_xor_or;
// ---------------------------------------------------------------------


// ---------------------------------------------------------------------
// Your DESIGN       
assign num_xnor = in_num0  ~^ in_num1;
assign num_and   = in_num1  &  in_num3;
assign num_xor  = in_num0  ^  in_num2;
assign num_or   = in_num2  |  in_num3;


assign max_xnor_and = (num_xnor >= num_and) ? num_xnor : num_and;
assign min_xnor_and = (num_xnor >= num_and) ? num_and  : num_xnor;
assign max_xor_or   = (num_xor  >= num_or ) ? num_xor  : num_or;
assign min_xor_or   = (num_xor  >= num_or ) ? num_or   : num_xor;

assign num_adder = max_xnor_and + min_xor_or;

assign out_num0 = num_adder ^ (num_adder >> 1); // Binary to Gray code conversion

assign out_num1 = min_xnor_and + max_xor_or;
// ---------------------------------------------------------------------

endmodule