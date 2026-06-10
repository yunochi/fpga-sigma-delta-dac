import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import windows
import os
import argparse

def analyze_sigma_delta_performance(file_path, fs, target_freq, audio_max_freq=20000):
    """
    시그마-델타 비트스트림을 분석하여 SNR 및 노이즈 쉐이핑 특성을 측정합니다.
    """
    if not os.path.exists(file_path):
        print(f"오류: {file_path} 파일을 찾을 수 없습니다. 시뮬레이션을 먼저 실행하세요.")
        return

    print(f"분석 시작: {file_path}")
    print(f"설정된 샘플링 주파수 (Fs): {fs/1e6:.3f} MHz")
    print(f"설정된 목표 신호 주파수: {target_freq/1e3:.3f} kHz")

    # 1. 데이터 로드 및 전처리
    with open(file_path, 'r') as f:
        # 공백이나 빈 줄 처리
        lines = f.readlines()
        bitstream = np.array([int(line.strip()) for line in lines if line.strip()])
    
    # 0/1 비트스트림을 -1/1 바이폴라 신호로 변환
    data = 2 * bitstream - 1
    n = len(data)
    
    # 2. Windowing (Kaiser with high beta)
    # Kaiser window with beta=20 provides extreme side-lobe suppression (> 150dB)
    window = windows.kaiser(n, beta=20)
    # window = windows.boxcar(n)
    # DC 오프셋 제거 및 윈도우 적용
    windowed_data = (data - np.mean(data)) * window
    
    # 3. FFT 수행
    fft_data = np.fft.rfft(windowed_data)
    psd = np.abs(fft_data)**2
    # 윈도우 코히어런트 게인 보정 (SNR은 비율이라 상관없지만 플롯을 위해)
    psd = psd / (np.sum(window)**2)
    freqs = np.fft.rfftfreq(n, 1/fs)
    
    # 4. 신호 피크 탐색 (설정된 target_freq 주변에서 실제 피크 검색)
    target_idx = np.argmin(np.abs(freqs - target_freq))
    search_range = max(50, int(target_freq / (fs/n) * 0.2)) 
    s_idx = max(0, target_idx - search_range)
    e_idx = min(len(psd), target_idx + search_range)
    
    if s_idx >= e_idx:
        print("오류: 신호를 찾을 수 있는 범위가 잘못되었습니다.")
        return

    peak_idx = s_idx + np.argmax(psd[s_idx:e_idx])
    
    # 포물선 보간(Parabolic Interpolation)으로 더 정밀한 주파수 계산
    if 0 < peak_idx < len(psd) - 1:
        y1, y2, y3 = np.log10(psd[peak_idx-1]), np.log10(psd[peak_idx]), np.log10(psd[peak_idx+1])
        adj = 0.5 * (y1 - y3) / (y1 - 2*y2 + y3)
        actual_freq = (peak_idx + adj) * (fs / n)
    else:
        actual_freq = freqs[peak_idx]
    
    # 5. 신호 전력 계산 (메인 로브 합산)
    # Kaiser(beta=20) 윈도우는 메인로브가 약 13-14 bins (±6.5)
    # 여기서는 안전하게 ±8 bins 정도를 사용하여 신호 에너지를 모두 합산함
    s_half_bins = min(8, max(2, peak_idx // 2))
    signal_bins = slice(max(0, peak_idx - s_half_bins), min(len(psd), peak_idx + s_half_bins + 1))
    signal_power = np.sum(psd[signal_bins])
    
    # 6. 노이즈 전력 계산
    low_idx = np.argmin(np.abs(freqs - 20))
    high_idx = np.argmin(np.abs(freqs - audio_max_freq))
    
    noise_mask = np.zeros_like(psd, dtype=bool)
    noise_mask[low_idx : high_idx+1] = True
    noise_mask[signal_bins] = False
    noise_power = np.sum(psd[noise_mask])
    
    snr_db = 10 * np.log10(signal_power / noise_power) if noise_power > 0 else 0
    
    # ... (기울기 계산 부분은 동일) ...
    # 7. 노이즈 쉐이핑 기울기 계산
    f_slope_low = audio_max_freq * 1.5
    f_slope_high = min(fs/2, audio_max_freq * 10)
    
    slope_idx = (freqs >= f_slope_low) & (freqs <= f_slope_high)
    if np.sum(slope_idx) > 10:
        log_f = np.log10(freqs[slope_idx])
        log_p = 10 * np.log10(psd[slope_idx] + 1e-20)
        slope, _ = np.polyfit(log_f, log_p, 1)
    else:
        slope = 0

    # 결과 출력
    print(f"\n{' 분석 결과 ':^40}")
    print(f"-"*40)
    print(f"측정된 신호 주파수: {actual_freq/1000:.3f} kHz")
    print(f"인밴드 SNR (20Hz-{audio_max_freq/1000:.1f}kHz): {snr_db:.2f} dB")
    print(f"노이즈 쉐이핑 기울기: {slope:.2f} dB/dec")
    print(f"-"*40)

    # 8. 시각화 (PSD Plot)
    plt.figure(figsize=(12, 6))
    psd_db = 10 * np.log10(psd / np.max(psd) + 1e-15)
    plt.semilogx(freqs, psd_db, color='#1f77b4', lw=1, label='Power Spectral Density')
    
    # 하이라이트 표시
    plt.axvspan(20, audio_max_freq, color='gray', alpha=0.15, label=f'Audio Band')
    
    # Signal Power 영역 표시 (로그 스케일에서 0Hz를 피하기 위해 0.1Hz 하한선 설정)
    sig_start_f = max(0.1, freqs[signal_bins.start])
    sig_stop_f = freqs[signal_bins.stop-1]
    plt.axvspan(sig_start_f, sig_stop_f, color='red', alpha=0.3, label='Signal Power')
    
    plt.title(f'Sigma-Delta DAC Analysis (Fs={fs/1e6:.2f}MHz, SNR: {snr_db:.2f} dB)', fontsize=14)
    plt.xlabel('Frequency (Hz)', fontsize=12)
    plt.ylabel('Relative Power (dB)', fontsize=12)
    plt.grid(True, which="both", ls="-", alpha=0.3)
    plt.xlim([10, fs/2])
    plt.ylim([-160, 10])
    plt.legend(loc='upper left')
    
    plt.tight_layout()
    plt.savefig('snr_plot.png', dpi=150)
    print("그래프가 'snr_plot.png'로 저장되었습니다.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Sigma-Delta Bitstream Analyzer')
    parser.add_argument('--file', type=str, default='dout.txt', help='Path to bitstream file')
    parser.add_argument('--fs', type=float, default=1e6, help='Sampling frequency (Hz)')
    parser.add_argument('--f0', type=float, default=1000, help='Target signal frequency (Hz)')
    parser.add_argument('--bw', type=float, default=20000, help='Audio bandwidth (Hz)')
    
    args = parser.parse_args()
    
    analyze_sigma_delta_performance(args.file, args.fs, args.f0, args.bw)
