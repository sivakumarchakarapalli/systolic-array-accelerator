`timescale 1ns/1ps
// ============================================================
// tb_mnist.v : handwritten-digit recognition on the accelerator
//
// The testbench plays the role of the CPU / PC software:
//   for each batch of 4 images:
//     layer 1: [4 x 196] @ W1 [196 x 32]  as 49 x 8  = 392 tiled 4x4 runs
//     CPU    : + bias, ReLU, requantize INT32 -> INT8
//     layer 2: [4 x 32]  @ W2 [32 x 12]   as  8 x 3  =  24 tiled 4x4 runs
//     CPU    : + bias, argmax -> digit
// A long K is handled with the accumulate mode (CTRL = 3):
// the first K-tile clears C, the next ones add to it.
//
// Every score is compared with the INT8 NumPy model (mnist_model.py),
// so hardware and Python must agree bit for bit.
// ============================================================
module tb_mnist;

    parameter N = 4;                     // array size (tiles are 4x4)
    localparam [31:0] A_BASE = 32'h400, B_BASE = 32'h800, C_BASE = 32'hC00;
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
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

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

    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            while (wr_busy) @(negedge clk);
            wr_req = 1; wr_addr = a; wr_data = d;
            @(negedge clk); wr_req = 0;
            @(posedge clk); while (!wr_done) @(posedge clk);
            #1 last_resp = wr_resp;
            if (last_resp !== 2'b00) begin
                errors = errors + 1;
                $display("FAIL: write 0x%h got response %b", a, last_resp);
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
        end
    endtask

    // ---------------- the network, from mnist_model.py ----------------
    localparam MAXIMG = 1000;
    reg  [31:0] meta   [0:5];            // images, D_IN, HID, N_PAD, M, S
    reg  [7:0]  x_mem  [0:MAXIMG*196-1];
    reg  [7:0]  w1_mem [0:196*32-1];
    reg  [31:0] b1_mem [0:31];
    reg  [7:0]  w2_mem [0:32*12-1];
    reg  [31:0] b2_mem [0:11];
    reg  [31:0] score_mem [0:MAXIMG*12-1];
    reg  [7:0]  label_mem [0:MAXIMG-1];

    integer n_img, d_in, hid, n_pad, rq_m, rq_s;
    integer img0;                        // first image of the current batch
    integer outbuf [0:4*32-1];           // INT32 results of one layer, 4 rows
    integer h      [0:4*32-1];           // INT8 hidden activations, 4 rows
    integer runs = 0;

    // C[4 x nout] = A[4 x k] @ W[k x nout] using 4x4 tiles
    //   layer 1: A = images (x_mem), W = W1     layer 2: A = h, W = W2
    task gemm(input integer layer);
        integer k, nout, nt, kt, i, j, polls;
        reg [7:0] av, bv;
        begin
            k    = (layer == 1) ? d_in : hid;
            nout = (layer == 1) ? hid  : n_pad;
            for (nt = 0; nt < nout / 4; nt = nt + 1) begin
                for (kt = 0; kt < k / 4; kt = kt + 1) begin
                    for (i = 0; i < 4; i = i + 1)
                        for (j = 0; j < 4; j = j + 1) begin
                            if (layer == 1) begin
                                av = x_mem[(img0 + i) * d_in + kt*4 + j];
                                bv = w1_mem[(kt*4 + i) * hid + nt*4 + j];
                            end else begin
                                av = h[i * hid + kt*4 + j];
                                bv = w2_mem[(kt*4 + i) * n_pad + nt*4 + j];
                            end
                            axi_write(A_BASE + 4*(i*4 + j), {{24{av[7]}}, av});
                            axi_write(B_BASE + 4*(i*4 + j), {{24{bv[7]}}, bv});
                        end
                    // first K-tile: start (clear C). Others: start + accumulate.
                    axi_write(CTRL, (kt == 0) ? 32'h1 : 32'h3);
                    runs = runs + 1;
                    polls = 0; last_data = 0;
                    while (last_data[1:0] != 2'b10 && polls < 100) begin
                        axi_read(STATUS); polls = polls + 1;
                    end
                end
                for (i = 0; i < 4; i = i + 1)
                    for (j = 0; j < 4; j = j + 1) begin
                        axi_read(C_BASE + 4*(i*4 + j));
                        outbuf[i * nout + nt*4 + j] = $signed(last_data);
                    end
            end
        end
    endtask

    // the "CPU" part between the layers: bias, ReLU, requantize to INT8
    task bias_relu_requant;
        integer i, j, v;
        reg signed [63:0] t;
        begin
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < hid; j = j + 1) begin
                    v = outbuf[i*hid + j] + $signed(b1_mem[j]);
                    if (v < 0) v = 0;                                  // ReLU
                    t = ($signed({32'd0, v}) * rq_m + (64'sd1 <<< (rq_s - 1))) >>> rq_s;
                    h[i*hid + j] = (t > 127) ? 127 : t;
                end
        end
    endtask

    // print an image as ASCII art (14x14)
    task show_image(input integer img);
        integer r, c, p;
        reg [8*14-1:0] line;
        begin
            for (r = 0; r < 14; r = r + 1) begin
                line = "";
                for (c = 0; c < 14; c = c + 1) begin
                    p = x_mem[img*196 + r*14 + c];
                    line = {line[8*13-1:0], (p > 80) ? "#" : (p > 30) ? "+" : (p > 8) ? "." : " "};
                end
                $display("      |%s|", line);
            end
        end
    endtask

    integer b, i, j, best, best_j, s, correct = 0, agree = 0, t_start, clocks;
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        $readmemh("mnist_meta.mem", meta);
        n_img = meta[0]; d_in = meta[1]; hid = meta[2]; n_pad = meta[3]; rq_m = meta[4]; rq_s = meta[5];
        if (d_in !== 196 || hid !== 32 || n_pad !== 12 || n_img % 4 != 0 || n_img > MAXIMG) begin
            $display("FAIL: mnist vector files missing or unexpected (meta %0d %0d %0d %0d)",
                     n_img, d_in, hid, n_pad);
            $finish;
        end
        $readmemh("x.mem", x_mem, 0, n_img*196-1);
        $readmemh("w1.mem", w1_mem);
        $readmemh("b1.mem", b1_mem);
        $readmemh("w2.mem", w2_mem);
        $readmemh("b2.mem", b2_mem);
        $readmemh("scores.mem", score_mem, 0, n_img*12-1);
        $readmemh("labels.mem", label_mem, 0, n_img-1);
        $display("MNIST on the systolic array: %0d images, network 196 -> 32 -> 10, INT8", n_img);
        $display("  requantize: h = (acc * %0d) >> %0d", rq_m, rq_s);
        $display("  first test image:");
        show_image(0);

        repeat (3) @(negedge clk);
        reset = 0;
        t_start = cyc;

        for (b = 0; b < n_img / 4; b = b + 1) begin
            img0 = b * 4;
            gemm(1);
            bias_relu_requant;
            gemm(2);
            for (i = 0; i < 4; i = i + 1) begin
                best = 0; best_j = 0;
                for (j = 0; j < n_pad; j = j + 1) begin
                    s = outbuf[i*n_pad + j] + $signed(b2_mem[j]);
                    if (s !== $signed(score_mem[(img0+i)*12 + j])) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL image %0d score[%0d]: hw %0d, numpy %0d",
                                     img0+i, j, s, $signed(score_mem[(img0+i)*12 + j]));
                    end
                    if (j == 0 || s > best) begin best = s; best_j = j; end
                end
                if (best_j == label_mem[img0+i]) correct = correct + 1;
                if (best_j == label_mem[img0+i])
                    $display("  image %3d: FPGA says %0d, label %0d", img0+i, best_j, label_mem[img0+i]);
                else
                    $display("  image %3d: FPGA says %0d, label %0d  <-- wrong digit", img0+i, best_j, label_mem[img0+i]);
            end
        end
        clocks = cyc - t_start;

        $display("----------------------------------------------------------");
        $display("Digits correct     : %0d / %0d", correct, n_img);
        $display("Scores vs NumPy    : %0d mismatches (bit-exact check of all %0d scores)",
                 errors, n_img * 12);
        $display("Accelerator runs   : %0d (416 per batch of 4 images)", runs);
        $display("Clocks per image   : %0d over AXI4-Lite", clocks / n_img);
        $display("Array busy         : %0d of %0d clocks = %0d.%0d%%", runs * 11, clocks,
                 (runs * 11 * 100) / clocks, ((runs * 11 * 1000) / clocks) % 10);
        $display("At 100 MHz         : %0d images/s", 100_000_000 / (clocks / n_img));
        $display("AXI protocol check : %0d violations", u_chk.errors);
        if (errors == 0 && u_chk.errors == 0)
            $display("PASS: MNIST on hardware == INT8 NumPy model on all %0d images", n_img);
        else
            $display("FAIL: %0d errors, %0d protocol violations", errors, u_chk.errors);
        $finish;
    end

endmodule
