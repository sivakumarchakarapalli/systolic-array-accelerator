`timescale 1ns/1ps
// =====================================================================
// axil_checker.v  -  passive AXI4-Lite protocol monitor (simulation only)
//
// Watches the bus every rising edge and reports a violation of:
//   R1  once VALID is high it must stay high until READY (handshake)
//   R2  the payload (addr / data / strb / resp) must not change while
//       VALID is high and READY is low
//   R3  BVALID only after BOTH the AW and the W handshake of that write
//   R4  RVALID only after the AR handshake of that read
//   R5  no X/Z on VALID/READY out of reset
//   R6  EXOKAY (2'b01) is not allowed in AXI4-Lite
// Plain Verilog-2005, so it runs in iverilog and in Vivado xsim.
// =====================================================================
module axil_checker (
    input wire        clk, reset,
    input wire        awvalid, awready, input wire [31:0] awaddr,
    input wire        wvalid,  wready,  input wire [31:0] wdata, input wire [3:0] wstrb,
    input wire        bvalid,  bready,  input wire [1:0]  bresp,
    input wire        arvalid, arready, input wire [31:0] araddr,
    input wire        rvalid,  rready,  input wire [31:0] rdata, input wire [1:0] rresp
);
    integer errors = 0;
    integer aw_cnt = 0, w_cnt = 0, b_cnt = 0, ar_cnt = 0, r_cnt = 0;

    // previous-cycle snapshot
    reg        p_aw_wait, p_w_wait, p_b_wait, p_ar_wait, p_r_wait;
    reg [31:0] p_awaddr, p_wdata, p_araddr, p_rdata;
    reg [3:0]  p_wstrb;
    reg [1:0]  p_bresp, p_rresp;

    task fail(input [8*48-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("[%0t] AXI CHECKER: %0s", $time, msg);
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            p_aw_wait = 0; p_w_wait = 0; p_b_wait = 0; p_ar_wait = 0; p_r_wait = 0;
            aw_cnt = 0; w_cnt = 0; b_cnt = 0; ar_cnt = 0; r_cnt = 0;
        end else begin
            // R5
            if ((^{awvalid,awready,wvalid,wready,bvalid,bready,
                   arvalid,arready,rvalid,rready}) === 1'bx)
                fail("R5 X/Z on a VALID or READY");

            // R1 + R2 : compare against last cycle's "waiting" state
            if (p_aw_wait && !awvalid)              fail("R1 AWVALID dropped before AWREADY");
            if (p_aw_wait && awaddr !== p_awaddr)   fail("R2 AWADDR changed while waiting");
            if (p_w_wait  && !wvalid)               fail("R1 WVALID dropped before WREADY");
            if (p_w_wait  && (wdata !== p_wdata || wstrb !== p_wstrb))
                                                    fail("R2 WDATA/WSTRB changed while waiting");
            if (p_b_wait  && !bvalid)               fail("R1 BVALID dropped before BREADY");
            if (p_b_wait  && bresp !== p_bresp)     fail("R2 BRESP changed while waiting");
            if (p_ar_wait && !arvalid)              fail("R1 ARVALID dropped before ARREADY");
            if (p_ar_wait && araddr !== p_araddr)   fail("R2 ARADDR changed while waiting");
            if (p_r_wait  && !rvalid)               fail("R1 RVALID dropped before RREADY");
            if (p_r_wait  && (rdata !== p_rdata || rresp !== p_rresp))
                                                    fail("R2 RDATA/RRESP changed while waiting");

            // R3 / R4 : ordering of responses vs. requests
            if (bvalid && (b_cnt >= aw_cnt || b_cnt >= w_cnt))
                fail("R3 BVALID before AW and W handshakes");
            if (rvalid && r_cnt >= ar_cnt)
                fail("R4 RVALID before AR handshake");

            // R6
            if (bvalid && bresp == 2'b01) fail("R6 EXOKAY on BRESP");
            if (rvalid && rresp == 2'b01) fail("R6 EXOKAY on RRESP");

            // count handshakes that happen on this edge
            if (awvalid && awready) aw_cnt = aw_cnt + 1;
            if (wvalid  && wready)  w_cnt  = w_cnt  + 1;
            if (bvalid  && bready)  b_cnt  = b_cnt  + 1;
            if (arvalid && arready) ar_cnt = ar_cnt + 1;
            if (rvalid  && rready)  r_cnt  = r_cnt  + 1;

            // snapshot for next edge
            p_aw_wait = awvalid && !awready;  p_awaddr = awaddr;
            p_w_wait  = wvalid  && !wready;   p_wdata  = wdata;  p_wstrb = wstrb;
            p_b_wait  = bvalid  && !bready;   p_bresp  = bresp;
            p_ar_wait = arvalid && !arready;  p_araddr = araddr;
            p_r_wait  = rvalid  && !rready;   p_rdata  = rdata;  p_rresp = rresp;
        end
    end
endmodule
