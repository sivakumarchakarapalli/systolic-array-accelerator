`timescale 1ns/1ps
// =====================================================================
// axil_master.v  -  AXI4-Lite master (protocol-compliant rewrite)
//
// What changed vs. the first version (master.v):
//   * AWVALID and WVALID are raised together and each one is held high
//     until ITS OWN handshake (VALID && READY) happens, then dropped.
//     -> never waits for AWREADY before WVALID (no deadlock with slaves
//        that wait for both), never leaves VALID high after the handshake.
//   * AWADDR/WDATA/WSTRB/ARADDR are registered at launch and stay stable
//     while VALID is high.
//   * BREADY / RREADY are raised at launch, so the response is taken on
//     the first cycle the slave offers it. "done" fires on the real
//     B / R handshake, not one cycle early.
//   * BRESP / RRESP are captured and returned to the user (wr_resp, rd_resp).
//   * WSTRB byte enables and AWPROT/ARPROT are driven.
//   * Write and read engines are independent, so a write and a read can
//     be in flight at the same time.
// =====================================================================
module axil_master (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high

    // ---------------- user write command ----------------
    input  wire        wr_req,         // 1-cycle request, sampled when !wr_busy
    input  wire [31:0] wr_addr,
    input  wire [31:0] wr_data,
    input  wire [3:0]  wr_strb,        // byte enables, bit i -> wr_data[8i+7:8i]
    output wire        wr_busy,
    output reg         wr_done,        // 1-cycle pulse on the B handshake
    output reg  [1:0]  wr_resp,        // BRESP of the finished write

    // ---------------- user read command -----------------
    input  wire        rd_req,
    input  wire [31:0] rd_addr,
    output wire        rd_busy,
    output reg         rd_done,        // 1-cycle pulse on the R handshake
    output reg  [31:0] rd_data,
    output reg  [1:0]  rd_resp,        // RRESP of the finished read

    // ---------------- AXI4-Lite: write address ----------
    output reg         awvalid,
    input  wire        awready,
    output reg  [31:0] awaddr,
    output wire [2:0]  awprot,
    // ---------------- AXI4-Lite: write data -------------
    output reg         wvalid,
    input  wire        wready,
    output reg  [31:0] wdata,
    output reg  [3:0]  wstrb,
    // ---------------- AXI4-Lite: write response ---------
    input  wire        bvalid,
    output reg         bready,
    input  wire [1:0]  bresp,
    // ---------------- AXI4-Lite: read address -----------
    output reg         arvalid,
    input  wire        arready,
    output reg  [31:0] araddr,
    output wire [2:0]  arprot,
    // ---------------- AXI4-Lite: read data --------------
    input  wire        rvalid,
    output reg         rready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp
);

    assign awprot = 3'b000;            // unprivileged, secure, data access
    assign arprot = 3'b000;

    localparam W_IDLE = 1'b0, W_BUSY = 1'b1;
    localparam R_IDLE = 1'b0, R_BUSY = 1'b1;

    reg w_state, r_state;

    assign wr_busy = (w_state == W_BUSY);
    assign rd_busy = (r_state == R_BUSY);

    // ================= WRITE ENGINE =================
    always @(posedge clk) begin
        if (reset) begin
            w_state <= W_IDLE;
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            bready  <= 1'b0;
            awaddr  <= 32'd0;
            wdata   <= 32'd0;
            wstrb   <= 4'd0;
            wr_done <= 1'b0;
            wr_resp <= 2'b00;
        end else begin
            wr_done <= 1'b0;                       // pulse by default

            case (w_state)
            W_IDLE: if (wr_req) begin
                awaddr  <= wr_addr;                // payload is frozen here...
                wdata   <= wr_data;
                wstrb   <= wr_strb;
                awvalid <= 1'b1;                   // ...and both VALIDs go up together
                wvalid  <= 1'b1;
                bready  <= 1'b1;                   // ready for the response early
                w_state <= W_BUSY;
            end

            W_BUSY: begin
                // each VALID drops only after its own handshake
                if (awvalid && awready) awvalid <= 1'b0;
                if (wvalid  && wready)  wvalid  <= 1'b0;

                // the slave may only raise BVALID after both AW and W
                // handshakes, so when B completes the transfer is over
                if (bvalid && bready) begin
                    bready  <= 1'b0;
                    wr_resp <= bresp;
                    wr_done <= 1'b1;
                    w_state <= W_IDLE;
                end
            end
            endcase
        end
    end

    // ================= READ ENGINE ==================
    always @(posedge clk) begin
        if (reset) begin
            r_state <= R_IDLE;
            arvalid <= 1'b0;
            rready  <= 1'b0;
            araddr  <= 32'd0;
            rd_done <= 1'b0;
            rd_data <= 32'd0;
            rd_resp <= 2'b00;
        end else begin
            rd_done <= 1'b0;

            case (r_state)
            R_IDLE: if (rd_req) begin
                araddr  <= rd_addr;
                arvalid <= 1'b1;
                rready  <= 1'b1;
                r_state <= R_BUSY;
            end

            R_BUSY: begin
                if (arvalid && arready) arvalid <= 1'b0;

                if (rvalid && rready) begin
                    rready  <= 1'b0;
                    rd_data <= rdata;
                    rd_resp <= rresp;
                    rd_done <= 1'b1;
                    r_state <= R_IDLE;
                end
            end
            endcase
        end
    end

endmodule
