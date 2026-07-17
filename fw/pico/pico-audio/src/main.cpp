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

// USB ring buffer capacity, detected at runtime from the library config.
int TOTAL_CAPACITY = 0;
int CENTER_LIMIT = 0; // 50% target center

void setup()
{
  // Initialize Serial for non-blocking debugging log
  Serial.begin(115200);

  // Required on cores without automatic TinyUSB initialization
  if (!TinyUSBDevice.isInitialized())
  {
    TinyUSBDevice.begin(0);
  }

  // Configure USB Audio Stream as Receiver (Speaker device on PC)
  auto usb_cfg = usb_in.defaultConfig(RX_MODE);
  usb_cfg.copyFrom(info);
  usb_cfg.product = "Pico I2S DAC";
  usb_cfg.enable_feedback_ep = true;
  usb_cfg.volume_active = true;
  usb_in.begin(usb_cfg);

  // Detect actual FIFO capacity from the library (packetSize * fifo_packets, rounded up to power of 2)
  // audioPacketSize() is public; fifo_packets comes from the config we just applied.
  {
    int p = 256;
    int sz = (int)usb_in.audioPacketSize() * (int)usb_cfg.fifo_packets;
    while (p < sz)
      p <<= 1;
    TOTAL_CAPACITY = p;
  }
  CENTER_LIMIT = TOTAL_CAPACITY / 2;

  // Configure I2S Output
  i2s_out.setSlave();
  i2s_out.setBCLK(I2S_PIN_BCK);
  i2s_out.setDATA(I2S_PIN_DATA);
  i2s_out.setBitsPerSample(16);
  // Set buffer: 8 buffers, 256 words (1024 bytes) each -> total 8192 bytes DMA queue
  i2s_out.setBuffers(8, 256, 0);

  if (!i2s_out.begin(AUDIO_SAMPLE_RATE))
  {
    Serial.println("[ERROR] I2S begin() failed");
  }
}

void report_usb_buffer(int avail)
{
  uint32_t now = millis();

  // Throttled periodic status report (once per 1000 milliseconds)
  static uint32_t last_report_ms = 0;
  if (now - last_report_ms >= 1000)
  {
    last_report_ms = now;
    Serial.printf("[STATUS] Buffer Level: %d | Center: %d | Capacity: %d | I2S Freq: %d Hz\n",
                  avail, CENTER_LIMIT, TOTAL_CAPACITY, AUDIO_SAMPLE_RATE);
  }
}

// Single-Core loop: Handles USB task and copies data directly to native I2S with Pacing Control & Cool-down
void loop()
{
  static bool playback_started = false;
  const int DATA_CHUNK_SIZE = 256;
  static uint8_t copy_buf[DATA_CHUNK_SIZE];
  int avail = usb_in.available();
  report_usb_buffer(avail);

  if (playback_started && avail < DATA_CHUNK_SIZE)
  {
    playback_started = false;
  }
  if (!playback_started)
  {
    if (avail >= CENTER_LIMIT)
    {
      playback_started = true;
    }
    else
    {
      return; // Keep buffering and wait, leaving I2S clock at nominal
    }
  }

  if (avail >= DATA_CHUNK_SIZE && i2s_out.availableForWrite() >= DATA_CHUNK_SIZE)
  {
    int read_bytes = usb_in.readBytes(copy_buf, DATA_CHUNK_SIZE);
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
