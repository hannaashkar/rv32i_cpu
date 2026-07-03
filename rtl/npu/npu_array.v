// ============================================================================
// npu_array — 4x4 output-stationary systolic grid + skew feeders + run FSM
// (decision D014, spec in docs/NPU.md)
//
// Purpose:    One `go` pulse streams one 4x4x4 tile: C[i][j] += sum_k
//             A[i][k]*B[k][j]. Accumulators persist across passes (K
//             tiling); `clr` zeroes them.
// Dataflow:   A rows enter from the west, B rows from the north, each
//             lane delayed by its index (classic systolic skew). During
//             run cycle t, PE(i,j)'s inputs carry A[i][t-i-j] and
//             B[t-i-j][j] (the pass-through registers add one cycle per
//             hop), so it accumulates exactly the k = t-i-j term. The
//             last term (k=3 at PE(3,3)) flows at t = 9: one pass = 10
//             run cycles. Outside a lane's live window the feeders
//             inject zeros — zero products, no accumulator pollution.
// Interfaces: amat/bmat — packed staging registers from npu_top:
//             amat[32*i+8*k +: 8] = A[i][k], bmat[32*k+8*j +: 8] = B[k][j]
//             go/clr    — 1-cycle pulses (a CTRL store; GO|CLR = clear
//                         then run). Never asserted while busy (core
//                         interlocks; asserted below).
//             done      — sticky "a pass completed"; cleared by clr/go.
// ============================================================================
module npu_array (
    input  wire         clk,
    input  wire         reset,
    input  wire         go,
    input  wire         clr,
    input  wire [127:0] amat,
    input  wire [127:0] bmat,
    output wire         busy,
    output reg          done,
    output wire [511:0] c_flat      // C[i][j] = c_flat[32*(4*i+j) +: 32]
);

    // ------------------------------------------------------------------
    // run FSM: cnt counts run cycles 0..9 while busy
    // ------------------------------------------------------------------
    reg       busy_r;
    reg [3:0] cnt;
    assign busy = busy_r;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy_r <= 1'b0;
            cnt    <= 4'd0;
            done   <= 1'b0;
        end else begin
            if (go) begin
                busy_r <= 1'b1;
                cnt    <= 4'd0;
                done   <= 1'b0;
            end else if (busy_r) begin
                if (cnt == 4'd9) begin
                    busy_r <= 1'b0;
                    done   <= 1'b1;
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end else if (clr) begin
                done <= 1'b0;          // CLR without GO also clears done
            end
        end
    end

    // ------------------------------------------------------------------
    // skew feeders: lane `off` (row i for A, column j for B) carries its
    // k-th element during run cycle t = k + off, zeros otherwise
    // ------------------------------------------------------------------
    function [7:0] afeed;              // west edge, row i: A[i][t-i]
        input [127:0] m;
        input [3:0]   t;
        input [1:0]   i;
        reg [3:0] k;
        begin
            k = t - {2'b00, i};
            if ((t >= {2'b00, i}) && (k < 4'd4))
                afeed = m[32*i + 8*k[1:0] +: 8];
            else
                afeed = 8'b0;
        end
    endfunction

    function [7:0] bfeed;              // north edge, col j: B[t-j][j]
        input [127:0] m;
        input [3:0]   t;
        input [1:0]   j;
        reg [3:0] k;
        begin
            k = t - {2'b00, j};
            if ((t >= {2'b00, j}) && (k < 4'd4))
                bfeed = m[32*k[1:0] + 8*j +: 8];
            else
                bfeed = 8'b0;
        end
    endfunction

    // ------------------------------------------------------------------
    // the grid: a flows west->east, b flows north->south
    // ------------------------------------------------------------------
    wire [7:0] a_h [0:3][0:4];         // a_h[i][j] = a into PE(i,j)
    wire [7:0] b_v [0:4][0:3];         // b_v[i][j] = b into PE(i,j)

    genvar gi, gj;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : FEED
            // genvar passed straight into the [1:0] function port (0..3)
            assign a_h[gi][0] = afeed(amat, cnt, gi);
            assign b_v[0][gi] = bfeed(bmat, cnt, gi);
        end
        for (gi = 0; gi < 4; gi = gi + 1) begin : ROW
            for (gj = 0; gj < 4; gj = gj + 1) begin : COL
                npu_pe PE (
                    .clk   (clk),
                    .reset (reset),
                    .clr   (clr),
                    .run   (busy_r),
                    .a_in  (a_h[gi][gj]),
                    .b_in  (b_v[gi][gj]),
                    .a_out (a_h[gi][gj+1]),
                    .b_out (b_v[gi+1][gj]),
                    .acc   (c_flat[32*(4*gi+gj) +: 32])
                );
            end
        end
    endgenerate

`ifdef VERILATOR
    // interlock invariants (docs/NPU.md): a CTRL pulse can never see a
    // running array — the cores stall/hold stores while busy
    always @(posedge clk) begin
        if (!reset && busy_r && (go || clr))
            $fatal(1, "npu_array: go/clr while busy (interlock violated)");
    end
`endif

endmodule
