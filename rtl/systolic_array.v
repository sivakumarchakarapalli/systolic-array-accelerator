`timescale 1ns/1ps
// ============================================================
// systolic_array.v : N x N grid of PEs (output-stationary)
//
//            b_top[0]  b_top[1]  b_top[2]  b_top[3]
//               |         |         |         |
//  a_left[0] -> PE00 ---> PE01 ---> PE02 ---> PE03
//               |         |         |         |
//  a_left[1] -> PE10 ---> PE11 ---> PE12 ---> PE13
//               ...
//
// - A values enter on the left of each row and move right.
// - B values enter on the top of each column and move down.
// - PE(i,j) ends up holding C[i][j] in its accumulator.
//
// This module does NOT skew the inputs. The caller must delay
// row i and column j by i and j clocks (step 3 adds that).
//
// Vectors are flattened because Verilog-2005 ports cannot be
// 2-D arrays:  a_left[i]  = a_left_flat[i*DW +: DW]
//              acc[i][j]  = acc_flat[(i*N+j)*AW +: AW]
// ============================================================
module systolic_array #(
    parameter N  = 4,           // array is N x N
    parameter DW = 8,           // input width
    parameter AW = 32           // accumulator width
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              clear,
    input  wire [N*DW-1:0]   a_left_flat,  // one A value per row
    input  wire [N*DW-1:0]   b_top_flat,   // one B value per column
    output wire [N*N*AW-1:0] acc_flat      // all N*N results
);

    // Horizontal wires: a_h[i][j] is the A value entering PE(i,j).
    // There are N+1 per row; the last one leaves the array unused.
    wire [DW-1:0] a_h [0:N-1][0:N];
    // Vertical wires: b_v[i][j] is the B value entering PE(i,j).
    wire [DW-1:0] b_v [0:N][0:N-1];

    genvar i, j;
    generate
        // array edges: connect the external inputs
        for (i = 0; i < N; i = i + 1) begin : g_left
            assign a_h[i][0] = a_left_flat[i*DW +: DW];
        end
        for (j = 0; j < N; j = j + 1) begin : g_top
            assign b_v[0][j] = b_top_flat[j*DW +: DW];
        end

        // the grid itself
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                pe #(.DW(DW), .AW(AW)) u_pe (
                    .clk   (clk),
                    .rst   (rst),
                    .clear (clear),
                    .a_in  (a_h[i][j]),
                    .b_in  (b_v[i][j]),
                    .a_out (a_h[i][j+1]),      // to the right
                    .b_out (b_v[i+1][j]),      // downwards
                    .acc   (acc_flat[(i*N+j)*AW +: AW])
                );
            end
        end
    endgenerate

endmodule
