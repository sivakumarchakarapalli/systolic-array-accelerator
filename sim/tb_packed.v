`timescale 1ns/1ps
// ============================================================
// tb_packed.v : step 9a directed tests of the packed A/B writes
//
//  1. packed A and B, then a run: C must equal A x B
//  2. WSTRB: a partial packed write changes only the enabled bytes
//  3. mixing old one-element writes and packed writes
//  4. error responses: read of a packed address, past the end,
//     misaligned, and a packed write while the array is busy
//  5. back-to-back packed writes followed at once by CTRL
//  6. the same at full bus speed (one write every 2 clocks), which is
//     faster than the 4-clock sequencer: the slave must stall the bus
// ============================================================
module tb_packed;

    parameter N = 4;                     // array size (tiles are 4x4)
    localparam [31:0] A_PACK = 32'h100, B_PACK = 32'h200, C_BASE = 32'hC00;
    localparam [31:0] CTRL = 32'h000, STATUS = 32'h004;

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
        .awvalid(m_awvalid), .awready(awready), .awaddr(m_awaddr), .awprot(awprot),
        .wvalid(m_wvalid), .wready(wready), .wdata(m_wdata), .wstrb(m_wstrb),
        .bvalid(bvalid), .bready(m_bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

    // test 6 needs writes faster than axil_master makes them, so a raw
    // driver can take over the write channels (VALID held high, BREADY = 1)
    reg         raw = 0, raw_awvalid = 0, raw_wvalid = 0;
    reg  [31:0] raw_awaddr = 0, raw_wdata = 0;
    wire        m_awvalid, m_wvalid, m_bready;
    wire [31:0] m_awaddr, m_wdata;
    wire [3:0]  m_wstrb;
    assign awvalid = raw ? raw_awvalid : m_awvalid;
    assign awaddr  = raw ? raw_awaddr  : m_awaddr;
    assign wvalid  = raw ? raw_wvalid  : m_wvalid;
    assign wdata   = raw ? raw_wdata   : m_wdata;
    assign wstrb   = raw ? 4'hF        : m_wstrb;
    assign bready  = raw ? 1'b1        : m_bready;

    integer raw_bad = 0;                 // non-OKAY responses during the raw burst
    always @(posedge clk) if (raw && bvalid && bresp != 2'b00) raw_bad = raw_bad + 1;

    axil_systolic #(.N(N), .DW(8)) dut (
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

    // ---------------- "software" helpers (same as step 5) ----------------
    reg  [1:0]  last_resp;
    reg  [31:0] last_data;
    integer     errors = 0;
    reg         expect_err = 0;
    integer     n_wr = 0, n_rd = 0;          // bus transactions, for the report

    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            while (wr_busy) @(negedge clk);
            wr_req = 1; wr_addr = a; wr_data = d;
            @(negedge clk); wr_req = 0;
            @(posedge clk); while (!wr_done) @(posedge clk);
            #1 last_resp = wr_resp;
            n_wr = n_wr + 1;
            if (last_resp !== 2'b00) begin
                if (!expect_err) begin
                    errors = errors + 1;
                    $display("FAIL: write 0x%h got response %b", a, last_resp);
                end
            end
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
            n_rd = n_rd + 1;
        end
    endtask


    localparam [31:0] A_BASE = 32'h400, B_BASE = 32'h800;
    reg signed [7:0]  A [0:15], B [0:15];
    integer t, i, j, k, sum;

    // write the model arrays A, B as packed rows
    task load_packed;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                axi_write(A_PACK + 4*i, {A[i*4+3], A[i*4+2], A[i*4+1], A[i*4]});
                axi_write(B_PACK + 4*i, {B[i*4+3], B[i*4+2], B[i*4+1], B[i*4]});
            end
        end
    endtask

    task run_and_check(input [8*40-1:0] name);
        integer bad, polls;
        begin
            axi_write(CTRL, 32'h1);
            polls = 0; last_data = 0;
            while (last_data[1:0] != 2'b10 && polls < 100) begin axi_read(STATUS); polls = polls + 1; end
            bad = 0;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < 4; k = k + 1) sum = sum + A[i*4+k] * B[k*4+j];
                    axi_read(C_BASE + 4*(i*4+j));
                    if ($signed(last_data) !== sum) begin
                        bad = bad + 1;
                        if (bad <= 3) $display("   C[%0d][%0d] = %0d, expected %0d", i, j, $signed(last_data), sum);
                    end
                end
            errors = errors + bad;
            $display("%0s %0s", bad ? "FAIL" : "ok  ", name);
        end
    endtask

    task expect_resp(input [1:0] want, input [8*40-1:0] name);
        begin
            if (last_resp !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: response %b, expected %b", name, last_resp, want);
            end else
                $display("ok   %0s -> %0s", name, want == 2'b10 ? "SLVERR" : want == 2'b11 ? "DECERR" : "OKAY");
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // 1. random packed load
        for (t = 0; t < 3; t = t + 1) begin
            for (i = 0; i < 16; i = i + 1) begin A[i] = $random; B[i] = $random; end
            if (t == 2) begin A[0] = -128; B[0] = -128; A[5] = 127; B[5] = -128; end
            load_packed;
            run_and_check("1. packed A and B");
        end

        // 2. WSTRB = 0101: only bytes 0 and 2 of row 1 of A change
        wr_strb = 4'b0101;
        axi_write(A_PACK + 4, 32'h11223344);
        wr_strb = 4'hF;
        A[4] = 8'h44; A[6] = 8'h22;
        run_and_check("2. WSTRB partial write");

        // 3. one old single-element write on top of packed data
        axi_write(B_BASE + 4*(2*4+3), 32'hFFFFFF9C);  B[11] = -100;
        axi_write(A_BASE + 4*(3*4+0), 32'h00000005);  A[12] = 5;
        run_and_check("3. mixed old + packed");

        // 4. error responses
        expect_err = 1;
        axi_read(A_PACK);              expect_resp(2'b10, "4. read A packed");
        axi_read(B_PACK + 8);          expect_resp(2'b10, "4. read B packed");
        axi_write(A_PACK + 16, 0);     expect_resp(2'b11, "4. A packed word 4 (past end)");
        axi_write(B_PACK + 32'h40, 0); expect_resp(2'b11, "4. B packed +0x40 (past end)");
        axi_write(A_PACK + 2, 0);      expect_resp(2'b10, "4. misaligned packed write");
        axi_write(CTRL, 32'h1);        // start, then write while busy
        axi_write(A_PACK, 32'h7F7F7F7F); expect_resp(2'b10, "4. packed write while busy");
        expect_err = 0;
        last_data = 0;
        while (last_data[1:0] != 2'b10) axi_read(STATUS);
        run_and_check("4. data unchanged by errors");

        // 5. a fresh load, then CTRL right after the last packed write
        for (i = 0; i < 16; i = i + 1) begin A[i] = $random; B[i] = $random; end
        load_packed;
        run_and_check("5. CTRL right after packed");

        // 6. full-speed burst: 8 packed writes + CTRL with VALID always high
        for (i = 0; i < 16; i = i + 1) begin A[i] = $random; B[i] = $random; end
        @(negedge clk); raw = 1;
        for (t = 0; t < 9; t = t + 1) begin
            raw_awaddr = (t == 8) ? CTRL : (t[0] ? B_PACK : A_PACK) + 4*(t/2);
            raw_wdata  = (t == 8) ? 32'h1 :
                         t[0] ? {B[(t/2)*4+3], B[(t/2)*4+2], B[(t/2)*4+1], B[(t/2)*4]}
                              : {A[(t/2)*4+3], A[(t/2)*4+2], A[(t/2)*4+1], A[(t/2)*4]};
            raw_awvalid = 1; raw_wvalid = 1;
            @(posedge clk); while (!awready) @(posedge clk);   // AW and W share the same
            @(negedge clk);                                    // READY timing in this slave
        end
        raw_awvalid = 0; raw_wvalid = 0;
        repeat (4) @(negedge clk);
        raw = 0;
        last_data = 0;
        while (last_data[1:0] != 2'b10) axi_read(STATUS);
        if (raw_bad) begin errors = errors + raw_bad; $display("FAIL 6. %0d burst writes not OKAY", raw_bad); end
        // run_and_check starts again; that only recomputes the same A x B
        run_and_check("6. full-speed packed burst");

        $display("AXI protocol check : %0d violations", u_chk.errors);
        if (errors == 0 && u_chk.errors == 0) $display("PASS: packed writes");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
