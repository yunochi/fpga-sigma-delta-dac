import numpy as np
import scipy.signal as signal

def design_halfband_filter():
    taps = 127

    # 1. SciPy의 firwin을 이용하여 대칭 차단주파수가 0.5(즉, fs_out/4)인 필터 설계
    # Half-band 조건(대칭성)을 위해 cutoff를 정확히 0.5로 설정합니다.
    h = signal.firwin(taps, cutoff=0.5, window='hamming')

    # 2. 16비트 정수형(소수점 아래 15비트) 스케일링 준비
    scale = 32768.0 # 2^15
    h_scaled = np.round(h * scale).astype(int)

    # 3. 하프밴드 제약 조건 강제 적용 (이상적인 대칭성 보장)
    center_idx = (taps - 1) // 2 # 63탭인 경우 31번 인덱스가 센터

    # 3.1. 홀수 오프셋 계수를 정확히 0으로 설정
    for i in range(taps):
        if i != center_idx and (i - center_idx) % 2 == 0:
            h_scaled[i] = 0

    # 3.2. 센터 탭은 정확히 1.0 (32768)로 고정
    h_scaled[center_idx] = 32768

    # 4. DC 이득(Gain) 미스매치 방지를 위한 미세 보정 (Fine Normalization)
    # 짝수 위상(Even phase)의 계수 합이 홀수 위상(Center tap = 32768)과 동일하게 32768이 되도록 맞춤.
    # 좌우 대칭이므로 한쪽 사이드 계수들의 합이 16384가 되도록 스케일링 조절
    side_indices = [i for i in range(center_idx + 1, taps) if (i - center_idx) % 2 != 0]
    # side_indices는 [32, 34, ..., 62]가 됨

    current_side_sum = sum(h_scaled[idx] for idx in side_indices)
    target_side_sum = 16384 # (32768 / 2)

    # 비율에 맞춰 사이드 계수 재조정
    adjusted_side = []
    accum_sum = 0
    for idx in side_indices:
        val = int(round(h_scaled[idx] * target_side_sum / current_side_sum))
        adjusted_side.append(val)
        accum_sum += val

    # 라운딩 에러로 인해 합이 16384에서 벗어난 오차가 있다면 가장 큰 계수(h[32])에 더해줌
    diff = target_side_sum - accum_sum
    if diff != 0:
        max_idx = np.argmax([abs(x) for x in adjusted_side])
        adjusted_side[max_idx] += diff

    # 5. 최종 보정된 대칭 계수 배열 재구성
    final_coefs = [0] * taps
    final_coefs[center_idx] = 32768
    for k, idx in enumerate(side_indices):
        val = adjusted_side[k]
        final_coefs[idx] = val
        final_coefs[center_idx - (idx - center_idx)] = val # 대칭 위치 복사

    return final_coefs

# 필터 설계 실행 및 출력
coefs = design_halfband_filter()
print("Designed 63-tap Half-Band FIR Coefficients:")
print(coefs)
