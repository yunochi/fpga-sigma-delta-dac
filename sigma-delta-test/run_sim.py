import subprocess
import argparse
import sys

import math

def main():
    parser = argparse.ArgumentParser(description='Sigma-Delta Simulation and Analysis Wrapper')
    parser.add_argument('--fs', type=int, default=1000000, help='Modulator Sampling Frequency (Hz)')
    parser.add_argument('--f0', type=float, default=1000, help='Desired Target Frequency (Hz)')
    
    args = parser.parse_args()

    # 1. Calculate N (Number of samples) - Matching Verilog logic
    target_res = 5
    n_samples = 1 << (args.fs // target_res - 1).bit_length()
    
    # Use target frequency directly
    target_f0 = args.f0

    print(f"--- Simulation Configuration ---")
    print(f"Target F0    : {target_f0} Hz")
    print(f"Samples (N)  : {n_samples}")
    print(f"---------------------------------------")

    print(f"--- Step 1: Compiling Verilog ---")
    compile_cmd = [
        "iverilog", 
        "-o", "sigma_delta_sim", 
        f"-Ptestbench.FS_HZ={args.fs}", 
        f"-Ptestbench.TARGET_F0={args.f0}",
        "sigma_delta.v"
    ]
    
    try:
        subprocess.run(compile_cmd, check=True)
    except subprocess.CalledProcessError:
        print("Compilation failed.")
        sys.exit(1)

    print(f"--- Step 2: Running Simulation ---")
    try:
        subprocess.run(["vvp", "sigma_delta_sim"], check=True)
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
