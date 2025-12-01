

module alu_control (

    input  wire [1:0] ALUOp,      // from main control
    input  wire [2:0] funct3,     // from instruction
    input  wire [6:0] funct7,     // from instruction
    output reg  [3:0] alu_control // to ALU
);
    always @(*) begin
        case (ALUOp)
            2'b00: begin
                // For LW/SW → always ADD
                alu_control = 4'b0010;  // ADD
            end

            2'b01: begin
                // For BEQ → SUB (a - b)
                alu_control = 4'b0110;  // SUB
            end

            2'b10: begin
                // R-type or I-type → use funct3 (and sometimes funct7)
                case (funct3)
                    3'b000: begin
                        // ADD / SUB / ADDI
                        if (funct7 == 7'b0100000) begin
                            alu_control = 4'b0110; // SUB
                        end else begin
                            alu_control = 4'b0010; // ADD or ADDI
                        end
                    end

                    3'b111: begin
                        // AND / ANDI
                        alu_control = 4'b0000;
                    end

                    3'b110: begin
                        // OR / ORI
                        alu_control = 4'b0001;
                    end

                    3'b100: begin
                        // XOR / XORI
                        alu_control = 4'b1100;
                    end

                    3'b010: begin
                        // SLT / SLTI
                        alu_control = 4'b0111;
                    end

                    default: begin
                        // default to ADD to be safe
                        alu_control = 4'b0010;
                    end
                endcase
            end

            default: begin
                alu_control = 4'b0010;   // ADD as safe default
            end
        endcase
    end

endmodule
