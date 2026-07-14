// ============================================================================
// ooo_sq — 8-entry store queue (decisions D013/D027)
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
    input  wire [3:0]  fill_tag4,    // full identity; assertion-only in synth
    input  wire [31:0] fill_addr,
    input  wire [31:0] fill_data,
    input  wire [2:0]  fill_f3,

    // retire marks the oldest unmarked entry committed (<=1/cycle)
    input  wire        retire_mark_en,

    // memory drain port (top routes to dmem/mmio/npu; also lockstep
    // snoop). mw_ready=0 holds the head in place — used by the NPU
    // backpressure (docs/NPU.md D014): a committed store must not reach
    // a busy device, so the drain waits instead.
    output wire        mw_valid,
    output wire [31:0] mw_addr,
    output wire [31:0] mw_data,
    output wire [2:0]  mw_f3,
    input  wire        mw_ready,

    // load forwarding query (combinational)
    input  wire        q_valid,      // qualifies color-window assertions
    input  wire [31:0] q_addr,
    input  wire [3:0]  q_color4,
    output wire        q_hit,        // full-word match: use q_data
    output wire [31:0] q_data,
    output wire        q_conflict,   // partial overlap: replay the load
    output wire        q_older,      // ANY older store still buffered —
                                     // IO loads replay on this (D014/B010)

    // squash: restore tail to checkpoint value, killing younger entries
    input  wire        flush_en,
    input  wire [3:0]  flush_tail4,

    // committed-tail tag (D020): the tag just past the last committed store.
    // A load-ordering-violation flush rewinds the SQ tail here — all older
    // (committed) stores survive to drain, all younger uncommitted stores die.
    output wire [3:0]  commit_tail4,

    // occupancy==0 (D020): after a violation flush the pipeline waits for the
    // SQ to fully drain to dmem, so a re-executed load reads correct memory
    // without depending on post-flush SQ-forward color arithmetic.
    output wire        sq_empty,

    // scheduler view: valid entries whose address is still unknown
    output wire [7:0]  unknown_mask,

    // raw view (no same-cycle fill bypass) — consumed ONLY by the
    // simulation-side wait-mask invariant check in ooo_iq (D021, INV-P5);
    // dead logic in synthesis
    output wire [7:0]  unknown_raw
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
    assign commit_tail4 = cptr;      // tag just past the last committed store

    wire [3:0] occupancy = tail - head;
    assign free_ge1   = (occupancy < 4'd8);
    assign free_ge2   = (occupancy < 4'd7);
    assign sq_empty   = (occupancy == 4'd0);

    // A store's address becomes visible to the load scheduler the same
    // cycle it executes (combinational fill bypass) — one cycle earlier
    // than the registered `known` bit alone would allow.
    genvar g;
    generate
        for (g = 0; g < SQD; g = g + 1) begin : UM
            assign unknown_mask[g] = v[g] && !known[g]
                                     && !(fill_en && (fill_pos == g[2:0]));
            assign unknown_raw[g]  = v[g] && !known[g];
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
    // Load forwarding: balanced youngest-older reduction (D027).
    //
    // The old source-ordered loop synthesized into an 8-deep compare/mux
    // cascade on every D026 top-20 setup path. Form all older/match predicates
    // in parallel and carry the selected payload through a fixed 8 -> 4 -> 2
    // -> 1 tree. The 38-bit tuple is:
    //   {valid_match, age_from_head, is_full_word, store_data}
    // The larger age is the YOUNGEST store older than the load. On the
    // defensive equal-age case, the left/lower-index entry wins exactly like
    // the old ascending scan's strict-`>` update. No register or load latency
    // is added. q_older remains an independent ordering predicate: unknown or
    // different-address older stores must still block MMIO/NPU loads.
    // ------------------------------------------------------------------
    function [37:0] youngest_of_two;
        input [37:0] left;
        input [37:0] right;
        begin
            if (!left[37])
                youngest_of_two = right;
            else if (right[37] && (right[36:33] > left[36:33]))
                youngest_of_two = right;
            else
                youngest_of_two = left;
        end
    endfunction

    wire [3:0] q_age;
    wire [3:0] q_entry_age [0:SQD-1];
    wire [SQD-1:0] q_older_vec;
    wire [SQD-1:0] q_match_vec;
    wire [37:0] q_cand [0:SQD-1];

    assign q_age = q_color4 - head;

    genvar qg;
    generate for (qg = 0; qg < SQD; qg = qg + 1) begin : GEN_Q_CAND
        assign q_entry_age[qg] = tag4[qg] - head;
        assign q_older_vec[qg] = v[qg] && (q_entry_age[qg] < q_age);
        assign q_match_vec[qg] = q_older_vec[qg]
                               && known[qg]
                               && (addr[qg][31:2] == q_addr[31:2]);
        assign q_cand[qg] = {q_match_vec[qg], q_entry_age[qg],
                             (f3[qg][1:0] == 2'b10), data[qg]};
    end endgenerate

    wire [37:0] q_l1 [0:3];
    wire [37:0] q_l2 [0:1];
    wire [37:0] q_winner;
    wire        q_older_lo;
    wire        q_older_hi;

    assign q_l1[0] = youngest_of_two(q_cand[0], q_cand[1]);
    assign q_l1[1] = youngest_of_two(q_cand[2], q_cand[3]);
    assign q_l1[2] = youngest_of_two(q_cand[4], q_cand[5]);
    assign q_l1[3] = youngest_of_two(q_cand[6], q_cand[7]);
    assign q_l2[0] = youngest_of_two(q_l1[0], q_l1[1]);
    assign q_l2[1] = youngest_of_two(q_l1[2], q_l1[3]);
    assign q_winner = youngest_of_two(q_l2[0], q_l2[1]);

    assign q_older_lo = |q_older_vec[3:0];
    assign q_older_hi = |q_older_vec[7:4];
    assign q_older    = q_older_lo || q_older_hi;
    assign q_hit      = q_winner[37] && q_winner[32];
    assign q_data     = q_winner[37] ? q_winner[31:0] : 32'b0;
    assign q_conflict = q_winner[37] && !q_winner[32];

`ifdef VERILATOR
    initial if (SQD != 8)
        $fatal(1, "ooo_sq: fixed forwarding tree requires SQD=8 (got %0d)",
               SQD);

    // INV-S1: independent copy of the original source-order scan. Every
    // standalone and full-core Verilator cycle is an equivalence check for
    // all four externally visible query outputs.
    reg        q_ref_found;
    reg [3:0]  q_ref_age;
    reg [31:0] q_ref_data;
    reg        q_ref_word;
    reg        q_ref_older;
    integer    q_ref_i;
    always @(*) begin
        q_ref_found = 1'b0;
        q_ref_age   = 4'd0;
        q_ref_data  = 32'b0;
        q_ref_word  = 1'b0;
        q_ref_older = 1'b0;
        for (q_ref_i = 0; q_ref_i < SQD; q_ref_i = q_ref_i + 1) begin
            if (v[q_ref_i]
                && ((tag4[q_ref_i] - head) < (q_color4 - head)))
                q_ref_older = 1'b1;
            if (v[q_ref_i] && known[q_ref_i]
                && (addr[q_ref_i][31:2] == q_addr[31:2])
                && ((tag4[q_ref_i] - head) < (q_color4 - head))) begin
                if (!q_ref_found
                    || ((tag4[q_ref_i] - head) > q_ref_age)) begin
                    q_ref_found = 1'b1;
                    q_ref_age   = tag4[q_ref_i] - head;
                    q_ref_data  = data[q_ref_i];
                    q_ref_word  = (f3[q_ref_i][1:0] == 2'b10);
                end
            end
        end
    end

    integer sq_inv_i;
    integer sq_inv_j;
    reg [3:0] sq_inv_live;
    reg [3:0] sq_inv_age;
    reg [3:0] sq_inv_commit_age;
    reg [3:0] sq_inv_flush_age;
    always @(posedge clk) if (!reset) begin
        if ((q_hit !== (q_ref_found && q_ref_word))
            || (q_data !== q_ref_data)
            || (q_conflict !== (q_ref_found && !q_ref_word))
            || (q_older !== q_ref_older))
            $fatal(1, "ooo_sq INV-S1: tree=%b/%08x/%b/%b scan=%b/%08x/%b/%b",
                   q_hit, q_data, q_conflict, q_older,
                   q_ref_found && q_ref_word, q_ref_data,
                   q_ref_found && !q_ref_word, q_ref_older);

        // INV-S2: local ring-window and request contracts. They turn silent
        // pointer corruption (for example alloc_n=3) into an exact failure.
        if (occupancy > 4'd8)
            $fatal(1, "ooo_sq INV-S2: occupancy %0d exceeds depth", occupancy);
        if (alloc_n > 2)
            $fatal(1, "ooo_sq INV-S2: alloc_n=%0d is outside 0..2", alloc_n);
        if (({1'b0, occupancy} + {3'b0, alloc_n}) > 5'd8)
            $fatal(1, "ooo_sq INV-S2: allocation exceeds capacity");

        sq_inv_live = 0;
        sq_inv_commit_age = cptr - head;
        for (sq_inv_i = 0; sq_inv_i < SQD; sq_inv_i = sq_inv_i + 1) begin
            if (v[sq_inv_i]) begin
                sq_inv_live = sq_inv_live + 1;
                sq_inv_age = tag4[sq_inv_i] - head;
                if (tag4[sq_inv_i][2:0] != sq_inv_i[2:0])
                    $fatal(1, "ooo_sq INV-S2: slot/tag mismatch at %0d",
                           sq_inv_i);
                if (sq_inv_age >= occupancy)
                    $fatal(1, "ooo_sq INV-S2: live tag outside window");
                if (comm[sq_inv_i] != (sq_inv_age < sq_inv_commit_age))
                    $fatal(1, "ooo_sq INV-S2: committed prefix broken");
                if (comm[sq_inv_i] && !known[sq_inv_i])
                    $fatal(1, "ooo_sq INV-S2: committed store is unknown");
            end
            for (sq_inv_j = sq_inv_i + 1; sq_inv_j < SQD;
                 sq_inv_j = sq_inv_j + 1)
                if (v[sq_inv_i] && v[sq_inv_j]
                    && (tag4[sq_inv_i] == tag4[sq_inv_j]))
                    $fatal(1, "ooo_sq INV-S2: duplicate live tag %0d",
                           tag4[sq_inv_i]);
        end
        if (sq_inv_live != occupancy)
            $fatal(1, "ooo_sq INV-S2: live=%0d occupancy=%0d",
                   sq_inv_live, occupancy);
        if (sq_inv_commit_age > occupancy)
            $fatal(1, "ooo_sq INV-S2: cptr lies beyond tail");

        // INV-S3: operation targets and externally visible implications.
        if (fill_en
            && (!v[fill_pos] || known[fill_pos]
                || (tag4[fill_pos] != fill_tag4)))
            $fatal(1, "ooo_sq INV-S3: fill target is not live unknown");
        if (retire_mark_en
            && (!v[cptr[2:0]] || !known[cptr[2:0]] || comm[cptr[2:0]]))
            $fatal(1, "ooo_sq INV-S3: retire target is not live known next");
        if (flush_en) begin
            sq_inv_flush_age = flush_tail4 - head;
            if ((sq_inv_flush_age < sq_inv_commit_age)
                || (sq_inv_flush_age > occupancy))
                $fatal(1, "ooo_sq INV-S3: flush tail outside cptr..tail");
        end
        if (q_valid && ((q_color4 - head) > occupancy))
            $fatal(1, "ooo_sq INV-S3: load color outside head..tail");
        if (q_hit && q_conflict)
            $fatal(1, "ooo_sq INV-S3: hit and conflict both set");
        if ((q_hit || q_conflict) && !q_older)
            $fatal(1, "ooo_sq INV-S3: match without older store");
        if (mw_valid
            && (!v[hidx] || !known[hidx] || !comm[hidx]
                || (tag4[hidx] != head)))
            $fatal(1, "ooo_sq INV-S3: invalid drain head");
    end
`endif

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

            // drain (held while the target device backpressures)
            if (mw_valid && mw_ready) begin
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
