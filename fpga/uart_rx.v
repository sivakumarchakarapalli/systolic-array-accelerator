`timescale 1ns/1ps
// =====================================================================
// uart_rx.v  -  8N1 UART receiver
//   CLKS_PER_BIT = clk_freq / baud   (100 MHz / 115200 = 868)
//   * 2-flop synchroniser on the asynchronous rx pin
//   * start bit re-checked at its middle (rejects glitches)
//   * every data bit sampled at the middle of its bit time
//   * data_valid pulses for one clock when a byte with a good stop bit
//     arrives; frame_err pulses instead if the stop bit is 0
// =====================================================================
module uart_rx #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        data_valid,
    output reg        frame_err
);
    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg rx_m = 1'b1, rx_s = 1'b1;
    always @(posedge clk) begin rx_m <= rx; rx_s <= rx_m; end

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE; cnt <= 0; bit_idx <= 0; shift <= 0;
            data <= 0; data_valid <= 1'b0; frame_err <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            frame_err  <= 1'b0;
            case (state)
            S_IDLE: begin
                cnt <= 0; bit_idx <= 0;
                if (!rx_s) state <= S_START;          // falling edge = start bit
            end
            S_START: begin                            // wait half a bit, check still low
                if (cnt == CLKS_PER_BIT/2 - 1) begin
                    cnt   <= 0;
                    state <= rx_s ? S_IDLE : S_DATA;  // glitch -> back to idle
                end else cnt <= cnt + 1'b1;
            end
            S_DATA: begin                             // one full bit later = middle of bit
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt   <= 0;
                    shift <= {rx_s, shift[7:1]};      // LSB first
                    if (bit_idx == 3'd7) state <= S_STOP;
                    bit_idx <= bit_idx + 1'b1;
                end else cnt <= cnt + 1'b1;
            end
            S_STOP: begin
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt <= 0;
                    if (rx_s) begin data <= shift; data_valid <= 1'b1; end
                    else      frame_err <= 1'b1;
                    state <= S_IDLE;
                end else cnt <= cnt + 1'b1;
            end
            endcase
        end
    end
endmodule
