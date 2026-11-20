#ifdef HID_DUAL
#include "hid_dual.h"
#include "hid_mode.h"
#include "USBHIDMouse.h"
#include "USBHIDKeyboard.h"
#include "USBHIDConsumerControl.h"

// Static, like the USB build: CDCOnBoot runs USB.begin() in app_main() before setup(), and TinyUSB refuses an
// interface added after that ("TinyUSB has already started!"). The mode is only known in setup() (NVS), so the
// USB HID interfaces are always in the descriptor and BLE mode just never sends on them (2026-11-19: created in
// setup(), they never reached the phone; every move answered ok and no pointer showed).
static USBHIDMouse usbMouseDev;
static USBHIDKeyboard usbKeyboardDev;
static USBHIDConsumerControl usbConsumerDev;
static USBHIDMouse *usbMouse;  // set in USB mode only: the routing below
static USBHIDKeyboard *usbKeyboard;
static USBHIDConsumerControl *usbConsumer;
static BleHidMouse bleMouse;
static BleHidKeyboard bleKeyboard;
static BleHidConsumer bleConsumer;

void hid_dual_begin() {
  usbMouseDev.begin();
  usbKeyboardDev.begin();
  usbConsumerDev.begin();
  if (hid_ble()) return;
  usbMouse = &usbMouseDev;
  usbKeyboard = &usbKeyboardDev;
  usbConsumer = &usbConsumerDev;
}

void DualMouse::move(int8_t x, int8_t y, int8_t wheel, int8_t pan) {
  if (usbMouse) usbMouse->move(x, y, wheel, pan);
  else bleMouse.move(x, y, wheel, pan);
}
void DualMouse::press(uint8_t b) {
  if (usbMouse) usbMouse->press(b);
  else bleMouse.press(b);
}
void DualMouse::release(uint8_t b) {
  if (usbMouse) usbMouse->release(b);
  else bleMouse.release(b);
}

size_t DualKeyboard::press(uint8_t k) {
  if (usbKeyboard) return usbKeyboard->press(k);
  bleKeyboard.press(k);
  return 1;
}
void DualKeyboard::releaseAll() {
  if (usbKeyboard) usbKeyboard->releaseAll();
  else bleKeyboard.releaseAll();
}
size_t DualKeyboard::write(uint8_t v) { return usbKeyboard ? usbKeyboard->write(v) : bleKeyboard.write(v); }

void DualConsumer::press(uint16_t u) {
  if (usbConsumer) usbConsumer->press(u);
  else bleConsumer.press(u);
}
void DualConsumer::release() {
  if (usbConsumer) usbConsumer->release();
  else bleConsumer.release();
}
#endif
