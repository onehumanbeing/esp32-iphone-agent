#pragma once
// --dual-hid: the mouse, keyboard and consumer control the command handler calls, sent to USB or BLE by this
// boot's mode (hid_mode.h). The USB HID interfaces exist in both modes (the descriptor is fixed before setup(),
// see hid_dual.cpp); in BLE mode nothing is sent on them.
#ifdef HID_DUAL
#include <Arduino.h>
#include "ble_hid.h"

void hid_dual_begin();  // after hid_mode_load(), before USB.begin()

class DualMouse {
public:
  void begin() {}
  void move(int8_t x, int8_t y, int8_t wheel = 0, int8_t pan = 0);
  void press(uint8_t buttons);
  void release(uint8_t buttons);
};

class DualKeyboard {
public:
  void begin() {}
  size_t press(uint8_t key);
  void releaseAll();
  size_t write(uint8_t value);
};

class DualConsumer {
public:
  void begin() {}
  void press(uint16_t usage);
  void release();
};
#endif
