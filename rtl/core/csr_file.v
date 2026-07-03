// ============================================================================
// csr_file — control and status registers (Zicsr scaffold, decision D012)
//
// Purpose:    Holds the CSRs and executes CSR instructions. Today that is
//             the read-only user counters cycle/instret (RISC-V Zicntr) for
//             IPC measurement, plus mscratch as the first writable CSR so
//             the full write path (RW/RS/RC, register and immediate forms)
//             is exercised logic, not dead scaffolding.
// Interfaces: EX-stage access port (combinational read, synchronous write)
//             and a retire strobe from WB that advances instret.
// Placement:  CSR instructions execute in EX. Nothing can kill an
//             instruction that has reached EX in this pipeline (mispredicts
//             only flush IF/ID and ID/EX, and there are no traps yet), so
//             committing the CSR write in EX is not speculative. The read
//             value returns through the EX result mux and forwards to
//             younger instructions like any ALU result.
// Semantics implemented (RV32 Zicsr):
//   * CSRRW/CSRRWI  csr := operand,        rd = old value
//   * CSRRS/CSRRSI  csr := csr | operand,  rd = old value
//   * CSRRC/CSRRCI  csr := csr & ~operand, rd = old value
//   * CSRRS/CSRRC with rs1=x0 (zimm=0) perform NO write, per the ISA.
//   * Unimplemented CSRs read as 0; writes to unimplemented or read-only
//     CSRs are dropped. Real behavior is an illegal-instruction trap —
//     deferred to the trap/exception stage together with mstatus/mtvec,
//     which slot into the address decode below.
// ============================================================================
module csr_file (
    input  wire        clk,
    input  wire        reset,

    // EX-stage access port
    input  wire        csr_en,     // CSR instruction currently in EX
    input  wire [11:0] csr_addr,   // instr[31:20] (rides the I-type immediate)
    input  wire [2:0]  funct3,     // operation + register/immediate form
    input  wire [4:0]  rs1_addr,   // rs1 field: zimm value / write-suppress
    input  wire [31:0] rs1_data,   // forwarded rs1 (register forms)
    output reg  [31:0] csr_rdata,  // old CSR value -> rd via EX result mux

    // Retired-instruction count this cycle (0..2 — the OoO core retires
    // up to 2/cycle; the in-order core passes {1'b0, validW})
    input  wire [1:0]  retire_n
);

    // CSR addresses (RISC-V privileged spec)
    localparam CSR_CYCLE    = 12'hC00;
    localparam CSR_INSTRET  = 12'hC02;
    localparam CSR_CYCLEH   = 12'hC80;
    localparam CSR_INSTRETH = 12'hC82;
    localparam CSR_MSCRATCH = 12'h340;

    // ------------------------------------------------------------------
    // Architectural state. Counters are 64-bit so they never wrap in
    // practice (2^64 cycles at 50 MHz is ~11,700 years); software reads
    // them as two 32-bit halves (rdcycle/rdcycleh).
    // ------------------------------------------------------------------
    reg [63:0] cycle_cnt   /*verilator public_flat_rd*/;
    reg [63:0] instret_cnt /*verilator public_flat_rd*/;
    reg [31:0] mscratch;

    // ------------------------------------------------------------------
    // Read port (combinational): the OLD value of the addressed CSR.
    // ------------------------------------------------------------------
    always @(*) begin
        case (csr_addr)
            CSR_CYCLE:    csr_rdata = cycle_cnt[31:0];
            CSR_CYCLEH:   csr_rdata = cycle_cnt[63:32];
            CSR_INSTRET:  csr_rdata = instret_cnt[31:0];
            CSR_INSTRETH: csr_rdata = instret_cnt[63:32];
            CSR_MSCRATCH: csr_rdata = mscratch;
            default:      csr_rdata = 32'b0;    // unimplemented CSRs read 0
        endcase
    end

    // ------------------------------------------------------------------
    // Write path. funct3[1:0] selects the operation, funct3[2] selects
    // the register vs the zero-extended 5-bit immediate operand (the rs1
    // FIELD reused as a constant). Per the ISA, CSRRS/CSRRC with rs1=x0
    // must not write at all (so reading via csrr never has side effects).
    // ------------------------------------------------------------------
    wire [31:0] operand   = funct3[2] ? {27'b0, rs1_addr} : rs1_data;
    wire        is_rw     = (funct3[1:0] == 2'b01);
    wire        write_req = csr_en && (is_rw || (rs1_addr != 5'b0));

    reg [31:0] wdata;
    always @(*) begin
        case (funct3[1:0])
            2'b01:   wdata = operand;                // CSRRW / CSRRWI
            2'b10:   wdata = csr_rdata |  operand;   // CSRRS / CSRRSI
            default: wdata = csr_rdata & ~operand;   // CSRRC / CSRRCI
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cycle_cnt   <= 64'b0;
            instret_cnt <= 64'b0;
            mscratch    <= 32'b0;
        end else begin
            cycle_cnt <= cycle_cnt + 64'd1;
            instret_cnt <= instret_cnt + {62'b0, retire_n};

            // Architectural writes. The counter CSRs (0xCxx) are read-only
            // by spec — a write there is dropped today and will trap once
            // the exception stage exists. New writable CSRs (mstatus,
            // mtvec, mepc, ...) each get a case entry here.
            if (write_req) begin
                case (csr_addr)
                    CSR_MSCRATCH: mscratch <= wdata;
                    default: ;                       // dropped
                endcase
            end
        end
    end

endmodule
