// ============================================================================
// gshare_bp — gshare direction predictor + tagged BTB (2 lookup ports)
//
// Purpose:    Frontend prediction for the 2-wide OoO core (D013).
//             Direction: gshare (GHR xor pc) into a 2-bit PHT.
//             Target:    direct-tagged BTB storing target + is_cond.
// Interfaces: two same-cycle lookups (fetch slots pc, pc+4); one train
//             port (EX resolve for branches/JALR, decode for JAL); GHR
//             speculative shift at fetch, absolute restore on mispredict.
// Conventions:
//   * A slot predicts TAKEN only on BTB hit AND (uncond OR gshare says
//     taken). Unknown branches (BTB miss) fall through — the resolve
//     path trains them.
//   * The GHR the caller attaches to each fetched slot is the PRE-shift
//     value: the checkpoint restores it and shifts in the actual
//     outcome, so history stays exact across mispredicts.
//
// D024 (A1): the PHT is TWO even/odd-banked sync-read M9Ks, not a fabric
// flop array. The old async-read PHT cost ~9k LEs: Quartus duplicated
// the 1024x2 array per read port (the read index pc^ghr is a
// combinational function of two registers, so no address register
// exists for it to retime into a RAM — unlike the BTB, whose pc-only
// index lets Quartus infer M9K by retiming pcF's register).
//
//   * Banking proof: pidx = pc[11:2]^ghr and the pair is (pc, pc+4), so
//     the two indices differ in bit0 ALWAYS (+4 flips pc[2]; the xor
//     with ghr[0] flips both parities equally). Slot0/slot1 therefore
//     never collide in banks split on pidx[0] — the D022 imem_banked
//     argument, applied to the PHT. Bank address = pidx[9:1].
//   * Read timing: the banks' address registers load the NEXT cycle's
//     indices, computed from npc0 (the exact value pcF will hold after
//     this edge — ALL redirect paths included, mirrored from the pcF
//     priority mux in ooo_cpu) and ghr_nx (this module's own GHR
//     next-value). Predictions therefore arrive the same fetch cycle as
//     the old async read, for redirects and holds alike. Two self-checks
//     guard this on every cycle of every test: INV-G1 (the pre-registered
//     read INDEX equals the pc actually being fetched — address timing)
//     and INV-G2 (the crossbarred dir0/dir1 equals a flat replay-shadow —
//     bank routing + crossbar polarity, the DATA path).
//   * The output crossbar un-swaps the banks using the parity
//     REGISTERED with the read (par0_q), imem_banked's sel_q argument.
//   * Training is a 2-phase read-modify-write on each bank's port B
//     (read tidx, write ctr±1 next cycle) with a 1-deep skid queue —
//     sustained 1 train/cycle alternating banks, 1 per 2 cycles to the
//     same bank; beyond that events are DROPPED (tr_drops counter).
//     Predictor state is a hint, never architecturally visible, so a
//     dropped update is a (counted) accuracy detail, not a bug.
//   * Warm reset: the M9K contents survive `reset` (MIF init happens at
//     device configuration only). A warm-trained PHT is a valid
//     predictor state; the BTB valid bits and GHR still reset, so
//     post-reset behavior stays sane. The behavioral arm mirrors this:
//     init once at time 0, no reset term.
// ============================================================================
module gshare_bp (
    input  wire        clk,
    input  wire        reset,

    // fetch-slot lookups (combinational)
    input  wire [31:0] pc0,
    input  wire [31:0] pc1,
    // D024: the value pcF will hold AFTER this edge (the pcF priority
    // mux output, all redirects included) — feeds the PHT banks'
    // address registers so direction is ready in pc0's own fetch cycle.
    input  wire [31:0] npc0,
    output wire        hit0,       // BTB hit
    output wire        cond0,      // entry is a conditional branch
    output wire        dir0,       // gshare direction for pc0
    output wire [31:0] target0,
    output wire        hit1,
    output wire        cond1,
    output wire        dir1,
    output wire [31:0] target1,

    // current speculative history (attached to fetched uops)
    output wire [9:0]  ghr_out,
    // speculative GHR shift: fetch asserts when a slot consumed a
    // conditional-branch prediction (shift in the predicted direction)
    input  wire        spec_shift,
    input  wire        spec_dir,
    // absolute GHR restore (mispredict recovery), then shift actual
    input  wire        restore_en,
    input  wire [9:0]  restore_ghr,
    input  wire        restore_shift,   // restored uop was conditional
    input  wire        restore_dir,     // its actual direction

    // train port (EX resolve; also decode-redirect for JAL)
    input  wire        train_en,
    input  wire [31:0] train_pc,
    input  wire        train_cond,      // conditional branch (vs JAL/JALR)
    input  wire        train_taken,
    input  wire [31:0] train_target,
    input  wire [9:0]  train_ghr        // pre-shift GHR at that fetch
);

`include "ooo_pkg.vh"

    // ------------------------------------------------------------ BTB
    // (unchanged by D024 — Quartus already infers these arrays into M9K
    // by retiming the fetch pc register into the RAM address port.)
    reg [31:0] btb_target [0:BTBD-1];
    reg [23:0] btb_tag    [0:BTBD-1];   // pc[31:8]
    reg        btb_valid  [0:BTBD-1];
    reg        btb_cond   [0:BTBD-1];

    wire [5:0]  idx0 = pc0[7:2];
    wire [5:0]  idx1 = pc1[7:2];
    assign hit0    = btb_valid[idx0] && (btb_tag[idx0] == pc0[31:8]);
    assign target0 = btb_target[idx0];
    assign cond0   = btb_cond[idx0];
    assign hit1    = btb_valid[idx1] && (btb_tag[idx1] == pc1[31:8]);
    assign target1 = btb_target[idx1];
    assign cond1   = btb_cond[idx1];

    // ------------------------------------------------------------ GHR
    reg [9:0] ghr;
    assign ghr_out = ghr;

    // The GHR's next value, shared by the register itself and the PHT
    // read pre-computation (restore beats speculative shift, as before).
    wire [9:0] ghr_nx = restore_en
                          ? (restore_shift ? {restore_ghr[8:0], restore_dir}
                                           : restore_ghr)
                          : (spec_shift ? {ghr[8:0], spec_dir} : ghr);

    // ------------------------------------------- PHT read (D024 banks)
    // Next-cycle indices for both fetch slots. During reset pcF is held
    // at 0 and ghr at 0, so the address registers pre-load index(0,0)
    // and the first real fetch (pc=0) reads correct entries.
    wire [9:0] ghr_eff = reset ? 10'b0 : ghr_nx;
    wire [9:0] npidx0  = (reset ? 10'b0 : npc0[11:2])          ^ ghr_eff;
    wire [9:0] npidx1  = (reset ? 10'd1 : npc0[11:2] + 10'd1)  ^ ghr_eff;

    wire       npar0   = npidx0[0];          // 1 = slot0 reads the ODD bank
    wire [8:0] addrE_n = npar0 ? npidx1[9:1] : npidx0[9:1];
    wire [8:0] addrO_n = npar0 ? npidx0[9:1] : npidx1[9:1];

    // ------------------------------------------------ PHT train events
    // Only conditional branches train the PHT (as before). Route by
    // index parity; each bank's engine does the 2-phase RMW.
    wire       pht_tr = train_en && train_cond;
    wire [9:0] tidx   = train_pc[11:2] ^ train_ghr;

    wire [1:0] rqE, rqO;
    wire       weE, weO;
    wire [8:0] waE, waO;
    wire [1:0] wvE, wvO;
    gshare_pht_bank BANK_E (
        .clk(clk), .reset(reset),
        .raddr_n(addrE_n), .rq(rqE),
        .ev_v(pht_tr && !tidx[0]), .ev_addr(tidx[9:1]), .ev_tkn(train_taken),
        .wr_en_o(weE), .wr_addr_o(waE), .wr_val_o(wvE)
    );
    gshare_pht_bank BANK_O (
        .clk(clk), .reset(reset),
        .raddr_n(addrO_n), .rq(rqO),
        .ev_v(pht_tr &&  tidx[0]), .ev_addr(tidx[9:1]), .ev_tkn(train_taken),
        .wr_en_o(weO), .wr_addr_o(waO), .wr_val_o(wvO)
    );

    // Crossbar select = the parity registered WITH the read (a select
    // from the live pc would mis-pair after redirects/holds).
    reg par0_q;
    always @(posedge clk) par0_q <= npar0;

    assign dir0 = par0_q ? rqO[1] : rqE[1];
    assign dir1 = par0_q ? rqE[1] : rqO[1];

    // ------------------------------------------------------- registers
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ghr <= 10'b0;
            for (i = 0; i < BTBD; i = i + 1) btb_valid[i] <= 1'b0;
        end else begin
            ghr <= ghr_nx;

            if (train_en) begin
                // BTB learns every taken control-flow instruction
                if (train_taken) begin
                    btb_valid [train_pc[7:2]] <= 1'b1;
                    btb_tag   [train_pc[7:2]] <= train_pc[31:8];
                    btb_target[train_pc[7:2]] <= train_target;
                    btb_cond  [train_pc[7:2]] <= train_cond;
                end
            end
        end
    end

`ifdef VERILATOR
    // INV-G1 (D024): the pre-registered read indices must equal the
    // live-recomputed indices of the pc actually being fetched — this
    // re-derives pidx from pc0/ghr every cycle and fatals on any npc0
    // path the pcF mirror missed. Armed in every run of every test.
    reg        chk_was_reset;
    reg [9:0]  chk_idx0_q, chk_idx1_q;
    initial begin chk_was_reset = 1'b1; chk_idx0_q = 0; chk_idx1_q = 0; end
    always @(posedge clk) begin
        if (!reset && !chk_was_reset) begin
            if (chk_idx0_q != (pc0[11:2] ^ ghr))
                $fatal(1, "gshare_bp INV-G1: slot0 PHT index stale (pc=%h)",
                       pc0);
            if (chk_idx1_q != (pc1[11:2] ^ ghr))
                $fatal(1, "gshare_bp INV-G1: slot1 PHT index stale (pc=%h)",
                       pc1);
        end
        chk_was_reset <= reset;
        chk_idx0_q    <= npidx0;
        chk_idx1_q    <= npidx1;
    end

    // INV-G2 (D024): read-routing shadow. A FLAT 1024x2 PHT is written by
    // REPLAYING the two banks' committed writes at their reconstructed
    // flat indices ({wr_addr, parity}); it is read at the flat slot
    // indices with the same 1-cycle latency as the banks. The crossbarred
    // dir0/dir1 must equal this flat read. This is independent of the
    // even/odd split, the address routing, and the crossbar polarity, so a
    // swapped bank address (addrE_n/addrO_n) or flipped crossbar (par0_q)
    // reads the wrong entry and FATALS here — the data-path check the
    // index-only INV-G1 does not provide (mirrors imem_banked's INV-F1).
    // Same-cycle read/write on one entry uses NBA read-first == the M9K
    // OLD_DATA mode, so the shadow and the banks stay bit-consistent.
    reg [1:0] sh_pht [0:PHTD-1];
    reg [1:0] sh_rq0, sh_rq1;
    integer g;
    initial for (g = 0; g < PHTD; g = g + 1) sh_pht[g] = 2'b01;  // weak NT
    always @(posedge clk) begin
        sh_rq0 <= sh_pht[npidx0];
        sh_rq1 <= sh_pht[npidx1];
        if (weE) sh_pht[{waE, 1'b0}] <= wvE;
        if (weO) sh_pht[{waO, 1'b1}] <= wvO;
    end
    always @(posedge clk) if (!reset && !chk_was_reset) begin
        if (dir0 !== sh_rq0[1])
            $fatal(1, "gshare_bp INV-G2: dir0 read-routing mismatch (pc=%h)",
                   pc0);
        if (dir1 !== sh_rq1[1])
            $fatal(1, "gshare_bp INV-G2: dir1 read-routing mismatch (pc=%h)",
                   pc1);
    end
`endif

endmodule

// ============================================================================
// gshare_pht_bank — one 512x2 PHT bank (D024): sync-read port A for the
// fetch slot, 2-phase read-modify-write train engine on port B with a
// 1-deep skid queue. Behavioral arm mirrors altsyncram semantics
// exactly: address-registered reads, OLD_DATA on mixed-port collisions,
// contents initialized once (MIF at configuration / initial at time 0)
// and NOT cleared by reset — see the D024 warm-reset note above.
// ============================================================================
module gshare_pht_bank (
    input  wire       clk,
    input  wire       reset,
    // port A: fetch read (address registered every cycle, data next cycle)
    input  wire [8:0] raddr_n,
    output wire [1:0] rq,
    // train event routed to this bank (at most one per cycle)
    input  wire       ev_v,
    input  wire [8:0] ev_addr,
    input  wire       ev_tkn,
    // committed write, exposed for the INV-G2 shadow check (D024). Real
    // signals in both arms; unused in synthesis (swept, zero cost).
    output wire       wr_en_o,
    output wire [8:0] wr_addr_o,
    output wire [1:0] wr_val_o
);

    // --------------------------------------------- 2-phase RMW engine
    // wrv=1 means port B is WRITING this cycle (the event read last
    // cycle); otherwise port B READS the queued event, else the
    // incoming one. An event arriving while the queue is full is
    // dropped (counted) — a hint lost, never a correctness issue.
    reg        qv;                   // skid queue
    reg  [8:0] qaddr;
    reg        qtkn;
    reg        wrv;                  // write phase pending
    reg  [8:0] wraddr;
    reg        wrtkn;

    wire       issue_rd = !wrv && (qv || ev_v);
    wire [8:0] rd_addr  = qv ? qaddr : ev_addr;
    wire       rd_tkn   = qv ? qtkn  : ev_tkn;

    wire [1:0] ctr_old;              // port B read data (write cycle)
    wire [1:0] ctr_new = wrtkn ? (ctr_old == 2'b11 ? 2'b11 : ctr_old + 2'b01)
                               : (ctr_old == 2'b00 ? 2'b00 : ctr_old - 2'b01);

    wire       b_wr    = wrv;
    wire [8:0] b_addr  = wrv ? wraddr : rd_addr;

    // Committed-write taps for the top-level INV-G2 shadow (D024).
    assign wr_en_o   = b_wr;
    assign wr_addr_o = wraddr;
    assign wr_val_o  = ctr_new;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            qv  <= 1'b0;
            wrv <= 1'b0;
        end else begin
            wrv <= issue_rd;
            if (issue_rd) begin
                wraddr <= rd_addr;
                wrtkn  <= rd_tkn;
            end
            if (issue_rd) begin
                // source consumed; a same-cycle arrival takes the queue
                qv <= qv ? ev_v : 1'b0;
                if (qv && ev_v) begin qaddr <= ev_addr; qtkn <= ev_tkn; end
            end else if (ev_v && !qv) begin
                qv <= 1'b1; qaddr <= ev_addr; qtkn <= ev_tkn;
            end
            // else: ev_v && !issue_rd && qv -> dropped (counted below)
        end
    end

`ifdef VERILATOR
    // Train throughput observability (read via waves / future harness).
    reg [31:0] tr_events /*verilator public_flat_rd*/;
    reg [31:0] tr_drops  /*verilator public_flat_rd*/;
    initial begin tr_events = 0; tr_drops = 0; end
    always @(posedge clk) if (!reset) begin
        if (ev_v)                     tr_events <= tr_events + 1;
        if (ev_v && !issue_rd && qv)  tr_drops  <= tr_drops  + 1;
    end

    // Behavioral RAM: read-first on both ports (== altsyncram OLD_DATA);
    // init once at time 0 (== MIF at configuration), NO reset term.
    reg [1:0] mem [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mem[i] = 2'b01;  // weak NT

    reg [1:0] aq, bq;
    always @(posedge clk) begin
        aq <= mem[raddr_n];
        if (b_wr) mem[b_addr] <= ctr_new;
        else      bq <= mem[b_addr];
    end
    assign rq      = aq;
    assign ctr_old = bq;
`else
    // Synthesis: one M9K, true dual port. Port A read-only (fetch),
    // port B bidirectional (train RMW). Explicit altsyncram + MIF init
    // is REQUIRED on MAX 10 (B006/D022); pht_init.mif = all weak-NT.
    wire [1:0] q_b;
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(2),
        .widthad_a(9),
        .numwords_a(512),
        .width_b(2),
        .widthad_b(9),
        .numwords_b(512),
        .init_file("pht_init.mif"),
        .intended_device_family("MAX 10"),
        .ram_block_type("M9K"),
        .lpm_type("altsyncram"),
        .outdata_reg_a("UNREGISTERED"),
        .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"),
        .indata_reg_b("CLOCK0"),
        .wrcontrol_wraddress_reg_b("CLOCK0"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .address_aclr_a("NONE"),
        .address_aclr_b("NONE"),
        .outdata_aclr_a("NONE"),
        .outdata_aclr_b("NONE"),
        .clock_enable_input_a("BYPASS"),
        .clock_enable_output_a("BYPASS"),
        .clock_enable_input_b("BYPASS"),
        .clock_enable_output_b("BYPASS")
    ) U_BANK (
        .clock0(clk),
        .address_a(raddr_n),
        .wren_a(1'b0),
        .data_a(2'b00),
        .q_a(rq),
        .address_b(b_addr),
        .wren_b(b_wr),
        .data_b(ctr_new),
        .q_b(q_b)
    );
    assign ctr_old = q_b;
`endif

endmodule
