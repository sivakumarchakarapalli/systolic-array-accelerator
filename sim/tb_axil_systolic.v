`timescale 1ns/1ps
// ============================================================
// tb_axil_systolic.v : the accelerator driven over AXI4-Lite
//
//   axil_master (your AXI project) --AXI4-Lite--> axil_systolic
//                         |
//                   axil_checker (protocol rules R1-R6)
//
// The testbench acts like CPU software: write A and B registers,
// write CTRL.start, poll STATUS, read CYCLES and C.
//   Test 1: ID register and the walkthrough example
//   Test 2: error responses (SLVERR / DECERR)
//   Test 3: writes while busy are refused and do not corrupt data
//   Test 4: 200 random matrices
// Also measures how many clocks one full job takes over the bus.
// ============================================================
module tb_axil_systolic;

    parameter N  = 4;
    parameter DW = 8;
    localparam [31:0] A_BASE = 32'h400, B_BASE = 32'h800, C_BASE = 32'hC00;
    localparam [31:0] CTRL = 32'h000, STATUS = 32'h004, CYCLES = 32'h008, ID = 32'h00C;
    localparam [1:0]  OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    // ---------------- user side of the master ----------------
    reg         wr_req = 0, rd_req = 0;
    reg  [31:0] wr_addr = 0, wr_data = 0, rd_addr = 0;
    reg  [3:0]  wr_strb = 4'hF;
    wire        wr_busy, wr_done, rd_busy, rd_done;
    wire [1:0]  wr_resp, rd_resp;
    wire [31:0] rd_data;

    // ---------------- AXI4-Lite bus ----------------
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [3:0]  wstrb;
    wire [2:0]  awprot, arprot;
    wire [1:0]  bresp, rresp;

    axil_master u_master (
        .clk(clk), .reset(reset),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
        .wr_busy(wr_busy), .wr_done(wr_done), .wr_resp(wr_resp),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_busy(rd_busy), .rd_done(rd_done),
        .rd_data(rd_data), .rd_resp(rd_resp),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

    axil_systolic #(.N(N), .DW(DW)) dut (
        .clk(clk), .reset(reset),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

    axil_checker u_chk (
        .clk(clk), .reset(reset),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

    // ---------------- "software" helpers ----------------
    reg  [1:0]  last_resp;
    reg  [31:0] last_data;
    integer errors = 0;

    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            while (wr_busy) @(negedge clk);
            wr_req = 1; wr_addr = a; wr_data = d;
            @(negedge clk); wr_req = 0;
            @(posedge clk); while (!wr_done) @(posedge clk);
            #1 last_resp = wr_resp;
        end
    endtask

    task axi_read(input [31:0] a);
        begin
            @(negedge clk);
            while (rd_busy) @(negedge clk);
            rd_req = 1; rd_addr = a;
            @(negedge clk); rd_req = 0;
            @(posedge clk); while (!rd_done) @(posedge clk);
            #1 begin last_resp = rd_resp; last_data = rd_data; end
        end
    endtask

    task expect_resp(input [1:0] want, input [8*32-1:0] what);
        begin
            if (last_resp !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: resp %b, expected %b", what, last_resp, want);
            end
        end
    endtask

    reg signed [DW-1:0] A [0:N-1][0:N-1];
    reg signed [DW-1:0] B [0:N-1][0:N-1];
    integer             C [0:N-1][0:N-1];
    integer i, j, k, test, polls, t0, bus_clocks;
    integer cyc;
    initial cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

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

    task load_ab;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    axi_write(A_BASE + 4*(i*N+j), {{24{A[i][j][DW-1]}}, A[i][j]});
                    expect_resp(OKAY, "write A");
                    axi_write(B_BASE + 4*(i*N+j), {{24{B[i][j][DW-1]}}, B[i][j]});
                    expect_resp(OKAY, "write B");
                end
        end
    endtask

    task start_and_wait;
        begin
            axi_write(CTRL, 32'h1);
            expect_resp(OKAY, "CTRL start");
            polls = 0;
            last_data = 0;
            while (last_data[1:0] != 2'b10 && polls < 100) begin   // done=1, busy=0
                axi_read(STATUS);
                polls = polls + 1;
            end
            if (polls >= 100) begin
                errors = errors + 1;
                $display("FAIL test %0d: STATUS never showed done", test);
            end
        end
    endtask

    task check_c;
        begin
            axi_read(CYCLES);
            if (last_data !== 3*N-1) begin
                errors = errors + 1;
                $display("FAIL test %0d: CYCLES = %0d, expected %0d", test, last_data, 3*N-1);
            end
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    axi_read(C_BASE + 4*(i*N+j));
                    if (last_resp !== OKAY || $signed(last_data) !== C[i][j]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL test %0d: C[%0d][%0d] = %0d (resp %b), expected %0d",
                                     test, i, j, $signed(last_data), last_resp, C[i][j]);
                    end
                end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // ---- Test 1: ID + walkthrough example ----
        test = 0;
        axi_read(ID);
        $display("Test 1 ID register = 0x%h", last_data);
        if (last_data !== (32'h5A00_0000 | (N << 8) | DW)) begin
            errors = errors + 1; $display("FAIL: wrong ID");
        end
        if (N == 4) begin
            A[0][0]=1; A[0][1]=2; A[0][2]=0; A[0][3]=-1;
            A[1][0]=3; A[1][1]=1; A[1][2]=2; A[1][3]=0;
            A[2][0]=0; A[2][1]=1; A[2][2]=1; A[2][3]=2;
            A[3][0]=2; A[3][1]=0; A[3][2]=1; A[3][3]=1;
            B[0][0]=1; B[0][1]=0; B[0][2]=2; B[0][3]=1;
            B[1][0]=2; B[1][1]=1; B[1][2]=0; B[1][3]=3;
            B[2][0]=1; B[2][1]=3; B[2][2]=1; B[2][3]=0;
            B[3][0]=0; B[3][1]=2; B[3][2]=1; B[3][3]=1;
            compute_reference;
            t0 = cyc;
            load_ab;
            start_and_wait;
            check_c;
            bus_clocks = cyc - t0;
            $display("   C read over AXI:");
            for (i = 0; i < N; i = i + 1) begin
                $write("  ");
                for (j = 0; j < N; j = j + 1) begin
                    axi_read(C_BASE + 4*(i*N+j));
                    $write(" %4d", $signed(last_data));
                end
                $write("\n");
            end
            $display("   one full job over the bus: %0d clocks (compute itself: %0d clocks)",
                     bus_clocks, 3*N-1);
        end

        // ---- Test 2: error responses ----
        axi_read (A_BASE);           expect_resp(SLVERR, "read A (write-only)");
        axi_read (B_BASE + 4);       expect_resp(SLVERR, "read B (write-only)");
        axi_write(C_BASE, 32'h1);    expect_resp(SLVERR, "write C (read-only)");
        axi_write(STATUS, 32'h1);    expect_resp(SLVERR, "write STATUS (read-only)");
        axi_write(ID, 32'h1);        expect_resp(SLVERR, "write ID (read-only)");
        axi_read (A_BASE + 2);       expect_resp(SLVERR, "misaligned read");
        axi_write(B_BASE + 1, 0);    expect_resp(SLVERR, "misaligned write");
        axi_read (32'h1000);         expect_resp(DECERR, "read unmapped 0x1000");
        axi_write(32'h0010, 0);      expect_resp(DECERR, "write unmapped 0x010");
        axi_read (A_BASE + 4*N*N);   expect_resp(DECERR, "read past end of A");
        axi_read (C_BASE + 4*N*N);   expect_resp(DECERR, "read past end of C");
        $display("Test 2 error responses (SLVERR/DECERR): %s", (errors == 0) ? "ok" : "FAILED");

        // ---- Test 3: writes while busy are refused ----
        test = 1;
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin A[i][j] = $random; B[i][j] = $random; end
        compute_reference;
        load_ab;
        axi_write(CTRL, 32'h1);                    expect_resp(OKAY,   "start");
        axi_write(A_BASE, 32'h55);                 expect_resp(SLVERR, "write A while busy");
        axi_write(CTRL, 32'h1);                    expect_resp(SLVERR, "start while busy");
        polls = 0; last_data = 0;
        while (last_data[1:0] != 2'b10 && polls < 100) begin axi_read(STATUS); polls = polls + 1; end
        check_c;
        start_and_wait;                            // rerun, no reload: A[0][0] must be unchanged
        check_c;
        $display("Test 3 writes while busy refused, data intact: %s", (errors == 0) ? "ok" : "FAILED");

        // ---- Test 4: random ----
        for (test = 2; test < 202; test = test + 1) begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin A[i][j] = $random; B[i][j] = $random; end
            compute_reference;
            load_ab;
            start_and_wait;
            check_c;
        end
        $display("Test 4 random: 200 signed %0dx%0d jobs over AXI4-Lite", N, N);
        $display("AXI protocol checker: %0d violations", u_chk.errors);

        if (errors == 0 && u_chk.errors == 0) $display("PASS: axil_systolic N=%0d, 0 errors", N);
        else $display("FAIL: axil_systolic N=%0d, %0d errors, %0d protocol violations",
                      N, errors, u_chk.errors);
        $finish;
    end

endmodule
