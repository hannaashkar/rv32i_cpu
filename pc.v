

module pc (
    input  wire        clk,
    input  wire        reset,
    input  wire        stall,      // NEW: from hazard unit (stallF)
    input  wire [31:0] next_pc,
    output reg  [31:0] pc
);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        pc <= 32'b0;              // on reset, PC = 0
    end else if (!stall) begin
        pc <= next_pc;            // normal advance
    end
    // else: stall == 1 → keep old pc (no assignment)
end

endmodule
