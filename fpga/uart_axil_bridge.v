`timescale 1ns/1ps
// =====================================================================
// uart_axil_bridge.v  -  turns command frames from a PC (over UART)
//                        into AXI4-Lite transactions on axil_master
//
// PC -> board (bytes, multi-byte fields are big-endian):
//   'W' (0x57)  A3 A2 A1 A0  D3 D2 D1 D0  S     10 bytes  write, S[3:0] = WSTRB
//   'R' (0x52)  A3 A2 A1 A0                      5 bytes  read
//   'P' (0x50)                                   1 byte   ping
// board -> PC:
//   write : ST                                   ST = {6'b0, BRESP}
//   read  : ST D3 D2 D1 D0                       ST = {6'b0, RRESP}
//   ping  : 0x50
//   unknown command byte : 0xEE
// A frame that stops arriving for TIMEOUT_CLKS clocks, or a byte with
// a bad stop bit, is thrown away and the bridge waits for a new command
// (so the PC can always resynchronise).
// =====================================================================
module uart_axil_bridge #(
    parameter TIMEOUT_CLKS = 10_000_000          // 100 ms at 100 MHz
)(
    input  wire        clk,
    input  wire        reset,

    // from uart_rx
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        rx_err,
    // to uart_tx
    output reg  [7:0]  tx_data,
    output reg         tx_start,
    input  wire        tx_busy,

    // to axil_master user ports
    output reg         wr_req,
    output reg  [31:0] wr_addr,
    output reg  [31:0] wr_data,
    output reg  [3:0]  wr_strb,
    input  wire        wr_busy,
    input  wire        wr_done,
    input  wire [1:0]  wr_resp,
    output reg         rd_req,
    output reg  [31:0] rd_addr,
    input  wire        rd_busy,
    input  wire        rd_done,
    input  wire [31:0] rd_data,
    input  wire [1:0]  rd_resp,

    output wire        active               // high while a frame is being handled
);
    localparam [7:0] CMD_W = 8'h57, CMD_R = 8'h52, CMD_P = 8'h50, NAK = 8'hEE;

    localparam [2:0] B_CMD = 3'd0, B_ARGS = 3'd1, B_ISSUE = 3'd2,
                     B_WAIT = 3'd3, B_SEND = 3'd4;

    reg [2:0]  state;
    reg        is_write;
    reg [3:0]  need;                         // argument bytes still to come
    reg [71:0] args;                         // A(4) D(4) S(1), shifted in MSB first
    reg [31:0] tmo;
    reg [39:0] txbuf;                        // up to 5 reply bytes, MSB first
    reg [2:0]  txlen;

    assign active = (state != B_CMD);

    always @(posedge clk) begin
        if (reset) begin
            state <= B_CMD; is_write <= 1'b0; need <= 0; args <= 0; tmo <= 0;
            txbuf <= 0; txlen <= 0; tx_data <= 0; tx_start <= 1'b0;
            wr_req <= 1'b0; rd_req <= 1'b0;
            wr_addr <= 0; wr_data <= 0; wr_strb <= 0; rd_addr <= 0;
        end else begin
            wr_req   <= 1'b0;
            rd_req   <= 1'b0;
            tx_start <= 1'b0;

            case (state)
            // ---------- wait for a command byte ----------
            B_CMD: if (rx_valid) begin
                tmo <= 0;
                case (rx_data)
                    CMD_W: begin is_write <= 1'b1; need <= 4'd9; state <= B_ARGS; end
                    CMD_R: begin is_write <= 1'b0; need <= 4'd4; state <= B_ARGS; end
                    CMD_P: begin txbuf <= {CMD_P, 32'd0}; txlen <= 3'd1; state <= B_SEND; end
                    default: begin txbuf <= {NAK, 32'd0}; txlen <= 3'd1; state <= B_SEND; end
                endcase
            end

            // ---------- collect address / data / strobe bytes ----------
            B_ARGS: begin
                if (rx_err || tmo == TIMEOUT_CLKS) begin
                    state <= B_CMD;                       // drop the broken frame
                end else if (rx_valid) begin
                    tmo  <= 0;
                    args <= {args[63:0], rx_data};
                    need <= need - 1'b1;
                    if (need == 4'd1) state <= B_ISSUE;
                end else tmo <= tmo + 1'b1;
            end

            // ---------- start the AXI transaction ----------
            B_ISSUE: begin
                if (is_write && !wr_busy) begin
                    wr_addr <= args[71:40];
                    wr_data <= args[39:8];
                    wr_strb <= args[3:0];
                    wr_req  <= 1'b1;
                    state   <= B_WAIT;
                end else if (!is_write && !rd_busy) begin
                    rd_addr <= args[31:0];                // a read frame has only A(4)
                    rd_req  <= 1'b1;
                    state   <= B_WAIT;
                end
            end

            // ---------- wait for the B or R handshake ----------
            B_WAIT: begin
                if (is_write && wr_done) begin
                    txbuf <= {6'd0, wr_resp, 32'd0}; txlen <= 3'd1; state <= B_SEND;
                end else if (!is_write && rd_done) begin
                    txbuf <= {6'd0, rd_resp, rd_data}; txlen <= 3'd5; state <= B_SEND;
                end
            end

            // ---------- send the reply, one byte at a time ----------
            B_SEND: begin
                if (txlen == 0) begin
                    state <= B_CMD;
                end else if (!tx_busy && !tx_start) begin
                    tx_data  <= txbuf[39:32];
                    tx_start <= 1'b1;
                    txbuf    <= {txbuf[31:0], 8'd0};
                    txlen    <= txlen - 1'b1;
                end
            end
            default: state <= B_CMD;
            endcase
        end
    end
endmodule
