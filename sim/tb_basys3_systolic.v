`timescale 1ns/1ps
// ============================================================
// tb_basys3_systolic.v : the whole board design, driven only
// through the UART pin, exactly like the PC script does.
//
//   this TB = "the PC":  serial bytes --> RsRx
//                         RsTx       --> serial bytes back
//
// It runs the first TESTS jobs from step 6's NumPy vectors
// (the 9 corner cases + random ones) and checks every C.
// The UART runs at CLKS_PER_BIT = 16 instead of 868 so the
// simulation is fast; the logic is the same.
// ============================================================
module tb_basys3_systolic;

    parameter N     = 4;
    parameter CPB   = 16;            // clocks per UART bit (868 on the board)
    parameter TESTS = 10;            // jobs to run (up to 1000 in the vector files)
    parameter VEC   = 1000;          // tests stored in the step 6 vector files
    localparam BIT  = CPB * 10;      // one bit time in ns (10 ns clock)
    localparam [31:0] A_BASE = 32'h400, B_BASE = 32'h800, C_BASE = 32'hC00;
    localparam [31:0] CTRL = 32'h000, STATUS = 32'h004, CYCLES = 32'h008, ID = 32'h00C;

    reg  clk = 0, btnC = 1, RsRx = 1;
    wire RsTx;
    wire [15:0] led;
    wire [6:0]  seg;
    wire [3:0]  an;
    wire        dp;
    always #5 clk = ~clk;

    basys3_systolic #(.N(N), .CLKS_PER_BIT(CPB), .UART_TIMEOUT(100_000)) dut (
        .clk(clk), .btnC(btnC), .RsRx(RsRx), .RsTx(RsTx),
        .led(led), .seg(seg), .dp(dp), .an(an));

    // ---------------- serial line, 8N1, LSB first ----------------
    task send_byte(input [7:0] b);
        integer k;
        begin
            RsRx = 0; #(BIT);                         // start bit
            for (k = 0; k < 8; k = k + 1) begin RsRx = b[k]; #(BIT); end
            RsRx = 1; #(BIT);                         // stop bit
        end
    endtask

    task recv_byte(output [7:0] b);
        integer k;
        begin
            @(negedge RsTx);                          // start bit begins
            #(BIT + BIT/2);                           // middle of bit 0
            for (k = 0; k < 8; k = k + 1) begin b[k] = RsTx; #(BIT); end
        end
    endtask

    // ---------------- the bridge protocol (same as the Python script) ----------------
    reg [7:0]  st, d3, d2, d1, d0;
    reg [31:0] rdval;
    integer    errors = 0;

    task uart_write(input [31:0] a, input [31:0] d);
        begin
            fork
                begin
                    send_byte(8'h57);
                    send_byte(a[31:24]); send_byte(a[23:16]); send_byte(a[15:8]); send_byte(a[7:0]);
                    send_byte(d[31:24]); send_byte(d[23:16]); send_byte(d[15:8]); send_byte(d[7:0]);
                    send_byte(8'h0F);
                end
                recv_byte(st);
            join
            if (st !== 8'h00) begin
                errors = errors + 1;
                $display("FAIL: write 0x%h got response %h", a, st);
            end
        end
    endtask

    task uart_read(input [31:0] a);
        begin
            fork
                begin
                    send_byte(8'h52);
                    send_byte(a[31:24]); send_byte(a[23:16]); send_byte(a[15:8]); send_byte(a[7:0]);
                end
                begin
                    recv_byte(st); recv_byte(d3); recv_byte(d2); recv_byte(d1); recv_byte(d0);
                end
            join
            rdval = {d3, d2, d1, d0};
            if (st !== 8'h00) begin
                errors = errors + 1;
                $display("FAIL: read 0x%h got response %h", a, st);
            end
        end
    endtask

    // ---------------- vectors from step 6 (NumPy) ----------------
    reg [31:0] meta  [0:1];
    reg [7:0]  a_mem [0:VEC*N*N-1];
    reg [7:0]  b_mem [0:VEC*N*N-1];
    reg [31:0] c_mem [0:VEC*N*N-1];

    integer t, e, base, polls, bad_before;

    initial begin
        $readmemh("meta.mem", meta);
        $readmemh("a.mem", a_mem);
        $readmemh("b.mem", b_mem);
        $readmemh("c_expected.mem", c_mem);
        if (meta[0] !== N || meta[1] !== VEC) begin
            $display("FAIL: step 6 vector files missing or not N=%0d with %0d tests", N, VEC);
            $finish;
        end

        repeat (20) @(posedge clk);
        btnC = 0;
        repeat (50) @(posedge clk);

        // ping
        fork send_byte(8'h50); recv_byte(st); join
        $display("Ping reply: 0x%h %s", st, (st == 8'h50) ? "(ok)" : "(FAIL)");
        if (st !== 8'h50) errors = errors + 1;

        uart_read(ID);
        $display("ID over UART: 0x%h", rdval);
        if (rdval !== 32'h5A000408) errors = errors + 1;

        for (t = 0; t < TESTS; t = t + 1) begin
            base = t * N * N;
            bad_before = errors;
            for (e = 0; e < N*N; e = e + 1) begin
                uart_write(A_BASE + 4*e, {{24{a_mem[base+e][7]}}, a_mem[base+e]});
                uart_write(B_BASE + 4*e, {{24{b_mem[base+e][7]}}, b_mem[base+e]});
            end
            uart_write(CTRL, 32'h1);
            polls = 0; rdval = 0;
            while (rdval[1:0] != 2'b10 && polls < 20) begin uart_read(STATUS); polls = polls + 1; end
            uart_read(CYCLES);
            if (rdval !== 3*N-1) begin errors = errors + 1; $display("FAIL: CYCLES = %0d", rdval); end
            for (e = 0; e < N*N; e = e + 1) begin
                uart_read(C_BASE + 4*e);
                if (rdval !== c_mem[base+e]) begin
                    errors = errors + 1;
                    $display("FAIL test %0d C[%0d][%0d]: hw %0d, numpy %0d",
                             t, e / N, e % N, $signed(rdval), $signed(c_mem[base+e]));
                end
            end
            if (errors == bad_before) $display("  test %2d ok   (7-seg shows %h = C[3][3])", t, dut.shown);
            else                      $display("  test %2d FAILED", t);
        end

        if (errors == 0) $display("PASS: board design over UART, %0d jobs == NumPy", TESTS);
        else             $display("FAIL: board design over UART, %0d errors", errors);
        $finish;
    end

endmodule
