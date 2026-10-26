`timescale 1ns/1ps
// ============================================================
// tb_systolic_core.v : self-checking testbench for the N x N array
//
//   Test 1: the walkthrough example (same A and B as the diagram).
//           Prints C and checks that PE(i,j) is final exactly
//           after clock i+j+N (the finish-time table).
//   Test 2: 500 random signed INT8 matrix pairs.
//
// The testbench does NOT skew any more. On clock t (t = 1..N) it
// simply presents column t-1 of A and row t-1 of B, all N values
// at once, then zeros. The skew.v hardware makes the staircase.
// ============================================================
module tb_systolic_core;

    parameter N  = 4;
    parameter DW = 8;
    parameter AW = 32;
    localparam T = 3*N - 2;              // clocks to finish

    reg clk = 0, rst = 1, clear = 0;
    reg  [N*DW-1:0]   a_col_flat = 0, b_row_flat = 0;
    wire [N*N*AW-1:0] acc_flat;

    systolic_core #(.N(N), .DW(DW), .AW(AW)) dut (
        .clk(clk), .rst(rst), .clear(clear),
        .a_col_flat(a_col_flat), .b_row_flat(b_row_flat),
        .acc_flat(acc_flat));

    always #5 clk = ~clk;

    // test matrices and the reference result
    reg signed [DW-1:0] A [0:N-1][0:N-1];
    reg signed [DW-1:0] B [0:N-1][0:N-1];
    integer             C [0:N-1][0:N-1];

    integer errors = 0, timing_errors = 0;
    integer i, j, k, t, test;

    // read PE(i,j)'s accumulator out of the flat bus
    function signed [AW-1:0] acc_of(input integer r, input integer c);
        acc_of = acc_flat[(r*N+c)*AW +: AW];
    endfunction

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

    // clear, then feed T skewed clocks; check each PE when it finishes
    task run_matrix(input check_timing);
        begin
            compute_reference;
            @(negedge clk); clear = 1; a_col_flat = 0; b_row_flat = 0;
            for (t = 1; t <= T; t = t + 1) begin
                @(negedge clk);
                clear = 0;
                // no skew here: column k of A and row k of B, all at once
                k = t - 1;
                for (i = 0; i < N; i = i + 1)
                    a_col_flat[i*DW +: DW] = (k < N) ? A[i][k] : 0;
                for (j = 0; j < N; j = j + 1)
                    b_row_flat[j*DW +: DW] = (k < N) ? B[k][j] : 0;
                // just after this posedge, clock t has happened
                @(posedge clk); #1;
                if (check_timing)
                    for (i = 0; i < N; i = i + 1)
                        for (j = 0; j < N; j = j + 1)
                            if (i + j + N == t && acc_of(i, j) !== C[i][j]) begin
                                timing_errors = timing_errors + 1;
                                $display("TIMING FAIL: PE(%0d,%0d) not final after clock %0d", i, j, t);
                            end
            end
            @(negedge clk); a_col_flat = 0; b_row_flat = 0;
            // final check of every PE
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    if (acc_of(i, j) !== C[i][j]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL test %0d: C[%0d][%0d] = %0d, expected %0d",
                                     test, i, j, acc_of(i, j), C[i][j]);
                    end
        end
    endtask

    initial begin
        $dumpfile("systolic_core.vcd");
        $dumpvars(0, tb_systolic_core);
        repeat (3) @(negedge clk);
        rst = 0;

        // ---- Test 1: walkthrough example (N = 4 only) ----
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
            run_matrix(1);
            $display("Test 1 walkthrough example, C from the array:");
            for (i = 0; i < N; i = i + 1)
                $display("   %4d %4d %4d %4d", acc_of(i,0), acc_of(i,1), acc_of(i,2), acc_of(i,3));
            $display("   finish-time check: %0d timing errors (PE(i,j) final after clock i+j+%0d, last = %0d)",
                     timing_errors, N, T);
        end

        // ---- Test 2: random signed matrices ----
        for (test = 1; test <= 500; test = test + 1) begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    A[i][j] = $random;
                    B[i][j] = $random;
                end
            run_matrix(test <= 20);        // timing check on the first 20 too
        end
        $display("Test 2 random: 500 signed %0dx%0d matrix multiplies checked", N, N);

        if (errors == 0 && timing_errors == 0)
            $display("PASS: systolic_core N=%0d, 0 errors", N);
        else
            $display("FAIL: systolic_core N=%0d, %0d value errors, %0d timing errors",
                     N, errors, timing_errors);
        $finish;
    end

endmodule
