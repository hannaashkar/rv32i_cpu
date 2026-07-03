// ============================================================================
// npu_pe — one processing element of the 4x4 output-stationary systolic
// array (decision D014, spec in docs/NPU.md)
//
// Purpose:    Holds one element of the C tile. Every run cycle it consumes
//             the int8 pair on its INPUTS (a from the west, b from the
//             north), adds their product to the resident 32-bit
//             accumulator, and passes both operands on through registers
//             (east / south) — the registered pass-through is what creates
//             the systolic skew, one extra cycle per hop.
// Interfaces: run   — shift + accumulate this cycle (array FSM's busy)
//             clr   — synchronous accumulator clear (CTRL.CLR; only ever
//                     pulsed while the array is idle, see interlocks)
// Assumes:    clr and run are never asserted together (write-while-busy is
//             impossible by the core-side interlocks; asserted in npu_top).
//             The 8x8 signed multiply maps onto a MAX 10 embedded 9x9
//             multiplier lane.
// ============================================================================
module npu_pe (
    input  wire        clk,
    input  wire        reset,
    input  wire        clr,
    input  wire        run,
    input  wire [7:0]  a_in,
    input  wire [7:0]  b_in,
    output reg  [7:0]  a_out,
    output reg  [7:0]  b_out,
    output reg  [31:0] acc
);

    // int8 x int8 -> int16 product of the *inputs* (the operands are
    // registered on the way OUT, not on the way in — PE(i,j) therefore
    // accumulates the value that entered the row/column i+j cycles ago,
    // which is exactly the systolic alignment npu_array's feeders assume)
    wire signed [15:0] prod = $signed(a_in) * $signed(b_in);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            a_out <= 8'b0;
            b_out <= 8'b0;
            acc   <= 32'b0;
        end else begin
            if (run) begin
                a_out <= a_in;
                b_out <= b_in;
            end
            if (clr)
                acc <= 32'b0;
            else if (run)
                acc <= acc + {{16{prod[15]}}, prod};   // sign-extended MAC
        end
    end

endmodule
