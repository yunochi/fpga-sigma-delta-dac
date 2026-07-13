PROJ := top
FAMILY := GW2A-18C
DEVICE := GW2AR-LV18QN88C8/I7
CST := tang-nano-20k.cst
SDC := tang-nano-20k.sdc

SYNTHFLAGS := -D MUA=1

SIMCOMPILER := iverilog
SIMULATOR := vvp
VIEWER := gtkwave

SRCS = $(wildcard *.v)
TBSRCS = $(filter %_tb.v, $(SRCS))
MODSRCS = $(filter-out %_tb.v %_incl.v, $(SRCS))
VVPS = $(patsubst %.v,%.vvp,$(TBSRCS))
VCDS = $(patsubst %_tb.v,%_wave.vcd,$(TBSRCS))

all: ${PROJ}.fs

simulate: $(VCDS)

prog: ${PROJ}.fs
	openFPGALoader -b tangnano20k -f $<

load: ${PROJ}.fs
	openFPGALoader -b tangnano20k $<

${PROJ}.fs: pnr${PROJ}.json
	gowin_pack -d GW2A-18C -o $@ pnr${PROJ}.json

pnr${PROJ}.json: ${CST} ${PROJ}.json
	nextpnr-himbaechel --json "${PROJ}.json" --write "$@" --device "${DEVICE}" --vopt "family=${FAMILY}" --vopt "cst=${CST}" --sdc "${SDC}" --report report.json

${PROJ}.json: $(MODSRCS)
	yosys ${SYNTHFLAGS} -p "read_verilog $^; synth_gowin -json $@"

%.vvp: %.v $(MODSRCS)
	$(SIMCOMPILER) $(SIMCOMPFLAGS) $^ -o $@

%_wave.vcd: %_tb.vvp
	$(SIMULATOR) $(SIMFLAGS) $<

clean:
	rm -f *.fs "${PROJ}.json" "pnr${PROJ}.json" *.vvp *.vcd
