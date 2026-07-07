module cpu_pipeline (
    input  wire clk,
    input  wire reset,
    output wire [9:0] leds,
    input  wire [9:0] switches
);

    // ======================================================
    // IF (Instruction Fetch) Stage
    // ======================================================
    // NOTE: /*verilator public_flat_rd*/ marks are simulation-only test
    // hooks read by the Verilator harness (tb/verilator/sim_main.cpp).
    // Quartus sees them as plain comments — no synthesis impact.
    wire [31:0] pcF /*verilator public_flat_rd*/;
    wire [31:0] next_pcF;
    wire [31:0] instrF;

    // Branch predictor signals routed into IF stage
    wire [31:0] next_pc_predF;   // Predicted next PC
    wire        pred_takenF;     // Predicted taken/not taken
    wire [31:0] pred_targetF;    // Predicted target from BTB

    // Predictor values forwarded to Decode and Execute stages
    wire        pred_takenD;
    wire [31:0] pred_targetD;

    wire        pred_takenE;
    wire [31:0] pred_targetE;

    // Hazard / stall / flush signals
    wire stallF;          // Freeze PC update
    wire stallD;          // Freeze IF/ID register
    wire flushE;          // Insert bubble into EX stage
    wire if_id_flush;     // Flush IF/ID when mispredict happens

    // NPU interlock stall (declared here, computed in EX — see below)
    wire npu_stallE;

    // Program counter register
    pc PC0 (
        .clk    (clk),
        .reset  (reset),
        .stall  (stallF | npu_stallE),
        .next_pc(next_pcF),
        .pc     (pcF)
    );

    // Instruction memory (second fetch port unused in the in-order core)
    imem IMEM0 (
        .pc          (pcF),
        .instruction (instrF),
        .pc2         (32'b0),
        .instruction2()
    );

    // Sequential next PC (default fall-through)
    wire [31:0] pc_plus4F = pcF + 32'd4;

    // IF/ID pipeline register
    wire [31:0] pcD;
    wire [31:0] instrD;

    // Valid bits (decision D012): mark architecturally real instructions
    // as they flow down the pipe. Flushes and bubbles carry valid=0, so
    // the instret counter sees exactly the retired program, not the
    // pipeline's stalls and wrong-path slots.
    wire validD;
    wire validE;
    wire validM;
    wire validW /*verilator public_flat_rd*/;

    if_id_reg IFID0 (
        .clk           (clk),
        .reset         (reset),
        .if_pc         (pcF),
        .if_instruction(instrF),
        .stall         (stallD | npu_stallE),
        .flush         (if_id_flush),

        .id_pc         (pcD),
        .id_instruction(instrD),
        .id_valid      (validD),

        // Propagate predictor info into Decode
        .pred_takenF(pred_takenF),
        .pred_targetF(pred_targetF),
        .pred_takenD(pred_takenD),
        .pred_targetD(pred_targetD)
    );

    // ======================================================
    // ID (Instruction Decode) Stage
    // ======================================================

    // Decode instruction fields
    wire [6:0] opcodeD = instrD[6:0];
    wire [4:0] rdD     = instrD[11:7];
    wire [2:0] funct3D = instrD[14:12];
    wire [4:0] rs1D    = instrD[19:15];
    wire [4:0] rs2D    = instrD[24:20];
    wire [6:0] funct7D = instrD[31:25];

    // Control signals generated in ID
    wire       RegWriteD;
    wire       MemReadD;
    wire       MemWriteD;
    wire       MemToRegD;
    wire       ALUSrcD;
    wire       ALUAPcD;
    wire       BranchD;
    wire       JalD;
    wire       JalrD;
    wire       CsrD;
    wire [2:0] ALUOpD;

    // Control unit (opcode-level decoding; funct3 only sub-decodes SYSTEM)
    control CU (
        .opcode   (opcodeD),
        .funct3   (funct3D),
        .RegWrite (RegWriteD),
        .MemRead  (MemReadD),
        .MemWrite (MemWriteD),
        .MemToReg (MemToRegD),
        .ALUSrc   (ALUSrcD),
        .ALUAPc   (ALUAPcD),
        .Branch   (BranchD),
        .Jal      (JalD),
        .Jalr     (JalrD),
        .Csr      (CsrD),
        .ALUOp    (ALUOpD)
    );

    // Signals forwarded into Writeback
    wire       RegWriteW /*verilator public_flat_rd*/;
    wire [4:0] rdW /*verilator public_flat_rd*/;
    wire [31:0] resultW /*verilator public_flat_rd*/;

    // Register file — read in ID, write in WB
    wire [31:0] rs1_dataD;
    wire [31:0] rs2_dataD;

    register_file RF0 (
        .clk       (clk),
        .reset     (reset),

        // Writeback inputs
        .reg_write (RegWriteW),
        .rd_addr   (rdW),
        .rd_data   (resultW),

        // Register file reads
        .rs1_addr (rs1D),
        .rs1_data (rs1_dataD),
        .rs2_addr (rs2D),
        .rs2_data (rs2_dataD)
    );

    // Sign-extend immediate generator
    wire [31:0] immD;

    sign_extend SE0 (
        .instruction(instrD),
        .imm_ext    (immD)
    );

    // ======================================================
    // ID/EX Pipeline Register
    // Holds all decoded signals for the Execute stage
    // ======================================================

    wire       RegWriteE;
    wire       MemReadE;
    wire       MemWriteE;
    wire       MemToRegE;
    wire       ALUSrcE;
    wire       ALUAPcE;
    wire       BranchE /*verilator public_flat_rd*/;
    wire       JalE;
    wire       JalrE;
    wire       CsrE;
    wire [2:0] ALUOpE;

    wire [31:0] pcE /*verilator public_flat_rd*/;
    wire [31:0] rs1_dataE;
    wire [31:0] rs2_dataE;
    wire [31:0] immE;
    wire [4:0]  rs1E;
    wire [4:0]  rs2E;
    wire [4:0]  rdE;
    wire [2:0]  funct3E;
    wire [6:0]  funct7E;

    wire [31:0] alu_resultM /*verilator public_flat_rd*/; // Used for forwarding

    id_ex_reg IDEX0 (
        .clk         (clk),
        .reset       (reset),
        .flush       (flushE),
        .stall       (npu_stallE),

        // Control signals
        .RegWrite_in (RegWriteD),
        .MemRead_in  (MemReadD),
        .MemWrite_in (MemWriteD),
        .MemToReg_in (MemToRegD),
        .ALUSrc_in   (ALUSrcD),
        .ALUAPc_in   (ALUAPcD),
        .Branch_in   (BranchD),
        .Jal_in      (JalD),
        .Jalr_in     (JalrD),
        .Csr_in      (CsrD),
        .valid_in    (validD),
        .ALUOp_in    (ALUOpD),

        // Operands and instruction fields
        .pc_in       (pcD),
        .rs1_data_in (rs1_dataD),
        .rs2_data_in (rs2_dataD),
        .imm_in      (immD),
        .rs1_in      (rs1D),
        .rs2_in      (rs2D),
        .rd_in       (rdD),
        .funct3_in   (funct3D),
        .funct7_in   (funct7D),

        // Outputs to EX stage
        .RegWrite_out(RegWriteE),
        .MemRead_out (MemReadE),
        .MemWrite_out(MemWriteE),
        .MemToReg_out(MemToRegE),
        .ALUSrc_out  (ALUSrcE),
        .ALUAPc_out  (ALUAPcE),
        .Branch_out  (BranchE),
        .Jal_out     (JalE),
        .Jalr_out    (JalrE),
        .Csr_out     (CsrE),
        .valid_out   (validE),
        .ALUOp_out   (ALUOpE),

        .pc_out      (pcE),
        .rs1_data_out(rs1_dataE),
        .rs2_data_out(rs2_dataE),
        .imm_out     (immE),
        .rs1_out     (rs1E),
        .rs2_out     (rs2E),
        .rd_out      (rdE),
        .funct3_out  (funct3E),
        .funct7_out  (funct7E),

        // Predicted info flowing forward
        .pred_takenD (pred_takenD),
        .pred_targetD(pred_targetD),
        .pred_takenE (pred_takenE),
        .pred_targetE(pred_targetE)
    );
    // ======================================================
    // EX (Execute) Stage
    // ======================================================
    wire [3:0]  alu_controlE;
    wire [31:0] rs1_fwdE /*verilator public_flat_rd*/;
    wire [31:0] rs2_fwdE;
    wire [31:0] alu_bE;
    wire [31:0] alu_resultE;
    wire        alu_zeroE /*verilator public_flat_rd*/;

    wire [1:0]  forwardAE /*verilator public_flat_rd*/;
    wire [1:0]  forwardBE;

    // Forwarding for source A (rs1)
    assign rs1_fwdE =
        (forwardAE == 2'b10) ? alu_resultM :
        (forwardAE == 2'b01) ? resultW     :
                               rs1_dataE;

    // Forwarding for source B (rs2) before ALUSrc mux
    wire [31:0] rs2_fwd_base /*verilator public_flat_rd*/;
    assign rs2_fwd_base =
        (forwardBE == 2'b10) ? alu_resultM :
        (forwardBE == 2'b01) ? resultW     :
                               rs2_dataE;

    // Final B input to ALU: either forwarded rs2 or immediate
    assign alu_bE = (ALUSrcE) ? immE : rs2_fwd_base;

    // Operand A: pc for AUIPC (decision D009/D1; jumps reuse this path)
    wire [31:0] alu_aE = ALUAPcE ? pcE : rs1_fwdE;

    // ALU instance
    alu ALU0 (
        .a          (alu_aE),
        .b          (alu_bE),
        .alu_control(alu_controlE),
        .result     (alu_resultE),
        .zero       (alu_zeroE)
    );

    // ALU control: decodes ALUOp + funct3/funct7
    alu_control ALUCTRL (
        .ALUOp      (ALUOpE),
        .funct3     (funct3E),
        .funct7     (funct7E),
        .alu_control(alu_controlE)
    );

    // Compute branch target (PC-relative) in EX stage
    wire [31:0] branch_targetE = pcE + immE;
    wire [31:0] pc_plus4E     = pcE + 32'd4;

    // Branch condition from the dedicated comparator (decision D007/B2):
    // operates on the forwarded operands, independent of the ALU, and
    // implements all six RV32I conditions via funct3.
    wire branch_condE;

    branch_unit BRU (
        .a      (rs1_fwdE),
        .b      (rs2_fwd_base),
        .funct3 (funct3E),
        .taken  (branch_condE)
    );

    wire branch_taken_ex;
    assign branch_taken_ex = BranchE && branch_condE;

    // ======================================================
    // Jumps (JAL/JALR — decision D008/C1)
    // ======================================================
    // Jumps are always taken. JAL's target comes from the branch-target
    // adder (pc+imm); JALR's target is the ALU result (rs1+imm) with the
    // LSB cleared as the ISA requires. rd receives pc+4 through the EX
    // result mux below, so the WB path is unchanged.
    wire        jumpE          = JalE | JalrE;
    wire        redirect_instE = BranchE | jumpE;   // can change the PC
    wire        actual_takenE  = branch_taken_ex | jumpE;
    wire [31:0] actual_targetE = JalrE ? (alu_resultE & ~32'h1)
                                       : branch_targetE;

    // ======================================================
    // CSR file (Zicsr — decision D012)
    // ======================================================
    // CSR ops execute here in EX: nothing that reached EX can be killed
    // (mispredicts only flush IF/ID + ID/EX), so the CSR write commits
    // non-speculatively. The CSR address arrives on the I-type immediate
    // bus (instr[31:20] == immE[11:0]); rs1E doubles as the zimm for the
    // immediate forms. instret advances on validW = a real instruction
    // (not a bubble or flushed slot) leaving WB.
    wire [31:0] csr_rdataE;

    csr_file CSR0 (
        .clk      (clk),
        .reset    (reset),

        .csr_en   (CsrE),
        .csr_addr (immE[11:0]),
        .funct3   (funct3E),
        .rs1_addr (rs1E),
        .rs1_data (rs1_fwdE),
        .csr_rdata(csr_rdataE),

        .retire_n ({1'b0, validW})
    );

    // EX result: old CSR value for CSR ops, link value (pc+4) for jumps,
    // ALU result otherwise
    wire [31:0] ex_resultE = CsrE  ? csr_rdataE :
                             jumpE ? pc_plus4E  : alu_resultE;

    // ======================================================
    // Branch Predictor (BHT + BTB)
    // ======================================================
    branch_predictor BP0 (
        .clk            (clk),
        .reset          (reset),

        // IF-stage query (prediction)
        .pcF            (pcF),
        .next_pc_predF  (next_pc_predF),
        .pred_takenF    (pred_takenF),
        .pred_targetF   (pred_targetF),

        // EX-stage update (correction) — jumps train the predictor too,
        // so repeat JAL/JALR encounters redirect from IF for free
        .BranchE        (redirect_instE),
        .pcE            (pcE),
        .branch_takenE  (actual_takenE),
        .branch_targetE (actual_targetE)
    );

    // ======================================================
    // Misprediction Detection (EX Stage)
    // ======================================================

    // pred_takenE / pred_targetE are the predictor's view of this
    // instruction; branches AND jumps are checked the same way
    wire mispredictE /*verilator public_flat_rd*/;
    assign mispredictE =
        redirect_instE && (
            (actual_takenE != pred_takenE) ||                     // wrong direction
            (actual_takenE && (actual_targetE != pred_targetE))   // or wrong target
        );

    // Correct next PC if prediction was wrong
    wire [31:0] next_pc_correctE;
    assign next_pc_correctE =
        actual_takenE ? actual_targetE : pc_plus4E;

    // Global next PC selection: corrected PC vs. predicted PC
    assign next_pcF = mispredictE ? next_pc_correctE
                                  : next_pc_predF;

    // ======================================================
    // NPU interlock (docs/NPU.md, decision D014)
    // ======================================================
    // An NPU access (0x5xxx_xxxx) may pass EX->MEM only when the array
    // is idle. busy_next also covers a GO store that is in MEM *right
    // now* (its busy register sets one cycle later). While waiting, the
    // access holds in EX: PC, IF/ID and ID/EX freeze and EX/MEM receives
    // bubbles — MEM and WB keep flowing, so no committed side effect can
    // repeat. The stalled instruction is a load/store, never a branch or
    // CSR op, so no mispredict/train/CSR logic fires while held.
    wire npu_busy;
    wire npu_busy_next;

    // The hold must SNAPSHOT the access's address and store data on its
    // first stall cycle (BUGLOG B011): the forwarding sources that made
    // them correct (producer still in MEM/WB) drain to bubbles while the
    // pipe is frozen, and the ID/EX operand copies are decode-time
    // regfile values — stale whenever forwarding was needed. Recomputing
    // from the live muxes mid-hold lets the effective address decay, the
    // region decode flip, and the interlock self-release onto a garbage
    // address. Snapshot once (forwarding is valid on the first EX
    // cycle), then use the held values for the stall decision and for
    // what EX/MEM finally latches on release.
    reg        npu_heldE;
    reg [31:0] npu_addr_holdE;
    reg [31:0] npu_data_holdE;

    wire [31:0] npu_eff_addrE = npu_heldE ? npu_addr_holdE : alu_resultE;
    wire is_npu_accessE = (MemReadE | MemWriteE)
                          && (npu_eff_addrE[31:28] == 4'h5);
    assign npu_stallE = is_npu_accessE && npu_busy_next;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            npu_heldE      <= 1'b0;
            npu_addr_holdE <= 32'b0;
            npu_data_holdE <= 32'b0;
        end else if (npu_stallE && !npu_heldE) begin
            npu_heldE      <= 1'b1;          // first hold cycle: snapshot
            npu_addr_holdE <= alu_resultE;   // forwarding still live here
            npu_data_holdE <= rs2_fwd_base;
        end else if (!npu_stallE) begin
            npu_heldE <= 1'b0;
        end
    end

`ifdef VERILATOR
    // the escape mode B011 fixed: a held access must release only
    // because the array went idle, never because its address decayed
    always @(posedge clk)
        if (!reset && npu_heldE && !npu_stallE && npu_busy_next)
            $fatal(1, "cpu_pipeline: NPU hold released while array busy");
`endif

    // ======================================================
    // EX/MEM Pipeline Register
    // Pass results from EX into MEM stage
    // ======================================================
    wire       RegWriteM;
    wire       MemReadM;
    wire       MemWriteM /*verilator public_flat_rd*/;
    wire       MemToRegM;
    wire       BranchM;
    wire [31:0] rs2_dataM /*verilator public_flat_rd*/;
    wire        alu_zeroM;
    wire [31:0] branch_targetM;
    wire [4:0]  rdM;
    wire [2:0]  funct3M /*verilator public_flat_rd*/;
    wire [31:0] pcM;   // lockstep observability; pruned in synthesis

    ex_mem_reg EXMEM0 (
        .clk              (clk),
        .reset            (reset),

        // Control signals — gated into a bubble while the EX instruction
        // is held by the NPU interlock (npu_stallE)
        .RegWrite_in      (RegWriteE & ~npu_stallE),
        .MemRead_in       (MemReadE  & ~npu_stallE),
        .MemWrite_in      (MemWriteE & ~npu_stallE),
        .MemToReg_in      (MemToRegE),
        .Branch_in        (BranchE   & ~npu_stallE),
        .valid_in         (validE    & ~npu_stallE),

        // Data signals. ex_resultE = pc+4 for jumps (link value), ALU
        // result otherwise — so jump links forward like any ALU result.
        // A held NPU access latches its SNAPSHOT address/data instead:
        // by release time the live muxes have decayed (B011).
        .alu_result_in    (npu_heldE ? npu_addr_holdE : ex_resultE),
        // Store data must be the FORWARDED rs2, not the raw ID/EX value —
        // otherwise a store right after its producer writes stale data
        // (BUGLOG B007, decision D011/F1)
        .rs2_data_in      (npu_heldE ? npu_data_holdE : rs2_fwd_base),
        .zero_in          (alu_zeroE),
        .branch_target_in (branch_targetE),
        .rd_in            (rdE),
        .funct3_in        (funct3E),
        .pc_in            (pcE),

        // Outputs to MEM stage
        .RegWrite_out     (RegWriteM),
        .MemRead_out      (MemReadM),
        .MemWrite_out     (MemWriteM),
        .MemToReg_out     (MemToRegM),
        .Branch_out       (BranchM),
        .valid_out        (validM),

        .alu_result_out   (alu_resultM),
        .rs2_data_out     (rs2_dataM),
        .zero_out         (alu_zeroM),
        .branch_target_out(branch_targetM),
        .rd_out           (rdM),
        .funct3_out       (funct3M),
        .pc_out           (pcM)
    );

    // ======================================================
    // Hazard Detection and Forwarding
    // ======================================================

    // Forwarding unit: resolves data hazards by bypassing
    forwarding_unit FU (
        .rs1E      (rs1E),
        .rs2E      (rs2E),
        .rdM       (rdM),
        .rdW       (rdW),
        .RegWriteM (RegWriteM),
        .RegWriteW (RegWriteW),
        .forwardAE (forwardAE),
        .forwardBE (forwardBE)
    );

    // Hazard unit: handles load-use stalls and branch flushes
    hazard_unit HU (
        .MemReadE    (MemReadE),
        .rdE         (rdE),
        .rs1D        (rs1D),
        .rs2D        (rs2D),
        .mispredictE (mispredictE),

        .stallF      (stallF),
        .stallD      (stallD),
        .flushE      (flushE),
        .if_id_flush (if_id_flush)
    );

	    // ======================================================
    // MEM (Memory Access) Stage
    // ======================================================

    // Simple MMIO address check: 0x4xxxxxxx region is treated as IO,
    // 0x5xxxxxxx is the NPU (docs/NPU.md, D014)
    wire is_ioM  = (alu_resultM[31:28] == 4'h4);
    wire is_npuM = (alu_resultM[31:28] == 4'h5);

    // Separate data paths for regular RAM, MMIO and NPU reads. The RAM read
    // is now SYNCHRONOUS (dmem registers it — B006/D016), so ram_read_dataW
    // is a WB-stage signal; MMIO/NPU reads stay combinational here in MEM
    // and are carried to WB through the MEM/WB register so all three align.
    wire [31:0] ram_read_dataW;   // dmem registered output → valid in WB
    wire [31:0] mmio_read_dataM;
    wire [31:0] npu_read_dataM;

    // Data memory: read and write ports carry the same MEM-stage access.
    // SYNC_READ=1 folds the former MEM/WB mem_data latch into the M9K read
    // register — one cycle of read latency, IPC-neutral (see WB stage).
    dmem #(.SYNC_READ(1)) DMEM0 (
        .clk        (clk),
        .mem_read   (MemReadM  & ~is_ioM & ~is_npuM),
        .raddr      (alu_resultM),
        .rfunct3    (funct3M),              // access size + sign extension
        .read_data  (ram_read_dataW),       // registered inside dmem → WB
        .mem_write  (MemWriteM & ~is_ioM & ~is_npuM),
        .waddr      (alu_resultM),
        .write_data (rs2_dataM),
        .wfunct3    (funct3M)
    );

    // NPU: the EX interlock guarantees any access arriving here finds
    // the array idle (asserted below); MEM-stage stores are committed
    // by definition in this pipeline, so side effects are safe.
    npu_top NPU0 (
        .clk       (clk),
        .reset     (reset),
        .raddr     (alu_resultM),
        .rdata     (npu_read_dataM),
        .we        (MemWriteM & is_npuM),
        .waddr     (alu_resultM),
        .wdata     (rs2_dataM),
        .busy      (npu_busy),
        .busy_next (npu_busy_next)
    );

`ifdef VERILATOR
    always @(posedge clk)
        if (!reset && (MemReadM | MemWriteM) && is_npuM && npu_busy)
            $fatal(1, "cpu_pipeline: NPU access reached MEM while busy");
`endif

    // MMIO block for LEDs and switches
    wire [9:0] leds_mmio;

    mmio MMIO0 (
        .clk      (clk),
        .reset    (reset),
        .raddr    (alu_resultM),
        .rdata    (mmio_read_dataM),
        .waddr    (alu_resultM),
        .wdata    (rs2_dataM),
        .we       (MemWriteM & is_ioM),     // write only when targeting IO region

        .leds     (leds_mmio),
        .switches (switches)
    );

    // MMIO / NPU read data is combinational here in MEM; select which of
    // the two. The RAM path is resolved in WB, where dmem's registered
    // output (ram_read_dataW) arrives; mem_is_ioM records that this access
    // targets IO/NPU rather than RAM so WB can pick the right source.
    wire        mem_is_ioM    = is_ioM | is_npuM;
    wire [31:0] io_read_dataM = is_npuM ? npu_read_dataM : mmio_read_dataM;

    // ======================================================
    // MEM/WB Pipeline Register
    // Carries the MMIO/NPU read data + its select bit and the ALU result
    // into WB. The RAM read register now lives inside dmem (B006/D016).
    // ======================================================
    wire [31:0] io_read_dataW /*verilator public_flat_rd*/;  // MMIO/NPU data in WB
    wire        mem_is_ioW;
    wire [31:0] alu_resultW;
    wire        MemToRegW /*verilator public_flat_rd*/;
    wire [31:0] pcW /*verilator public_flat_rd*/;  // lockstep: retired PC

    mem_wb_reg MEMWB0 (
        .clk           (clk),
        .reset         (reset),

        // Control
        .RegWrite_in   (RegWriteM),
        .MemToReg_in   (MemToRegM),
        .valid_in      (validM),

        // Data
        .mem_data_in   (io_read_dataM),    // MMIO/NPU read data
        .mem_is_io_in  (mem_is_ioM),       // 1 = load target is IO/NPU
        .alu_result_in (alu_resultM),
        .rd_in         (rdM),
        .pc_in         (pcM),

        // Outputs to WB
        .RegWrite_out  (RegWriteW),
        .MemToReg_out  (MemToRegW),
        .valid_out     (validW),
        .mem_data_out  (io_read_dataW),
        .mem_is_io_out (mem_is_ioW),
        .alu_result_out(alu_resultW),
        .rd_out        (rdW),
        .pc_out        (pcW)
    );

    // ======================================================
    // WB (Writeback) Stage
    // ======================================================
    // Load value: registered RAM read from dmem, unless the access targeted
    // IO/NPU, whose data rode the MEM/WB register. Both land in WB aligned.
    wire [31:0] mem_dataW /*verilator public_flat_rd*/ =
        mem_is_ioW ? io_read_dataW : ram_read_dataW;

    // Choose between memory data and ALU result as the value to write back
    assign resultW = MemToRegW ? mem_dataW : alu_resultW;

    // ======================================================
    // FPGA IO Mapping
    // ======================================================

    // LEDs are fully memory-mapped via MMIO
    assign leds = leds_mmio;

endmodule
