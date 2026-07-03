# ============================================================================
# rv32i_cpu — top-level Makefile
#
# Runs under MSYS2 bash (UCRT64). From PowerShell/cmd use scripts\make.cmd,
# which sets up the MSYS2 environment and forwards all arguments:
#     scripts\make.cmd test
#     scripts\make.cmd wave PROG=sw/tests/smoke_arith.hex
#
# Main targets:
#   make sim          build the Verilator model (obj_dir/Vcpu_pipeline)
#   make sw           assemble all test programs in sw/tests -> .hex
#   make test         run the smoke test (build everything as needed)
#   make run PROG=x   run an arbitrary .hex program
#   make wave PROG=x  same, but dump sim.fst waveform
#   make synth-check  Quartus Analysis & Synthesis sanity check
#   make clean
# ============================================================================

# --- toolchain (see CLAUDE.md "Environment") --------------------------------
VERILATOR     ?= verilator
XPACK_BIN     ?= /c/Users/ASUS/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
RISCV_GCC     ?= $(XPACK_BIN)/riscv-none-elf-gcc
RISCV_OBJCOPY ?= $(XPACK_BIN)/riscv-none-elf-objcopy
PYTHON        ?= /c/Users/ASUS/AppData/Local/Programs/Python/Python312/python.exe
QUARTUS_MAP   ?= /c/intelfpga_lite/20.1/quartus/bin64/quartus_map.exe

# --- design ------------------------------------------------------------------
TOP       := cpu_pipeline
RTL_DIRS  := rtl/core rtl/mem rtl/soc
RTL_SRCS  := $(wildcard rtl/core/*.v) $(wildcard rtl/mem/*.v) $(wildcard rtl/soc/*.v)
SIM_MAIN  := tb/verilator/sim_main.cpp
SIM_BIN   := obj_dir/V$(TOP)

# Verilator flags:
#   --trace-fst   compile-in FST tracing (enabled at runtime with +trace)
#   -Wno-fatal    legacy code trips WIDTH/style warnings; keep them visible
#                 but non-fatal until the cleanup pass
#   OPT_*=-O2     MSYS2 gcc 16.1.0-5 fails to link C++ compiled with -Os
#                 (missing out-of-line std::string move ctor in libstdc++);
#                 Verilator defaults to -Os, so force -O2 everywhere
#   VM_PARALLEL_BUILDS=1  the __ALL.cpp concatenation rule generates an
#                 empty file under MSYS2 make (verilator 5.048); parallel
#                 mode compiles each generated source directly instead
VFLAGS := --cc --exe --build -j 0 --top-module $(TOP) --trace-fst -Wno-fatal \
          -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 -MAKEFLAGS OPT_GLOBAL=-O2 \
          -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
          +define+SIM_BIG_MEM \
          $(addprefix -I,$(RTL_DIRS))

# --- software ----------------------------------------------------------------
# rv32i_zicsr: modern binutils gates CSR instructions (rdcycle, csrrw, ...)
# behind the Zicsr extension in -march; the core implements it (D012)
SW_CFLAGS := -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
             -T sw/common/link.ld
SW_TESTS  := $(patsubst %.S,%.hex,$(wildcard sw/tests/*.S))

# Default regression program
PROG ?= sw/tests/smoke_arith.hex

.PHONY: all sim sw test run wave synth-check clean
all: test

# --- simulator build ----------------------------------------------------------
sim: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(SIM_MAIN)
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(SIM_MAIN) -o V$(TOP)

# --- software build ------------------------------------------------------------
sw: $(SW_TESTS)

sw/tests/%.elf: sw/tests/%.S sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -o $@ $<

%.bin: %.elf
	$(RISCV_OBJCOPY) -O binary $< $@

%.hex: %.bin scripts/bin2hex.py
	$(PYTHON) scripts/bin2hex.py $< $@

# Keep intermediate .elf/.bin around for objdump-based debugging
.PRECIOUS: sw/tests/%.elf %.bin

# --- run ------------------------------------------------------------------------
test: $(SIM_BIN) $(SW_TESTS)
	./$(SIM_BIN) +imem=$(PROG)

# Run every test program in sw/tests; fail if any fails
regress: $(SIM_BIN) $(SW_TESTS)
	@pass=0; fail=0; \
	for h in sw/tests/*.hex; do \
	  if out=$$(./$(SIM_BIN) +imem=$$h); then \
	    pass=$$((pass+1)); printf 'PASS  %s\n' "$$h"; \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  %s : %s\n' "$$h" "$$out"; \
	  fi; \
	done; \
	printf 'regress: %d passed, %d failed\n' $$pass $$fail; \
	[ $$fail -eq 0 ]

run: $(SIM_BIN)
	./$(SIM_BIN) +imem=$(PROG)

wave: $(SIM_BIN)
	./$(SIM_BIN) +imem=$(PROG) +trace
	@echo "waveform written to sim.fst"

# --- synthesis sanity check -------------------------------------------------------
synth-check:
	cd synth && $(QUARTUS_MAP) rv32i_cpu

clean:
	rm -rf obj_dir sim.fst
	rm -f sw/tests/*.elf sw/tests/*.bin sw/tests/*.hex
