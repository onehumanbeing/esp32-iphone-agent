#include "../hid_bridge/board_support.h"
#include "../hid_bridge/note4_battery.h"
#include <cstdio>
#include <cassert>
#include <cstring>

#ifdef M5_STOPWATCH
// The screen task's side (stopwatch_ui.cpp needs M5Unified): board_support only forwards to it.
#include "../hid_bridge/stopwatch_ui.h"
static int begun;
void stopwatch_begin() { begun++; }
uint8_t stopwatch_battery() { return 87; }
#endif

int main() {
  assert(note4_battery_percent(0) == 0);
  assert(note4_battery_percent(3300) == 0);
  assert(note4_battery_percent(3700) == 48);
  assert(note4_battery_percent(4200) == 100);
  assert(note4_battery_percent(65535) == 100);
  puts("Battery level estimates stayed within range");

#ifdef M5_STOPWATCH
  board_begin();
  assert(begun == 1 && board_battery_percent() == 87);
  assert(strcmp(board_status_fields(), ",\"board\":\"stopwatch\",\"ui\":1,\"ota\":1") == 0);
  assert(!board_supports_usb_release());
  assert(strcmp(firmware_target, "ESPA:stopwatch") == 0);
  puts("StopWatch board hooks reach the screen task");
  return 0;
#endif
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
