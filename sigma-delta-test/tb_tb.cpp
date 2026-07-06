// Verilator C++ testbench for sim_dut.
// Replaces the Verilog `testbench` module: generates clock, sine stimulus,
// interval counter, and writes the SDM bitstream to a file.
#include "Vsim_dut.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Must match the Verilog testbench's `real PI = 3.14159265` exactly,
// so the sine stimulus is bit-identical to the Icarus reference run.
static const double PI = 3.14159265;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // --- Configuration (defaults mirror run_sim.py / sim_tb.v) ---
    double fs = 12288000.0;      // Modulator sampling frequency (Hz)
    double f0 = 1000.0;         // Target tone frequency (Hz)
    int    target_res = 5;       // Frequency resolution (Hz)
    double amplitude = 30000.0;  // Sine amplitude (16-bit signed range)
    int    osr = 128;           // Oversampling ratio
    const char* outfile = "dout.txt";

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--fs")          && i+1 < argc) fs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--f0")          && i+1 < argc) f0 = atof(argv[++i]);
        else if (!strcmp(argv[i], "--target-res")  && i+1 < argc) target_res = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--amp")         && i+1 < argc) amplitude = atof(argv[++i]);
        else if (!strcmp(argv[i], "--osr")         && i+1 < argc) osr = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out")         && i+1 < argc) outfile = argv[++i];
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: tb [opts]\n  --fs --f0 --target-res --amp --osr --out\n");
            return 0;
        }
    }

    // N_SAMPLES = 1 << ceil(log2(fs / target_res))  (matches Verilog $clog2)
    int n_bits = 0;
    {   long v = (long)(fs / target_res);
        if (v < 1) v = 1;
        while ((1L << n_bits) < v) n_bits++;
    }
    long N = 1L << n_bits;

    printf("--- Verilator Testbench ---\n");
    printf("Fs           : %.0f Hz (%.3f MHz)\n", fs, fs / 1e6);
    printf("Target F0    : %.4f Hz\n", f0);
    printf("OSR          : %d (input rate %.0f Hz)\n", osr, fs / osr);
    printf("Amplitude    : %.1f\n", amplitude);
    printf("Target Res   : %d Hz\n", target_res);
    printf("Actual Res   : %f Hz\n", fs / N);
    printf("N_SAMPLES    : %ld (2^%d)\n", N, n_bits);
    printf("----------------------------\n");

    // --- DUT instantiation ---
    Vsim_dut* dut = new Vsim_dut;

    FILE* f = fopen(outfile, "wb");
    if (!f) { perror(outfile); delete dut; return 1; }
    // Large write buffer to minimize I/O overhead.
    static char iobuf[1 << 20];
    setvbuf(f, iobuf, _IOFBF, sizeof(iobuf));

    // --- Reset (mirror `#100 rst_n = 1`; give a few cycles under reset) ---
    dut->clk = 0;
    dut->rst_n = 0;
    dut->data_in = 0;
    dut->data_interval_cnt = (uint16_t)(osr - 1);
    dut->eval();
    for (int r = 0; r < 5; r++) {
        dut->clk = 1; dut->eval();
        dut->clk = 0; dut->eval();
    }

    // --- Mirror of the testbench's own registers (updated nonblocking @posedge) ---
    uint32_t cycle_cnt = 0;
    uint16_t interval_cnt = (uint16_t)(osr - 1);  // wraps on first real posedge
    int16_t  data_in = 0;

    dut->rst_n = 1;
    dut->data_in = data_in;
    dut->data_interval_cnt = interval_cnt;
    dut->eval();  // settle combinational logic with rst_n=1

    for (long i = 0; i < N; i++) {
        // Inputs the DUT sees DURING this cycle (= current register values).
        dut->data_in = data_in;
        dut->data_interval_cnt = interval_cnt;
        dut->rst_n = 1;

        // $fwrite samples sdm_out BEFORE the NBA region, i.e. the value
        // registered at the previous posedge (or reset). Capture it here.
        unsigned sample = dut->sdm_out ? 1u : 0u;

        // Compute next register values (RHS uses current cycle_cnt like nonblocking).
        uint32_t next_cycle_cnt = cycle_cnt + 1;
        uint16_t next_interval_cnt;
        int16_t  next_data_in;
        if (interval_cnt >= (uint16_t)(osr - 1)) {
            next_interval_cnt = 0;
            next_data_in = (int16_t)(long)(amplitude * sin(2.0 * PI * f0 * (double)cycle_cnt / fs));
        } else {
            next_interval_cnt = (uint16_t)(interval_cnt + 1);
            next_data_in = data_in;  // hold
        }

        // Posedge: DUT sequential logic updates based on current inputs.
        dut->clk = 1;
        dut->eval();

        // Emit the OLD sample (matches the original $fwrite timing exactly).
        fputc('0' + (int)sample, f);
        fputc('\n', f);

        // Negedge.
        dut->clk = 0;
        dut->eval();

        // Advance mirrored registers.
        cycle_cnt   = next_cycle_cnt;
        interval_cnt = next_interval_cnt;
        data_in      = next_data_in;
    }

    fclose(f);
    printf("Done: %ld samples written to %s\n", N, outfile);

    delete dut;
    return 0;
}
