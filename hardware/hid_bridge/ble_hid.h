#pragma once
#ifdef HID_TRANSPORT_BLE
#include <Arduino.h>
class NimBLEServer;

void ble_hid_begin(NimBLEServer *server);
void ble_hid_disconnected(uint16_t handle);
bool ble_hid_ready();
void ble_hid_poll();
uint32_t ble_hid_session();
bool ble_hid_allows(int handle);
void ble_hid_claim(uint16_t handle, bool subscribed);
bool ble_hid_command_begin(uint32_t session);
bool ble_hid_command_ok();

// Match the USB HID interface used by the command handler.
class BleHidMouse {
public:
  void begin() {}
  void move(int8_t x, int8_t y, int8_t wheel = 0, int8_t pan = 0);
  void press(uint8_t buttons);
  void release(uint8_t buttons);
};

class BleHidKeyboard : public Print {
public:
  void begin() {}
  void press(uint8_t key);
  void releaseAll();
  size_t write(uint8_t value) override;
};

class BleHidConsumer {
public:
  void begin() {}
  void press(uint16_t usage);
  void release();
};
#endif
