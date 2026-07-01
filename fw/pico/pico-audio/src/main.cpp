#include <Arduino.h>
#include "AudioTools.h"
#include "AudioTools/Communication/USB/USBAudioStream.h"
#include "pico/util/queue.h"
#include <I2S.h>

// -----------------------------------------------------------------------------
// Configuration Constants
// -----------------------------------------------------------------------------
#define I2S_PIN_BCK  0  
#define I2S_PIN_WS   1  
#define I2S_PIN_DATA 2  

#define SAMPLE_RATE     48000
#define CHANNELS        2
#define BITS_PER_SAMPLE 16

#define QUEUE_DEPTH     8192 // Cross-core FIFO buffer depth (samples)

// -----------------------------------------------------------------------------
// Global Instances
// -----------------------------------------------------------------------------
AudioInfo info(SAMPLE_RATE, CHANNELS, BITS_PER_SAMPLE);
USBAudioStream usb_in;   // UAC2 device interface
I2S i2s_out(OUTPUT);     // RP2040/RP2350 hardware-accelerated I2S
queue_t audio_queue;

// -----------------------------------------------------------------------------
// Core 0 (Main Core): USB Audio Reception & Buffer Enqueue
// -----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);

  // Initialize safe cross-core communication queue
  queue_init(&audio_queue, sizeof(uint32_t), QUEUE_DEPTH);

  // Initialize TinyUSB Device
  if (!TinyUSBDevice.isInitialized()) {
    TinyUSBDevice.begin(0);
  }

  // Configure USB Audio Stream (RX Only)
  auto usb_cfg = usb_in.defaultConfig(RX_MODE);
  usb_cfg.copyFrom(info);
  usb_cfg.product = "Pico USB-I2S DAC";
  
  // Disable feedback EP to prevent host PC throttling
  usb_cfg.enable_feedback_ep = false;
  
  usb_in.begin(usb_cfg);
  Serial.println("Core 0: USB Audio initialized.");

  // Re-enumerate USB connection to trigger host detection
  if (TinyUSBDevice.mounted()) {
    TinyUSBDevice.detach();
    delay(100);
    TinyUSBDevice.attach();
  }
}

void loop() {
  // Process USB events (runs callbacks synchronously in Main thread)
  tud_task();

  int avail = usb_in.available();
  avail = (avail / 4) * 4; // Align to 4-byte frames (stereo 16-bit)
  
  if (avail > 0) {
    static uint32_t temp_buf[256]; // 4-byte aligned temporary buffer
    int max_to_read = sizeof(temp_buf);
    int to_read = (avail > max_to_read) ? max_to_read : avail;
    
    int read_bytes = usb_in.readBytes((uint8_t*)temp_buf, to_read);
    
    int samples_read = read_bytes / 4;
    for (int i = 0; i < samples_read; i++) {
      if (!queue_try_add(&audio_queue, &temp_buf[i])) {
        break; // Stop pushing if queue is full (overrun)
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Core 1 (Sub Core): Direct I2S Hardware Playback
// -----------------------------------------------------------------------------
void setup1() {
  delay(500); // Allow Core 0 setup completion

  // Configure hardware-accelerated I2S driver
  i2s_out.setBCLK(I2S_PIN_BCK);
  i2s_out.setDATA(I2S_PIN_DATA);
  i2s_out.setBuffers(8, 512); // 8 DMA buffers, 512 bytes each
  
  if (!i2s_out.begin(SAMPLE_RATE)) {
    Serial.println("Core 1: Direct I2S initialization failed!");
    while (1) delay(100);
  }
  
  Serial.println("Core 1: Direct I2S initialized.");
}

void loop1() {
  uint32_t sample;
  // Block Core 1 until a sample is available in the queue from Core 0.
  queue_remove_blocking(&audio_queue, &sample);
  
  // Write the sample to I2S (blocks naturally matching exact 48kHz clock)
  i2s_out.write(sample, true);
}
