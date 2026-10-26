`timescale 1ns/1ps
// ============================================================
// systolic_top.v : a complete matrix-multiply accelerator
//
//   write port --> [ A buffer ] [ B buffer ]
//                        |           |
//   start ------> [ controller FSM ] picks column k / row k
//                        |           |
//                  [ systolic_core = skew + 4x4 array ]
//                        |
//   read port  <-- C (the PE accumulators)      busy / done
//
// How to use it:
//   1. Write all N*N values of A and B through the write port.
//   2. Pulse start for one clock. With accumulate = 1 at the same
//      time, the PEs are NOT cleared, so C += A*B (used for tiling:
//      a long K dimension is split into many 4x4 runs).
//   3. Wait for done = 1  (3N-1 clocks after start, 11 for N=4).
//   4. Read C[i][j] through the read port.
// Writes and start are ignored while busy = 1.
//
// FSM:
//   IDLE --start--> CLEAR (1 clk) --> FEED (N clks) --> DRAIN (2N-2 clks) --> DONE
//    ^                                                                         |
//    +------------------------------ start ------------------------------------+
// ============================================================
module systolic_top #(
    parameter N  = 4,
    parameter DW = 8,
    parameter AW = 32,
    parameter IW = (N <= 2) ? 1 : $clog2(N)    // bits to index a row/column (derived, do not override)
)(
    input  wire          clk,
    input  wire          rst,

    // write port for the input matrices
    input  wire          wr_en,
    input  wire          wr_sel,            // 0 = A, 1 = B
    input  wire [IW-1:0] wr_row,
    input  wire [IW-1:0] wr_col,
    input  wire [DW-1:0] wr_data,

    // control and status
    input  wire          start,
    input  wire          accumulate,        // with start: keep C, add A*B to it
    output wire          busy,
    output wire          done,
    output reg  [15:0]   cycles,            // clocks taken by the last run

    // read port for the result
    input  wire [IW-1:0] rd_row,
    input  wire [IW-1:0] rd_col,
    output wire [AW-1:0] rd_data
);

    localparam CW = $clog2(2*N);                // bits for the step counter

    // ---------------- FSM state ----------------
    localparam S_IDLE  = 3'd0,
               S_CLEAR = 3'd1,
               S_FEED  = 3'd2,
               S_DRAIN = 3'd3,
               S_DONE  = 3'd4;

    reg [2:0]    state;
    reg [CW-1:0] cnt;       // which column/row in FEED, clocks left in DRAIN
    reg          acc_mode;  // this run adds to C instead of replacing it

    assign busy = (state == S_CLEAR) || (state == S_FEED) || (state == S_DRAIN);
    assign done = (state == S_DONE);

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            cnt      <= 0;
            acc_mode <= 1'b0;
        end else begin
            case (state)
                S_IDLE, S_DONE:
                    if (start) begin
                        state    <= S_CLEAR;
                        acc_mode <= accumulate;
                    end
                S_CLEAR: begin                      // zero every accumulator (unless acc_mode)
                    state <= S_FEED;
                    cnt   <= 0;
                end
                S_FEED: begin                       // send column cnt of A, row cnt of B
                    if (cnt == N-1) begin
                        state <= S_DRAIN;
                        cnt   <= 0;
                    end else
                        cnt <= cnt + 1;
                end
                S_DRAIN: begin                      // send zeros until the last PE finishes
                    if (cnt == 2*N-3) state <= S_DONE;
                    else              cnt   <= cnt + 1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // performance counter: clocks spent busy in the last run
    always @(posedge clk) begin
        if (rst)
            cycles <= 0;
        else if ((state == S_IDLE || state == S_DONE) && start)
            cycles <= 0;
        else if (busy)
            cycles <= cycles + 1;
    end

    // ---------------- input buffers ----------------
    // a_buf[i*N+j] = A[i][j],  b_buf[i*N+j] = B[i][j]
    reg [DW-1:0] a_buf [0:N*N-1];
    reg [DW-1:0] b_buf [0:N*N-1];

    always @(posedge clk) begin
        if (wr_en && !busy) begin                   // never change data mid-run
            if (wr_sel == 1'b0) a_buf[wr_row*N + wr_col] <= wr_data;
            else                b_buf[wr_row*N + wr_col] <= wr_data;
        end
    end

    // ---------------- feed the core ----------------
    // In FEED, column cnt of A and row cnt of B go out; otherwise zeros.
    //
    // The feed is REGISTERED with a one-clock lookahead: in the clock
    // before FEED step k, we already read column k into a_col_flat.
    // So the DSP48 inputs come straight from flip-flops (fast), and
    // the latency is still 3N-1. Without this, the slowest path was
    //   cnt -> buffer RAM -> mux -> DSP48 of PE(0,0)   (WNS 1.986 ns).
    wire          feed_next = (state == S_CLEAR) || (state == S_FEED && cnt != N-1);
    wire [IW-1:0] k_next    = (state == S_CLEAR) ? {IW{1'b0}} : cnt[IW-1:0] + 1'b1;

    reg [N*DW-1:0] a_col_flat, b_row_flat;
    integer r;
    always @(posedge clk) begin
        for (r = 0; r < N; r = r + 1) begin
            if (rst || !feed_next) begin
                a_col_flat[r*DW +: DW] <= 0;
                b_row_flat[r*DW +: DW] <= 0;
            end else begin
                a_col_flat[r*DW +: DW] <= a_buf[r*N + k_next];   // A[r][k]
                b_row_flat[r*DW +: DW] <= b_buf[k_next*N + r];   // B[k][r]
            end
        end
    end

    wire [N*N*AW-1:0] acc_flat;

    systolic_core #(.N(N), .DW(DW), .AW(AW)) u_core (
        .clk(clk), .rst(rst),
        .clear(state == S_CLEAR && !acc_mode),
        .a_col_flat(a_col_flat), .b_row_flat(b_row_flat),
        .acc_flat(acc_flat));

    // ---------------- result read port ----------------
    assign rd_data = acc_flat[(rd_row*N + rd_col)*AW +: AW];

endmodule
