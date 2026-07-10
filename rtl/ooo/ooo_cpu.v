// ============================================================================
// ooo_cpu — 2-wide out-of-order RV32I+Zicsr core (decision D013)
//
// Drop-in replacement top for cpu_pipeline (same clk/reset/leds/switches
// interface). docs/OOO.md is the binding spec; read it first.
//
// Structure kept deliberately in ONE file for the tightly-coupled OoO
// state machine (rename tables, ROB, checkpoints, retire, exec pipes and
// recovery must update atomically); the self-contained structures live in
// their own modules (gshare_bp, ooo_decode, ooo_iq, ooo_sq, ooo_prf) and
// the leaf functions (alu, branch_unit, csr_file, memories) are shared
// with the in-order core.
//
// Pipeline: F -> D -> R(rename/dispatch) -> IS -> RF -> EX -> WB -> RT
// ============================================================================
`include "ooo_uop.vh"

module ooo_cpu #(
    // D021 load-speculation policy (constant-folded per build; Verilator
    // A/B override via -GLOAD_POLICY=<n>, see Makefile):
    //   0 = conservative — a load waits until every older store address is
    //       known (D020 SPEC_LOADS=0, cycle-identical)
    //   1 = always-speculate — loads never wait; the LQ violation CAM +
    //       flush-at-head repair real conflicts (D020 SPEC_LOADS=1,
    //       cycle-identical)
    //   2 = store-set predicted (Chrysos & Emer, docs/STORESET.md) — a load
    //       that has violated waits for its predicted producer store only
    //   3 = 1-bit load-wait table (Alpha 21264 stWait style, measured for
    //       comparison) — a load that has violated waits for ALL older
    //       unresolved store addresses (the conservative mask)
    parameter LOAD_POLICY = 2
) (
    input  wire clk,
    input  wire reset,
    output wire [9:0] leds,
    input  wire [9:0] switches
);

`include "ooo_pkg.vh"
`include "alu_ops.vh"

    integer i;

    // =====================================================================
    // Restore (mispredict recovery) bus — driven by port0 EX, consumed by
    // nearly everything. Declared first.
    // =====================================================================
    reg         restore_en;
    reg  [5:0]  restore_tag;      // mispredicting branch's ROB tag
    reg  [3:0]  restore_chk;      // its checkpoint tag (4b ring tag)
    reg  [31:0] restore_npc;
    reg  [9:0]  restore_ghr;
    reg         restore_shift;    // conditional? then shift in actual dir
    reg         restore_dir;

    // Load-ordering-violation recovery (D020, Strategy B-real). A poisoned
    // load flushes at the ROB head via a multi-cycle drain (rare — real
    // violations only). lq_drain != 0 stalls the whole machine while the
    // freelist is rebuilt from the architectural map (arat). See docs/LQ.md.
    // Load-violation flush-at-head is a multi-cycle drain (D020, rare). While
    // draining, the machine is frozen and the freelist ring is rebuilt one
    // phys tag per cycle from the architectural map. lq_state: 0=idle,
    // 1=sweeping. lq_sweep walks phys tags 0..PHYS; lq_wp is the freelist
    // write pointer (count of free tags found so far).
    reg         lq_state;
    reg  [6:0]  lq_sweep;         // 0..PHYS (64) — current phys tag under test
    reg  [5:0]  lq_wp;            // freelist write pointer / free count
    reg  [31:0] lq_flush_pc;      // (unused now; kept for probes/future)
    wire        lq_flushing = lq_state;

    // ROB head tag (for all age comparisons)
    reg  [4:0]  rob_head;
    reg         rob_head_ph;
    reg  [4:0]  rob_tail;
    reg         rob_tail_ph;
    wire [5:0]  head_tag = {rob_head_ph, rob_head};
    wire [5:0]  tail_tag = {rob_tail_ph, rob_tail};
    wire [5:0]  rob_count = tail_tag - head_tag;
    wire        rob_empty = (rob_count == 6'd0);

    function is_younger;             // strictly younger than anchor
        input [5:0] t;
        input [5:0] anchor;
        begin
            is_younger = ((t - head_tag) > (anchor - head_tag));
        end
    endfunction

    // =====================================================================
    // F — fetch (2-wide, unaligned pair)
    // =====================================================================
    reg  [31:0] pcF /*verilator public_flat_rd*/;
    wire [31:0] pc0 = pcF;
    wire [31:0] pc1 = pcF + 32'd4;

    wire fd_accept;                 // F/D register will load new content
    wire dr_accept;                 // D/R register will load new content
    wire dec_redirect;              // decode-stage redirect (JAL / RAS ret)
    wire [31:0] dec_redirect_pc;

    // Banked M9K program ROM (D022): the banks' read registers ARE the F/D
    // instruction registers (fd_i0/fd_i1 below) — the same latch fold as
    // D016 (in-order IF/ID) and D018 (dmem load). rd_en = fd_accept is the
    // whole contract: fd_v0/fd_v1 are set to 1 in exactly one place, the
    // lowest-priority `else if (fd_accept)` branch of the F/D block, so
    // every edge that asserts the valids also captures mem[pcF] — invariant:
    // whenever fd_v*=1 the ROM outputs are the words at fd_pc0/fd_pc1.
    // Every redirect (lq_flush_start/lq_flushing/restore_en/dec_redirect)
    // nulls the valids, so a stale or wrong-path capture is never consumed,
    // and the first fd_accept after a redirect captures the redirected pair
    // on the same edge it re-asserts the valids — the 2-cycle mispredict
    // penalty is unchanged. !fd_accept is the B012 hold: pcF has already
    // advanced past a held group, so the read registers must freeze with it.
    wire [31:0] fd_i0, fd_i1;
    imem_banked IMEM0 (
        .clk(clk), .rd_en(fd_accept),
        .pc(pc0),
        .instr0(fd_i0), .instr1(fd_i1)
    );

    wire        bt_hit0, bt_cond0, bt_dir0, bt_hit1, bt_cond1, bt_dir1;
    wire [31:0] bt_tgt0, bt_tgt1;
    wire [9:0]  ghr_now;

    // predictions
    wire take0      = bt_hit0 && (!bt_cond0 || bt_dir0);
    wire cond_used0 = bt_hit0 && bt_cond0;
    wire cond_used1 = bt_hit1 && bt_cond1;
    // slot1 dies if slot0 is predicted taken, or both slots would consume
    // a conditional prediction (1 GHR shift per cycle — see docs/OOO.md)
    wire kill1      = take0 || (cond_used0 && cond_used1);
    wire take1      = !kill1 && bt_hit1 && (!bt_cond1 || bt_dir1);
    wire [31:0] fetch_npc = take0 ? bt_tgt0
                          : take1 ? bt_tgt1
                          : kill1 ? pc1 : (pcF + 32'd8);
    wire [31:0] pnpc0_f = take0 ? bt_tgt0 : pc1;
    wire [31:0] pnpc1_f = take1 ? bt_tgt1 : (pcF + 32'd8);

    wire ghr_shift = fd_accept && (cond_used0 || (!kill1 && cond_used1));
    wire ghr_dir   = cond_used0 ? bt_dir0 : bt_dir1;

    // EX-resolve train signals (defined at port0 EX below)
    reg         train_en;
    reg  [31:0] train_pc;
    reg         train_cond;
    reg         train_taken;
    reg  [31:0] train_target;
    reg  [9:0]  train_ghr;
    // decode-stage JAL train (loses to EX train on collision)
    wire        dtrain_en;
    wire [31:0] dtrain_pc, dtrain_target;

    gshare_bp BP0 (
        .clk(clk), .reset(reset),
        .pc0(pc0), .pc1(pc1),
        .hit0(bt_hit0), .cond0(bt_cond0), .dir0(bt_dir0), .target0(bt_tgt0),
        .hit1(bt_hit1), .cond1(bt_cond1), .dir1(bt_dir1), .target1(bt_tgt1),
        .ghr_out(ghr_now),
        .spec_shift(ghr_shift && !restore_en),
        .spec_dir(ghr_dir),
        .restore_en(restore_en),
        .restore_ghr(restore_ghr),
        .restore_shift(restore_shift),
        .restore_dir(restore_dir),
        .train_en(train_en || dtrain_en),
        .train_pc(train_en ? train_pc : dtrain_pc),
        .train_cond(train_en ? train_cond : 1'b0),
        .train_taken(train_en ? train_taken : 1'b1),
        .train_target(train_en ? train_target : dtrain_target),
        .train_ghr(train_en ? train_ghr : 10'b0)
    );

    // F/D register (instructions live in IMEM0's read registers, D022)
    reg         fd_v0, fd_v1;
    reg  [31:0] fd_pc0, fd_pc1, fd_pnpc0, fd_pnpc1;
    reg  [9:0]  fd_ghr0, fd_ghr1;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pcF <= 32'b0;
            fd_v0 <= 1'b0; fd_v1 <= 1'b0;
            fd_pc0 <= 0; fd_pc1 <= 0;
            fd_pnpc0 <= 0; fd_pnpc1 <= 0; fd_ghr0 <= 0; fd_ghr1 <= 0;
        end else if (lq_flush_start) begin
            // load-ordering-violation flush: refetch from the violated load's
            // PC (D020). Front-end squashed; dispatch is frozen during drain.
            pcF   <= rob_pc[h0];
            fd_v0 <= 1'b0;
            fd_v1 <= 1'b0;
        end else if (lq_flushing) begin
            // hold the fetch PC steady while the freelist rebuild drains
            fd_v0 <= 1'b0;
            fd_v1 <= 1'b0;
        end else if (restore_en) begin
            pcF   <= restore_npc;
            fd_v0 <= 1'b0;
            fd_v1 <= 1'b0;
        end else if (dec_redirect) begin
            // the redirecting instruction moved into D/R; the in-flight
            // fetch is wrong-path
            pcF   <= dec_redirect_pc;
            fd_v0 <= 1'b0;
            fd_v1 <= 1'b0;
        end else if (fd_accept) begin
            pcF      <= fetch_npc;
            fd_v0    <= 1'b1;
            fd_v1    <= !kill1;
            fd_pc0   <= pc0;   fd_pc1   <= pc1;
            fd_pnpc0 <= pnpc0_f; fd_pnpc1 <= pnpc1_f;
            fd_ghr0  <= ghr_now; fd_ghr1 <= ghr_now;
        end
    end

    // =====================================================================
    // D — decode + RAS + decode-redirect
    // =====================================================================
    wire        d0_br, d0_jal, d0_jalr, d0_ld, d0_st, d0_csr, d0_wr;
    wire        d0_r1u, d0_r2u, d0_asrc, d0_apc;
    wire [3:0]  d0_actl;
    wire [31:0] d0_imm, d0_jtgt;
    wire [4:0]  d0_rs1, d0_rs2, d0_rd;
    wire [2:0]  d0_f3;
    ooo_decode DEC0 (
        .instr(fd_i0), .pc(fd_pc0),
        .is_branch(d0_br), .is_jal(d0_jal), .is_jalr(d0_jalr),
        .is_load(d0_ld), .is_store(d0_st), .is_csr(d0_csr), .wr(d0_wr),
        .rs1_used(d0_r1u), .rs2_used(d0_r2u),
        .alu_ctrl(d0_actl), .alu_src(d0_asrc), .alu_apc(d0_apc),
        .imm(d0_imm), .rs1(d0_rs1), .rs2(d0_rs2), .rd(d0_rd),
        .funct3(d0_f3), .jal_target(d0_jtgt)
    );

    wire        d1_br, d1_jal, d1_jalr, d1_ld, d1_st, d1_csr, d1_wr;
    wire        d1_r1u, d1_r2u, d1_asrc, d1_apc;
    wire [3:0]  d1_actl;
    wire [31:0] d1_imm, d1_jtgt;
    wire [4:0]  d1_rs1, d1_rs2, d1_rd;
    wire [2:0]  d1_f3;
    ooo_decode DEC1 (
        .instr(fd_i1), .pc(fd_pc1),
        .is_branch(d1_br), .is_jal(d1_jal), .is_jalr(d1_jalr),
        .is_load(d1_ld), .is_store(d1_st), .is_csr(d1_csr), .wr(d1_wr),
        .rs1_used(d1_r1u), .rs2_used(d1_r2u),
        .alu_ctrl(d1_actl), .alu_src(d1_asrc), .alu_apc(d1_apc),
        .imm(d1_imm), .rs1(d1_rs1), .rs2(d1_rs2), .rd(d1_rd),
        .funct3(d1_f3), .jal_target(d1_jtgt)
    );

    // RAS (decode-managed; TOS checkpointed, content best-effort)
    reg [31:0] ras [0:RASD-1];
    reg [2:0]  ras_tos;

    wire call0 = fd_v0 && (d0_jal || d0_jalr)
                 && (d0_rd == 5'd1 || d0_rd == 5'd5);
    wire ret0  = fd_v0 && d0_jalr && (d0_rd == 5'd0)
                 && (d0_rs1 == 5'd1 || d0_rs1 == 5'd5);

    // slot0 redirect decision
    wire [31:0] ras_top0 = ras[ras_tos];
    reg         redir0;
    reg  [31:0] pnpc0_d;
    always @(*) begin
        redir0  = 1'b0;
        pnpc0_d = fd_pnpc0;
        if (fd_v0 && d0_jal) begin
            pnpc0_d = d0_jtgt;
            redir0  = (fd_pnpc0 != d0_jtgt);
        end else if (ret0) begin
            pnpc0_d = ras_top0;
            redir0  = (fd_pnpc0 != ras_top0);
        end
    end
    wire [2:0] tos1 = call0 ? (ras_tos + 3'd1)
                    : ret0  ? (ras_tos - 3'd1) : ras_tos;

    wire d1_alive = fd_v1 && !redir0;
    wire call1 = d1_alive && (d1_jal || d1_jalr)
                 && (d1_rd == 5'd1 || d1_rd == 5'd5);
    wire ret1  = d1_alive && d1_jalr && (d1_rd == 5'd0)
                 && (d1_rs1 == 5'd1 || d1_rs1 == 5'd5);
    wire [31:0] ras_top1 = call0 ? (fd_pc0 + 32'd4) : ras[tos1];
    reg         redir1;
    reg  [31:0] pnpc1_d;
    always @(*) begin
        redir1  = 1'b0;
        pnpc1_d = fd_pnpc1;
        if (d1_alive && d1_jal) begin
            pnpc1_d = d1_jtgt;
            redir1  = (fd_pnpc1 != d1_jtgt);
        end else if (ret1) begin
            pnpc1_d = ras_top1;
            redir1  = (fd_pnpc1 != ras_top1);
        end
    end
    wire [2:0] tos2 = call1 ? (tos1 + 3'd1)
                    : ret1  ? (tos1 - 3'd1) : tos1;

    assign dec_redirect    = dr_accept && (redir0 || redir1) && !restore_en;
    assign dec_redirect_pc = redir0 ? pnpc0_d : pnpc1_d;

    // decode-train the BTB for taken JALs it missed (loses to EX train)
    assign dtrain_en = dr_accept && !restore_en
                       && ((fd_v0 && d0_jal && redir0)
                           || (d1_alive && d1_jal && redir1 && !redir0));
    assign dtrain_pc     = (fd_v0 && d0_jal && redir0) ? fd_pc0 : fd_pc1;
    assign dtrain_target = (fd_v0 && d0_jal && redir0) ? d0_jtgt : d1_jtgt;

    // RAS state update — only when this decode group actually advances
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ras_tos <= 3'b0;
            for (i = 0; i < RASD; i = i + 1) ras[i] <= 32'b0;
        end else if (restore_en) begin
            ras_tos <= chk_rastos_r;      // from the restoring checkpoint
        end else if (dr_accept) begin
            if (call0) ras[ras_tos + 3'd1] <= fd_pc0 + 32'd4;
            if (call1) ras[tos1 + 3'd1]    <= fd_pc1 + 32'd4;
            ras_tos <= tos2;
        end
    end

    // D/R register (rename inputs). Field-by-field, two slots.
    reg         dr_v0, dr_v1;
    reg  [31:0] dr_pc0, dr_pc1, dr_imm0, dr_imm1, dr_pnpc0, dr_pnpc1;
    reg  [9:0]  dr_ghr0, dr_ghr1;
    reg  [2:0]  dr_rtos0, dr_rtos1;
    reg         dr_br0, dr_jalr0, dr_ld0, dr_st0, dr_csr0, dr_wr0;
    reg         dr_br1, dr_jalr1, dr_ld1, dr_st1, dr_csr1, dr_wr1;
    reg         dr_r1u0, dr_r2u0, dr_asrc0, dr_apc0;
    reg         dr_r1u1, dr_r2u1, dr_asrc1, dr_apc1;
    reg  [3:0]  dr_actl0, dr_actl1;
    reg  [4:0]  dr_rs10, dr_rs20, dr_rd0, dr_rs11, dr_rs21, dr_rd1;
    reg  [2:0]  dr_f30, dr_f31;

    // rename decides how many D/R slots dispatch this cycle
    wire ok0, ok1;
    wire [1:0] n_disp = {1'b0, ok0} + {1'b0, ok1};
    wire [1:0] dr_cnt = {1'b0, dr_v0} + {1'b0, dr_v1};
    assign dr_accept = (n_disp == dr_cnt);   // empties this cycle
    assign fd_accept = dr_accept;            // F/D reloads exactly then

    wire d_have = fd_v0;                     // decode group present

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            dr_v0 <= 1'b0; dr_v1 <= 1'b0;
            dr_pc0<=0; dr_pc1<=0; dr_imm0<=0; dr_imm1<=0;
            dr_pnpc0<=0; dr_pnpc1<=0; dr_ghr0<=0; dr_ghr1<=0;
            dr_rtos0<=0; dr_rtos1<=0;
            dr_br0<=0; dr_jalr0<=0; dr_ld0<=0; dr_st0<=0; dr_csr0<=0; dr_wr0<=0;
            dr_br1<=0; dr_jalr1<=0; dr_ld1<=0; dr_st1<=0; dr_csr1<=0; dr_wr1<=0;
            dr_r1u0<=0; dr_r2u0<=0; dr_asrc0<=0; dr_apc0<=0;
            dr_r1u1<=0; dr_r2u1<=0; dr_asrc1<=0; dr_apc1<=0;
            dr_actl0<=0; dr_actl1<=0;
            dr_rs10<=0; dr_rs20<=0; dr_rd0<=0; dr_rs11<=0; dr_rs21<=0; dr_rd1<=0;
            dr_f30<=0; dr_f31<=0;
        end else if (restore_en || lq_flush_start || lq_flushing) begin
            // branch mispredict OR a load-violation flush-at-head: the D/R
            // group is wrong-path (or stale across the flush drain). Clear it
            // for the whole flush so no stale uop dispatches when the sweep
            // ends and the machine refetches the load's PC. (D020)
            dr_v0 <= 1'b0; dr_v1 <= 1'b0;
        end else if (dr_accept) begin
            // load the (possibly redirect-corrected) decode group. A
            // slot1 that itself redirects still dispatches — only the
            // fetch BEHIND it was wrong-path.
            dr_v0 <= d_have;
            dr_v1 <= d_have && d1_alive;
            dr_pc0 <= fd_pc0;   dr_pc1 <= fd_pc1;
            dr_imm0 <= d0_imm;  dr_imm1 <= d1_imm;
            dr_pnpc0 <= pnpc0_d; dr_pnpc1 <= pnpc1_d;
            dr_ghr0 <= fd_ghr0; dr_ghr1 <= fd_ghr1;
            dr_rtos0 <= tos1;   dr_rtos1 <= tos2;
            dr_br0 <= d0_br; dr_jalr0 <= d0_jalr; dr_ld0 <= d0_ld;
            dr_st0 <= d0_st; dr_csr0 <= d0_csr;
            dr_wr0 <= d0_wr && (d0_rd != 5'd0);
            dr_br1 <= d1_br; dr_jalr1 <= d1_jalr; dr_ld1 <= d1_ld;
            dr_st1 <= d1_st; dr_csr1 <= d1_csr;
            dr_wr1 <= d1_wr && (d1_rd != 5'd0);
            dr_r1u0 <= d0_r1u; dr_r2u0 <= d0_r2u;
            dr_asrc0 <= d0_asrc; dr_apc0 <= d0_apc;
            dr_r1u1 <= d1_r1u; dr_r2u1 <= d1_r2u;
            dr_asrc1 <= d1_asrc; dr_apc1 <= d1_apc;
            dr_actl0 <= d0_actl; dr_actl1 <= d1_actl;
            dr_rs10 <= d0_rs1; dr_rs20 <= d0_rs2; dr_rd0 <= d0_rd;
            dr_rs11 <= d1_rs1; dr_rs21 <= d1_rs2; dr_rd1 <= d1_rd;
            dr_f30 <= d0_f3;   dr_f31 <= d1_f3;
        end else if (ok0 && dr_v1) begin
            // partial dispatch: slot1 shifts into slot0
            dr_v0 <= 1'b1;  dr_v1 <= 1'b0;
            dr_pc0 <= dr_pc1;   dr_imm0 <= dr_imm1;
            dr_pnpc0 <= dr_pnpc1; dr_ghr0 <= dr_ghr1; dr_rtos0 <= dr_rtos1;
            dr_br0 <= dr_br1; dr_jalr0 <= dr_jalr1; dr_ld0 <= dr_ld1;
            dr_st0 <= dr_st1; dr_csr0 <= dr_csr1; dr_wr0 <= dr_wr1;
            dr_r1u0 <= dr_r1u1; dr_r2u0 <= dr_r2u1;
            dr_asrc0 <= dr_asrc1; dr_apc0 <= dr_apc1;
            dr_actl0 <= dr_actl1;
            dr_rs10 <= dr_rs11; dr_rs20 <= dr_rs21; dr_rd0 <= dr_rd1;
            dr_f30 <= dr_f31;
        end else if (ok0 && !dr_v1) begin
            dr_v0 <= 1'b0;
        end
    end

    // =====================================================================
    // R — rename / dispatch
    // =====================================================================
    reg  [5:0] rat  [0:31];
    // architectural RAT (D020): committed arch->phys map, updated at retire.
    // The recovery point for a load-ordering-violation flush-at-head, since a
    // load owns no checkpoint and rat[] is the (polluted) speculative map.
    reg  [5:0] arat [0:31];

    // is a physical tag currently architectural (mapped by some arch reg)?
    // Used by the flush-at-head freelist rebuild: every non-architectural tag
    // (except p0) is free after the flush.
    function in_arat;
        input [5:0] ptag;
        integer j;
        begin
            in_arat = 1'b0;
            for (j = 0; j < 32; j = j + 1)
                if (arat[j] == ptag) in_arat = 1'b1;
        end
    endfunction

    // (flush-at-head freelist rebuild is a per-cycle sweep, D020: see the FSM
    // in the main clocked block. Each cycle tests ONE phys tag via in_arat,
    // avoiding a wide nested-unroll that overwhelms elaboration.)
    reg        busy [0:PHYS-1];
    reg  [5:0] fl   [0:31];
    reg  [5:0] fl_alloc, fl_free;             // 6-bit ring counters
    wire [5:0] fl_avail = 6'd32 - (fl_alloc - fl_free);

    // checkpoints
    reg [191:0] chk_rat   [0:NCHKPT-1];
    reg [5:0]   chk_fl    [0:NCHKPT-1];
    reg [3:0]   chk_sqt   [0:NCHKPT-1];
    reg [9:0]   chk_ghr   [0:NCHKPT-1];
    reg [2:0]   chk_rtos  [0:NCHKPT-1];
    reg [3:0]   chk_a, chk_f;                 // alloc/free ring counters
    wire [3:0]  chk_avail = 4'd8 - (chk_a - chk_f);
    wire [2:0]  chk_rastos_r = chk_rtos[restore_chk[2:0]];

    // SQ interface wires. Store positions: slot0's store always lands at
    // tail; slot1's store lands at tail + (1 if slot0 is also a store).
    wire       sq_ge1, sq_ge2;
    wire [3:0] sq_tail4;
    wire [7:0] sq_unknown;
    wire [7:0] sq_unknown_raw;   // sim-only invariant view (D021)
    wire [2:0] sq_pos0 = sq_tail4[2:0];
    wire [2:0] sq_pos1 = sq_tail4[2:0] + {2'b0, dr_st0};

    // IQ interface wires
    wire iq_ge1, iq_ge2;

    // ctrl-op classification of D/R slots
    wire ctrl0 = dr_br0 | dr_jalr0;
    wire ctrl1 = dr_br1 | dr_jalr1;

    // resource checks (slot0 first; slot1 only as a pair extension)
    wire rob_ge1 = (rob_count <= 6'd31);
    wire rob_ge2 = (rob_count <= 6'd30);

    assign ok0 = dr_v0 && !restore_en && !lq_flushing && !lq_flush_start
                 && rob_ge1 && iq_ge1
                 && (!dr_wr0  || (fl_avail >= 6'd1))
                 && (!dr_st0  || sq_ge1)
                 && (!dr_ld0  || lq_ge1)
                 && (!ctrl0   || (chk_avail >= 4'd1))
                 && (!dr_csr0 || rob_empty);

    assign ok1 = ok0 && dr_v1
                 && !dr_csr1 && !dr_csr0
                 && rob_ge2 && iq_ge2
                 && (fl_avail >= ({5'b0, dr_wr0} + {5'b0, dr_wr1}))
                 && (!(dr_st0 && dr_st1) || sq_ge2)
                 && (!dr_st1 || sq_ge1)
                 && (!(dr_ld0 && dr_ld1) || lq_ge2)
                 && (!dr_ld1 || lq_ge1)
                 && (!ctrl1 || (chk_avail >= (ctrl0 ? 4'd2 : 4'd1)));

    // rename lookups
    wire [5:0] ps1_0 = rat[dr_rs10];
    wire [5:0] ps2_0 = rat[dr_rs20];
    wire [5:0] pd0   = dr_wr0 ? fl[fl_alloc[4:0]] : 6'd0;
    wire [5:0] old0  = rat[dr_rd0];
    wire fwd11 = dr_wr0 && (dr_rs11 == dr_rd0);
    wire fwd21 = dr_wr0 && (dr_rs21 == dr_rd0);
    wire [5:0] ps1_1 = fwd11 ? pd0 : rat[dr_rs11];
    wire [5:0] ps2_1 = fwd21 ? pd0 : rat[dr_rs21];
    wire [5:0] pd1   = dr_wr1 ? fl[(fl_alloc + {5'b0, dr_wr0}) & 6'd31]
                              : 6'd0;
    wire [5:0] old1  = (dr_wr0 && (dr_rd1 == dr_rd0)) ? pd0 : rat[dr_rd1];

    // grant/WB tag clears visible to dispatch-ready computation
    wire        sel0_v, sel1_v, sel2_v;
    wire [`UOPW-1:0] sel0_uop, sel1_uop, sel2_uop;
    reg         wb_v2_isload_wr;    // load WB this cycle (declared below)
    reg  [5:0]  wb_pd2_r;

    function rdy_now;
        input [5:0] ps;
        input       used;
        begin
            if (!used || ps == 6'd0)
                rdy_now = 1'b1;
            else
                rdy_now = !busy[ps]
                    || (sel0_v && sel0_uop[`U_WR] && sel0_uop[`U_PD] == ps)
                    || (sel1_v && sel1_uop[`U_WR] && sel1_uop[`U_PD] == ps)
                    || (wb_v2_isload_wr && wb_pd2_r == ps);
        end
    endfunction

    // slot ready bits (slot1 sources produced by slot0 are never ready)
    wire r1_0 = rdy_now(ps1_0, dr_r1u0);
    wire r2_0 = rdy_now(ps2_0, dr_r2u0);
    wire r1_1 = (fwd11 && dr_r1u1) ? 1'b0 : rdy_now(ps1_1, dr_r1u1);
    wire r2_1 = (fwd21 && dr_r2u1) ? 1'b0 : rdy_now(ps2_1, dr_r2u1);

    // load colors and masks
    wire [3:0] color0 = sq_tail4;
    wire [3:0] color1 = sq_tail4 + {3'b0, dr_st0};
    wire [7:0] mask0  = sq_unknown;
    wire [7:0] mask1  = sq_unknown | ((dr_st0 && ok0) ? (8'b1 << sq_pos0)
                                                      : 8'b0);

    // D021: per-uop dispatch wait masks by load-speculation policy. pred0/1
    // are the store-set predictor's one-hot "wait for this SQ slot" hints
    // (0 = no prediction / speculate). ANDing them with the conservative
    // mask0/mask1 is the safety bracket — a stale prediction either names an
    // older still-unknown store (a legal, bounded wait) or is masked to 0
    // (speculate; the LQ CAM repairs a real conflict). Predicted STORES wait
    // too (in-set store->store ordering makes "wait for the last fetched
    // store of the set" transitive). LOAD_POLICY is a parameter: each arm
    // constant-folds; policies 0/1 synthesize to the exact D020 netlists.
    // store-set hint wires — driven by the STSET generate block below
    // (tied off under policies 0/1, so those netlists are exactly D020's)
    wire       ss_v0, ss_v1, sf_v0, sf_v1;
    wire [3:0] ss_id0, ss_id1;
    wire [2:0] sf_pos0, sf_pos1;
    wire [7:0] pred0 = (ss_v0 && sf_v0) ? (8'b1 << sf_pos0) : 8'b0;
    wire [7:0] pred1 = (ss_v1 && sf_v1) ? (8'b1 << sf_pos1) : 8'b0;
    wire [7:0] dmask0 = (LOAD_POLICY == 0) ? (dr_ld0 ? mask0 : 8'b0)
                      : (LOAD_POLICY == 1) ? 8'b0
                      : (LOAD_POLICY == 3) ? ((dr_ld0 && ss_v0) ? mask0
                                                                : 8'b0)
                      : ((dr_ld0 | dr_st0) ? (pred0 & mask0) : 8'b0);
    wire [7:0] dmask1 = (LOAD_POLICY == 0) ? (dr_ld1 ? mask1 : 8'b0)
                      : (LOAD_POLICY == 1) ? 8'b0
                      : (LOAD_POLICY == 3) ? ((dr_ld1 && ss_v1) ? mask1
                                                                : 8'b0)
                      : ((dr_ld1 | dr_st1) ? (pred1 & mask1) : 8'b0);

    // uop assembly
    function [`UOPW-1:0] mkuop;
        input [3:0]  actl;
        input        asrc, apc, br, jalr, ld, st, csr;
        input [2:0]  f3;
        input [31:0] imm, pc, pnpc;
        input [4:0]  rs1a;
        input [5:0]  ps1, ps2, pd;
        input        wr;
        input [5:0]  tag;
        input [2:0]  sqpos;
        input [3:0]  sqcol, chkt;
        input        haschk;
        input [9:0]  ghr;
        reg [`UOPW-1:0] x;
        begin
            x = {`UOPW{1'b0}};
            x[`U_ALUCTRL] = actl;  x[`U_ALUSRC] = asrc; x[`U_ALUAPC] = apc;
            x[`U_ISBR] = br;       x[`U_ISJALR] = jalr; x[`U_ISLOAD] = ld;
            x[`U_ISSTORE] = st;    x[`U_ISCSR] = csr;   x[`U_F3] = f3;
            x[`U_IMM] = imm;       x[`U_PC] = pc;       x[`U_PNPC] = pnpc;
            x[`U_RS1A] = rs1a;     x[`U_PS1] = ps1;     x[`U_PS2] = ps2;
            x[`U_PD] = pd;         x[`U_WR] = wr;       x[`U_TAG] = tag;
            x[`U_SQPOS] = sqpos;   x[`U_SQCOL] = sqcol; x[`U_CHK] = chkt;
            x[`U_HASCHK] = haschk; x[`U_GHR] = ghr;
            mkuop = x;
        end
    endfunction

    wire [5:0] tag0 = tail_tag;
    wire [5:0] tag1 = tail_tag + 6'd1;

    wire [`UOPW-1:0] uop0 = mkuop(dr_actl0, dr_asrc0, dr_apc0, dr_br0,
        dr_jalr0, dr_ld0, dr_st0, dr_csr0, dr_f30, dr_imm0, dr_pc0,
        dr_pnpc0, dr_rs10, ps1_0, ps2_0, pd0, dr_wr0, tag0, sq_pos0,
        color0, chk_a, ctrl0, dr_ghr0);
    wire [3:0] chk_tag1 = chk_a + {3'b0, ctrl0};
    wire [`UOPW-1:0] uop1 = mkuop(dr_actl1, dr_asrc1, dr_apc1, dr_br1,
        dr_jalr1, dr_ld1, dr_st1, dr_csr1, dr_f31, dr_imm1, dr_pc1,
        dr_pnpc1, dr_rs11, ps1_1, ps2_1, pd1, dr_wr1, tag1, sq_pos1,
        color1, chk_tag1, ctrl1, dr_ghr1);

    // pack the post-slot0 / post-pair RATs for checkpointing
    reg [191:0] rat_after0;
    reg [191:0] rat_after1;
    always @(*) begin
        for (i = 0; i < 32; i = i + 1) begin
            rat_after0[i*6 +: 6] = (dr_wr0 && (i[4:0] == dr_rd0))
                                   ? pd0 : rat[i];
            rat_after1[i*6 +: 6] = (dr_wr1 && (i[4:0] == dr_rd1)) ? pd1
                                 : (dr_wr0 && (i[4:0] == dr_rd0)) ? pd0
                                 : rat[i];
        end
    end

    // =====================================================================
    // ROB
    // =====================================================================
    reg        rob_v    [0:ROBD-1];
    reg        rob_done [0:ROBD-1];
    reg        rob_wr   [0:ROBD-1];
    reg  [4:0] rob_rd   [0:ROBD-1];
    reg  [5:0] rob_pd   [0:ROBD-1];
    reg  [5:0] rob_old  [0:ROBD-1];
    reg        rob_st   [0:ROBD-1];
    reg        rob_ctrl [0:ROBD-1];
    reg [31:0] rob_pc   [0:ROBD-1];
    reg [31:0] rob_val  [0:ROBD-1];
    reg        rob_ld   [0:ROBD-1];     // load? (for LQ retire-free)
    reg        rob_poison[0:ROBD-1];    // load-ordering violation (D020)

    // retire decisions
    wire [4:0] h0 = rob_head;
    wire [4:0] h1 = rob_head + 5'd1;
    // A poisoned load at the head triggers a flush instead of retiring
    // (D020). It must be `done` (its stale read completed). We also wait for
    // the store queue to fully drain to dmem (sq_empty) BEFORE flushing, so
    // the re-executed load reads correct memory directly from dmem and does
    // not depend on post-flush SQ-forward color arithmetic. While the drain
    // runs (lq_flushing) no instruction retires.
    wire head_poison = (rob_count != 6'd0) && rob_v[h0] && rob_done[h0]
                       && rob_poison[h0];
    // wait until no COMMITTED store is still pending drain (!mw_valid): all
    // stores older than the poisoned load have retired (it is at the head) so
    // they are committed; once they have drained to dmem the re-executed load
    // reads correct memory. Younger uncommitted stores never set mw_valid, so
    // this does not deadlock (they are killed by the flush's SQ rewind).
    // The flush takes ABSOLUTE priority: a younger branch's mispredict is
    // wrong-path relative to the poisoned load, so restore_en is suppressed
    // whenever a flush starts (see restore_en assignment below).
    wire lq_flush_start = head_poison && !mw_valid && !lq_flushing;

    wire ret0_ok = (rob_count != 6'd0) && rob_v[h0] && rob_done[h0]
                   && !rob_poison[h0] && !lq_flushing;
    wire ret1_ok = ret0_ok && (rob_count != 6'd1)
                   && rob_v[h1] && rob_done[h1] && !rob_poison[h1]
                   && !(rob_st[h0] && rob_st[h1]);
    wire [1:0] retire_n = {1'b0, ret0_ok} + {1'b0, ret1_ok};

    // =====================================================================
    // execution pipes: RF -> EX -> WB registers (3 ports)
    // =====================================================================
    reg              rf_v  [0:2];
    reg [`UOPW-1:0]  rf_u  [0:2];
    reg              ex_v  [0:2];
    reg [`UOPW-1:0]  ex_u  [0:2];
    reg [31:0]       ex_a  [0:2];
    reg [31:0]       ex_b  [0:2];
    reg              wb_v  [0:2];
    reg              wb_wr [0:2];
    reg [5:0]        wb_pd [0:2];
    reg [31:0]       wb_val[0:2];
    reg [5:0]        wb_tag[0:2];
    reg              wb_ld [0:2];
    reg              wb2_use_dmem;   // WB: slot-2 load takes the sync dmem read (D016)

    // Load completion is broadcast at EX-success (replay is known there),
    // not WB — load-to-use is 2 cycles. A load killed by a same-cycle
    // restore may still broadcast: its consumers are younger than the
    // restoring branch by dataflow and die in the same squash.
    always @(*) begin
        wb_v2_isload_wr = ex_v[2] && ex_u[2][`U_ISLOAD] && !p2_replay
                          && ex_u[2][`U_WR];
        wb_pd2_r        = ex_u[2][`U_PD];
    end

    // PRF
    wire [31:0] prf_r0a, prf_r0b, prf_r1a, prf_r1b, prf_r2a, prf_r2b;
    ooo_prf PRF0 (
        .clk(clk),
        .r0a_tag(rf_u[0][`U_PS1]), .r0b_tag(rf_u[0][`U_PS2]),
        .r1a_tag(rf_u[1][`U_PS1]), .r1b_tag(rf_u[1][`U_PS2]),
        .r2a_tag(rf_u[2][`U_PS1]), .r2b_tag(rf_u[2][`U_PS2]),
        .r0a(prf_r0a), .r0b(prf_r0b),
        .r1a(prf_r1a), .r1b(prf_r1b),
        .r2a(prf_r2a), .r2b(prf_r2b),
        .w0_en(wb_v[0] && wb_wr[0]), .w0_tag(wb_pd[0]), .w0_data(wb_val[0]),
        .w1_en(wb_v[1] && wb_wr[1]), .w1_tag(wb_pd[1]), .w1_data(wb_val[1]),
        .w2_en(wb_v[2] && wb_wr[2]), .w2_tag(wb_pd[2]), .w2_data(wb_result2)
    );

    // WB-stage bypass into EX operands
    function [31:0] bypass;
        input [5:0]  ps;
        input [31:0] rfval;
        begin
            if (wb_v[0] && wb_wr[0] && wb_pd[0] == ps)      bypass = wb_val[0];
            else if (wb_v[1] && wb_wr[1] && wb_pd[1] == ps) bypass = wb_val[1];
            else if (wb_v[2] && wb_wr[2] && wb_pd[2] == ps) bypass = wb_result2;
            else                                            bypass = rfval;
        end
    endfunction

    // ---------------- port0 EX: ALU + branch/JALR resolve ----------------
    wire [31:0] p0_a = ex_u[0][`U_ALUAPC] ? ex_u[0][`U_PC]
                                          : bypass(ex_u[0][`U_PS1], ex_a[0]);
    wire [31:0] p0_rs2 = bypass(ex_u[0][`U_PS2], ex_b[0]);
    wire [31:0] p0_b = ex_u[0][`U_ALUSRC] ? ex_u[0][`U_IMM] : p0_rs2;
    wire [31:0] p0_alu;
    wire        p0_zero;
    alu ALU0 (.a(p0_a), .b(p0_b), .alu_control(ex_u[0][`U_ALUCTRL]),
              .result(p0_alu), .zero(p0_zero));
    wire p0_cond;
    branch_unit BRU0 (.a(p0_a), .b(p0_rs2), .funct3(ex_u[0][`U_F3]),
                      .taken(p0_cond));

    wire p0_isctrl = ex_u[0][`U_ISBR] | ex_u[0][`U_ISJALR];
    wire p0_taken  = ex_u[0][`U_ISBR] ? p0_cond : 1'b1;
    wire [31:0] p0_target = ex_u[0][`U_ISJALR] ? (p0_alu & ~32'h1)
                                               : ex_u[0][`U_IMM];
    wire [31:0] p0_npc = p0_taken ? p0_target
                                  : (ex_u[0][`U_PC] + 32'd4);
    // A branch being squashed by a load-violation flush-at-head must NOT
    // trigger its own mispredict recovery (D020): the whole pipe younger than
    // the poisoned load is discarded, so a stale in-flight branch's redirect
    // is wrong-path. Gate on the flush signals (not kill_ex0, which would form
    // a combinational loop through restore_en).
    wire p0_mispredict = ex_v[0] && p0_isctrl
                         && (p0_npc != ex_u[0][`U_PNPC])
                         && !lq_flush_start && !lq_flushing;
    wire [31:0] p0_result = ex_u[0][`U_ISJALR] ? (ex_u[0][`U_PC] + 32'd4)
                                               : p0_alu;

    always @(*) begin
        restore_en    = p0_mispredict;
        restore_tag   = ex_u[0][`U_TAG];
        restore_chk   = ex_u[0][`U_CHK];
        restore_npc   = p0_npc;
        restore_ghr   = ex_u[0][`U_GHR];
        restore_shift = ex_u[0][`U_ISBR];
        restore_dir   = p0_taken;

        train_en     = ex_v[0] && p0_isctrl;
        train_pc     = ex_u[0][`U_PC];
        train_cond   = ex_u[0][`U_ISBR];
        train_taken  = p0_taken;
        train_target = p0_target;
        train_ghr    = ex_u[0][`U_GHR];
    end

    // ---------------- port1 EX: ALU + CSR --------------------------------
    wire [31:0] p1_a = ex_u[1][`U_ALUAPC] ? ex_u[1][`U_PC]
                                          : bypass(ex_u[1][`U_PS1], ex_a[1]);
    wire [31:0] p1_rs2 = bypass(ex_u[1][`U_PS2], ex_b[1]);
    wire [31:0] p1_b = ex_u[1][`U_ALUSRC] ? ex_u[1][`U_IMM] : p1_rs2;
    wire [31:0] p1_alu;
    wire        p1_zero;
    alu ALU1 (.a(p1_a), .b(p1_b), .alu_control(ex_u[1][`U_ALUCTRL]),
              .result(p1_alu), .zero(p1_zero));

    wire [31:0] csr_rdata;
    csr_file CSR0 (
        .clk(clk), .reset(reset),
        .csr_en(ex_v[1] && ex_u[1][`U_ISCSR]),
        .csr_addr(ex_u[1][25:14]),          // imm[11:0] = the CSR address
        .funct3(ex_u[1][`U_F3]),
        .rs1_addr(ex_u[1][`U_RS1A]),
        .rs1_data(p1_a),
        .csr_rdata(csr_rdata),
        .retire_n(retire_n)
    );
    wire [31:0] p1_result = ex_u[1][`U_ISCSR] ? csr_rdata : p1_alu;

    // ---------------- port2 EX: AGU + SQ + dmem/mmio ----------------------
    wire [31:0] p2_a = bypass(ex_u[2][`U_PS1], ex_a[2]);
    wire [31:0] p2_data = bypass(ex_u[2][`U_PS2], ex_b[2]);
    wire [31:0] p2_addr = p2_a + ex_u[2][`U_IMM];
    wire        p2_isio  = (p2_addr[31:28] == 4'h4);
    wire        p2_isnpu = (p2_addr[31:28] == 4'h5);   // NPU region (D014)
    wire        p2_io_any = p2_isio | p2_isnpu;
    wire        p2_load  = ex_v[2] && ex_u[2][`U_ISLOAD];
    wire        p2_store = ex_v[2] && ex_u[2][`U_ISSTORE];

    // SQ
    wire        sq_qhit, sq_qconf, sq_qolder;
    wire [3:0]  sq_commit_tail4;
    wire        sq_empty;
    wire [31:0] sq_qdata;
    wire        mw_valid /*verilator public_flat_rd*/;
    wire [31:0] mw_addr  /*verilator public_flat_rd*/;
    wire [31:0] mw_data  /*verilator public_flat_rd*/;
    wire [2:0]  mw_f3    /*verilator public_flat_rd*/;

    ooo_sq SQ0 (
        .clk(clk), .reset(reset),
        .alloc_n({1'b0, ok0 && dr_st0} + {1'b0, ok1 && dr_st1}),
        .free_ge1(sq_ge1), .free_ge2(sq_ge2),
        .tail4(sq_tail4),
        .fill_en(p2_store),
        .fill_pos(ex_u[2][`U_SQPOS]),
        .fill_addr(p2_addr), .fill_data(p2_data),
        .fill_f3(ex_u[2][`U_F3]),
        .retire_mark_en((ret0_ok && rob_st[h0]) || (ret1_ok && rob_st[h1])),
        .mw_valid(mw_valid), .mw_addr(mw_addr), .mw_data(mw_data),
        .mw_f3(mw_f3), .mw_ready(mw_ready),
        .q_addr(p2_addr), .q_color4(ex_u[2][`U_SQCOL]),
        .q_hit(sq_qhit), .q_data(sq_qdata), .q_conflict(sq_qconf),
        .q_older(sq_qolder),
        // flush on branch mispredict OR a load-violation flush-at-head.
        // Branch: rewind to the branch's checkpointed SQ tail. Violation:
        // rewind to the committed tail (kill all uncommitted younger stores;
        // older committed stores survive to drain).
        .flush_en(restore_en || lq_flush_start),
        .flush_tail4(lq_flush_start ? sq_commit_tail4
                                    : chk_sqt[restore_chk[2:0]]),
        .commit_tail4(sq_commit_tail4),
        .sq_empty(sq_empty),
        .unknown_mask(sq_unknown),
        .unknown_raw(sq_unknown_raw)
    );

    // ------------------------------------------------------------------
    // Load queue (D020): byte mask from funct3 + addr[1:0], violation CAM.
    // ------------------------------------------------------------------
    function [3:0] bytemask;
        input [2:0] f3;
        input [1:0] a10;
        reg [3:0] m;
        begin
            case (f3[1:0])
                2'b00:   m = 4'b0001 << a10;              // byte
                2'b01:   m = 4'b0011 << {a10[1], 1'b0};   // half (aligned)
                default: m = 4'b1111;                     // word
            endcase
            bytemask = m;
        end
    endfunction

    wire        lq_ge1, lq_ge2;
    wire        lq_vio_en;
    wire [5:0]  lq_vio_tag;
    // A speculative load is one to a plain RAM address (IO/NPU keep the
    // conservative strong-ordering replay path, INV-10). Only RAM loads
    // allocate/execute in the LQ and can be violated.
    wire        p2_load_ram = p2_load && !p2_io_any;

    ooo_lq LQ0 (
        .clk(clk), .reset(reset),
        .head_tag(head_tag),
        // alloc at dispatch for RAM loads (in program order)
        .alloc0_en(ok0 && dr_ld0),
        .alloc0_tag(tag0),
        .alloc1_en(ok1 && dr_ld1),
        .alloc1_tag(tag1),
        .free_ge1(lq_ge1), .free_ge2(lq_ge2),
        // execute: RAM load performed its read at port2 EX
        .exec_en(p2_load_ram && !p2_replay),
        .exec_tag(ex_u[2][`U_TAG]),
        .exec_waddr(p2_addr[31:2]),
        .exec_bytemask(bytemask(ex_u[2][`U_F3], p2_addr[1:0])),
        // store address fill drives the violation CAM
        .st_fill_en(p2_store),
        .st_tag(ex_u[2][`U_TAG]),
        .st_waddr(p2_addr[31:2]),
        .st_bytemask(bytemask(ex_u[2][`U_F3], p2_addr[1:0])),
        .vio_en(lq_vio_en), .vio_tag(lq_vio_tag),
        // retire frees (in order); tags are the retiring ROB entries
        .retire0_en(ret0_ok && rob_ld[h0]),
        .retire0_tag(head_tag),
        .retire1_en(ret1_ok && rob_ld[h1]),
        .retire1_tag(head_tag + 6'd1),
        // squash: branch mispredict flushes younger; a violation drain
        // clears everything (the ROB empties)
        .flush_en(restore_en), .flush_tag(restore_tag),
        .flush_all(lq_flush_start)
    );

`ifdef LQ_PROBE
    // opt-in violation/flush trace for debugging (enable with +define+LQ_PROBE;
    // off in normal sim so stdout stays clean for the harness's PASS parsing).
    always @(posedge clk) if (!reset) begin
        if (lq_vio_en)
            $display("[LQ] VIOLATION vio_tag=%0d st_tag=%0d", lq_vio_tag, ex_u[2][`U_TAG]);
        if (lq_flush_start)
            $display("[LQ] FLUSH pc=%h", rob_pc[h0]);
    end
`endif

    // ------------------------------------------------------------------
    // Store-set memory-dependence predictor (D021, docs/STORESET.md).
    // Instantiated only under the predicted policies (2 = store sets,
    // 3 = 21264-style 1-bit load-wait, which reuses the SSIT valid bit and
    // ignores the LFST); policies 0/1 tie the hint wires off so their
    // netlists are exactly D020's.
    // ------------------------------------------------------------------
    generate if (LOAD_POLICY == 2 || LOAD_POLICY == 3) begin : STSET
        // Training, phase 1 (capture): register the violated pair at the
        // cycle the LQ CAM fires, gated EXACTLY like the poison write
        // below — a violation whose load is squashed by a same-cycle
        // branch restore is wrong-path and must not train. Phase 2
        // (apply) runs next cycle: the rob_pc 32:1 read + SSIT merge are
        // FF-to-FF in their own cycle, so NOTHING is appended after the
        // violation CAM (the D020 critical path). The poisoned ROB entry
        // cannot be reallocated before its flush-at-head fires, so
        // rob_pc[tag] is stable across the capture->apply boundary.
        reg        sst_train_v;
        reg  [4:0] sst_train_tag;
        reg  [5:0] sst_train_stpc;
        wire [31:0] sst_stpc_full = ex_u[2][`U_PC];
        always @(posedge clk or posedge reset) begin
            if (reset) begin
                sst_train_v    <= 1'b0;
                sst_train_tag  <= 5'b0;
                sst_train_stpc <= 6'b0;
            end else begin
                // !lq_flush_start: a CAM hit in the exact cycle a
                // flush-at-head starts must NOT train — the flush clears
                // every rob_v at this edge, so the N+1 apply would read a
                // dead ROB entry (B014, caught by the INV-P7 assertion on
                // riscv-test ld_st). The dropped event is a genuine pair
                // that simply retrains on its next violation.
                sst_train_v    <= lq_vio_en
                                  && !(restore_en
                                       && is_younger(lq_vio_tag, restore_tag))
                                  && !lq_flushing && !lq_flush_start;
                sst_train_tag  <= lq_vio_tag[4:0];
                sst_train_stpc <= sst_stpc_full[7:2];
            end
        end
        wire [31:0] sst_ldpc_full = rob_pc[sst_train_tag];
        wire        sst_busy_unused;

        ooo_stset SST0 (
            .clk(clk), .reset(reset),
            .lk_pc0(dr_pc0[7:2]),
            .lk_ssv0(ss_v0), .lk_ssid0(ss_id0),
            .lk_pc1(dr_pc1[7:2]),
            .lk_ssv1(ss_v1), .lk_ssid1(ss_id1),
            .lf_v0(sf_v0), .lf_pos0(sf_pos0),
            .lf_v1(sf_v1), .lf_pos1(sf_pos1),
            // dispatching stores update their set's last-fetched entry
            .stw0_en(ok0 && dr_st0 && ss_v0),
            .stw0_ssid(ss_id0), .stw0_sqpos(sq_pos0),
            .stw1_en(ok1 && dr_st1 && ss_v1),
            .stw1_ssid(ss_id1), .stw1_sqpos(sq_pos1),
            .train_en(sst_train_v),
            .train_ldpc(sst_ldpc_full[7:2]),
            .train_stpc(sst_train_stpc),
            // the hijacked-cycle blackout is internal (lk_ssv* forced 0)
            .train_busy(sst_busy_unused)
        );

`ifdef STSET_PROBE
        // opt-in predictor trace (+define+STSET_PROBE), LQ_PROBE style
        always @(posedge clk) if (!reset) begin
            if (sst_train_v)
                $display("[STSET] TRAIN ld_pc6=%h st_pc6=%h",
                         sst_ldpc_full[7:2], sst_train_stpc);
            if (ok0 && (dr_ld0 || dr_st0) && (dmask0 != 8'b0))
                $display("[STSET] WAIT pc=%h mask=%b", dr_pc0, dmask0);
            if (ok1 && (dr_ld1 || dr_st1) && (dmask1 != 8'b0))
                $display("[STSET] WAIT pc=%h mask=%b", dr_pc1, dmask1);
        end
`endif

`ifdef VERILATOR
        // INV-P7: the training apply must read a live ROB entry
        always @(posedge clk) if (!reset) begin
            if (sst_train_v && !rob_v[sst_train_tag])
                $fatal(1, "ooo_cpu: stset training reads a dead ROB entry");
        end
`endif
    end else begin : NOSTSET
        assign ss_v0 = 1'b0;   assign ss_v1 = 1'b0;
        assign ss_id0 = 4'b0;  assign ss_id1 = 4'b0;
        assign sf_v0 = 1'b0;   assign sf_v1 = 1'b0;
        assign sf_pos0 = 3'b0; assign sf_pos1 = 3'b0;
    end endgenerate

    // memory write routing (SQ drain -> dmem, mmio or npu). The drain
    // fires only when the target accepts: a busy NPU backpressures via
    // mw_ready and the committed store waits at the SQ head (D014) —
    // dmem/mmio always accept, so for them mw_fire == mw_valid.
    wire mw_isio  = (mw_addr[31:28] == 4'h4);
    wire mw_isnpu = (mw_addr[31:28] == 4'h5);
    wire npu_busy, npu_busy_next;
    wire mw_ready = !(mw_isnpu && npu_busy);
    wire mw_fire /*verilator public_flat_rd*/ = mw_valid && mw_ready;
    wire [31:0] dmem_rdata, mmio_rdata, npu_rdata;

    dmem #(.SYNC_READ(1)) DMEM0 (
        .clk(clk),
        .mem_read(p2_load && !p2_io_any),
        .raddr(p2_addr), .rfunct3(ex_u[2][`U_F3]),
        .read_data(dmem_rdata),
        .mem_write(mw_fire && !mw_isio && !mw_isnpu),
        .waddr(mw_addr), .write_data(mw_data), .wfunct3(mw_f3)
    );

    wire [9:0] leds_mmio;
    mmio MMIO0 (
        .clk(clk), .reset(reset),
        .raddr(p2_addr), .rdata(mmio_rdata),
        .waddr(mw_addr), .wdata(mw_data),
        .we(mw_fire && mw_isio),
        .leds(leds_mmio), .switches(switches)
    );
    assign leds = leds_mmio;

    // NPU (docs/NPU.md D014): reads are side-effect-free, so the
    // speculative load pipe may touch it freely; writes are committed
    // stores and, by mw_ready above, only ever arrive while idle.
    npu_top NPU0 (
        .clk(clk), .reset(reset),
        .raddr(p2_addr), .rdata(npu_rdata),
        .we(mw_fire && mw_isnpu),
        .waddr(mw_addr), .wdata(mw_data),
        .busy(npu_busy), .busy_next(npu_busy_next)
    );

    // load value: SQ forward (extract) > mmio raw word > dmem extracted
    function [31:0] extract_load;
        input [31:0] word;
        input [1:0]  a10;
        input [2:0]  f3;
        reg [7:0]  b;
        reg [15:0] h;
        begin
            b = word[a10*8 +: 8];
            h = word[a10[1]*16 +: 16];
            case (f3)
                3'b000:  extract_load = {{24{b[7]}}, b};
                3'b001:  extract_load = {{16{h[15]}}, h};
                3'b100:  extract_load = {24'b0, b};
                3'b101:  extract_load = {16'b0, h};
                default: extract_load = word;
            endcase
        end
    endfunction

    // IO-region loads are strongly ordered (D014, fixes B010): they
    // replay until every older store has drained — so when one finally
    // performs, an SQ forward hit is impossible (asserted below) and the
    // device read is the program-order value. NPU loads additionally
    // wait for the array to go idle (busy_next covers a same-cycle GO
    // drain), which is what makes busy architecturally unobservable and
    // the instantaneous ISS mirror exact.
    wire        p2_replay = p2_load && (sq_qconf
                          || (p2_io_any && sq_qolder)
                          || (p2_isnpu  && npu_busy_next));
    // Load result sources. dmem is SYNCHRONOUS now (D016): its extracted
    // word (dmem_rdata) is a WB-stage signal — valid one cycle after
    // p2_addr — so the RAM select is deferred to WB (wb_result2 below). The
    // SQ-forward / MMIO / NPU sources are combinational here and are
    // captured into wb_val[2] at EX->WB. p2_use_dmem marks a plain RAM load.
    wire        p2_use_dmem = !sq_qhit && !p2_isio && !p2_isnpu;
    wire [31:0] p2_nondmem  =
        sq_qhit  ? extract_load(sq_qdata, p2_addr[1:0], ex_u[2][`U_F3])
      : p2_isio  ? mmio_rdata
      :            npu_rdata;

    // WB-stage load result: a plain RAM load takes the synchronous dmem read
    // (valid this WB cycle); otherwise the SQ/MMIO/NPU value captured in
    // wb_val[2]. This lands the SAME cycle wb_val[2] used to, so load-to-use,
    // wakeup and the 2-cycle load latency are all unchanged (IPC-neutral).
    wire [31:0] wb_result2 = wb2_use_dmem ? dmem_rdata : wb_val[2];

`ifdef VERILATOR
    always @(posedge clk)
        if (!reset && p2_load && p2_io_any && !p2_replay && sq_qhit)
            $fatal(1, "ooo_cpu: IO load completed with an SQ forward hit");

    // D021 predictor invariants (docs/STORESET.md INV-P1..P3). The subset
    // property IS the architectural-safety argument (every dispatch mask
    // lies between the verified speculative and conservative extremes) —
    // check it on every dispatch, under every policy.
    always @(posedge clk) if (!reset) begin
        if (ok0 && ((dmask0 & ~mask0) != 8'b0))
            $fatal(1, "ooo_cpu: slot0 mask not a subset of conservative");
        if (ok1 && ((dmask1 & ~mask1) != 8'b0))
            $fatal(1, "ooo_cpu: slot1 mask not a subset of conservative");
        if (LOAD_POLICY == 2 && ok0
            && ((dmask0 & (dmask0 - 8'd1)) != 8'b0))
            $fatal(1, "ooo_cpu: slot0 predicted mask not one-hot");
        if (LOAD_POLICY == 2 && ok1
            && ((dmask1 & (dmask1 - 8'd1)) != 8'b0))
            $fatal(1, "ooo_cpu: slot1 predicted mask not one-hot");
        if (ok0 && dr_st0 && dmask0[sq_pos0])
            $fatal(1, "ooo_cpu: slot0 store waits on itself");
        if (ok1 && dr_st1 && dmask1[sq_pos1])
            $fatal(1, "ooo_cpu: slot1 store waits on itself");
    end

    // ROB-head forward-progress watchdog: a wait-mask deadlock (or any
    // other head wedge) trips this within one sim run. 2048 cycles is far
    // beyond any legitimate stall (NPU busy ~10s of cycles, SQ drain <=8).
    reg [11:0] wd_cnt;
    reg [5:0]  wd_head;
    always @(posedge clk) begin
        if (reset || rob_empty || (head_tag != wd_head)
            || rob_done[h0] || lq_flushing) begin
            wd_head <= head_tag;
            wd_cnt  <= 12'd0;
        end else begin
            wd_cnt <= wd_cnt + 12'd1;
            if (wd_cnt > 12'd2048)
                $fatal(1, "ooo_cpu: ROB head stalled >2048 cycles");
        end
    end
`endif

    // =====================================================================
    // IQ
    // =====================================================================
    ooo_iq IQ0 (
        .clk(clk), .reset(reset),
        .head_tag(head_tag),
        .disp0_en(ok0), .disp0_uop(uop0),
        .disp0_r1(r1_0), .disp0_r2(r2_0), .disp0_mask(dmask0),
        .disp1_en(ok1), .disp1_uop(uop1),
        .disp1_r1(r1_1), .disp1_r2(r2_1), .disp1_mask(dmask1),
        .free_ge1(iq_ge1), .free_ge2(iq_ge2),
        .sq_unknown(sq_unknown), .sq_unknown_raw(sq_unknown_raw),
        .wkl_en(wb_v2_isload_wr), .wkl_tag(wb_pd2_r),
        .rep_en(p2_replay), .rep_tag(ex_u[2][`U_TAG]),
        .ldone_en(ex_v[2] && ex_u[2][`U_ISLOAD] && !p2_replay),
        .ldone_tag(ex_u[2][`U_TAG]),
        // branch mispredict flushes entries younger-than-branch (tag-relative);
        // a load-violation flush-at-head empties the WHOLE IQ via flush_all.
        // (The prior head_tag-1 "everything is younger" trick never matched —
        // relage is 6-bit so > 63 is always false — leaving stale IQ entries
        // that re-issued post-flush with reallocated phys regs. B013.)
        .flush_en(restore_en),
        .flush_tag(restore_tag),
        .flush_all(lq_flush_start),
        .sel0_v(sel0_v), .sel0_uop(sel0_uop),
        .sel1_v(sel1_v), .sel1_uop(sel1_uop),
        .sel2_v(sel2_v), .sel2_uop(sel2_uop)
    );

    // =====================================================================
    // pipeline registers + all core state updates
    // =====================================================================
    // A load-violation flush-at-head empties the ROB, so it kills EVERY
    // in-flight uop (all are younger-or-equal to the poisoned head). Fold that
    // into the kill nets as an unconditional kill while flushing/starting.
    wire kill_all = lq_flush_start || lq_flushing;
    wire kill_rf0 = kill_all || (restore_en && is_younger(rf_u[0][`U_TAG], restore_tag));
    wire kill_rf1 = kill_all || (restore_en && is_younger(rf_u[1][`U_TAG], restore_tag));
    wire kill_rf2 = kill_all || (restore_en && is_younger(rf_u[2][`U_TAG], restore_tag));
    wire kill_ex0 = kill_all || (restore_en && is_younger(ex_u[0][`U_TAG], restore_tag));
    wire kill_ex1 = kill_all || (restore_en && is_younger(ex_u[1][`U_TAG], restore_tag));
    wire kill_ex2 = kill_all || (restore_en && is_younger(ex_u[2][`U_TAG], restore_tag));
    wire kill_s0  = kill_all || (restore_en && is_younger(sel0_uop[`U_TAG], restore_tag));
    wire kill_s1  = kill_all || (restore_en && is_younger(sel1_uop[`U_TAG], restore_tag));
    wire kill_s2  = kill_all || (restore_en && is_younger(sel2_uop[`U_TAG], restore_tag));

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) rat[i] <= i[5:0];
            for (i = 0; i < 32; i = i + 1) arat[i] <= i[5:0];
            for (i = 0; i < PHYS; i = i + 1) busy[i] <= 1'b0;
            for (i = 0; i < 32; i = i + 1) fl[i] <= 6'd32 + i[5:0];
            fl_alloc <= 6'b0; fl_free <= 6'b0;
            chk_a <= 4'b0; chk_f <= 4'b0;
            rob_head <= 5'b0; rob_head_ph <= 1'b0;
            rob_tail <= 5'b0; rob_tail_ph <= 1'b0;
            lq_state <= 1'b0; lq_sweep <= 7'd0; lq_wp <= 6'd0;
            lq_flush_pc <= 32'b0;
            for (i = 0; i < ROBD; i = i + 1) begin
                rob_v[i] <= 1'b0; rob_done[i] <= 1'b0; rob_wr[i] <= 1'b0;
                rob_rd[i] <= 5'b0; rob_pd[i] <= 6'b0; rob_old[i] <= 6'b0;
                rob_st[i] <= 1'b0; rob_ctrl[i] <= 1'b0;
                rob_pc[i] <= 32'b0; rob_val[i] <= 32'b0;
                rob_ld[i] <= 1'b0; rob_poison[i] <= 1'b0;
            end
            for (i = 0; i < 3; i = i + 1) begin
                rf_v[i] <= 1'b0; rf_u[i] <= {`UOPW{1'b0}};
                ex_v[i] <= 1'b0; ex_u[i] <= {`UOPW{1'b0}};
                ex_a[i] <= 32'b0; ex_b[i] <= 32'b0;
                wb_v[i] <= 1'b0; wb_wr[i] <= 1'b0; wb_pd[i] <= 6'b0;
                wb_val[i] <= 32'b0; wb_tag[i] <= 6'b0; wb_ld[i] <= 1'b0;
            end
            wb2_use_dmem <= 1'b0;
        end else begin
            // ------------------------------ dispatch (rename side effects)
            if (ok0) begin
                if (dr_wr0) begin
                    rat[dr_rd0]  <= pd0;
                    busy[pd0]    <= 1'b1;
                end
                rob_v[rob_tail]    <= 1'b1;
                rob_done[rob_tail] <= 1'b0;
                rob_wr[rob_tail]   <= dr_wr0;
                rob_rd[rob_tail]   <= dr_rd0;
                rob_pd[rob_tail]   <= pd0;
                rob_old[rob_tail]  <= old0;
                rob_st[rob_tail]   <= dr_st0;
                rob_ctrl[rob_tail] <= ctrl0;
                rob_pc[rob_tail]   <= dr_pc0;
                rob_ld[rob_tail]   <= dr_ld0;
                rob_poison[rob_tail] <= 1'b0;
                if (ctrl0) begin
                    chk_rat [chk_a[2:0]] <= rat_after0;
                    chk_fl  [chk_a[2:0]] <= fl_alloc + {5'b0, dr_wr0};
                    chk_sqt [chk_a[2:0]] <= sq_tail4;
                    chk_ghr [chk_a[2:0]] <= dr_ghr0;
                    chk_rtos[chk_a[2:0]] <= dr_rtos0;
                end
            end
            if (ok1) begin
                if (dr_wr1) begin
                    rat[dr_rd1] <= pd1;
                    busy[pd1]   <= 1'b1;
                end
                rob_v[rob_tail + 5'd1]    <= 1'b1;
                rob_done[rob_tail + 5'd1] <= 1'b0;
                rob_wr[rob_tail + 5'd1]   <= dr_wr1;
                rob_rd[rob_tail + 5'd1]   <= dr_rd1;
                rob_pd[rob_tail + 5'd1]   <= pd1;
                rob_old[rob_tail + 5'd1]  <= old1;
                rob_st[rob_tail + 5'd1]   <= dr_st1;
                rob_ctrl[rob_tail + 5'd1] <= ctrl1;
                rob_pc[rob_tail + 5'd1]   <= dr_pc1;
                rob_ld[rob_tail + 5'd1]   <= dr_ld1;
                rob_poison[rob_tail + 5'd1] <= 1'b0;
                if (ctrl1) begin
                    chk_rat [chk_tag1[2:0]] <= rat_after1;
                    chk_fl  [chk_tag1[2:0]] <= fl_alloc + {5'b0, dr_wr0}
                                                        + {5'b0, dr_wr1};
                    chk_sqt [chk_tag1[2:0]] <= sq_tail4 + {3'b0, dr_st0};
                    chk_ghr [chk_tag1[2:0]] <= dr_ghr1;
                    chk_rtos[chk_tag1[2:0]] <= dr_rtos1;
                end
            end
            if (ok0) begin
                fl_alloc <= fl_alloc + {5'b0, dr_wr0} + {5'b0, ok1 && dr_wr1};
                {rob_tail_ph, rob_tail} <= tail_tag + {4'b0, n_disp};
                chk_a <= chk_a + {3'b0, ctrl0}
                               + {3'b0, ok1 && ctrl1};
            end

            // ------------------------------ busy clears (select + load WB)
            if (sel0_v && sel0_uop[`U_WR]) busy[sel0_uop[`U_PD]] <= 1'b0;
            if (sel1_v && sel1_uop[`U_WR]) busy[sel1_uop[`U_PD]] <= 1'b0;
            if (wb_v2_isload_wr)           busy[wb_pd2_r]        <= 1'b0;

            // ------------------------------ RF stage load (from selects)
            rf_v[0] <= sel0_v && !kill_s0;
            rf_u[0] <= sel0_uop;
            rf_v[1] <= sel1_v && !kill_s1;
            rf_u[1] <= sel1_uop;
            rf_v[2] <= sel2_v && !kill_s2;
            rf_u[2] <= sel2_uop;

            // ------------------------------ EX stage load (PRF read done)
            ex_v[0] <= rf_v[0] && !kill_rf0;
            ex_u[0] <= rf_u[0];
            ex_a[0] <= prf_r0a;  ex_b[0] <= prf_r0b;
            ex_v[1] <= rf_v[1] && !kill_rf1;
            ex_u[1] <= rf_u[1];
            ex_a[1] <= prf_r1a;  ex_b[1] <= prf_r1b;
            ex_v[2] <= rf_v[2] && !kill_rf2;
            ex_u[2] <= rf_u[2];
            ex_a[2] <= prf_r2a;  ex_b[2] <= prf_r2b;

            // ------------------------------ WB stage load (EX results)
            wb_v[0]   <= ex_v[0] && !kill_ex0;
            wb_wr[0]  <= ex_u[0][`U_WR];
            wb_pd[0]  <= ex_u[0][`U_PD];
            wb_val[0] <= p0_result;
            wb_tag[0] <= ex_u[0][`U_TAG];
            wb_ld[0]  <= 1'b0;

            wb_v[1]   <= ex_v[1] && !kill_ex1;
            wb_wr[1]  <= ex_u[1][`U_WR];
            wb_pd[1]  <= ex_u[1][`U_PD];
            wb_val[1] <= p1_result;
            wb_tag[1] <= ex_u[1][`U_TAG];
            wb_ld[1]  <= 1'b0;

            wb_v[2]   <= ex_v[2] && !kill_ex2 && !p2_replay;
            wb_wr[2]  <= ex_u[2][`U_WR];
            wb_pd[2]  <= ex_u[2][`U_PD];
            wb_val[2]    <= p2_nondmem;    // SQ-fwd / MMIO / NPU (D016)
            wb2_use_dmem <= p2_use_dmem;   // RAM load -> take dmem_rdata in WB
            wb_tag[2] <= ex_u[2][`U_TAG];
            wb_ld[2]  <= ex_u[2][`U_ISLOAD];

            // ------------------------------ ROB done from WB
            if (wb_v[0]) begin
                rob_done[wb_tag[0][4:0]] <= 1'b1;
                rob_val [wb_tag[0][4:0]] <= wb_val[0];
            end
            if (wb_v[1]) begin
                rob_done[wb_tag[1][4:0]] <= 1'b1;
                rob_val [wb_tag[1][4:0]] <= wb_val[1];
            end
            if (wb_v[2]) begin
                rob_done[wb_tag[2][4:0]] <= 1'b1;
                rob_val [wb_tag[2][4:0]] <= wb_result2;
            end

            // ------------------------------ retire
            if (ret0_ok) begin
                rob_v[h0] <= 1'b0;
                if (rob_wr[h0]) begin
                    fl[fl_free[4:0]] <= rob_old[h0];
                    fl_free <= fl_free + 6'd1 + {5'b0, ret1_ok && rob_wr[h1]};
                end else if (ret1_ok && rob_wr[h1]) begin
                    fl[fl_free[4:0]] <= rob_old[h1];
                    fl_free <= fl_free + 6'd1;
                end
                if (ret1_ok && rob_wr[h0] && rob_wr[h1])
                    fl[(fl_free + 6'd1) & 6'd31] <= rob_old[h1];
                if (ret1_ok) rob_v[h1] <= 1'b0;
                {rob_head_ph, rob_head} <= head_tag + {4'b0, retire_n};
                chk_f <= chk_f + {3'b0, rob_ctrl[h0]}
                               + {3'b0, ret1_ok && rob_ctrl[h1]};
                // architectural RAT update (D020): commit the arch->phys map
                // in program order. slot1 (younger) wins a same-cycle WAW.
                if (rob_wr[h0]) arat[rob_rd[h0]] <= rob_pd[h0];
                if (ret1_ok && rob_wr[h1]) arat[rob_rd[h1]] <= rob_pd[h1];
            end

            // ------------------------------ poison (load-ordering violation)
            // The violation CAM (LQ) names the oldest younger executed load
            // that a just-filled store overwrote. Mark its ROB entry poisoned
            // so it flushes when it reaches the head. Suppressed if that entry
            // is being squashed this cycle by a branch restore.
            if (lq_vio_en && !(restore_en
                               && is_younger(lq_vio_tag, restore_tag)))
                rob_poison[lq_vio_tag[4:0]] <= 1'b1;

            // ------------------------------ restore (LAST: wins conflicts)
            if (restore_en) begin
                for (i = 0; i < 32; i = i + 1)
                    rat[i] <= chk_rat[restore_chk[2:0]][i*6 +: 6];
                fl_alloc <= chk_fl[restore_chk[2:0]];
                chk_a    <= restore_chk + 4'd1;
                {rob_tail_ph, rob_tail} <= restore_tag + 6'd1;
                for (i = 0; i < ROBD; i = i + 1)
                    if (is_younger({rob_tail_ph_of(i), i[4:0]}, restore_tag))
                        rob_v[i] <= 1'b0;
            end

            // ------------------------------ load-violation flush-at-head FSM
            // (D020, Strategy B-real). Rare (real violations only). Phase 1:
            // snap arch state, empty the ROB, refetch the load's PC, and start
            // the freelist rebuild. Phases 2..: sweep phys tags, pushing every
            // non-architectural (not-in-arat) tag back onto the freelist ring.
            // The whole machine is frozen (dispatch/issue/retire gated on
            // !lq_flushing) during the drain.
            if (lq_flush_start) begin
                // Phase 1: snap architectural state, empty the ROB, and start
                // the freelist rebuild sweep. The front-end refetch (pcF <=
                // load PC) and IQ/SQ flush happen in their own always blocks,
                // gated on lq_flush_start. Dispatch/issue/retire are frozen
                // while lq_state is set.
                for (i = 0; i < 32; i = i + 1) rat[i] <= arat[i];
                {rob_tail_ph, rob_tail} <= head_tag;
                for (i = 0; i < ROBD; i = i + 1) begin
                    rob_v[i]      <= 1'b0;
                    rob_poison[i] <= 1'b0;
                end
                // nothing is in flight after a full flush: clear every busy
                // bit (architectural values committed; freed tags unallocated).
                for (i = 0; i < PHYS; i = i + 1) busy[i] <= 1'b0;
                chk_a <= 4'd0; chk_f <= 4'd0;
                // start the sweep: walk phys tags from 0, write free tags to
                // fl[0..]. Exactly 32 tags are free after a flush (PHYS=64, 32
                // architectural incl p0), so lq_wp ends at 32 and the ring
                // matches the reset layout: fl[0..31] all free, popped from 0.
                lq_wp    <= 6'd0;
                lq_sweep <= 7'd0;
                lq_state <= 1'b1;
            end else if (lq_state) begin
                // Phase 2: one phys tag per cycle. Push tag lq_sweep onto the
                // freelist iff it is not p0 and not architectural (not in arat).
                if (lq_sweep < PHYS) begin
                    if ((lq_sweep != 7'd0) && !in_arat(lq_sweep[5:0])) begin
                        fl[lq_wp[4:0]] <= lq_sweep[5:0];
                        lq_wp          <= lq_wp + 6'd1;
                    end
                    lq_sweep <= lq_sweep + 7'd1;
                end else begin
                    // sweep complete: all 32 free tags now in fl[0..31].
                    // fl_alloc=fl_free=0 => fl_avail=32 (all free), matching
                    // the reset ring layout exactly.
                    fl_alloc <= 6'd0;
                    fl_free  <= 6'd0;
                    lq_state <= 1'b0;
                end
            end
        end
    end

    // helper: reconstruct the phase of a ROB index relative to head/tail
    function rob_tail_ph_of;
        input integer idx;
        reg [4:0] x;
        begin
            x = idx[4:0];
            // an index is "ahead" of head with the head's phase if it is
            // >= head, otherwise it wrapped and carries the opposite phase
            rob_tail_ph_of = (x >= rob_head) ? rob_head_ph : ~rob_head_ph;
        end
    endfunction

    // =====================================================================
    // retire-side lockstep observation (2 slots)
    // =====================================================================
    wire        ret0_v  /*verilator public_flat_rd*/ = ret0_ok;
    wire [31:0] ret0_pc /*verilator public_flat_rd*/ = rob_pc[h0];
    wire        ret0_wr /*verilator public_flat_rd*/ = rob_wr[h0];
    wire [4:0]  ret0_rd /*verilator public_flat_rd*/ = rob_rd[h0];
    wire [31:0] ret0_val/*verilator public_flat_rd*/ = rob_val[h0];
    wire        ret1_v  /*verilator public_flat_rd*/ = ret1_ok;
    wire [31:0] ret1_pc /*verilator public_flat_rd*/ = rob_pc[h1];
    wire        ret1_wr /*verilator public_flat_rd*/ = rob_wr[h1];
    wire [4:0]  ret1_rd /*verilator public_flat_rd*/ = rob_rd[h1];
    wire [31:0] ret1_val/*verilator public_flat_rd*/ = rob_val[h1];

endmodule
