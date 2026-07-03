module pc (
    input  wire        clk,
    input  wire        reset,
    input  wire        stall,      // freeze PC update during hazards
    input  wire [31:0] next_pc,    // next PC value from fetch/branch logic
    output reg  [31:0] pc          // current program counter
);

    // ---------------------------------------------------------
    // Program Counter
    // ---------------------------------------------------------
    // Reset sets PC to 0.
    // On each cycle, PC updates to next_pc unless a stall is active.
    // Stalling is used for load-use hazards to prevent the pipeline
    // from fetching the wrong instruction.
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= 32'b0;          // start execution at address 0
        end 
        else if (!stall) begin
            pc <= next_pc;        // normal sequential or branch update
        end
        // If stall == 1, PC holds its value (no assignment)
    end

endmodule
