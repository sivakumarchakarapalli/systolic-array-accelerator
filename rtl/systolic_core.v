`timescale 1ns/1ps
// ============================================================
// systolic_core.v : skew logic + N x N systolic array
//
//                 b_row (row k of B, all N values at once)
//                        |
//                    [ skew B ]
//                        | staggered
//   a_col  ->[ skew A ]->[ systolic_array ]-> acc (C)
//  (column k of A,
//   all N values at once)
//
// Usage: on clock k+1 (k = 0..N-1) present column k of A on
// a_col_flat and row k of B on b_row_flat, then send zeros.
// C is complete 3N-2 clocks after the first column.
// ============================================================
module systolic_core #(
    parameter N  = 4,
    parameter DW = 8,
    parameter AW = 32
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              clear,
    input  wire [N*DW-1:0]   a_col_flat,   // a_col[i] = A[i][k]
    input  wire [N*DW-1:0]   b_row_flat,   // b_row[j] = B[k][j]
    output wire [N*N*AW-1:0] acc_flat      // acc[i][j] = C[i][j]
);

    wire [N*DW-1:0] a_skewed, b_skewed;

    skew #(.N(N), .DW(DW)) u_skew_a (
        .clk(clk), .rst(rst), .in_flat(a_col_flat), .out_flat(a_skewed));

    skew #(.N(N), .DW(DW)) u_skew_b (
        .clk(clk), .rst(rst), .in_flat(b_row_flat), .out_flat(b_skewed));

    systolic_array #(.N(N), .DW(DW), .AW(AW)) u_array (
        .clk(clk), .rst(rst), .clear(clear),
        .a_left_flat(a_skewed), .b_top_flat(b_skewed),
        .acc_flat(acc_flat));

endmodule
