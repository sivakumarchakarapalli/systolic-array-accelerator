`timescale 1ns/1ps
// ============================================================
// skew.v : staggers N input lanes into a staircase
//
//   lane 0 : in ---------------------------> out   (0 clocks)
//   lane 1 : in --[R]----------------------> out   (1 clock)
//   lane 2 : in --[R]--[R]-----------------> out   (2 clocks)
//   lane 3 : in --[R]--[R]--[R]------------> out   (3 clocks)
//
// Lane i is a shift register i stages long, so whatever enters
// lane i comes out exactly i clocks later. Used once for the rows
// of A and once for the columns of B.
//
//   in  lane i = in_flat [i*DW +: DW]
//   out lane i = out_flat[i*DW +: DW]
// ============================================================
module skew #(
    parameter N  = 4,
    parameter DW = 8
)(
    input  wire            clk,
    input  wire            rst,
    input  wire [N*DW-1:0] in_flat,
    output wire [N*DW-1:0] out_flat
);

    // lane 0 needs no delay: a plain wire
    assign out_flat[0 +: DW] = in_flat[0 +: DW];

    genvar i;
    generate
        for (i = 1; i < N; i = i + 1) begin : g_lane
            // i registers in a chain: sr[0] is the first, sr[i-1] the last
            reg [DW-1:0] sr [0:i-1];
            integer m;

            always @(posedge clk) begin
                if (rst) begin
                    for (m = 0; m < i; m = m + 1)
                        sr[m] <= 0;
                end else begin
                    sr[0] <= in_flat[i*DW +: DW];
                    for (m = 1; m < i; m = m + 1)
                        sr[m] <= sr[m-1];         // shift one stage each clock
                end
            end

            assign out_flat[i*DW +: DW] = sr[i-1];
        end
    endgenerate

endmodule
