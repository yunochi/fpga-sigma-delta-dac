#include <Arduino.h>
#include <I2S.h>
#include "AudioTools.h"
#include "AudioTools/Communication/USB/USBAudioStream.h"

#define AUDIO_SAMPLE_RATE 96000

// 2 channels, 16-bit PCM
AudioInfo info(AUDIO_SAMPLE_RATE, 2, 16);

USBAudioStream usb_in;
I2S i2s_out(OUTPUT);

#define I2S_PIN_BCK 0
#define I2S_PIN_WS 1
#define I2S_PIN_DATA 2

// Static buffer limit config (USB ring buffer capacity 12288 bytes)
const int TOTAL_CAPACITY = 12288;
const int CENTER_LIMIT = TOTAL_CAPACITY / 2; // 6144 bytes target center

void setup()
{
  // Initialize Serial for non-blocking debugging log
  Serial.begin(115200);

  // Required on cores without automatic TinyUSB initialization
  if (!TinyUSBDevice.isInitialized())
  {
    TinyUSBDevice.begin(0);
  }

  // 1. Configure USB Audio Stream as Receiver (Speaker device on PC)
  auto usb_cfg = usb_in.defaultConfig(RX_MODE);
  usb_cfg.copyFrom(info);
  usb_cfg.product = "Pico I2S DAC";
  usb_cfg.enable_feedback_ep = false; // Disable feedback endpoint to eliminate host driver jitter/pops
  usb_in.begin(usb_cfg);

  // 2. Configure Native I2S Output
  i2s_out.setBCLK(I2S_PIN_BCK);
  i2s_out.setDATA(I2S_PIN_DATA);
  i2s_out.setBitsPerSample(16);
  // Set buffer: 8 buffers, 256 words (1024 bytes) each -> total 8192 bytes DMA queue
  i2s_out.setBuffers(8, 256, 0);

  // Start I2S at target sample rate (Initially disabled to prevent noise, set pins to LOW)
  pinMode(I2S_PIN_BCK, OUTPUT);
  digitalWrite(I2S_PIN_BCK, LOW);
  pinMode(I2S_PIN_WS, OUTPUT);
  digitalWrite(I2S_PIN_WS, LOW);
  pinMode(I2S_PIN_DATA, OUTPUT);
  digitalWrite(I2S_PIN_DATA, LOW);
}

// Software PLL / Clock Recovery for Adaptive I2S Sync
void adjust_i2s_clock(int avail)
{
  static uint32_t last_adjust_ms = 0;
  uint32_t now = millis();

  // Only evaluate frequency changes once every 100 milliseconds
  if (now - last_adjust_ms < 10)
  {
    return;
  }
  last_adjust_ms = now;

  // 24b.8b 고정소수점. 16샘플 이동평균
  static uint32_t avail_moving_avarage = CENTER_LIMIT << 12;
  avail_moving_avarage -= avail_moving_avarage >> 4;
  avail_moving_avarage += avail << 8;
  int avg_avail = avail_moving_avarage >> 12;

  static int last_hz = AUDIO_SAMPLE_RATE;
  int target_hz = AUDIO_SAMPLE_RATE;
  const int margin = 1;
  if (avg_avail > CENTER_LIMIT + margin || avg_avail < CENTER_LIMIT - margin)
  {
    int error = (avg_avail - CENTER_LIMIT);
    // error = (error > 0) ? error - (margin/2) : error + (margin/2);
    int freq_adjust = error / (CENTER_LIMIT / 200);
    target_hz = AUDIO_SAMPLE_RATE + freq_adjust;
  }

  // Set the frequency only when a shift is requested to keep PIO BCLK noise free
  if (target_hz != last_hz)
  {
    last_hz = target_hz;
    i2s_out.setFrequency(target_hz);
    Serial.printf("[PLL] Frequency adjusted: %d Hz (Buffer: %d/%d)\n", target_hz, avg_avail, TOTAL_CAPACITY);
  }

  // Throttled periodic status report (once per 1000 milliseconds)
  static uint32_t last_report_ms = 0;
  if (now - last_report_ms >= 1000)
  {
    last_report_ms = now;
    Serial.printf("[STATUS] Buffer Level: %d | Center: %d | Capacity: %d | Current I2S Freq: %d Hz\n",
                  avg_avail, CENTER_LIMIT, TOTAL_CAPACITY, last_hz);
  }
}

// Single-Core loop: Handles USB task and copies data directly to native I2S with Pacing Control & Cool-down
void loop()
{
  TinyUSBDevice.task(); // Handle USB tasks (required for TinyUSB)

  static bool playback_started = false;
  static uint32_t last_reset_ms = 0;
  const int DATA_CHUNK_SIZE = 256;
  static uint8_t copy_buf[DATA_CHUNK_SIZE];

  int avail = usb_in.available();

  if (playback_started && avail < DATA_CHUNK_SIZE)
  {
    playback_started = false;
    last_reset_ms = millis();                // Record physical reset time
    i2s_out.setFrequency(AUDIO_SAMPLE_RATE); // Reset clock to nominal

    // Stop I2S output and set pins to LOW to prevent noise
    i2s_out.end();
    pinMode(I2S_PIN_BCK, OUTPUT);
    digitalWrite(I2S_PIN_BCK, LOW);
    pinMode(I2S_PIN_WS, OUTPUT);
    digitalWrite(I2S_PIN_WS, LOW);
    pinMode(I2S_PIN_DATA, OUTPUT);
    digitalWrite(I2S_PIN_DATA, LOW);

    Serial.printf("[SYSTEM] Underrun detected (%d bytes). Resetting and cool-down...\n", avail);
  }

  if (!playback_started)
  {
    // Force a 50ms cool-down period to let physical USB memory fill up.
    if (millis() - last_reset_ms < 50)
    {
      return;
    }
    if (avail >= CENTER_LIMIT)
    {
      playback_started = true;
      
      // Start I2S output when playback starts
      i2s_out.begin(AUDIO_SAMPLE_RATE);

      Serial.printf("[SYSTEM] Pre-buffering complete. Starting play. Capacity: %d bytes\n", TOTAL_CAPACITY);
    }
    else
    {
      return; // Keep buffering and wait, leaving I2S clock at nominal
    }
  }

  // Actively track and correct the clock frequency based on buffer watermarks
  adjust_i2s_clock(usb_in.available());

  // Pacing Control: Consume 256 bytes *only* when both:
  // 1) USB stream has at least 256 bytes available, AND
  // 2) Native I2S DMA queue has space to accept at least 256 bytes without blocking.
  if (avail >= DATA_CHUNK_SIZE && i2s_out.availableForWrite() >= DATA_CHUNK_SIZE)
  {
    int to_read = DATA_CHUNK_SIZE;
    to_read = (to_read / 4) * 4; // Align to 4-byte frame boundaries (Stereo 16-bit)

    int read_bytes = usb_in.readBytes(copy_buf, to_read);
    if (read_bytes > 0)
    {
      int16_t *samples = (int16_t *)copy_buf;
      int num_frames = read_bytes / 4;
      for (int i = 0; i < num_frames; i++)
      {
        uint16_t data_left = samples[2 * i];
        uint16_t data_right = samples[2 * i + 1];
        i2s_out.write16(data_left, data_right);
      }
    }
  }
}
