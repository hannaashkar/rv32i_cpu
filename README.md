<p align="center">
  <img src="https://img.shields.io/badge/Verilog-RISC--V_CPU-brightgreen?style=for-the-badge&logo=verilog" />
  <img src="https://img.shields.io/badge/FPGA-DE10--Lite-blue?style=for-the-badge&logo=intel" />
  <img src="https://img.shields.io/badge/Project-Pipelined_CPU-red?style=for-the-badge&logo=riscv" />
</p>

🧠 RISC-V 5-Stage Pipelined CPU (with Branch Prediction & Hazard Handling)
Designed and implemented by: Hanna Ashkar

A full hardware implementation of a pipelined RISC-V CPU in Verilog, including forwarding, stalling, branch prediction, and MMIO.

🚀 Overview

This project implements a RISC-V RV32I compatible CPU from scratch using:

✔️ 5 pipeline stages (IF → ID → EX → MEM → WB)

✔️ Hazard detection unit (load-use stalls)

✔️ Forwarding unit (EX → EX, MEM → EX bypass paths)

✔️ Branch predictor (2-bit BHT + BTB)

✔️ Branch misprediction flush logic

✔️ Full ALU with 32-bit operations

✔️ Register file with 2 read ports + 1 write port

✔️ Instruction & data memory

✔️ MMIO for LEDs & switches (for FPGA demo )

The CPU can run on simulation or on a Terasic DE10-Lite FPGA.

📂 Project Structure
src/
   cpu_pipeline.v
   pc.v
   imem.v
   dmem.v
   register_file.v
   alu.v
   alu_control.v
   control.v
   sign_extend.v
   hazard_unit.v
   forwarding_unit.v
   branch_predictor.v
   if_id_reg.v
   id_ex_reg.v
   ex_mem_reg.v
   mem_wb_reg.v

sim/
   cpu_pipeline_tb.v
   run.do

docs/
   pipeline-diagram.png
   block-diagram.png

README.md


---

## 🧰 CPU Pipeline Summary

### **IF – Instruction Fetch**
- PC logic
- Branch predictor  
- Fetch instruction from `imem`

### **ID – Decode**
- Instruction decoding  
- Register file read  
- Immediate generation  
- Hazard detection (load-use)

### **EX – Execute**
- ALU operations  
- Forwarding paths  
- Branch target calculation  
- Branch resolution

### **MEM – Memory**
- Data memory read/write  
- MMIO (LEDs/switches)  
- Select RAM/MMIO based on address

### **WB – Write Back**
- Writes ALU result or load value back to register file

---

## 🔧 Hazard Handling

### ✔️ Forwarding (Bypassing)
- EX/MEM → EX
- MEM/WB → EX  
Prevents unnecessary stalls.

### ✔️ Load-Use Stall
If EX is doing a load and ID needs its result → pipeline stalls 1 cycle.

---

## 🧠 Branch Prediction

Implemented using:

- **BHT** (2-bit saturating counters)
- **BTB** (direct mapped target buffer)
- **Prediction update** in EX stage
- **Flushes IF/ID + ID/EX on mispredict**

This improves performance by reducing stalls on branches.

---

## 🧪 Simulation (Modelsim)

Run:
cd sim
vsim -do run.do


The testbench shows:

- PC changes  
- Pipeline signals  
- Register values  
- LED MMIO output  

---

## 🔥 FPGA Demo (Terasic DE10-Lite)

The CPU exposes MMIO signals:



0x40000000 → LED output
0x40000004 → Switch input


Example loop program increments register x3 and writes to LEDs.

### Minimal FPGA wrapper:

```verilog
module de10_top(
    input  wire CLOCK_50,
    output wire [9:0] LEDR
);

    wire clk = CLOCK_50;
    wire reset = 1'b0;

    cpu_pipeline CPU0 (
        .clk(clk),
        .reset(reset),
        .leds_mmio(LEDR),
        .switches(10'b0)
    );

endmodule

📸 Screenshots / Videos


💡 Future Work
Add RV32IM (mul/div)

Add instruction/data caches

Add UART MMIO

Add exception/interrupt logic

Support full RV32I assembler loading

👨‍💻 Author

Hanna Ashkar
Electrical Engineering — Technion
FPGA / Digital Design / RISC-V
