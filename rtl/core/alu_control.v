module alu_control (
    input  wire [1:0] ALUOp,      // High-level ALU control coming from the main control unit
    input  wire [2:0] funct3,     // funct3 field extracted from the instruction
    input  wire [6:0] funct7,     // funct7 field (mainly used for ADD/SUB)
    output reg  [3:0] alu_control // Operation code sent to the ALU
);

    always @(*) begin
        case (ALUOp)

            2'b00: begin
                // Load/store instructions always use ADD for address calculation
                alu_control = 4'b0010;   // ADD
            end

            2'b01: begin
                // Branch-equal uses subtraction to compare rs1 and rs2
                alu_control = 4'b0110;   // SUB
            end

            2'b10: begin
                // R-type and I-type ALU instructions → decode based on funct3/funct7
                case (funct3)

                    3'b000: begin
                        // ADD / ADDI share funct3=000, SUB has same funct3 but funct7 is different
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
                        // SLT and SLTI
                        alu_control = 4'b0111;
                    end

                    default: begin
                        // Fall back to ADD if we don't recognize the funct3
                        alu_control = 4'b0010;
                    end

                endcase
            end

            default: begin
                // Safety fallback → treat unknown ALUOp as ADD
                alu_control = 4'b0010;
            end

        endcase
    end

endmodule
