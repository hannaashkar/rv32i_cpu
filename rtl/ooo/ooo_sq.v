// ============================================================================
// ooo_sq — 8-entry store queue (decision D013)
//
// Purpose:    Stores execute (address+data capture) out of order into this
//             queue, but memory only changes at retire: the ROB marks the
//             oldest unmarked entry committed, and the head drains to
//             dmem/mmio at one store per cycle. All MMIO side effects are
//             therefore non-speculative.
// Forwarding: a load queries with its address and its dispatch-time color
//             (4-bit tail tag). Among VALID, ADDRESS-KNOWN entries OLDER
//             than the color that match the same word address, the
//             YOUNGEST decides: a full-word store forwards its data; a
//             sub-word store forces the load to replay until the store
//             commits (conservative — see docs/OOO.md).
// Age:        4-bit tags (3 index + phase). The head can never pass a
//             live load's color, because stores younger than the load
//             cannot retire before it.
// ============================================================================
module ooo_sq (
    input  wire        clk,
    input  wire        reset,

    // allocation at rename: how many stores dispatch this cycle (0..2).
    // Positions are always tail, tail+1 — the TOP computes each store
    // uop's own position from tail4 and the slot pairing.
    input  wire [1:0]  alloc_n,
    output wire        free_ge1,
    output wire        free_ge2,
    output wire [3:0]  tail4,        // current tail tag (load colors)

    // fill from the memory pipe's EX stage
    input  wire        fill_en,
    input  wire [2:0]  fill_pos,
    input  wire [31:0] fill_addr,
    input  wire [31:0] fill_data,
    input  wire [2:0]  fill_f3,

    // retire marks the oldest unmarked entry committed (<=1/cycle)
    input  wire        retire_mark_en,

    // memory drain port (top routes to dmem/mmio; also lockstep snoop)
    output wire        mw_valid,
    output wire [31:0] mw_addr,
    output wire [31:0] mw_data,
    output wire [2:0]  mw_f3,

    // load forwarding query (combinational)
    input  wire [31:0] q_addr,
    input  wire [3:0]  q_color4,
    output reg         q_hit,        // full-word match: use q_data
    output reg  [31:0] q_data,
    output reg         q_conflict,   // partial overlap: replay the load

    // squash: restore tail to checkpoint value, killing younger entries
    input  wire        flush_en,
    input  wire [3:0]  flush_tail4,

    // scheduler view: valid entries whose address is still unknown
    output wire [7:0]  unknown_mask
);

`include "ooo_pkg.vh"

    reg        v       [0:SQD-1];
    reg        known   [0:SQD-1];
    reg        comm    [0:SQD-1];
    reg [3:0]  tag4    [0:SQD-1];
    reg [31:0] addr    [0:SQD-1];
    reg [31:0] data    [0:SQD-1];
    reg [2:0]  f3      [0:SQD-1];

    reg [3:0] head, tail, cptr;      // 4-bit counters (3 idx + phase)
    assign tail4 = tail;

    wire [3:0] occupancy = tail - head;
    assign free_ge1   = (occupancy < 4'd8);
    assign free_ge2   = (occupancy < 4'd7);

    // A store's address becomes visible to the load scheduler the same
    // cycle it executes (combinational fill bypass) — one cycle earlier
    // than the registered `known` bit alone would allow.
    genvar g;
    generate
        for (g = 0; g < SQD; g = g + 1) begin : UM
            assign unknown_mask[g] = v[g] && !known[g]
                                     && !(fill_en && (fill_pos == g[2:0]));
        end
    endgenerate

    // ------------------------------------------------------------------
    // drain port: head entry, once committed
    // ------------------------------------------------------------------
    wire [2:0] hidx = head[2:0];
    assign mw_valid = v[hidx] && comm[hidx] && (occupancy != 4'd0);
    assign mw_addr  = addr[hidx];
    assign mw_data  = data[hidx];
    assign mw_f3    = f3[hidx];

    // ------------------------------------------------------------------
    // load forwarding: youngest older matching store decides
    // ------------------------------------------------------------------
    integer k;
    reg        m_found;
    reg [3:0]  m_age;
    reg [31:0] m_data;
    reg        m_word;
    always @(*) begin
        m_found = 1'b0; m_age = 4'd0; m_data = 32'b0; m_word = 1'b0;
        for (k = 0; k < SQD; k = k + 1) begin
            if (v[k] && known[k]
                && (addr[k][31:2] == q_addr[31:2])
                && ((tag4[k] - head) < (q_color4 - head))) begin
                if (!m_found || ((tag4[k] - head) > m_age)) begin
                    m_found = 1'b1;
                    m_age   = tag4[k] - head;
                    m_data  = data[k];
                    m_word  = (f3[k][1:0] == 2'b10);   // SW covers any load
                end
            end
        end
        q_hit      = m_found && m_word;
        q_data     = m_data;
        q_conflict = m_found && !m_word;
    end

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            head <= 4'b0; tail <= 4'b0; cptr <= 4'b0;
            for (i = 0; i < SQD; i = i + 1) begin
                v[i] <= 1'b0; known[i] <= 1'b0; comm[i] <= 1'b0;
                tag4[i] <= 4'b0; addr[i] <= 32'b0; data[i] <= 32'b0;
                f3[i] <= 3'b0;
            end
        end else begin
            // allocation (0, 1 or 2 entries at tail, tail+1)
            if (alloc_n != 2'd0) begin
                v[tail[2:0]]     <= 1'b1;
                known[tail[2:0]] <= 1'b0;
                comm[tail[2:0]]  <= 1'b0;
                tag4[tail[2:0]]  <= tail;
                if (alloc_n == 2'd2) begin
                    v[tail[2:0]+3'd1]     <= 1'b1;
                    known[tail[2:0]+3'd1] <= 1'b0;
                    comm[tail[2:0]+3'd1]  <= 1'b0;
                    tag4[tail[2:0]+3'd1]  <= tail + 4'd1;
                end
                tail <= tail + {2'b0, alloc_n};
            end

            // fill (address/data capture at EX)
            if (fill_en) begin
                known[fill_pos] <= 1'b1;
                addr[fill_pos]  <= fill_addr;
                data[fill_pos]  <= fill_data;
                f3[fill_pos]    <= fill_f3;
            end

            // retire marks next-to-commit
            if (retire_mark_en) begin
                comm[cptr[2:0]] <= 1'b1;
                cptr <= cptr + 4'd1;
            end

            // drain
            if (mw_valid) begin
                v[hidx] <= 1'b0;
                head    <= head + 4'd1;
            end

            // squash: rewind tail, invalidate younger-than-new-tail
            if (flush_en) begin
                tail <= flush_tail4;
                for (i = 0; i < SQD; i = i + 1)
                    if (v[i] && !((tag4[i] - head) < (flush_tail4 - head)))
                        v[i] <= 1'b0;
                // a same-cycle allocation is wrong-path by construction
                if (alloc_n != 2'd0) begin
                    v[tail[2:0]] <= 1'b0;
                    if (alloc_n == 2'd2) v[tail[2:0]+3'd1] <= 1'b0;
                end
            end
        end
    end

endmodule
