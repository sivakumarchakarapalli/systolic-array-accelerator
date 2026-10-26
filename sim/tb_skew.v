`timescale 1ns/1ps
// ============================================================
// tb_skew.v : unit test for skew.v
//   Drives a new random value into every lane on every clock and
//   checks that lane i outputs the value it was given i clocks ago.
// ============================================================
module tb_skew;

    parameter N  = 4;
    parameter DW = 8;
    localparam DEPTH = 16;               // history kept by the testbench

    reg clk = 0, rst = 1;
    reg  [N*DW-1:0] in_flat = 0;
    wire [N*DW-1:0] out_flat;

    skew #(.N(N), .DW(DW)) dut (.clk(clk), .rst(rst),
                                .in_flat(in_flat), .out_flat(out_flat));

    always #5 clk = ~clk;

    reg [N*DW-1:0] hist [0:DEPTH-1];     // hist[d] = input d clocks ago
    integer errors = 0, t, i, d;

    initial begin
        for (d = 0; d < DEPTH; d = d + 1) hist[d] = 0;
        repeat (3) @(negedge clk);
        rst = 0;

        for (t = 0; t < 1000; t = t + 1) begin
            @(negedge clk);
            // new random input this clock
            for (d = DEPTH-1; d > 0; d = d - 1) hist[d] = hist[d-1];
            for (i = 0; i < N; i = i + 1) in_flat[i*DW +: DW] = $random;
            hist[0] = in_flat;
            #1;
            // lane 0 is a wire (0 clocks); lane i shows the value from i clocks ago
            for (i = 0; i < N; i = i + 1)
                if (t >= i && out_flat[i*DW +: DW] !== hist[i][i*DW +: DW]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("FAIL clock %0d lane %0d: out=%h expected %h",
                                 t, i, out_flat[i*DW +: DW], hist[i][i*DW +: DW]);
                end
            @(posedge clk);
        end

        if (errors == 0) $display("PASS: skew N=%0d, lane i delayed by exactly i clocks (1000 clocks)", N);
        else             $display("FAIL: skew N=%0d, %0d errors", N, errors);
        $finish;
    end

endmodule
