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
RISCV_OBJCOPY ?= $(XPACK_BIN)/riscv-none-elf-objcopy
PYTHON        ?= /c/Users/ASUS/AppData/Local/Programs/Python/Python312/python.exe
QUARTUS_MAP   ?= /c/intelfpga_lite/20.1/quartus/bin64/quartus_map.exe
QUARTUS_FIT   ?= /c/intelfpga_lite/20.1/quartus/bin64/quartus_fit.exe
QUARTUS_STA   ?= /c/intelfpga_lite/20.1/quartus/bin64/quartus_sta.exe

# --- environment landmine guards (audit 2026-07-11) ---------------------------
# Landmine 1: xpack riscv-gcc invoked from MSYS make tries to create its
# temp files in C:\WINDOWS\ unless TMP/TEMP reach it in Windows backslash
# form AT THE RECIPE LEVEL (exported shell variables do not survive into
# the native tool). Bake the fix into the gcc invocation itself.
WINTMP    ?= C:\Users\ASUS\AppData\Local\Temp
RISCV_GCC ?= TMP='$(WINTMP)' TEMP='$(WINTMP)' $(XPACK_BIN)/riscv-none-elf-gcc

# Landmine 2: under MSYS2 a Verilator build with VERILATOR_ROOT unset
# SILENTLY produces a broken model (wrong include root). Default to the
# known install when it exists. The value MUST be the MSYS mount form
# (/ucrt64/...): the /c/Users/... spelling of the same directory is
# rejected by verilator as "set to inconsistent path".
MSYS_VROOT := /ucrt64/share/verilator
ifeq ($(origin VERILATOR_ROOT),undefined)
  ifneq ($(wildcard $(MSYS_VROOT)),)
    export VERILATOR_ROOT := $(MSYS_VROOT)
  endif
endif
define CHECK_VROOT
if [ -z "$$VERILATOR_ROOT" ]; then case "$$(uname -s)" in MSYS*|MINGW*) \
  echo 'ERROR: VERILATOR_ROOT is unset - Verilator silently mis-builds under MSYS2.'; \
  echo '  fix: export VERILATOR_ROOT=/ucrt64/share/verilator'; \
  exit 1;; esac; fi
endef

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

# Audit X/reset-randomization models. These live in separate build trees so
# the normal deterministic models and benchmark cycle counts remain untouched.
X_BIN       := obj_dir_x/V$(TOP)
X_BIN_OOO   := obj_dir_x_ooo/V$(OOO_TOP)
XFLAGS      := --x-assign unique --x-initial unique

# D021: OoO A/B knobs. LOAD_POLICY overrides the ooo_cpu top parameter
# (0=conservative, 1=always-speculate/D020, 2=store-set predicted,
# 3=21264-style 1-bit load-wait table); empty = the RTL default. VDEFS adds
# Verilog defines to the OoO build, e.g. VDEFS=+define+LQ_PROBE. Both are
# baked into the Verilated model, so the .ooo_flags_stamp below forces a
# rebuild when they change (mtimes don't).
LOAD_POLICY ?=
OOO_GFLAGS  := $(if $(LOAD_POLICY),-GLOAD_POLICY=$(LOAD_POLICY))
VDEFS       ?=

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
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(SIM_MAIN) -o V$(TOP)

sim-ooo: $(SIM_BIN_OOO)

# NOTE: string-compare via cat, NOT cmp — diffutils is not installed in
# the MSYS2 environment, so `... | cmp -s -` exited 127 and REWROTE the
# stamp every run, silently re-verilating the OoO model on every build
# invocation (found by the 2026-07-11 audit follow-up).
obj_dir_ooo/.ooo_flags_stamp: FORCE
	@mkdir -p obj_dir_ooo
	@[ "$$(cat $@ 2>/dev/null)" = '$(LOAD_POLICY) $(VDEFS)' ] \
	    || echo '$(LOAD_POLICY) $(VDEFS)' > $@

$(SIM_BIN_OOO): $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) tb/verilator/iss.h \
                obj_dir_ooo/.ooo_flags_stamp
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) $(VDEFS) --top-module $(OOO_TOP) --Mdir obj_dir_ooo \
	    $(OOO_GFLAGS) -CFLAGS -DOOO_TOP \
	    $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) -o V$(OOO_TOP)

# Separate X-initialized builds catch state that accidentally depends on
# Verilator's ordinary all-zero startup. At runtime regress-x also selects
# rand-reset mode 2 with explicit seeds; the testbench's four reset cycles must
# bring every architecturally relevant valid/control bit to a legal state.
$(X_BIN): $(RTL_SRCS) $(SIM_MAIN) tb/verilator/iss.h
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) $(XFLAGS) --Mdir obj_dir_x \
	    $(RTL_SRCS) $(SIM_MAIN) -o V$(TOP)

obj_dir_x_ooo/.ooo_flags_stamp: FORCE
	@mkdir -p obj_dir_x_ooo
	@[ "$$(cat $@ 2>/dev/null)" = '$(LOAD_POLICY) $(VDEFS) $(XFLAGS)' ] \
	    || echo '$(LOAD_POLICY) $(VDEFS) $(XFLAGS)' > $@

$(X_BIN_OOO): $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) tb/verilator/iss.h \
              obj_dir_x_ooo/.ooo_flags_stamp
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) $(XFLAGS) $(VDEFS) --top-module $(OOO_TOP) \
	    --Mdir obj_dir_x_ooo $(OOO_GFLAGS) -CFLAGS -DOOO_TOP \
	    $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) -o V$(OOO_TOP)

# --- NPU unit testbench (docs/NPU.md) -----------------------------------------
# Standalone Verilator build of npu_top vs a C++ golden tile model.
NPU_TB := obj_dir_npu/Vnpu_top
NPU_SRCS := rtl/npu/npu_pe.v rtl/npu/npu_array.v rtl/npu/npu_top.v

$(NPU_TB): $(NPU_SRCS) tb/verilator/npu_tb.cpp
	@$(CHECK_VROOT)
	$(VERILATOR) --cc --exe --build -j 0 --top-module npu_top \
	    --Mdir obj_dir_npu -Wno-fatal \
	    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 \
	    -MAKEFLAGS OPT_GLOBAL=-O2 -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
	    $(NPU_SRCS) tb/verilator/npu_tb.cpp -o Vnpu_top

npu-tb: $(NPU_TB)
	./$(NPU_TB)
.PHONY: npu-tb

# --- store-set predictor unit testbench (docs/STORESET.md, D021) --------------
# Standalone build of ooo_stset vs a C++ golden model. -GDECAY_W=8 shrinks
# the decay epoch to 256 cycles so cyclic clearing is covered. STSET_AW=5
# exercises the SSIT=32 LE-escape configuration (rm -rf obj_dir_stset when
# switching — the flag is baked into the build).
STSET_AW ?= 6
STSET_TB := obj_dir_stset/Vooo_stset

$(STSET_TB): rtl/ooo/ooo_stset.v tb/verilator/stset_tb.cpp
	@$(CHECK_VROOT)
	$(VERILATOR) --cc --exe --build -j 0 --top-module ooo_stset \
	    --Mdir obj_dir_stset -Wno-fatal -GDECAY_W=8 -GSSIT_AW=$(STSET_AW) \
	    -CFLAGS -DTB_SSIT_AW=$(STSET_AW) \
	    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 \
	    -MAKEFLAGS OPT_GLOBAL=-O2 -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
	    rtl/ooo/ooo_stset.v tb/verilator/stset_tb.cpp -o Vooo_stset

stset-tb: $(STSET_TB)
	./$(STSET_TB)
.PHONY: stset-tb

# --- physical register file unit testbench (docs/PRF_SHRINK.md, D025) ---------
# Standalone build of ooo_prf (M9K/LVT banked, folded read) vs a C++ golden
# model = the old async register file + one-cycle read latency. ~300k random
# read/write interleavings, every output checked every cycle.
PRF_TB := obj_dir_prf/Vooo_prf

$(PRF_TB): rtl/ooo/ooo_prf.v tb/verilator/prf_tb.cpp
	@$(CHECK_VROOT)
	$(VERILATOR) --cc --exe --build -j 0 --top-module ooo_prf \
	    --Mdir obj_dir_prf -Wno-fatal \
	    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 \
	    -MAKEFLAGS OPT_GLOBAL=-O2 -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
	    rtl/ooo/ooo_prf.v tb/verilator/prf_tb.cpp -o Vooo_prf

prf-tb: $(PRF_TB)
	./$(PRF_TB)
.PHONY: prf-tb

# --- load-queue unit testbench (balanced violation selector, D026) ------------
# Standalone public-interface lifecycle model plus exact modular-age CAM oracle.
# The DUT also carries an independent Verilator-only old-scan equivalence check.
LQ_TB := obj_dir_lq/Vooo_lq

$(LQ_TB): Makefile rtl/ooo/ooo_lq.v rtl/ooo/ooo_pkg.vh rtl/ooo/ooo_uop.vh \
          tb/verilator/lq_tb.cpp
	@$(CHECK_VROOT)
	$(VERILATOR) --cc --exe --build -j 0 --top-module ooo_lq \
	    --Mdir obj_dir_lq -Wno-fatal -Irtl/ooo \
	    -MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_SLOW=-O2 \
	    -MAKEFLAGS OPT_GLOBAL=-O2 -MAKEFLAGS VM_PARALLEL_BUILDS=1 \
	    rtl/ooo/ooo_lq.v tb/verilator/lq_tb.cpp -o Vooo_lq

lq-tb: $(LQ_TB)
	./$(LQ_TB)
.PHONY: lq-tb

# --- software build ------------------------------------------------------------
sw: $(SW_TESTS)

sw/tests/%.elf: sw/tests/%.S sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -o $@ $<

# FPGA LED demo (imem synthesis default). Self-paced walker — see led_demo.S.
sw/demo/%.elf: sw/demo/%.S sw/common/link.ld
	$(RISCV_GCC) $(SW_CFLAGS) -o $@ $<

.PHONY: demo
demo: sw/demo/led_demo.hex
	$(MAKE) mif MIF_PROG=demo
	@echo "demo built: LED walker MIFs (make mif restores the MLP demo)"

# Memory M9K init images (D022 imem, D023 dmem): program hex -> even/odd
# bank MIFs for rtl/mem/imem_banked.v, data hex -> one flat MIF for
# rtl/mem/dmem.v (paths resolve in synth/). All .mif files are CHECKED IN
# (same policy as sw/demo/*.hex): a fresh clone must compile the Quartus
# project without Python or riscv-gcc.
#
# MIF_PROG selects what the board runs (D023 default: the MLP demo).
#   make mif MIF_PROG=demo  -> the LED walker, no data image
#   make mif                -> MLP board demo (8 images, switch-selected)
MIF_EVEN  := synth/imem_even.mif
MIF_ODD   := synth/imem_odd.mif
MIF_DMEM  := synth/dmem.mif
IMEM_DEPTH := 2048
DMEM_DEPTH := 16384

MIF_PROG ?= mlp
ifeq ($(MIF_PROG),demo)
MIF_TEXT := sw/demo/led_demo.hex
MIF_DATA := sw/demo/empty_data.hex
else
MIF_TEXT := sw/npu_mlp/mlp_board.text.hex
MIF_DATA := sw/npu_mlp/mlp_board.data.hex
endif

# Stale-program guard (audit 2026-07-11): the MIF targets depend on
# WHICH program MIF_PROG selects, not just on file mtimes — without this
# stamp, `make mif MIF_PROG=demo` after an mlp build says "up to date"
# and the board silently ships the wrong program.
synth/.mif_prog_stamp: FORCE
	@[ "$$(cat $@ 2>/dev/null)" = '$(MIF_PROG)' ] || echo '$(MIF_PROG)' > $@

$(MIF_EVEN): $(MIF_TEXT) scripts/hex2mif.py synth/.mif_prog_stamp
	$(PYTHON) scripts/hex2mif.py $< $(MIF_EVEN) $(MIF_ODD) \
	    --depth-words $(IMEM_DEPTH) --pad 0x00000013 --check

$(MIF_ODD): $(MIF_EVEN) ;

$(MIF_DMEM): $(MIF_DATA) scripts/hex2mif.py synth/.mif_prog_stamp
	$(PYTHON) scripts/hex2mif.py $< $(MIF_DMEM) --single \
	    --depth-words $(DMEM_DEPTH) --pad 0 --check

.PHONY: mif
mif: $(MIF_EVEN) $(MIF_ODD) $(MIF_DMEM)

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
# 600 iterations ≈ 510M cycles ≈ 10.2 simulated seconds on the in-order
# baseline. The faster current OoO core needs 720 iterations to clear
# CoreMark's 10-second reporting rule; coremark-ooo sets that default below.
# Use coremark-quick[-ooo] for a short CRC-only correctness check.
CM_ITER ?= 600
CM_OPT  ?= -O2
CM_REQUIRE_REPORT ?= 1
COREMARK_LOG ?= coremark.log
CM_FLAGS = $(SW_CFLAGS) $(CM_OPT) -ffreestanding \
           -I$(CM_DIR) -I$(CM_DIR)/rv32 -Isw/common \
           -DITERATIONS=$(CM_ITER) \
           -DFLAGS_STR='"$(CM_OPT) -march=rv32i_zicsr"'

# ITERATIONS/opt level are baked in via -D, so the elf must rebuild when
# CM_ITER/CM_OPT change even though no source file did: the stamp file
# records the last-built flags and only changes when they do.
$(CM_DIR)/.cm_flags_stamp: FORCE
	@[ "$$(cat $@ 2>/dev/null)" = '$(CM_ITER) $(CM_OPT)' ] \
	    || echo '$(CM_ITER) $(CM_OPT)' > $@
FORCE:

$(CM_DIR)/coremark.elf: $(CM_SRCS) $(CM_DIR)/coremark.h \
                        $(CM_DIR)/rv32/core_portme.h $(SW_CDEPS) \
                        $(CM_DIR)/.cm_flags_stamp
	$(RISCV_GCC) $(CM_FLAGS) -o $@ $(CRT0) $(LIBMIN) $(CM_SRCS) -lm -lgcc

# Pass gate = the three benchmark CRCs against the official expected values
# for the 2K performance profile (seeds 0/0/0x66). Full targets additionally
# require CoreMark's own "Correct operation validated" line, which includes
# the >=10-second rule; quick targets deliberately request CRC-only mode.
coremark: $(RUN_BIN) $(CM_DIR)/coremark.text.hex $(CM_DIR)/coremark.data.hex
	set -o pipefail; ./$(RUN_BIN) +imem=$(CM_DIR)/coremark.text.hex \
	    +dmem=$(CM_DIR)/coremark.data.hex \
	    +max_cycles=900000000 | tee $(COREMARK_LOG)
	@grep -Eq 'crclist.*0xe714'  $(COREMARK_LOG) && \
	 grep -Eq 'crcmatrix.*0x1fd7' $(COREMARK_LOG) && \
	 grep -Eq 'crcstate.*0x8e3a'  $(COREMARK_LOG) \
	    && echo "coremark: CRCs match official 2K performance-run values" \
	    || { echo "coremark: CRC MISMATCH — computation is wrong"; exit 1; }
	@if [ "$(CM_REQUIRE_REPORT)" = "1" ]; then \
	    grep -q 'Correct operation validated' $(COREMARK_LOG) \
	      && echo "coremark: reportable run (CoreMark >=10-second rule met)" \
	      || { echo "coremark: NOT REPORTABLE — raise CM_ITER or use coremark-quick"; exit 1; }; \
	fi

coremark-quick:
	$(MAKE) coremark CM_ITER=10 CM_REQUIRE_REPORT=0

# Apples-to-apples current-tree comparison: both models consume the exact same
# 720-iteration ELF/HEX, and separate logs preserve both reportable results.
coremark-compare:
	$(MAKE) coremark RUN_BIN=$(SIM_BIN) CM_ITER=720 COREMARK_LOG=coremark-inorder.log
	$(MAKE) coremark RUN_BIN=$(SIM_BIN_OOO) CM_ITER=720 COREMARK_LOG=coremark-ooo.log
	$(PYTHON) scripts/coremark_compare.py coremark-inorder.log coremark-ooo.log

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

# --- board MLP demo (D023): NPU-only, switch-selected image, 7-seg output ----
# Linked against link_board.ld (8 KB imem / 64 KB dmem) so exceeding the
# synthesized memories is a LINK error. The sim run executes the demo's
# self-test phase (classify images 0-7 vs the offline reference) and exits
# at its MMIO_SIM_EXIT store; the board continues into the switch loop.
$(MLP_DIR)/mlp_board.elf: $(MLP_DIR)/mlp_board.c $(MLP_DIR)/weights.h \
                    sw/common/npu.h sw/common/link_board.ld $(SW_CDEPS)
	$(RISCV_GCC) $(filter-out -T sw/common/link.ld,$(CFLAGS_C)) \
	    -T sw/common/link_board.ld -o $@ $(CRT0) $(LIBMIN) $< -lgcc
.PRECIOUS: $(MLP_DIR)/mlp_board.elf

mlp-board: $(MLP_DIR)/mlp_board.text.hex $(MLP_DIR)/mlp_board.data.hex mif
	@echo "mlp-board: MIFs in synth/ now hold the MLP demo (quartus recompile to ship)"

npu-mlp-board: $(RUN_BIN) $(MLP_DIR)/mlp_board.text.hex $(MLP_DIR)/mlp_board.data.hex
	./$(RUN_BIN) +imem=$(MLP_DIR)/mlp_board.text.hex \
	    +dmem=$(MLP_DIR)/mlp_board.data.hex +max_cycles=900000000
npu-mlp-board-ooo:
	$(MAKE) npu-mlp-board RUN_BIN=$(SIM_BIN_OOO)
.PHONY: mlp-board npu-mlp-board npu-mlp-board-ooo

# --- run ------------------------------------------------------------------------
test: $(RUN_BIN) $(SW_TESTS)
	./$(RUN_BIN) +imem=$(PROG)

# Run every assembly test in sw/tests and every C test in sw/ctests
# NOTE: iterate $(SW_TESTS) (derived from the .S sources), NOT the .hex
# glob — a stale .hex from a deleted/renamed test must not keep "passing".
regress: $(RUN_BIN) $(SW_TESTS) $(CTEST_HEX)
	@pass=0; fail=0; \
	for h in $(SW_TESTS); do \
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

# Decode/system coverage-tail lane. Kept separate from the proven default
# seeds: --sys injects FENCE/ECALL/EBREAK/reserved words at low weight while
# lockstep proves the documented side-effect-free NOP contract at retirement.
regress-rand-sys: $(RUN_BIN)
	@mkdir -p build/rand; pass=0; fail=0; \
	for s in $$(seq 1 $(RAND_SEEDS)); do \
	  $(PYTHON) scripts/gen_random_test.py $$s build/rand/sys_$$s.hex $(RAND_LEN) --sys; \
	  if out=$$(./$(RUN_BIN) +imem=build/rand/sys_$$s.hex); then \
	    pass=$$((pass+1)); \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  sys seed %s\n%s\n' "$$s" "$$out"; \
	  fi; \
	done; \
	printf 'regress-rand-sys: %d/%d seeds passed (system/decode-tail, lockstep-checked)\n' \
	    $$pass $(RAND_SEEDS); \
	[ $$fail -eq 0 ]

# NPU/MMIO ordering lane (B010/B011): generated bursts use back-to-back GO,
# immediate-producer address/store-data dependencies, and strongly ordered
# readbacks. The ISS mirrors every access; default/vio streams stay unchanged.
regress-rand-npu: $(RUN_BIN)
	@mkdir -p build/rand; pass=0; fail=0; \
	for s in $$(seq 1 $(RAND_SEEDS)); do \
	  $(PYTHON) scripts/gen_random_test.py $$s build/rand/npu_$$s.hex $(RAND_LEN) --npu; \
	  if out=$$(./$(RUN_BIN) +imem=build/rand/npu_$$s.hex); then \
	    pass=$$((pass+1)); \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  npu seed %s\n%s\n' "$$s" "$$out"; \
	  fi; \
	done; \
	printf 'regress-rand-npu: %d/%d seeds passed (NPU ordering/interlocks, lockstep-checked)\n' \
	    $$pass $(RAND_SEEDS); \
	[ $$fail -eq 0 ]

# Randomized startup/reset lane (audit 2026-07-11). Each X model was compiled
# with --x-assign/--x-initial unique; runtime mode 2 randomizes initial state.
# The complete directed+C suite runs at multiple explicit seeds under lockstep.
X_SEEDS   ?= 4
X_RUN_BIN ?= $(X_BIN)
regress-x: $(X_RUN_BIN) $(SW_TESTS) $(CTEST_HEX)
	@pass=0; fail=0; \
	for s in $$(seq 1 $(X_SEEDS)); do \
	  xargs="+verilator+rand+reset+2 +verilator+seed+$$s"; \
	  for h in $(SW_TESTS); do \
	    if out=$$(./$(X_RUN_BIN) +imem=$$h $$xargs); then \
	      pass=$$((pass+1)); \
	    else \
	      fail=$$((fail+1)); printf 'FAIL  X seed %s %s\n%s\n' "$$s" "$$h" "$$out"; \
	    fi; \
	  done; \
	  for c in $(CTESTS); do \
	    b=$${c%.c}; \
	    if out=$$(./$(X_RUN_BIN) +imem=$$b.text.hex +dmem=$$b.data.hex \
	              +max_cycles=2000000 $$xargs); then \
	      pass=$$((pass+1)); \
	    else \
	      fail=$$((fail+1)); printf 'FAIL  X seed %s %s\n%s\n' "$$s" "$$c" "$$out"; \
	    fi; \
	  done; \
	done; \
	printf 'regress-x: %d/%d runs passed (%d seeds, randomized initial/reset state, lockstep-checked)\n' \
	    $$pass $$(( ($(words $(SW_TESTS)) + $(words $(CTESTS))) * $(X_SEEDS) )) \
	    $(X_SEEDS); \
	[ $$fail -eq 0 ]

# --vio variant (D020): same seeds but with the load-ordering-violation
# stress pattern injected, so the LQ poison + flush-at-head recovery fires
# under random interleaving (the plain seeds essentially never violate).
regress-rand-vio: $(RUN_BIN)
	@mkdir -p build/rand; pass=0; fail=0; \
	for s in $$(seq 1 $(RAND_SEEDS)); do \
	  $(PYTHON) scripts/gen_random_test.py $$s build/rand/vio_$$s.hex $(RAND_LEN) --vio; \
	  if out=$$(./$(RUN_BIN) +imem=build/rand/vio_$$s.hex); then \
	    pass=$$((pass+1)); \
	  else \
	    fail=$$((fail+1)); printf 'FAIL  vio seed %s\n%s\n' "$$s" "$$out"; \
	  fi; \
	done; \
	printf 'regress-rand-vio: %d/%d seeds passed (LQ-violation stress, lockstep-checked)\n' \
	    $$pass $(RAND_SEEDS); \
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

# --- RTL line coverage (audit 2026-07-11: a promised roadmap deliverable) -----
# Separate coverage-instrumented builds (line coverage only — toggle
# coverage on 48k LEs of RTL is noise). `make coverage` runs the directed
# + ISA suites on BOTH cores, merges the per-test .dat files, and prints
# the combined RTL line-coverage percentage (also written to
# build/cov/coverage.info in lcov format for annotation tools).
COV_BIN     := obj_dir_cov/V$(TOP)
COV_BIN_OOO := obj_dir_cov_ooo/V$(OOO_TOP)

$(COV_BIN): $(RTL_SRCS) $(SIM_MAIN) tb/verilator/iss.h
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) --coverage-line --Mdir obj_dir_cov \
	    $(RTL_SRCS) $(SIM_MAIN) -o V$(TOP)

$(COV_BIN_OOO): $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) tb/verilator/iss.h
	@$(CHECK_VROOT)
	$(VERILATOR) $(VFLAGS) --coverage-line --top-module $(OOO_TOP) \
	    --Mdir obj_dir_cov_ooo -CFLAGS -DOOO_TOP \
	    $(RTL_SRCS) $(OOO_SRCS) $(SIM_MAIN) -o V$(OOO_TOP)

coverage: $(COV_BIN) $(COV_BIN_OOO) $(SW_TESTS) $(CTEST_HEX) $(RVT_HEX)
	@mkdir -p build/cov && rm -f build/cov/*.dat
	@n=0; fail=0; \
	for h in $(SW_TESTS); do \
	  ./$(COV_BIN) +imem=$$h +covout=build/cov/io_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  ./$(COV_BIN_OOO) +imem=$$h +covout=build/cov/oo_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  n=$$((n+1)); \
	done; \
	for c in sw/ctests/*.c; do b=$${c%.c}; \
	  ./$(COV_BIN) +imem=$$b.text.hex +dmem=$$b.data.hex +max_cycles=2000000 \
	      +covout=build/cov/ioc_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  ./$(COV_BIN_OOO) +imem=$$b.text.hex +dmem=$$b.data.hex +max_cycles=2000000 \
	      +covout=build/cov/ooc_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  n=$$((n+1)); \
	done; \
	for s in $(RVT_DIR)/rv32ui/*.S; do b=$${s%.S}; \
	  ./$(COV_BIN) +imem=$$b.text.hex +dmem=$$b.data.hex \
	      +covout=build/cov/ioi_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  ./$(COV_BIN_OOO) +imem=$$b.text.hex +dmem=$$b.data.hex \
	      +covout=build/cov/ooi_$$n.dat >/dev/null || fail=$$((fail+1)); \
	  n=$$((n+1)); \
	done; \
	echo "coverage: $$n programs run per core, $$fail failures"; \
	[ $$fail -eq 0 ]
	verilator_coverage --write-info build/cov/coverage.info build/cov/*.dat
	@awk -F: '/^DA:/ { split($$2,a,","); tot++; if (a[2]>0) hit++ } \
	  END { printf "coverage: RTL line coverage %d/%d = %.1f%% (both cores, directed+ctests+ISA suites)\n", \
	        hit, tot, 100.0*hit/tot }' build/cov/coverage.info
.PHONY: coverage

# Umbrella: everything that must be green before merging to main
verify: regress regress-isa regress-rand regress-rand-sys regress-rand-npu regress-x

# The suite targets are recipes, not files: without .PHONY a stray file
# named e.g. "regress" would silently skip the entire suite (the -ooo
# aliases were protected; the base targets were not — audit 2026-07-11).
.PHONY: regress regress-rand regress-rand-sys regress-rand-npu regress-rand-vio regress-x regress-isa verify coremark coremark-quick coremark-compare

# --- OoO core aliases: identical suites, second binary ------------------------
regress-ooo:
	$(MAKE) regress RUN_BIN=$(SIM_BIN_OOO)
regress-isa-ooo:
	$(MAKE) regress-isa RUN_BIN=$(SIM_BIN_OOO)
regress-rand-ooo:
	$(MAKE) regress-rand RUN_BIN=$(SIM_BIN_OOO)
regress-rand-sys-ooo:
	$(MAKE) regress-rand-sys RUN_BIN=$(SIM_BIN_OOO)
regress-rand-npu-ooo:
	$(MAKE) regress-rand-npu RUN_BIN=$(SIM_BIN_OOO)
regress-x-ooo:
	$(MAKE) regress-x X_RUN_BIN=$(X_BIN_OOO)
regress-rand-vio-ooo:
	$(MAKE) regress-rand-vio RUN_BIN=$(SIM_BIN_OOO)
# The current OoO core completes 600 iterations in ~8.44 benchmark seconds,
# so its full/reportable default is 720. A command-line CM_ITER still wins.
coremark-ooo: CM_ITER = 720
coremark-ooo:
	$(MAKE) coremark RUN_BIN=$(SIM_BIN_OOO) CM_ITER=$(CM_ITER)
coremark-quick-ooo:
	$(MAKE) coremark RUN_BIN=$(SIM_BIN_OOO) CM_ITER=10 CM_REQUIRE_REPORT=0
verify-ooo: lq-tb regress-ooo regress-isa-ooo regress-rand-ooo regress-rand-sys-ooo regress-rand-npu-ooo regress-x-ooo regress-rand-vio-ooo
.PHONY: sim-ooo regress-ooo regress-isa-ooo regress-rand-ooo regress-rand-sys-ooo regress-rand-npu-ooo regress-x-ooo regress-rand-vio-ooo \
	    coremark-ooo coremark-quick-ooo verify-ooo

run: $(RUN_BIN)
	./$(RUN_BIN) +imem=$(PROG) $(DMEM_ARG)

wave: $(RUN_BIN)
	./$(RUN_BIN) +imem=$(PROG) $(DMEM_ARG) +trace
	@echo "waveform written to sim.fst"

# --- synthesis sanity check -------------------------------------------------------
# LE-budget gate (audit 2026-07-11): the old error-count-only gate is the
# exact gate that missed the D020 capacity blowout (103% LEs discovered a
# branch later). A&S "Total logic elements" is pre-packing: history says
# ~53,004 still fitted (97%, D022) and 53,200 failed ROUTING (D023), so
# the default budget is deliberately below both. Override: LE_BUDGET=nnn
# (0 disables the check). A red gate here means "will not fit the 10M50",
# not "RTL is broken" — map errors still fail on their own.
LE_BUDGET ?= 52000
synth-check:
	cd synth && $(QUARTUS_MAP) rv32i_cpu
	@les=$$(sed -n 's/^Total logic elements : \([0-9,]*\).*/\1/p' \
	       synth/output_files/rv32i_cpu.map.summary | tr -d ,); \
	[ -n "$$les" ] || { echo 'synth-check: could not parse LE count from map.summary'; exit 1; }; \
	echo "synth-check: A&S total logic elements = $$les (budget $(LE_BUDGET), device 49760)"; \
	if [ $(LE_BUDGET) -gt 0 ] && [ $$les -gt $(LE_BUDGET) ]; then \
	  echo "synth-check: OVER LE BUDGET ($$les > $(LE_BUDGET)) — capacity regression (D020/D021 lesson)"; \
	  exit 1; \
	fi

# Full fit + STA with archived critical paths — the board top's actual
# critical path was never recorded before (only ad-hoc synth_sta*/ runs
# of the bare core). Writes output_files/critical_paths.rpt.
synth-fit: synth-check
	cd synth && $(QUARTUS_FIT) rv32i_cpu

synth-sta:
	cd synth && $(QUARTUS_STA) -t ../scripts/sta_paths.tcl rv32i_cpu
.PHONY: synth-fit synth-sta

clean:
	rm -rf obj_dir obj_dir_ooo obj_dir_x obj_dir_x_ooo obj_dir_npu obj_dir_stset obj_dir_prf obj_dir_lq sim.fst
	rm -f sw/tests/*.elf sw/tests/*.bin sw/tests/*.hex
	rm -f sw/ctests/*.elf sw/ctests/*.bin sw/ctests/*.hex
	rm -f sw/coremark/coremark.elf sw/coremark/*.bin sw/coremark/*.hex
	rm -f sw/coremark/.cm_flags_stamp coremark*.log
	rm -f sw/npu_mlp/mlp.elf sw/npu_mlp/*.bin sw/npu_mlp/*.hex
