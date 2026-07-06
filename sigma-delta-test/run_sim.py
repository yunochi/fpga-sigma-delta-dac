import subprocess
import argparse
import sys
import os

import math

VERILATOR_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "obj_dir", "tb")

def main():
    parser = argparse.ArgumentParser(description='Sigma-Delta Simulation and Analysis Wrapper')
    parser.add_argument('--fs', type=int, default=12288000, help='Modulator Sampling Frequency (Hz)')
    parser.add_argument('--f0', type=float, default=1000, help='Desired Target Frequency (Hz)')
    parser.add_argument('--target-res', type=int, default=5, help='Frequency resolution (Hz)')
    parser.add_argument('--amp', type=float, default=30000.0, help='Sine amplitude')
    parser.add_argument('--osr', type=int, default=128, help='Oversampling ratio')
    parser.add_argument('--sim', choices=['verilator', 'icarus'], default='verilator',
                        help='Simulator backend (default: verilator, ~300x faster than icarus)')
    parser.add_argument('--rebuild', action='store_true', help='Force Verilator rebuild before running')

    args = parser.parse_args()

    # 1. Calculate N (Number of samples) - Matching Verilog logic
    n_samples = 1 << (args.fs // args.target_res - 1).bit_length()
    target_f0 = args.f0

    print(f"--- Simulation Configuration ---")
    print(f"Simulator    : {args.sim}")
    print(f"Target F0    : {target_f0} Hz")
    print(f"Samples (N)  : {n_samples}")
    print(f"---------------------------------------")

    if args.sim == 'verilator':
        # Build the Verilator binary if missing (or if --rebuild)
        if args.rebuild or not os.path.exists(VERILATOR_BIN):
            print(f"--- Step 1: Building Verilator binary ---")
            try:
                subprocess.run(["make", "clean"], check=True)
                subprocess.run(["make"], check=True)
            except subprocess.CalledProcessError:
                print("Verilator build failed. Falling back to icarus (--sim icarus).")
                args.sim = 'icarus'
            else:
                print(f"--- Step 2: Running Verilator Simulation ---")

        if args.sim == 'verilator':
            run_cmd = [
                VERILATOR_BIN,
                "--fs", str(args.fs),
                "--f0", str(args.f0),
                "--target-res", str(args.target_res),
                "--amp", str(args.amp),
                "--osr", str(args.osr),
            ]
            try:
                subprocess.run(run_cmd, check=True)
            except subprocess.CalledProcessError:
                print("Simulation failed.")
                sys.exit(1)

    if args.sim == 'icarus':
        print(f"--- Step 1: Compiling Verilog ---")
        compile_cmd = [
            "iverilog",
            "-o", "sim_icarus",
            f"-Ptestbench.FS_HZ={args.fs}",
            f"-Ptestbench.TARGET_F0={args.f0}",
            f"-Ptestbench.TARGET_RES={args.target_res}",
            "sim_tb.v"
        ]

        try:
            subprocess.run(compile_cmd, check=True)
        except subprocess.CalledProcessError:
            print("Compilation failed.")
            sys.exit(1)

        print(f"--- Step 2: Running Simulation ---")
        try:
            subprocess.run(["vvp", "sim_icarus"], check=True)
        except subprocess.CalledProcessError:
            print("Simulation failed.")
            sys.exit(1)

    print(f"--- Step 3: Analyzing SNR with Fs={args.fs}, Target F0={target_f0:.4f} ---")
    analyze_cmd = [
        "python3", "analyze_snr.py",
        "--fs", str(args.fs),
        "--f0", str(target_f0)
    ]
    subprocess.run(analyze_cmd)

if __name__ == "__main__":
    main()
