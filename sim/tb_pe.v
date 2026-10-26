`timescale 1ns/1ps
// ============================================================
// tb_pe.v : self-checking testbench for pe.v
//   Test 1: the corner case -128 * -128 and mixed signs
//   Test 2: a_out / b_out are a_in / b_in delayed by one clock
//   Test 3: 1000 random dot products of length 4, compared with
//           a reference sum computed in the testbench
// Prints PASS or FAIL with the number of errors.
// ============================================================
module tb_pe;

    reg               clk = 0;
    reg               rst = 1;
    reg               clear = 0;
    reg  signed [7:0] a_in = 0, b_in = 0;
    wire signed [7:0] a_out, b_out;
    wire signed [31:0] acc;

    pe dut (.clk(clk), .rst(rst), .clear(clear),
            .a_in(a_in), .b_in(b_in),
            .a_out(a_out), .b_out(b_out), .acc(acc));

    always #5 clk = ~clk;              // 100 MHz

    integer errors = 0;
    integer t, k;
    integer expected;
    reg signed [7:0] av [0:3];
    reg signed [7:0] bv [0:3];

    // drive inputs on the falling edge so they are stable at posedge
    task feed(input signed [7:0] a, input signed [7:0] b);
        begin
            @(negedge clk);
            a_in = a; b_in = b;
        end
    endtask

    // one dot product: clear, feed 4 pairs, then check acc
    task dot4;
        begin
            @(negedge clk); clear = 1; a_in = 0; b_in = 0;
            @(negedge clk); clear = 0;
            a_in = av[0]; b_in = bv[0];
            for (k = 1; k < 4; k = k + 1)
                feed(av[k], bv[k]);
            @(negedge clk); a_in = 0; b_in = 0;  // last product is now in acc
            expected = av[0]*bv[0] + av[1]*bv[1] + av[2]*bv[2] + av[3]*bv[3];
            if (acc !== expected) begin
                errors = errors + 1;
                $display("FAIL dot: a=%0d %0d %0d %0d b=%0d %0d %0d %0d acc=%0d exp=%0d",
                         av[0], av[1], av[2], av[3], bv[0], bv[1], bv[2], bv[3],
                         acc, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("pe.vcd");
        $dumpvars(0, tb_pe);

        repeat (3) @(negedge clk);
        rst = 0;

        // ---- Test 1: corner cases ----
        av[0] = -128; bv[0] = -128;   // largest product, +16384
        av[1] =  127; bv[1] = -128;
        av[2] =   -1; bv[2] =   -1;
        av[3] =    0; bv[3] =   55;
        dot4;
        $display("Test 1 corner cases : acc = %0d (expected %0d)", acc, expected);

        // ---- Test 2: pass-through delay ----
        @(negedge clk); a_in = 8'sd37; b_in = -8'sd90;
        @(posedge clk); #1;
        if (a_out !== 8'sd37 || b_out !== -8'sd90) begin
            errors = errors + 1;
            $display("FAIL pass-through: a_out=%0d b_out=%0d", a_out, b_out);
        end else
            $display("Test 2 pass-through : a_out=%0d b_out=%0d one clock later", a_out, b_out);

        // ---- Test 3: random dot products ----
        for (t = 0; t < 1000; t = t + 1) begin
            for (k = 0; k < 4; k = k + 1) begin
                av[k] = $random;
                bv[k] = $random;
            end
            dot4;
        end
        $display("Test 3 random       : 1000 dot products checked");

        if (errors == 0) $display("PASS: pe, 0 errors");
        else             $display("FAIL: pe, %0d errors", errors);
        $finish;
    end

endmodule
