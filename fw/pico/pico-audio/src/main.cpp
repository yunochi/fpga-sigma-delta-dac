#include <Arduino.h>
#include "AudioTools.h"
#include "AudioTools/Communication/USB/USBAudioStream.h"

// Define audio format: 48000 Hz, 2 channels, 16-bit PCM
AudioInfo info(48000, 2, 16);

USBAudioStream usb_in;   // USB Audio Source (Receives audio from PC)
I2SStream i2s_out;       // I2S Sink (Sends audio to external DAC)
StreamCopy copier(i2s_out, usb_in); // Copies audio data from USB to I2S

// Define I2S GPIO pins for RP2350 / RP2040
// You can change these pins to match your hardware connections.
#define I2S_PIN_BCK  0  // GP22 (BCLK/BCK)
#define I2S_PIN_WS   1  // GP21 (LRCK/WS)
#define I2S_PIN_DATA 2  // GP20 (DIN/SD)

void setup() {
  // Start serial communication for debugging
  Serial.begin(115200);
  
  // Required on cores without automatic TinyUSB initialization
  if (!TinyUSBDevice.isInitialized()) {
    TinyUSBDevice.begin(0);
  }

  // 1. Configure USB Audio Stream as Receiver (Speaker device on PC)
  auto usb_cfg = usb_in.defaultConfig(RX_MODE);
  usb_cfg.copyFrom(info);
  usb_cfg.product = "Pico I2S DAC";
  usb_cfg.enable_feedback_ep = true; // Enable feedback endpoint for synchronization
  usb_in.begin(usb_cfg);

  // 2. Configure I2S Output Stream
  auto i2s_cfg = i2s_out.defaultConfig(TX_MODE);
  i2s_cfg.copyFrom(info);
  i2s_cfg.pin_data = I2S_PIN_DATA;
  i2s_cfg.pin_ws = I2S_PIN_WS;
  i2s_cfg.pin_bck = I2S_PIN_BCK;
  
  // Start I2S
  i2s_out.begin(i2s_cfg);


  Serial.println("USB Audio to I2S Bridge Initialized!");

  // Re-enumerate USB to force the host computer to detect the new audio interface
  if (TinyUSBDevice.mounted()) {
    TinyUSBDevice.detach();
    delay(100);
    TinyUSBDevice.attach();
  }
}

unsigned long last_print = 0;
void loop() {
  TinyUSBDevice.task(); // Handle USB tasks (required for TinyUSB)
  // Read from USB and write to I2S
  copier.copy();

  if (millis() - last_print > 1000) {
    last_print = millis();
    Serial.print("USB Avail: ");
    Serial.println(usb_in.available());
  }
}
