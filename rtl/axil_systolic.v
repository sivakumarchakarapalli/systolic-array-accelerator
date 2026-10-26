`timescale 1ns/1ps
// =====================================================================
// axil_systolic.v : AXI4-Lite slave wrapper around systolic_top
//
// Turns the accelerator into bus registers, so a CPU, a MicroBlaze or
// the UART->AXI bridge from the AXI4-Lite project can drive it.
//
// Address map (byte addresses, every register is 32 bits):
//   0x000  CTRL    W   bit0 = 1 : start a run (self-clearing)
//                      bit1 = 1 : accumulate, C += A*B (no clear), for tiling
//   0x004  STATUS  R   bit0 = busy, bit1 = done
//   0x008  CYCLES  R   clocks taken by the last run (11 for 4x4)
//   0x00C  ID      R   0x5A00_0000 | N<<8 | DW  (0x5A000408 for 4x4 INT8)
//   0x100 + 4*w        A packed W   step 9: 4 INT8 per write, w < N*N/4
//   0x200 + 4*w        B packed W   byte k of word w = element 4*w+k
//                                   (row-major), only bytes with WSTRB set
//   0x400 + 4*(i*N+j)  A[i][j]  W   low byte = signed INT8
//   0x800 + 4*(i*N+j)  B[i][j]  W   low byte = signed INT8
//   0xC00 + 4*(i*N+j)  C[i][j]  R   signed 32-bit result
//
// Responses:
//   OKAY    normal access
//   SLVERR  misaligned address, wrong direction (read A/B, write C or
//           a status register), or A/B/CTRL written while busy
//   DECERR  no register at that address
//
// The AXI handshake logic follows axil_mem_slave.v from the AXI4-Lite
// extension: AW and W are latched independently, READY never depends
// on VALID, and one write can wait in B while the next is accepted.
// N must be a power of two (row/column are taken from address bits).
//
// Step 9a, packed writes: one 32-bit write to 0x100/0x200 carries 4
// elements. A small sequencer then writes them into the A/B buffer one
// per clock (the buffer has one write port). While it runs, the next
// bus write waits, so a CTRL start can never overtake the data.
// =====================================================================
module axil_systolic #(
    parameter N  = 4,
    parameter DW = 8,
    parameter AW = 32
)(
    input  wire        clk,
    input  wire        reset,

    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] awaddr,
    input  wire [2:0]  awprot,

    input  wire        wvalid,
    output wire        wready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,

    output reg         bvalid,
    input  wire        bready,
    output reg  [1:0]  bresp,

    input  wire        arvalid,
    output wire        arready,
    input  wire [31:0] araddr,
    input  wire [2:0]  arprot,

    output reg         rvalid,
    input  wire        rready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp
);

    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;
    localparam IW = (N <= 2) ? 1 : $clog2(N);
    localparam [31:0] ID_VALUE = 32'h5A00_0000 | (N << 8) | DW;

    // register / region codes
    localparam [3:0] R_CTRL = 4'd0, R_STATUS = 4'd1, R_CYCLES = 4'd2, R_ID = 4'd3,
                     R_A = 4'd4, R_B = 4'd5, R_C = 4'd6, R_NONE = 4'd7,
                     R_AP = 4'd8, R_BP = 4'd9;
    localparam PW = (N*N/4 <= 1) ? 1 : $clog2(N*N/4);   // bits of a packed word index

    // ---------------- the accelerator ----------------
    reg           acc_wr_en, acc_wr_sel, acc_start, acc_accum;
    reg  [IW-1:0] acc_wr_row, acc_wr_col;
    reg  [DW-1:0] acc_wr_data;
    wire          acc_busy, acc_done;
    wire [15:0]   acc_cycles;
    wire [AW-1:0] acc_rd_data;

    // which register an address points at
    function [3:0] region;
        input [31:0] a;
        begin
            if      (a == 32'h000) region = R_CTRL;
            else if (a == 32'h004) region = R_STATUS;
            else if (a == 32'h008) region = R_CYCLES;
            else if (a == 32'h00C) region = R_ID;
            else if (a[31:10] == 0 && a[9:8] == 2'b01 && a[7:2] < N*N/4) region = R_AP;
            else if (a[31:10] == 0 && a[9:8] == 2'b10 && a[7:2] < N*N/4) region = R_BP;
            else if (a[31:12] == 0 && a[9:2] < N*N) begin
                case (a[11:10])
                    2'b01:   region = R_A;
                    2'b10:   region = R_B;
                    2'b11:   region = R_C;
                    default: region = R_NONE;
                endcase
            end else
                region = R_NONE;
        end
    endfunction

    // element index -> row / column (N is a power of two)
    function [IW-1:0] row_of; input [31:0] a; row_of = a[9:2] >> IW;      endfunction
    function [IW-1:0] col_of; input [31:0] a; col_of = a[9:2] & (N - 1);  endfunction

    // ======================= WRITE PATH =======================
    reg        aw_full, w_full;
    reg [31:0] aw_addr_q, w_data_q;
    reg [3:0]  w_strb_q;

    assign awready = !aw_full;
    assign wready  = !w_full;

    // packed-write sequencer: 4 lanes, one element per clock
    reg          pk_busy, pk_sel;
    reg  [1:0]   pk_lane;
    reg  [PW-1:0] pk_word;
    reg  [31:0]  pk_data;
    reg  [3:0]   pk_strb;
    wire [7:0]   pk_elem = {pk_word, pk_lane};          // element index 4*w + lane

    wire       do_write = aw_full && w_full && (!bvalid || bready) && !pk_busy;
    wire [3:0] w_reg    = region(aw_addr_q);

    // response for the write we are about to commit
    reg [1:0] w_resp;
    always @* begin
        if (aw_addr_q[1:0] != 2'b00)                     w_resp = SLVERR;
        else if (w_reg == R_NONE)                        w_resp = DECERR;
        else if (w_reg == R_STATUS || w_reg == R_CYCLES ||
                 w_reg == R_ID     || w_reg == R_C)      w_resp = SLVERR;  // read-only
        else if (acc_busy || acc_start)                  w_resp = SLVERR;  // CTRL/A/B while busy
        else                                             w_resp = OKAY;
    end

    always @(posedge clk) begin
        if (reset) begin
            aw_full <= 1'b0;  w_full <= 1'b0;
            aw_addr_q <= 0;   w_data_q <= 0;  w_strb_q <= 0;
            bvalid <= 1'b0;   bresp <= OKAY;
            acc_wr_en <= 1'b0; acc_start <= 1'b0; acc_accum <= 1'b0;
            acc_wr_sel <= 1'b0; acc_wr_row <= 0; acc_wr_col <= 0; acc_wr_data <= 0;
            pk_busy <= 1'b0; pk_sel <= 1'b0; pk_lane <= 0; pk_word <= 0;
            pk_data <= 0;    pk_strb <= 0;
        end else begin
            acc_wr_en <= 1'b0;                   // 1-clock pulses by default
            acc_start <= 1'b0;

            // sequencer: one lane per clock, skip lanes whose WSTRB bit is 0
            if (pk_busy) begin
                if (pk_strb[pk_lane]) begin
                    acc_wr_en   <= 1'b1;
                    acc_wr_sel  <= pk_sel;
                    acc_wr_row  <= pk_elem >> IW;
                    acc_wr_col  <= pk_elem & (N - 1);
                    acc_wr_data <= pk_data[pk_lane*8 +: DW];
                end
                pk_lane <= pk_lane + 1'b1;
                if (pk_lane == 2'd3) pk_busy <= 1'b0;
            end

            if (awvalid && awready) begin aw_addr_q <= awaddr; aw_full <= 1'b1; end
            else if (do_write)            aw_full <= 1'b0;

            if (wvalid && wready) begin w_data_q <= wdata; w_strb_q <= wstrb; w_full <= 1'b1; end
            else if (do_write)          w_full <= 1'b0;

            if (do_write) begin
                if (w_resp == OKAY) begin
                    if (w_reg == R_CTRL && w_strb_q[0] && w_data_q[0]) begin
                        acc_start <= 1'b1;
                        acc_accum <= w_data_q[1];
                    end
                    if ((w_reg == R_A || w_reg == R_B) && w_strb_q[0]) begin
                        acc_wr_en   <= 1'b1;
                        acc_wr_sel  <= (w_reg == R_B);
                        acc_wr_row  <= row_of(aw_addr_q);
                        acc_wr_col  <= col_of(aw_addr_q);
                        acc_wr_data <= w_data_q[DW-1:0];
                    end
                    if (w_reg == R_AP || w_reg == R_BP) begin
                        pk_busy <= 1'b1;
                        pk_sel  <= (w_reg == R_BP);
                        pk_lane <= 2'd0;
                        pk_word <= aw_addr_q[2 +: PW];
                        pk_data <= w_data_q;
                        pk_strb <= w_strb_q;
                    end
                end
                bvalid <= 1'b1;
                bresp  <= w_resp;
            end else if (bvalid && bready)
                bvalid <= 1'b0;
        end
    end

    // ======================= READ PATH ========================
    assign arready = !rvalid;

    wire [3:0] r_reg = region(araddr);

    always @(posedge clk) begin
        if (reset) begin
            rvalid <= 1'b0; rdata <= 0; rresp <= OKAY;
        end else begin
            if (arvalid && arready) begin
                rvalid <= 1'b1;
                rdata  <= 32'd0;
                if (araddr[1:0] != 2'b00)               rresp <= SLVERR;
                else case (r_reg)
                    R_CTRL:   rresp <= OKAY;            // reads as 0
                    R_STATUS: begin rresp <= OKAY; rdata <= {30'd0, acc_done, acc_busy}; end
                    R_CYCLES: begin rresp <= OKAY; rdata <= {16'd0, acc_cycles}; end
                    R_ID:     begin rresp <= OKAY; rdata <= ID_VALUE; end
                    R_C:      begin rresp <= OKAY; rdata <= acc_rd_data; end
                    R_A, R_B, R_AP, R_BP: rresp <= SLVERR;   // write-only
                    default:  rresp <= DECERR;
                endcase
            end else if (rvalid && rready)
                rvalid <= 1'b0;
        end
    end

    systolic_top #(.N(N), .DW(DW), .AW(AW)) u_acc (
        .clk(clk), .rst(reset),
        .wr_en(acc_wr_en), .wr_sel(acc_wr_sel),
        .wr_row(acc_wr_row), .wr_col(acc_wr_col), .wr_data(acc_wr_data),
        .start(acc_start), .accumulate(acc_accum), .busy(acc_busy), .done(acc_done), .cycles(acc_cycles),
        .rd_row(row_of(araddr)), .rd_col(col_of(araddr)), .rd_data(acc_rd_data));

endmodule
