#pragma once
// Which link carries the phone's mouse and keyboard.
//   flash.sh             USB HID, always
//   flash.sh --ble-hid   BLE HID, always (also --note4)
//   flash.sh --dual-hid  both compiled in; the mode is read from NVS at boot and changed with `hidmode usb|ble`,
//                        which saves it and restarts the board (docs/hid-mode-switch.md)
#ifdef HID_DUAL
#ifndef HID_TRANSPORT_BLE
#error "HID_DUAL needs HID_TRANSPORT_BLE (flash.sh --dual-hid sets both)"
#endif
void hid_mode_load();         // once, before USB.begin() and ble_begin()
bool hid_ble();               // this boot's mode; fixed until the next restart
bool hid_mode_changed();      // this boot is the first one after `hidmode` switched it
bool hid_mode_save(bool ble);  // takes effect at the next boot
#elif defined(HID_TRANSPORT_BLE)
inline bool hid_ble() { return true; }
#else
inline bool hid_ble() { return false; }
#endif
