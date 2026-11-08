#include "../hid_bridge/board_support.h"
#include "../hid_bridge/note4_battery.h"
#include <cstdio>
#include <cassert>
#include <cstring>

int main() {
  assert(note4_battery_percent(0) == 0);
  assert(note4_battery_percent(3300) == 0);
  assert(note4_battery_percent(3700) == 48);
  assert(note4_battery_percent(4200) == 100);
  assert(note4_battery_percent(65535) == 100);
  puts("Battery level estimates stayed within range");

  // Non-Note 4 targets must run on a host without Arduino or GPIO, without touching battery or power pins.
  board_begin();
  assert(board_battery_percent() == 0);
  assert(strcmp(board_status_fields(), "") == 0);
#ifdef HID_TRANSPORT_BLE
  assert(!board_supports_usb_release());
  assert(strcmp(firmware_target, "ESPA:ble-8m") == 0);
#else
  assert(board_supports_usb_release());
  assert(strcmp(firmware_target, "ESPA:usb-8m") == 0);
#endif
}
