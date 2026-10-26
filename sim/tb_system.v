`timescale 1ns/1ps
// ============================================================
// tb_system.v : full-system test against the Python/NumPy model
//
//   golden.py (NumPy) --> a.mem, b.mem, c_expected.mem, meta.mem
//                              |
//   tb_system: $readmemh --> axil_master --AXI4-Lite--> axil_systolic
//                              |                 (+ axil_checker)
//                    compare C with c_expected.mem
//                    write hw_results.txt  --> golden.py check
//
// The testbench has no reference model of its own: every expected
// value comes from NumPy. It only moves data and compares.
// ============================================================
module tb_system;

    parameter N    = 4;
    parameter DW   = 8;
    parameter MAXW = 65536;          // room for up to 65536 elements per file
    localparam [31:0] A_BASE = 32'h400, B_BASE = 32'h800, C_BASE = 32'hC00;
    localparam [31:0] CTRL = 32'h000, STATUS = 32'h004, CYCLES = 32'h008, ID = 32'h00C;
    localparam [1:0]  OKAY = 2'b00;

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;            // 100 MHz

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

    // ---------------- vectors from Python ----------------
    reg [31:0]   meta  [0:1];        // meta[0] = N, meta[1] = number of tests
    reg [DW-1:0] a_mem [0:MAXW-1];
    reg [DW-1:0] b_mem [0:MAXW-1];
    reg [31:0]   c_mem [0:MAXW-1];

    // ---------------- "software" helpers (same as step 5) ----------------
    reg  [1:0]  last_resp;
    reg  [31:0] last_data;

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

    integer tests, t, e, base, polls, fout;
    integer errors = 0, bad_tests = 0, errors_before;
    integer cyc = 0, t_start, total_clocks;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        $readmemh("meta.mem", meta);
        tests = meta[1];
        if (meta[0] !== N || tests < 1 || tests * N * N > MAXW) begin
            $display("FAIL: vector files missing or for the wrong N (meta N=%0d, tests=%0d, TB N=%0d)",
                     meta[0], meta[1], N);
            $finish;
        end
        $readmemh("a.mem", a_mem, 0, tests*N*N-1);
        $readmemh("b.mem", b_mem, 0, tests*N*N-1);
        $readmemh("c_expected.mem", c_mem, 0, tests*N*N-1);
        $display("Loaded %0d tests for N=%0d from the Python/NumPy model", tests, N);

        fout = $fopen("hw_results.txt", "w");
        repeat (3) @(negedge clk);
        reset = 0;

        axi_read(ID);
        if (last_data[15:8] !== N) begin
            $display("FAIL: ID register says N=%0d, vectors are for N=%0d", last_data[15:8], N);
            errors = errors + 1;
        end

        t_start = cyc;
        for (t = 0; t < tests; t = t + 1) begin
            base = t * N * N;
            errors_before = errors;

            // 1. load A and B (sign-extend each INT8 into the 32-bit word)
            for (e = 0; e < N*N; e = e + 1) begin
                axi_write(A_BASE + 4*e, {{24{a_mem[base+e][DW-1]}}, a_mem[base+e]});
                if (last_resp !== OKAY) errors = errors + 1;
                axi_write(B_BASE + 4*e, {{24{b_mem[base+e][DW-1]}}, b_mem[base+e]});
                if (last_resp !== OKAY) errors = errors + 1;
            end

            // 2. start and poll STATUS until done
            axi_write(CTRL, 32'h1);
            polls = 0; last_data = 0;
            while (last_data[1:0] != 2'b10 && polls < 100) begin
                axi_read(STATUS); polls = polls + 1;
            end
            if (polls >= 100) begin
                errors = errors + 1;
                $display("FAIL test %0d: never finished", t);
            end

            // 3. read C, compare with NumPy, save for golden.py check
            for (e = 0; e < N*N; e = e + 1) begin
                axi_read(C_BASE + 4*e);
                $fdisplay(fout, "%08h", last_data);
                if (last_resp !== OKAY || last_data !== c_mem[base+e]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("FAIL test %0d C[%0d][%0d]: hw %0d, numpy %0d",
                                 t, e / N, e % N, $signed(last_data), $signed(c_mem[base+e]));
                end
            end
            if (errors != errors_before) bad_tests = bad_tests + 1;

            if (t < 9 || (t + 1) % 250 == 0) begin
                if (errors == errors_before) $display("  test %4d ok", t);
                else                         $display("  test %4d FAILED", t);
            end
        end
        total_clocks = cyc - t_start;
        $fclose(fout);

        $display("----------------------------------------------------------");
        $display("Tests run         : %0d (%0d failed)", tests, bad_tests);
        $display("Results compared  : %0d", tests * N * N);
        $display("Bus clocks / job  : %0d   (compute only: %0d)", total_clocks / tests, 3*N-1);
        $display("MACs / job        : %0d", N*N*N);
        $display("At 100 MHz        : %0d jobs/s, %0d MMAC/s over AXI4-Lite",
                 100_000_000 / (total_clocks / tests),
                 (100 * N*N*N) / (total_clocks / tests));
        $display("AXI protocol check: %0d violations", u_chk.errors);
        $display("Hardware C values written to hw_results.txt");
        if (errors == 0 && u_chk.errors == 0)
            $display("PASS: system test N=%0d, hardware == NumPy on all %0d tests", N, tests);
        else
            $display("FAIL: system test N=%0d, %0d errors, %0d protocol violations",
                     N, errors, u_chk.errors);
        $finish;
    end

endmodule
