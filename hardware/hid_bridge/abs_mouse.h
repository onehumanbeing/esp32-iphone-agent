// An absolute mouse (ABS_POINTER builds): the same calls as USBHIDMouse, plus moveTo(). iOS maps X/Y straight to
// screen fractions while AssistiveTouch is on, so no homing or calibration. It ignores X/Y in a report that changes
// a button: move in one report, wait, then press (spikes/abs-touch/README.md).
#pragma once
#include "USBHID.h"

class AbsMouse : public USBHIDDevice {
public:
  static const uint16_t FULL = 32767;
  // Relative moves (`move`, the keep-awake wiggle) in screen units per mouse unit, about what a relative mouse does.
  static const int MOVE_SCALE = 50;
  // A relative move longer than the screen ends at its edge anyway; bounding it keeps a wild `move` (a paced loop
  // of 8 ms reports) far under the 8 s watchdog.
  static const long MAX_MOVE = FULL / MOVE_SCALE + 1;

  AbsMouse() { hid.addDevice(this, sizeof DESCRIPTOR); }  // must be global: USB starts before setup()
  void begin() { hid.begin(); }

  void moveTo(long x, long y) {
    x_ = constrain(x, 0, FULL);
    y_ = constrain(y, 0, FULL);
    send(0);
  }
  // Paced, for a drag: a jump is a flick to iOS, and the list flies. At a relative mouse's speed it scrolls as far
  // as it is dragged.
  // The target is clamped to the screen first, so a glide takes at most FULL / step reports (~1.1 s at 245 / 8 ms),
  // whatever the coordinates: an out-of-range drag must not hold the loop into the watchdog.
  void glideTo(long x, long y, int step, int ms) {
    x = constrain(x, 0, FULL);
    y = constrain(y, 0, FULL);
    long x0 = x_, y0 = y_;
    long n = max(labs(x - x0), labs(y - y0)) / step + 1;
    for (long i = 1; i <= n; i++) {
      moveTo(x0 + (x - x0) * i / n, y0 + (y - y0) * i / n);
      delay(ms);
    }
  }
  void move(int dx, int dy, int8_t wheel = 0, int8_t = 0) {
    if (dx || dy) moveTo(x_ + dx * MOVE_SCALE, y_ + dy * MOVE_SCALE);
    if (wheel) send(wheel);
  }
  void press(uint8_t b) { buttons_ |= b; send(0); }
  void release(uint8_t b) { buttons_ &= ~b; send(0); }
  bool held() const { return buttons_; }

  uint16_t _onGetDescriptor(uint8_t *buffer) override {
    memcpy(buffer, DESCRIPTOR, sizeof DESCRIPTOR);
    return sizeof DESCRIPTOR;
  }

private:
  static const uint8_t REPORT_ID = 10;  // USBHID.h takes 1-6
  static constexpr uint8_t DESCRIPTOR[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,  // Generic Desktop, Mouse, Application
    0x85, REPORT_ID,
    0x09, 0x01, 0xA1, 0x00,              //   Pointer, Physical
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03,  //     Buttons 1-3
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
    0x95, 0x05, 0x81, 0x03,              //     padding
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31,  //     X, Y
    0x15, 0x00, 0x26, 0xFF, 0x7F, 0x35, 0x00, 0x46, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
    0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x35, 0x00, 0x45, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,  // Wheel
    0xC0, 0xC0,
  };

  void send(int8_t wheel) {
    uint8_t r[6] = {buttons_, (uint8_t)x_, (uint8_t)(x_ >> 8), (uint8_t)y_, (uint8_t)(y_ >> 8), (uint8_t)wheel};
    hid.SendReport(REPORT_ID, r, sizeof r);
  }

  USBHID hid;
  uint8_t buttons_ = 0;
  uint16_t x_ = 0, y_ = 0;
};
