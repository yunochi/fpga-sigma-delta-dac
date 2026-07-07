# Makefile for Verilator-based sigma-delta simulation.
#
#   make            # build the simulator binary `tb`
#   make run        # build + run default config, then analyze SNR
#   make clean

VERILATOR ?= verilator
TOP       := sim_dut
TB_SRC    := tb_tb.cpp
BIN       := tb
BIN_DIR   := obj_dir
BIN_PATH  := $(BIN_DIR)/$(BIN)
OSR       ?= 256

# Verilog sources (DUT + submodules)
VSRC      := sim_dut.v sigma-delta-3rd-order.v sigma-delta-2nd-order.v \
             fir_upsample.v linear_upsample.v

VFLAGS    := --cc --exe --build -Wall -Wno-WIDTH -Wno-UNUSED \
             -Wno-UNOPTFLAT -Wno-MODDUP -Wno-CASEINCOMPLETE \
             -Wno-DECLFILENAME \
             --top-module $(TOP) \
             -GOVERSAMPLING_RATIO=$(OSR)

.PHONY: all clean run

all: $(BIN_PATH)

$(BIN_PATH): $(VSRC) $(TB_SRC)
	$(VERILATOR) $(VFLAGS) $(VSRC) --exe $(TB_SRC) -o $(BIN) -Mdir $(BIN_DIR)
	@printf '%s' '$(OSR)' > $(BIN_DIR)/.built_osr

run: $(BIN_PATH)
	./$(BIN_PATH) --fs 12288000 --f0 1000 --target-res 5
	python3 analyze_snr.py --fs 12288000 --f0 1000

clean:
	rm -rf obj_dir $(BIN) dout.txt
