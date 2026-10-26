`timescale 1ns/1ps
// =====================================================================
// uart_tx.v  -  8N1 UART transmitter
//   pulse 'start' with 'data' while busy == 0; tx idles high
// =====================================================================
module uart_tx #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       start,
    input  wire [7:0] data,
    output wire       busy,
    output reg        tx
);
    reg [9:0]  frame;        // {stop, data[7:0], start}
    reg [3:0]  bits_left;
    reg [15:0] cnt;

    assign busy = (bits_left != 0);

    always @(posedge clk) begin
        if (reset) begin
            tx <= 1'b1; frame <= 10'h3FF; bits_left <= 0; cnt <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                frame     <= {1'b1, data, 1'b0};
                bits_left <= 4'd10;
                cnt       <= 0;
                tx        <= 1'b0;                    // start bit goes out now
            end
        end else begin
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt       <= 0;
                frame     <= {1'b1, frame[9:1]};
                bits_left <= bits_left - 1'b1;
                tx        <= (bits_left == 1) ? 1'b1 : frame[1];
            end else cnt <= cnt + 1'b1;
        end
    end
endmodule
