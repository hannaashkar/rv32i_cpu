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
RTL_DIRS  := rtl/core rtl/mem rtl/soc rtl/ooo rtl/npu
RTL_SRCS  := $(wildcard rtl/core/*.v) $(wildcard rtl/mem/*.v) \
             $(wildcard rtl/soc/*.v) $(wildcard rtl/npu/*.v)
OOO_SRCS  := $(wildcard rtl/ooo/*.v)
SIM_MAIN  := tb/verilator/sim_main.cpp
SIM_BIN   := obj_dir/V$(TOP)

# 2-wide OoO core (D013): same harness, second Verilator build
OOO_TOP     := ooo_cpu
SIM_BIN_OOO := obj_dir_ooo/V$(OOO_TOP)

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

# --- C programs (sw/ctests): crt0 + libmin, Harvard text/data images --------
# -lgcc supplies __mulsi3/__divsi3 etc. (rv32i has no hardware M extension)
CRT0     := sw/common/crt0.S
LIBMIN   := sw/common/libmin.c
SW_CDEPS := $(CRT0) $(LIBMIN) sw/common/rv32.h sw/common/npu.h \
            sw/common/link.ld
CFLAGS_C := $(SW_CFLAGS) -O2 -ffreestanding -Wall
CTESTS   := $(wildcard sw/ctests/*.c)
CTEST_HEX := $(patsubst %.c,%.text.hex,$(CTESTS)) \
             $(patsubst %.c,%.data.hex,$(CTESTS))

# Default regression program (+ optional DMEM=<data.hex> for C programs)
PROG ?= sw/tests/smoke_arith.hex
DMEM ?=
DMEM_ARG = $(if $(DMEM),+dmem=$(DMEM),)

# Which core the run/regress targets drive; the -ooo aliases override this
RUN_BIN ?= $(SIM_BIN)

.PHONY: all sim sw test run wave synth-check clean
all: test

# --- simulator build ----------------------------------------------------------
sim: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(SIM_MAIN) tb/verilator/iss.h
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(SIM_MAIN) -o V$(TOP)

sim-ooo: $(SIM_BIN_OOO)

$(SIM_BIN_OOO): $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) tb/verilator/iss.h
	$(VERILATOR) $(VFLAGS) --top-module $(OOO_TOP) --Mdir obj_dir_ooo \
	    -CFLAGS -DOOO_TOP \
	    $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) -o V$(OOO_TOP)

# --- NPU unit testbench (docs/NPU.md) -----------------------------------------
# Standalone Verilator build of npu_top vs a C++ golden tile model.
NPU_TB := obj_dir_npu/Vnpu_top
NPU_SRCS := rtl/npu/npu_pe.v rtl/npu/npu_array.v rtl/npu/npu_top.v

$(NPU_TB): $(NPU_SRCS) tb/verilator/npu_tb.cpp
	$(VERILATOR) --cc --exe --build -j 0 --top-module npu_top \
	    --Mdir obj_dir_npu -Wno-fatal \
	    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 \
	    -MAKEFLAGS OPT_GLOBAL=-O2 -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
	    $(NPU_SRCS) tb/verilator/npu_tb.cpp -o Vnpu_top

npu-tb: $(NPU_TB)
	./$(NPU_TB)
.PHONY: npu-tb

# --- software build ------------------------------------------------------------
sw: $(SW_TESTS)

sw/tests/%.elf: sw/tests/%.S sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -o $@ $<

# FPGA LED demo (imem synthesis default). Self-paced walker — see led_demo.S.
sw/demo/%.elf: sw/demo/%.S sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -o $@ $<

.PHONY: demo
demo: sw/demo/led_demo.hex
	@echo "demo built: sw/demo/led_demo.hex (imem synthesis default)"

%.bin: %.elf
	$(RISCV_OBJCOPY) -O binary $< $@

%.hex: %.bin scripts/bin2hex.py
	$(PYTHON) scripts/bin2hex.py $< $@

# Keep intermediate .elf/.bin around for objdump-based debugging
.PRECIOUS: sw/tests/%.elf %.bin

# --- C program build (Harvard split) -----------------------------------------
# One elf, two images: .text -> imem hex, initialized data -> dmem hex.
# The .dmem_origin sentinel (crt0.S) pins the data image to 0x10000000 —
# without it an empty .rodata would shift every address (see link.ld).
sw/ctests/%.elf: sw/ctests/%.c $(SW_CDEPS)
	$(RISCV_GCC) $(CFLAGS_C) -o $@ $(CRT0) $(LIBMIN) $< -lgcc

%.text.hex: %.elf scripts/bin2hex.py
	$(RISCV_OBJCOPY) -O binary --only-section=.text $< $*.text.bin
	$(PYTHON) scripts/bin2hex.py $*.text.bin $@

%.data.hex: %.elf scripts/bin2hex.py
	$(RISCV_OBJCOPY) -O binary --only-section=.dmem_origin \
	    --only-section=.rodata --only-section=.data --only-section=.sdata \
	    $< $*.data.bin
	$(PYTHON) scripts/bin2hex.py $*.data.bin $@

.PRECIOUS: sw/ctests/%.elf

# --- CoreMark (Task 1.6 baseline benchmark) ----------------------------------
# Upstream EEMBC sources vendored unmodified in sw/coremark/ (Apache-2.0);
# the port layer lives in sw/coremark/rv32/. Timing = rdcycle (D012),
# console = sim-console MMIO snoop. Validation is CoreMark's own CRC check,
# printed as "Correct operation validated" — grep enforces it below.
CM_DIR  := sw/coremark
CM_SRCS := $(CM_DIR)/core_list_join.c $(CM_DIR)/core_main.c \
           $(CM_DIR)/core_matrix.c $(CM_DIR)/core_state.c \
           $(CM_DIR)/core_util.c \
           $(CM_DIR)/rv32/core_portme.c $(CM_DIR)/rv32/ee_printf.c \
           $(CM_DIR)/rv32/cvt.c
# 600 iterations ≈ 510M cycles ≈ 10.2 simulated seconds at 50 MHz — the
# minimum CoreMark accepts as a reportable run (its 10-second rule counts
# into total_errors!). Use CM_ITER=10 for a quick correctness check; the
# CRC gate below is iteration-count independent.
CM_ITER ?= 600
CM_OPT  ?= -O2
CM_FLAGS = $(SW_CFLAGS) $(CM_OPT) -ffreestanding \
           -I$(CM_DIR) -I$(CM_DIR)/rv32 -Isw/common \
           -DITERATIONS=$(CM_ITER) \
           -DFLAGS_STR='"$(CM_OPT) -march=rv32i_zicsr"'

# ITERATIONS/opt level are baked in via -D, so the elf must rebuild when
# CM_ITER/CM_OPT change even though no source file did: the stamp file
# records the last-built flags and only changes when they do.
$(CM_DIR)/.cm_flags_stamp: FORCE
	@echo '$(CM_ITER) $(CM_OPT)' | cmp -s - $@ 2>/dev/null \
	    || echo '$(CM_ITER) $(CM_OPT)' > $@
FORCE:

$(CM_DIR)/coremark.elf: $(CM_SRCS) $(CM_DIR)/coremark.h \
                        $(CM_DIR)/rv32/core_portme.h $(SW_CDEPS) \
                        $(CM_DIR)/.cm_flags_stamp
	$(RISCV_GCC) $(CM_FLAGS) -o $@ $(CRT0) $(LIBMIN) $(CM_SRCS) -lm -lgcc

# Pass gate = the three benchmark CRCs against the official expected values
# for the 2K performance profile (seeds 0/0/0x66) — these are independent
# of iteration count, unlike "Correct operation validated" which also
# requires the >=10s rule to be satisfied (CM_ITER >= 600 here).
coremark: $(RUN_BIN) $(CM_DIR)/coremark.text.hex $(CM_DIR)/coremark.data.hex
	./$(RUN_BIN) +imem=$(CM_DIR)/coremark.text.hex \
	    +dmem=$(CM_DIR)/coremark.data.hex \
	    +max_cycles=900000000 | tee coremark.log
	@grep -Eq 'crclist.*0xe714'  coremark.log && \
	 grep -Eq 'crcmatrix.*0x1fd7' coremark.log && \
	 grep -Eq 'crcstate.*0x8e3a'  coremark.log \
	    && echo "coremark: CRCs match official 2K performance-run values" \
	    || { echo "coremark: CRC MISMATCH — computation is wrong"; exit 1; }

# --- quantized MNIST MLP on the NPU (docs/NPU.md, D014/D015) ------------------
# weights.h is generated offline by scripts/train_mlp.py (numpy, seeded).
# PASS = soft/NPU logits bit-exact + predictions match the offline integer
# reference; the printed cycle counts are the measured speedup.
MLP_DIR := sw/npu_mlp

$(MLP_DIR)/mlp.elf: $(MLP_DIR)/mlp.c $(MLP_DIR)/weights.h sw/common/npu.h \
                    $(SW_CDEPS)
	$(RISCV_GCC) $(CFLAGS_C) -o $@ $(CRT0) $(LIBMIN) $< -lgcc
.PRECIOUS: $(MLP_DIR)/mlp.elf

npu-mlp: $(RUN_BIN) $(MLP_DIR)/mlp.text.hex $(MLP_DIR)/mlp.data.hex
	./$(RUN_BIN) +imem=$(MLP_DIR)/mlp.text.hex \
	    +dmem=$(MLP_DIR)/mlp.data.hex +max_cycles=900000000
npu-mlp-ooo:
	$(MAKE) npu-mlp RUN_BIN=$(SIM_BIN_OOO)
.PHONY: npu-mlp npu-mlp-ooo

# --- run ------------------------------------------------------------------------
test: $(RUN_BIN) $(SW_TESTS)
	./$(RUN_BIN) +imem=$(PROG)

# Run every assembly test in sw/tests and every C test in sw/ctests
regress: $(RUN_BIN) $(SW_TESTS) $(CTEST_HEX)
	@pass=0; fail=0; \
	for h in sw/tests/*.hex; do \
	  if out=$$(./$(RUN_BIN) +imem=$$h); then \
	    pass=$$((pass+1)); printf 'PASS  %s\n' "$$h"; \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  %s : %s\n' "$$h" "$$out"; \
	  fi; \
	done; \
	for c in sw/ctests/*.c; do \
	  b=$${c%.c}; \
	  if out=$$(./$(RUN_BIN) +imem=$$b.text.hex +dmem=$$b.data.hex \
	            +max_cycles=2000000); then \
	    pass=$$((pass+1)); printf 'PASS  %s\n' "$$c"; \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  %s : %s\n' "$$c" "$$out"; \
	  fi; \
	done; \
	printf 'regress: %d passed, %d failed\n' $$pass $$fail; \
	[ $$fail -eq 0 ]

# --- constrained-random regression (every instruction lockstep-checked) ------
# Programs are generated fresh each run (seeded, reproducible) and checked
# instruction-by-instruction against the golden model — no self-checking
# needed in the programs themselves. Reproduce one failure with:
#   python scripts/gen_random_test.py <seed> r.hex && obj_dir/Vcpu_pipeline +imem=r.hex
RAND_SEEDS ?= 25
RAND_LEN   ?= 3000
regress-rand: $(RUN_BIN)
	@mkdir -p build/rand; pass=0; fail=0; \
	for s in $$(seq 1 $(RAND_SEEDS)); do \
	  $(PYTHON) scripts/gen_random_test.py $$s build/rand/rand_$$s.hex $(RAND_LEN); \
	  if out=$$(./$(RUN_BIN) +imem=build/rand/rand_$$s.hex); then \
	    pass=$$((pass+1)); \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  seed %s\n%s\n' "$$s" "$$out"; \
	  fi; \
	done; \
	printf 'regress-rand: %d/%d seeds passed (%s instrs each, lockstep-checked)\n' \
	    $$pass $(RAND_SEEDS) $(RAND_LEN); \
	[ $$fail -eq 0 ]

# --- official riscv-tests rv32ui ISA suite (lockstep-checked too) -------------
# Vendored unmodified from riscv-software-src/riscv-tests; our environment
# header lives in sw/riscv-tests/env. Excluded: fence_i (Harvard imem has
# no store path to instruction memory), ma_data (no traps; misaligned lane
# behavior is documented SoC-specific).
RVT_DIR  := sw/riscv-tests
RVT_SRCS := $(wildcard $(RVT_DIR)/rv32ui/*.S)
RVT_HEX  := $(patsubst %.S,%.text.hex,$(RVT_SRCS)) \
            $(patsubst %.S,%.data.hex,$(RVT_SRCS))

$(RVT_DIR)/rv32ui/%.elf: $(RVT_DIR)/rv32ui/%.S $(RVT_DIR)/rv64ui/%.S \
                         $(RVT_DIR)/env/riscv_test.h \
                         $(RVT_DIR)/macros/test_macros.h sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -I$(RVT_DIR)/env -I$(RVT_DIR)/macros -o $@ $<

.PRECIOUS: $(RVT_DIR)/rv32ui/%.elf

regress-isa: $(RUN_BIN) $(RVT_HEX)
	@pass=0; fail=0; \
	for s in $(RVT_DIR)/rv32ui/*.S; do \
	  b=$${s%.S}; \
	  if out=$$(./$(RUN_BIN) +imem=$$b.text.hex +dmem=$$b.data.hex); then \
	    pass=$$((pass+1)); \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  %s : %s\n' "$$b" "$$out"; \
	  fi; \
	done; \
	printf 'regress-isa: %d/%d riscv-tests rv32ui passed\n' \
	    $$pass $$((pass+fail)); \
	[ $$fail -eq 0 ]

# Umbrella: everything that must be green before merging to main
verify: regress regress-isa regress-rand

# --- OoO core aliases: identical suites, second binary ------------------------
regress-ooo:
	$(MAKE) regress RUN_BIN=$(SIM_BIN_OOO)
regress-isa-ooo:
	$(MAKE) regress-isa RUN_BIN=$(SIM_BIN_OOO)
regress-rand-ooo:
	$(MAKE) regress-rand RUN_BIN=$(SIM_BIN_OOO)
coremark-ooo:
	$(MAKE) coremark RUN_BIN=$(SIM_BIN_OOO)
verify-ooo: regress-ooo regress-isa-ooo regress-rand-ooo
.PHONY: sim-ooo regress-ooo regress-isa-ooo regress-rand-ooo coremark-ooo verify-ooo

run: $(RUN_BIN)
	./$(RUN_BIN) +imem=$(PROG) $(DMEM_ARG)

wave: $(RUN_BIN)
	./$(RUN_BIN) +imem=$(PROG) $(DMEM_ARG) +trace
	@echo "waveform written to sim.fst"

# --- synthesis sanity check -------------------------------------------------------
synth-check:
	cd synth && $(QUARTUS_MAP) rv32i_cpu

clean:
	rm -rf obj_dir obj_dir_ooo obj_dir_npu sim.fst
	rm -f sw/tests/*.elf sw/tests/*.bin sw/tests/*.hex
	rm -f sw/ctests/*.elf sw/ctests/*.bin sw/ctests/*.hex
	rm -f sw/coremark/coremark.elf sw/coremark/*.bin sw/coremark/*.hex
	rm -f sw/coremark/.cm_flags_stamp coremark.log
	rm -f sw/npu_mlp/mlp.elf sw/npu_mlp/*.bin sw/npu_mlp/*.hex
