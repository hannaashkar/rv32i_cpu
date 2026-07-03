module cpu_pipeline (
    input  wire clk,
    input  wire reset,
    output wire [9:0] leds,
    input  wire [9:0] switches
);

    // ======================================================
    // IF (Instruction Fetch) Stage
    // ======================================================
    wire [31:0] pcF;
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

    // Program counter register
    pc PC0 (
        .clk    (clk),
        .reset  (reset),
        .stall  (stallF),
        .next_pc(next_pcF),
        .pc     (pcF)
    );

    // Instruction memory
    imem IMEM0 (
        .pc         (pcF),
        .instruction(instrF)
    );

    // Sequential next PC (default fall-through)
    wire [31:0] pc_plus4F = pcF + 32'd4;

    // IF/ID pipeline register
    wire [31:0] pcD;
    wire [31:0] instrD;

    if_id_reg IFID0 (
        .clk           (clk),
        .reset         (reset),
        .if_pc         (pcF),
        .if_instruction(instrF),
        .stall         (stallD),
        .flush         (if_id_flush),

        .id_pc         (pcD),
        .id_instruction(instrD),

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
    wire       BranchD;
    wire [1:0] ALUOpD;

    wire [31:0] debug_x3; // For FPGA LED debugging

    // Control unit (opcode-level decoding)
    control CU (
        .opcode   (opcodeD),
        .RegWrite (RegWriteD),
        .MemRead  (MemReadD),
        .MemWrite (MemWriteD),
        .MemToReg (MemToRegD),
        .ALUSrc   (ALUSrcD),
        .Branch   (BranchD),
        .ALUOp    (ALUOpD)
    );

    // Signals forwarded into Writeback
    wire       RegWriteW;
    wire [4:0] rdW;
    wire [31:0] resultW;

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
        .rs2_data (rs2_dataD),

        .debug_x3(debug_x3)
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
    wire       BranchE;
    wire [1:0] ALUOpE;

    wire [31:0] pcE;
    wire [31:0] rs1_dataE;
    wire [31:0] rs2_dataE;
    wire [31:0] immE;
    wire [4:0]  rs1E;
    wire [4:0]  rs2E;
    wire [4:0]  rdE;
    wire [2:0]  funct3E;
    wire [6:0]  funct7E;

    wire [31:0] alu_resultM; // Used for forwarding

    id_ex_reg IDEX0 (
        .clk         (clk),
        .reset       (reset),
        .flush       (flushE),

        // Control signals
        .RegWrite_in (RegWriteD),
        .MemRead_in  (MemReadD),
        .MemWrite_in (MemWriteD),
        .MemToReg_in (MemToRegD),
        .ALUSrc_in   (ALUSrcD),
        .Branch_in   (BranchD),
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
        .Branch_out  (BranchE),
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
    wire [31:0] rs1_fwdE;
    wire [31:0] rs2_fwdE;
    wire [31:0] alu_bE;
    wire [31:0] alu_resultE;
    wire        alu_zeroE;

    wire [1:0]  forwardAE;
    wire [1:0]  forwardBE;

    // Forwarding for source A (rs1)
    assign rs1_fwdE =
        (forwardAE == 2'b10) ? alu_resultM :
        (forwardAE == 2'b01) ? resultW     :
                               rs1_dataE;

    // Forwarding for source B (rs2) before ALUSrc mux
    wire [31:0] rs2_fwd_base =
        (forwardBE == 2'b10) ? alu_resultM :
        (forwardBE == 2'b01) ? resultW     :
                               rs2_dataE;

    // Final B input to ALU: either forwarded rs2 or immediate
    assign alu_bE = (ALUSrcE) ? immE : rs2_fwd_base;

    // ALU instance
    alu ALU0 (
        .a          (rs1_fwdE),
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

    // Actual branch outcome in EX (currently for BEQ-style logic)
    wire branch_taken_ex;
    assign branch_taken_ex = BranchE && alu_zeroE;

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

        // EX-stage update (correction)
        .BranchE        (BranchE),
        .pcE            (pcE),
        .branch_takenE  (branch_taken_ex),
        .branch_targetE (branch_targetE)
    );

    // ======================================================
    // Misprediction Detection (EX Stage)
    // ======================================================

    // pred_takenE / pred_targetE are the predictor's view of this branch
    wire mispredictE;
    assign mispredictE =
        BranchE && (
            (branch_taken_ex != pred_takenE) ||                     // wrong direction
            (branch_taken_ex && (branch_targetE != pred_targetE))   // or wrong target
        );

    // Correct next PC if prediction was wrong
    wire [31:0] next_pc_correctE;
    assign next_pc_correctE =
        branch_taken_ex ? branch_targetE : (pcE + 32'd4);

    // Global next PC selection: corrected PC vs. predicted PC
    assign next_pcF = mispredictE ? next_pc_correctE
                                  : next_pc_predF;

    // ======================================================
    // EX/MEM Pipeline Register
    // Pass results from EX into MEM stage
    // ======================================================
    wire       RegWriteM;
    wire       MemReadM;
    wire       MemWriteM;
    wire       MemToRegM;
    wire       BranchM;
    wire [31:0] rs2_dataM;
    wire        alu_zeroM;
    wire [31:0] branch_targetM;
    wire [4:0]  rdM;

    ex_mem_reg EXMEM0 (
        .clk              (clk),
        .reset            (reset),

        // Control signals
        .RegWrite_in      (RegWriteE),
        .MemRead_in       (MemReadE),
        .MemWrite_in      (MemWriteE),
        .MemToReg_in      (MemToRegE),
        .Branch_in        (BranchE),

        // Data signals
        .alu_result_in    (alu_resultE),
        .rs2_data_in      (rs2_dataE),
        .zero_in          (alu_zeroE),
        .branch_target_in (branch_targetE),
        .rd_in            (rdE),

        // Outputs to MEM stage
        .RegWrite_out     (RegWriteM),
        .MemRead_out      (MemReadM),
        .MemWrite_out     (MemWriteM),
        .MemToReg_out     (MemToRegM),
        .Branch_out       (BranchM),

        .alu_result_out   (alu_resultM),
        .rs2_data_out     (rs2_dataM),
        .zero_out         (alu_zeroM),
        .branch_target_out(branch_targetM),
        .rd_out           (rdM)
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

    // Simple MMIO address check: 0x4xxxxxxx region is treated as IO
    wire is_ioM = (alu_resultM[31:28] == 4'h4);

    // Separate data paths for regular RAM and MMIO reads
    wire [31:0] ram_read_dataM;
    wire [31:0] mmio_read_dataM;

    // Data memory (used for normal load/store instructions)
    dmem DMEM0 (
        .clk        (clk),
        .mem_read   (MemReadM  & ~is_ioM),  // only access RAM when not IO
        .mem_write  (MemWriteM & ~is_ioM),  // only write RAM when not IO
        .addr       (alu_resultM),
        .write_data (rs2_dataM),
        .read_data  (ram_read_dataM)
    );

    // MMIO block for LEDs and switches
    wire [9:0] leds_mmio;

    mmio MMIO0 (
        .clk      (clk),
        .reset    (reset),
        .addr     (alu_resultM),
        .wdata    (rs2_dataM),
        .we       (MemWriteM & is_ioM),     // write only when targeting IO region
        .rdata    (mmio_read_dataM),

        .leds     (leds_mmio),
        .switches (switches)
    );

    // Select the correct read data: MMIO vs regular RAM
    wire [31:0] dmem_read_dataM;
    assign dmem_read_dataM = is_ioM ? mmio_read_dataM
                                    : ram_read_dataM;

    // ======================================================
    // MEM/WB Pipeline Register
    // Carries either memory data or ALU result into WB stage
    // ======================================================
    wire [31:0] mem_dataW;
    wire [31:0] alu_resultW;
    wire        MemToRegW;

    mem_wb_reg MEMWB0 (
        .clk           (clk),
        .reset         (reset),

        // Control
        .RegWrite_in   (RegWriteM),
        .MemToReg_in   (MemToRegM),

        // Data
        .mem_data_in   (dmem_read_dataM),
        .alu_result_in (alu_resultM),
        .rd_in         (rdM),

        // Outputs to WB
        .RegWrite_out  (RegWriteW),
        .MemToReg_out  (MemToRegW),
        .mem_data_out  (mem_dataW),
        .alu_result_out(alu_resultW),
        .rd_out        (rdW)
    );

    // ======================================================
    // WB (Writeback) Stage
    // ======================================================
    // Choose between memory data and ALU result as the value to write back
    assign resultW = MemToRegW ? mem_dataW : alu_resultW;

    // ======================================================
    // FPGA Debug / IO Mapping
    // ======================================================

    // Optionally: show x3 on LEDs for debugging
    // assign leds = debug_x3[9:0];

    // In the final version, LEDs are fully memory-mapped via MMIO
    assign leds = leds_mmio;

endmodule
