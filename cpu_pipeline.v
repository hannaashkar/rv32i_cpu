module cpu_pipeline (
    input wire clk,
    input wire reset,
	 output wire [9:0] leds,
    input  wire [9:0] switches
);
    // =========================
    // IF stage
    // =========================
    wire [31:0] pcF;
    wire [31:0] next_pcF;
    wire [31:0] instrF;

	 
	 
	 
	 
	 
	 
 // Branch predictor <-> IF
 
    wire [31:0] next_pc_predF;  // predicted next PC from BP
    wire        pred_takenF;    // predicted taken?
    wire [31:0] pred_targetF;   // predicted target PC
	
	wire        pred_takenD;
   wire [31:0] pred_targetD;
	 
	 wire        pred_takenE;    // predicted taken?
    wire [31:0] pred_targetE;   // predicted target PC
	 
    // Hazard / stall / flush signals
    wire        stallF;        // stall Fetch (PC)
    wire        stallD;        // stall Decode (IF/ID)
    wire        flushE;        // flush Execute (ID/EX -> bubble)
    wire        if_id_flush;   // flush Decode (IF/ID -> bubble on branch)

    pc PC0 (
        .clk    (clk),
        .reset  (reset),
        .stall  (stallF),      // from hazard unit
        .next_pc(next_pcF),
        .pc     (pcF)
    );

    imem IMEM0 (
        .pc         (pcF),
        .instruction(instrF)
    );

    // PC + 4
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
        .flush         (if_id_flush),   // flushed on taken branch
        .id_pc         (pcD),
        .id_instruction(instrD),
		  
		 .pred_takenF   (pred_takenF),
		.pred_targetF  (pred_targetF),
		.pred_takenD (pred_takenD),
		.pred_targetD(pred_targetD)
    );

    // =========================
    // ID stage
    // =========================

    // RISC-V fields from instrD
    wire [6:0] opcodeD  = instrD[6:0];
    wire [4:0] rdD      = instrD[11:7];
    wire [2:0] funct3D  = instrD[14:12];
    wire [4:0] rs1D     = instrD[19:15];
    wire [4:0] rs2D     = instrD[24:20];
    wire [6:0] funct7D  = instrD[31:25];

    // control signals in ID
    wire        RegWriteD;
    wire        MemReadD;
    wire        MemWriteD;
    wire        MemToRegD;
    wire        ALUSrcD;
    wire        BranchD;
    wire [1:0]  ALUOpD;
	 
	 
	 wire [31:0] debug_x3; // =============================================================

	 
	 

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

    // WB stage signals for regfile write
    wire        RegWriteW;
    wire [4:0]  rdW;
    wire [31:0] resultW;

    // Register file in ID
    wire [31:0] rs1_dataD;
    wire [31:0] rs2_dataD;

    register_file RF0 (
        .clk       (clk),
        .reset     (reset),

        .reg_write (RegWriteW),   // from WB stage
        .rd_addr   (rdW),         // from WB stage
        .rd_data   (resultW),     // from WB stage

        .rs1_addr  (rs1D),
        .rs1_data  (rs1_dataD),
        .rs2_addr  (rs2D),
        .rs2_data  (rs2_dataD),
		      .debug_x3(debug_x3)

    );

    // Immediate
    wire [31:0] immD;

    sign_extend SE0 (
        .instruction(instrD),
        .imm_ext    (immD)
    );

    // =========================
    // ID/EX pipeline register
    // =========================
    wire        RegWriteE;
    wire        MemReadE;
    wire        MemWriteE;
    wire        MemToRegE;
    wire        ALUSrcE;
    wire        BranchE;
    wire [1:0]  ALUOpE;

    wire [31:0] pcE;
    wire [31:0] rs1_dataE;
    wire [31:0] rs2_dataE;
    wire [31:0] immE;
    wire [4:0]  rs1E;
    wire [4:0]  rs2E;
    wire [4:0]  rdE;
    wire [2:0]  funct3E;
    wire [6:0]  funct7E;
	 
	 
	  wire [31:0] alu_resultM;

    id_ex_reg IDEX0 (
        .clk         (clk),
        .reset       (reset),
        .flush       (flushE),

        .RegWrite_in (RegWriteD),
        .MemRead_in  (MemReadD),
        .MemWrite_in (MemWriteD),
        .MemToReg_in (MemToRegD),
        .ALUSrc_in   (ALUSrcD),
        .Branch_in   (BranchD),
        .ALUOp_in    (ALUOpD),

        .pc_in       (pcD),
        .rs1_data_in (rs1_dataD),
        .rs2_data_in (rs2_dataD),
        .imm_in      (immD),
        .rs1_in      (rs1D),
        .rs2_in      (rs2D),
        .rd_in       (rdD),
        .funct3_in   (funct3D),
        .funct7_in   (funct7D),

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
		  
		  
		  .pred_takenD (pred_takenD),
		  .pred_targetD(pred_targetD),
		   .pred_takenE (pred_takenE),
		  .pred_targetE(pred_targetE)
		  
		  
    );

    // =========================
    // EX stage
    // =========================
    wire [3:0]  alu_controlE;
    wire [31:0] rs1_fwdE;
    wire [31:0] rs2_fwdE;
    wire [31:0] alu_bE;
    wire [31:0] alu_resultE;
    wire        alu_zeroE;

    wire [1:0]  forwardAE;
    wire [1:0]  forwardBE;

    // Forwarded source A (rs1E)
    assign rs1_fwdE =
        (forwardAE == 2'b10) ? alu_resultM :
        (forwardAE == 2'b01) ? resultW     :
                               rs1_dataE;

    // Forwarded source B (rs2E)
    wire [31:0] rs2_fwd_base =
        (forwardBE == 2'b10) ? alu_resultM :
        (forwardBE == 2'b01) ? resultW     :
                               rs2_dataE;

    // After forwarding, still respect ALUSrc (immediate vs register)
    assign alu_bE = (ALUSrcE) ? immE : rs2_fwd_base;

    alu ALU0 (
        .a          (rs1_fwdE),
        .b          (alu_bE),
        .alu_control(alu_controlE),
        .result     (alu_resultE),
        .zero       (alu_zeroE)
    );

    alu_control ALUCTRL (
        .ALUOp      (ALUOpE),
        .funct3     (funct3E),
        .funct7     (funct7E),
        .alu_control(alu_controlE)
    );

    // Branch target in EX stage (Harris & Harris)
	 
    wire [31:0] branch_targetE = pcE + immE;

    // Branch decision in EX: BranchE && ZeroE
	 
	 
	     // Actual branch outcome in EX
    wire branch_taken_ex;
    assign branch_taken_ex = BranchE && alu_zeroE;  // for BEQ (and later BNE etc.)
	 
	 
	     // =========================
    // Branch Predictor (BHT + BTB)
    // =========================
    branch_predictor  BP0 (
        .clk            (clk),
        .reset          (reset),

        // IF stage query
        .pcF            (pcF),
        .next_pc_predF  (next_pc_predF),
        .pred_takenF    (pred_takenF),
        .pred_targetF   (pred_targetF),

        // EX stage update
        .BranchE        (BranchE),
        .pcE            (pcE),
        .branch_takenE  (branch_taken_ex),
        .branch_targetE (branch_targetE)
    );

	 
	 

    // --- MIS-PREDICTION DETECTION (EX stage) ---

    // pred_takenE / pred_targetE come from id_ex_reg (you added them in step 3)
    wire mispredictE;
    assign mispredictE =
        BranchE && (            // only care if this instruction is a branch
            (branch_taken_ex != pred_takenE) ||          // predicted taken vs actual
            (branch_taken_ex && (branch_targetE != pred_targetE))  // wrong target
        );

    // What PC should we REALLY go to, if prediction was wrong?
    wire [31:0] next_pc_correctE;
    assign next_pc_correctE =
        branch_taken_ex ? branch_targetE : (pcE + 32'd4);



    // Next PC mux: branch target or PC+4

	assign next_pcF = mispredictE ? next_pc_correctE : next_pc_predF;



  //========================================================================================
  
    // =========================
    // EX/MEM pipeline register
    // =========================
    wire        RegWriteM;
    wire        MemReadM;
    wire        MemWriteM;
    wire        MemToRegM;
    wire        BranchM;
  //  wire [31:0] alu_resultM;
    wire [31:0] rs2_dataM;
    wire        alu_zeroM;
    wire [31:0] branch_targetM;
    wire [4:0]  rdM;

    ex_mem_reg EXMEM0 (
    .clk              (clk),
    .reset            (reset),

    .RegWrite_in      (RegWriteE),
    .MemRead_in       (MemReadE),
    .MemWrite_in      (MemWriteE),
    .MemToReg_in      (MemToRegE),
    .Branch_in        (BranchE),

    .alu_result_in    (alu_resultE),
    .rs2_data_in      (rs2_dataE),
    .zero_in          (alu_zeroE),
    .branch_target_in (branch_targetE),
    .rd_in            (rdE),

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

    // =========================
    // Hazard & Forwarding
    // =========================
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

    hazard_unit HU (
        .MemReadE       (MemReadE),
        .rdE            (rdE),
        .rs1D           (rs1D),
        .rs2D           (rs2D),
        //.branch_taken_ex(branch_taken_ex),
		  .mispredictE (mispredictE),

        .stallF         (stallF),
        .stallD         (stallD),
        .flushE         (flushE),
        .if_id_flush    (if_id_flush)
    );
	 
	 
	 
	 
	 
	 
    // =========================
    // MEM stage
    // =========================

	 
	 
	 
	 
	 
	 
	 
	 
	 
    // IO detection: addresses 0x4xxxxxxx are IO (LEDs, switches, etc.)
    wire is_ioM = (alu_resultM[31:28] == 4'h4);

    // Separate read-data wires for RAM and MMIO
    wire [31:0] ram_read_dataM;
    wire [31:0] mmio_read_dataM;

    // ---- Data RAM (unchanged logic, just gated by ~is_ioM) ----
    dmem DMEM0 (
        .clk        (clk),
        .mem_read   (MemReadM  & ~is_ioM),   // only when NOT IO
        .mem_write  (MemWriteM & ~is_ioM),   // only when NOT IO
        .addr       (alu_resultM),
        .write_data (rs2_dataM),
        .read_data  (ram_read_dataM)
    );

    // ---- MMIO block (for LEDs / switches) ----
	 wire [9:0] leds_mmio;

	 
	 
    mmio MMIO0 (
        .clk      (clk),
        .reset    (reset),
        .addr     (alu_resultM),
        .wdata    (rs2_dataM),
        .we       (MemWriteM & is_ioM),      // only when IO address
        .rdata    (mmio_read_dataM),

        // will connect to FPGA pins later
        .leds     (leds_mmio),                        
        .switches (switches)                    // pretend all switches = 0
    );

    // Final data going back into the pipeline:
    // if IO address → mmio_read_dataM
    // else          → ram_read_dataM
	 
	 
    wire [31:0] dmem_read_dataM;
    assign dmem_read_dataM = is_ioM ? mmio_read_dataM : ram_read_dataM;

	 
	 
	 
	 
	 
	 
	 
	 
	 
	 
	 
	 

    // =========================
    // MEM/WB pipeline register
    // =========================
    wire [31:0] mem_dataW;
    wire [31:0] alu_resultW;
    wire        MemToRegW;

    mem_wb_reg MEMWB0 (
        .clk           (clk),
        .reset         (reset),

        .RegWrite_in   (RegWriteM),
        .MemToReg_in   (MemToRegM),
        .mem_data_in   (dmem_read_dataM),
        .alu_result_in (alu_resultM),
        .rd_in         (rdM),

        .RegWrite_out  (RegWriteW),
        .MemToReg_out  (MemToRegW),
        .mem_data_out  (mem_dataW),
        .alu_result_out(alu_resultW),
        .rd_out        (rdW)
    );

    // =========================
    // WB stage
    // =========================
    assign resultW = MemToRegW ? mem_dataW : alu_resultW;
	 

// === DEBUG/TEST OUTPUT FOR FPGA DEMO ===
// Show the x3 register on LEDs (lower 10 bits)
//assign leds = debug_x3[9:0];

assign leds = leds_mmio;


endmodule
