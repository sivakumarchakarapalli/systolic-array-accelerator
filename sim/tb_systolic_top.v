`timescale 1ns/1ps
// ============================================================
// tb_systolic_top.v : self-checking testbench for the accelerator
//
// The testbench now behaves like software using the accelerator:
// write A and B, pulse start, wait for done, read C.
//   Test 1: walkthrough example, checks C, done timing and busy
//   Test 2: start and writes while busy must be ignored
//   Test 3: 500 random matrices, back to back, no reset between
// ============================================================
module tb_systolic_top;

    parameter N  = 4;
    parameter DW = 8;
    parameter AW = 32;
    localparam IW = (N <= 2) ? 1 : $clog2(N);
    localparam EXP_CYCLES = 3*N - 1;          // CLEAR 1 + FEED N + DRAIN 2N-2

    reg clk = 0, rst = 1;
    reg          wr_en = 0, wr_sel = 0;
    reg [IW-1:0] wr_row = 0, wr_col = 0, rd_row = 0, rd_col = 0;
    reg [DW-1:0] wr_data = 0;
    reg          start = 0;
    wire         busy, done;
    wire [15:0]  cycles;
    wire [AW-1:0] rd_data;

    systolic_top #(.N(N), .DW(DW), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_sel(wr_sel), .wr_row(wr_row), .wr_col(wr_col), .wr_data(wr_data),
        .start(start), .accumulate(1'b0), .busy(busy), .done(done), .cycles(cycles),
        .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data));

    always #5 clk = ~clk;

    reg signed [DW-1:0] A [0:N-1][0:N-1];
    reg signed [DW-1:0] B [0:N-1][0:N-1];
    integer             C [0:N-1][0:N-1];
    integer errors = 0, i, j, k, test, waited;

    // ---- "driver" tasks: what software would do ----
    task write_elem(input sel, input integer r, input integer c, input [DW-1:0] v);
        begin
            @(negedge clk);
            wr_en = 1; wr_sel = sel; wr_row = r; wr_col = c; wr_data = v;
            @(negedge clk);
            wr_en = 0;
        end
    endtask

    task load_matrices;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    write_elem(0, i, j, A[i][j]);
                    write_elem(1, i, j, B[i][j]);
                end
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
        end
    endtask

    // wait for done, with a timeout so a broken FSM cannot hang the sim
    task wait_done;
        begin
            waited = 0;
            while (!done && waited < 1000) begin
                @(negedge clk); waited = waited + 1;
            end
            if (!done) begin
                errors = errors + 1;
                $display("FAIL test %0d: done never came (timeout)", test);
            end
        end
    endtask

    task compute_reference;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    C[i][j] = 0;
                    for (k = 0; k < N; k = k + 1)
                        C[i][j] = C[i][j] + A[i][k] * B[k][j];
                end
        end
    endtask

    task check_result;
        begin
            if (cycles !== EXP_CYCLES) begin
                errors = errors + 1;
                $display("FAIL test %0d: cycles = %0d, expected %0d", test, cycles, EXP_CYCLES);
            end
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    rd_row = i; rd_col = j; #1;
                    if ($signed(rd_data) !== C[i][j]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL test %0d: C[%0d][%0d] = %0d, expected %0d",
                                     test, i, j, $signed(rd_data), C[i][j]);
                    end
                end
        end
    endtask

    task run_one;
        begin
            compute_reference;
            load_matrices;
            pulse_start;
            wait_done;
            check_result;
        end
    endtask

    initial begin
        $dumpfile("systolic_top.vcd");
        $dumpvars(0, tb_systolic_top);
        repeat (3) @(negedge clk);
        rst = 0;

        // ---- Test 1: walkthrough example ----
        test = 0;
        if (N == 4) begin
            A[0][0]=1; A[0][1]=2; A[0][2]=0; A[0][3]=-1;
            A[1][0]=3; A[1][1]=1; A[1][2]=2; A[1][3]=0;
            A[2][0]=0; A[2][1]=1; A[2][2]=1; A[2][3]=2;
            A[3][0]=2; A[3][1]=0; A[3][2]=1; A[3][3]=1;
            B[0][0]=1; B[0][1]=0; B[0][2]=2; B[0][3]=1;
            B[1][0]=2; B[1][1]=1; B[1][2]=0; B[1][3]=3;
            B[2][0]=1; B[2][1]=3; B[2][2]=1; B[2][3]=0;
            B[3][0]=0; B[3][1]=2; B[3][2]=1; B[3][3]=1;
            if (busy || done) begin
                errors = errors + 1;
                $display("FAIL: busy/done should be 0 after reset");
            end
            run_one;
            $display("Test 1 walkthrough example: start -> done in %0d clocks (expected %0d)",
                     cycles, EXP_CYCLES);
            $display("   C read back through the read port:");
            for (i = 0; i < N; i = i + 1) begin
                rd_row = i;
                rd_col = 0; #1; k = $signed(rd_data);
                rd_col = 1; #1; j = $signed(rd_data);
                $write("   %4d %4d", k, j);
                rd_col = 2; #1; k = $signed(rd_data);
                rd_col = 3; #1; j = $signed(rd_data);
                $display(" %4d %4d", k, j);
            end
        end

        // ---- Test 2: start and writes during busy are ignored ----
        test = 1;
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = $random; B[i][j] = $random;
            end
        compute_reference;
        load_matrices;
        pulse_start;
        @(negedge clk);
        if (!busy) begin
            errors = errors + 1;
            $display("FAIL test 1: busy not set after start");
        end
        // try to disturb the run: overwrite A[0][0] and pulse start again
        wr_en = 1; wr_sel = 0; wr_row = 0; wr_col = 0; wr_data = 8'h55; start = 1;
        @(negedge clk);
        wr_en = 0; start = 0;
        wait_done;
        check_result;
        // run again WITHOUT reloading: if the busy-time write had landed,
        // A[0][0] would now be 0x55 and this second result would be wrong
        pulse_start;
        wait_done;
        check_result;
        $display("Test 2 writes/start while busy ignored: %s", (errors == 0) ? "ok" : "FAILED");

        // ---- Test 3: random, back to back without reset ----
        for (test = 2; test < 502; test = test + 1) begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    A[i][j] = $random; B[i][j] = $random;
                end
            run_one;
        end
        $display("Test 3 random: 500 signed %0dx%0d runs, back to back, every run %0d clocks",
                 N, N, EXP_CYCLES);

        if (errors == 0) $display("PASS: systolic_top N=%0d, 0 errors", N);
        else             $display("FAIL: systolic_top N=%0d, %0d errors", N, errors);
        $finish;
    end

endmodule
