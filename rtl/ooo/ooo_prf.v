// ============================================================================
// ooo_prf — merged physical register file, 6R / 3W (decision D013)
//
// Purpose:    Holds ALL register values (committed and speculative) in one
//             file, R10K style. p0 is architecturally zero: never written
//             (writes to p0 are gated off by wr=0 upstream), reads as 0.
// Ports:      2 read ports per execution pipe (rs1/rs2 for ports 0..2),
//             1 write port per pipe.
// Bypass:     write-first — a read of a tag being written this cycle
//             returns the new value. This closes the select-at-t+2 case:
//             a consumer reading the PRF in the same cycle its producer
//             is in WB (see docs/OOO.md timing).
// ============================================================================
module ooo_prf (
    input  wire        clk,

    input  wire [5:0]  r0a_tag, r0b_tag,   // port0 rs1/rs2
    input  wire [5:0]  r1a_tag, r1b_tag,   // port1 rs1/rs2
    input  wire [5:0]  r2a_tag, r2b_tag,   // port2 rs1/rs2
    output wire [31:0] r0a, r0b, r1a, r1b, r2a, r2b,

    input  wire        w0_en, w1_en, w2_en,
    input  wire [5:0]  w0_tag, w1_tag, w2_tag,
    input  wire [31:0] w0_data, w1_data, w2_data
);

    reg [31:0] regs [0:63];

    always @(posedge clk) begin
        if (w0_en) regs[w0_tag] <= w0_data;
        if (w1_en) regs[w1_tag] <= w1_data;
        if (w2_en) regs[w2_tag] <= w2_data;
    end

    function [31:0] rd_bypass;
        input [5:0] tag;
        begin
            if (tag == 6'd0)                    rd_bypass = 32'b0;
            else if (w0_en && w0_tag == tag)    rd_bypass = w0_data;
            else if (w1_en && w1_tag == tag)    rd_bypass = w1_data;
            else if (w2_en && w2_tag == tag)    rd_bypass = w2_data;
            else                                rd_bypass = regs[tag];
        end
    endfunction

    assign r0a = rd_bypass(r0a_tag);
    assign r0b = rd_bypass(r0b_tag);
    assign r1a = rd_bypass(r1a_tag);
    assign r1b = rd_bypass(r1b_tag);
    assign r2a = rd_bypass(r2a_tag);
    assign r2b = rd_bypass(r2b_tag);

endmodule
