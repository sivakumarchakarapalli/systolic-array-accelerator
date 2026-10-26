`timescale 1ns/1ps
// ============================================================
// pe.v : one Processing Element of an output-stationary
//        systolic array.
//
//   a_in  --> [ acc += a_in * b_in ] --> a_out   (to the right)
//                     |
//   b_in (from above) +--> b_out                (to below)
//
// Every clock:
//   1. multiply the A value and B value arriving now,
//   2. add the product to this PE's own accumulator,
//   3. register A and B and pass them to the neighbours.
// After all K pairs have passed, acc holds one element C[i][j].
// ============================================================
// use_dsp: put the multiply-accumulate in a DSP48E1 slice. Without it,
// Vivado builds small 8x8 multipliers out of LUTs (0 DSPs, ~2000 LUTs).
(* use_dsp = "yes" *)
module pe #(
    parameter DW = 8,           // input width  (signed INT8)
    parameter AW = 32           // accumulator width
)(
    input  wire                 clk,
    input  wire                 rst,     // synchronous, active high
    input  wire                 clear,   // zero acc before a new matrix
    input  wire signed [DW-1:0] a_in,    // from the left neighbour
    input  wire signed [DW-1:0] b_in,    // from the top neighbour
    output reg  signed [DW-1:0] a_out,   // to the right neighbour
    output reg  signed [DW-1:0] b_out,   // to the bottom neighbour
    (* use_dsp = "yes" *)
    output reg  signed [AW-1:0] acc      // this PE's result
);

    // 8b x 8b signed gives a 16b signed product
    (* use_dsp = "yes" *) wire signed [2*DW-1:0] prod = a_in * b_in;

    always @(posedge clk) begin
        if (rst) begin
            a_out <= 0;
            b_out <= 0;
            acc   <= 0;
        end else begin
            // pass the operands on: this one-cycle delay per PE is
            // what makes the array "systolic"
            a_out <= a_in;
            b_out <= b_in;

            if (clear)
                acc <= 0;
            else
                acc <= acc + prod;   // prod is sign-extended to AW
        end
    end

endmodule
