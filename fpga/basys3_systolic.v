`timescale 1ns/1ps
// =====================================================================
// basys3_systolic.v : the systolic-array accelerator on a Basys3
//
//   PC (Python) --USB-UART 115200--> uart_rx --> uart_axil_bridge
//                                                  |
//                                             axil_master
//                                                  | AXI4-Lite
//                                             axil_systolic  (steps 1-5)
//   uart_tx <-- reply bytes <---------------------+
//
//   btnC       reset
//   led[0]     the last write got an error response (SLVERR/DECERR)
//   led[1]     the last read got an error response
//   led[2]     a PC frame is being handled (flickers while the PC talks)
//   led[15]    heartbeat, ~1.5 Hz: the clock and bitstream are alive
//   7-segment  low 16 bits of the last value the PC read, in hex
//              (after a job, the PC reads C[3][3] last)
//
// Every block below the AXI bus is reused unchanged:
//   uart_rx, uart_tx, uart_axil_bridge, axil_master  <- AXI4-Lite project
//   axil_systolic -> systolic_top -> systolic_core   <- steps 1-5
// =====================================================================
module basys3_systolic #(
    parameter N            = 4,
    parameter CLKS_PER_BIT = 868,         // 100 MHz / 115200 baud
    parameter UART_TIMEOUT = 10_000_000   // drop a half-received frame after 100 ms
)(
    input  wire        clk,               // 100 MHz, pin W5
    input  wire        btnC,              // reset
    input  wire        RsRx,              // UART from PC (pin B18)
    output wire        RsTx,              // UART to PC   (pin A18)
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an
);

    // ---------------- reset: synchronise btnC, plus power-on reset ----------------
    reg [1:0] rst_sync = 2'b11;
    reg [3:0] por_cnt  = 4'd0;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], btnC};
        if (por_cnt != 4'hF) por_cnt <= por_cnt + 1'b1;
    end
    // The reset is registered and may be copied (max_fanout): it drives
    // ~700 loads, including the reset pins of all 16 DSP48s. As one
    // LUT driving every load it became the critical path (WNS 3.14 ns).
    (* max_fanout = 50 *) reg reset = 1'b1;
    always @(posedge clk) reset <= rst_sync[1] | (por_cnt != 4'hF);

    // ---------------- UART <-> bridge ----------------
    wire [7:0]  rx_byte, tx_byte;
    wire        rx_valid, rx_err, tx_start, tx_busy;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .reset(reset), .rx(RsRx),
        .data(rx_byte), .data_valid(rx_valid), .frame_err(rx_err));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .reset(reset), .start(tx_start), .data(tx_byte),
        .busy(tx_busy), .tx(RsTx));

    // ---------------- bridge -> AXI master ----------------
    wire        wr_req, rd_req, br_active;
    wire [31:0] wr_addr, wr_data, rd_addr;
    wire [3:0]  wr_strb;
    wire        wr_busy, wr_done, rd_busy, rd_done;
    wire [1:0]  wr_resp, rd_resp;
    wire [31:0] rd_data;

    uart_axil_bridge #(.TIMEOUT_CLKS(UART_TIMEOUT)) u_bridge (
        .clk(clk), .reset(reset),
        .rx_data(rx_byte), .rx_valid(rx_valid), .rx_err(rx_err),
        .tx_data(tx_byte), .tx_start(tx_start), .tx_busy(tx_busy),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
        .wr_busy(wr_busy), .wr_done(wr_done), .wr_resp(wr_resp),
        .rd_req(rd_req), .rd_addr(rd_addr),
        .rd_busy(rd_busy), .rd_done(rd_done), .rd_data(rd_data), .rd_resp(rd_resp),
        .active(br_active));

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

    axil_systolic #(.N(N), .DW(8)) u_acc (
        .clk(clk), .reset(reset),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp));

    // ---------------- things a human can see ----------------
    reg [15:0] shown;
    reg [25:0] beat;
    reg        wr_err, rd_err;
    always @(posedge clk) begin
        if (reset) begin
            shown <= 16'd0; beat <= 26'd0; wr_err <= 1'b0; rd_err <= 1'b0;
        end else begin
            beat <= beat + 1'b1;
            if (rd_done) begin shown <= rd_data[15:0]; rd_err <= (rd_resp != 2'b00); end
            if (wr_done) wr_err <= (wr_resp != 2'b00);
        end
    end

    assign led[0]     = wr_err;
    assign led[1]     = rd_err;
    assign led[2]     = br_active;
    assign led[14:3]  = 12'd0;
    assign led[15]    = beat[25];
    assign dp         = 1'b1;              // off (active low)

    sevenseg_hex4 u_7seg (.clk(clk), .reset(reset), .value(shown), .seg(seg), .an(an));

endmodule


// ---------------------------------------------------------------------
// sevenseg_hex4: shows a 16-bit value as 4 hex digits (Basys3, active low)
// ---------------------------------------------------------------------
module sevenseg_hex4 (
    input  wire        clk, reset,
    input  wire [15:0] value,
    output reg  [6:0]  seg,
    output reg  [3:0]  an
);
    reg [17:0] refresh;                     // 100 MHz / 2^16 per digit ~ 1.5 kHz
    always @(posedge clk) refresh <= reset ? 18'd0 : refresh + 1'b1;
    wire [1:0] digit = refresh[17:16];

    reg [3:0] nib;
    always @(*) begin
        case (digit)
            2'd0:    begin an = 4'b1110; nib = value[ 3: 0]; end
            2'd1:    begin an = 4'b1101; nib = value[ 7: 4]; end
            2'd2:    begin an = 4'b1011; nib = value[11: 8]; end
            default: begin an = 4'b0111; nib = value[15:12]; end
        endcase
        case (nib)                          //  gfedcba  (0 = segment on)
            4'h0: seg = 7'b1000000;  4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;  4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;  4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;  4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;  4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;  4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;  4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;  default: seg = 7'b0001110;
        endcase
    end
endmodule
