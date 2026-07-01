#include <Arduino.h>
#include "AudioTools.h"

// Define audio format: 48000 Hz, 2 channels, 16-bit PCM
AudioInfo info(48000, 2, 16);
I2SStream i2s_out; 

#define I2S_PIN_BCK  0  
#define I2S_PIN_WS   1  
#define I2S_PIN_DATA 2  

void setup() {
  Serial.begin(115200);

  // Configure I2S Output
  auto i2s_cfg = i2s_out.defaultConfig(TX_MODE);
  i2s_cfg.copyFrom(info);
  i2s_cfg.pin_data = I2S_PIN_DATA;
  i2s_cfg.pin_ws = I2S_PIN_WS;
  i2s_cfg.pin_bck = I2S_PIN_BCK;
  i2s_cfg.i2s_format = I2S_STD_FORMAT;
  
  // Buffer settings (Default)
  i2s_cfg.buffer_count = 8;
  i2s_cfg.buffer_size = 512;
  
  i2s_out.begin(i2s_cfg);
}

int16_t sample_val = 10000; // Amplitude
int sample_cnt = 0;
int16_t samples[2];          // Stereo sample buffer
int direction = 0;

void loop() {
  // 48000Hz / 440Hz = 약 109 샘플이 한 주기
  sample_cnt++;
  if (sample_cnt >= 55) {
    direction = !direction;
    sample_cnt = 0;
  }
  if (direction) {
    sample_val += 200;
  } else {
    sample_val -= 200;
  }
  
  samples[0] = sample_val * 2; // Left
  samples[1] = sample_val; // Right

  // I2SStream에 4바이트(16비트 스테레오 1샘플) 직접 기입
  i2s_out.write((uint8_t*)samples, sizeof(samples));
}
