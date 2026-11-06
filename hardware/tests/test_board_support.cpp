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
  puts("电池电压估算范围检查通过");

  // 非 Note 4 目标可在没有 Arduino/GPIO API 的宿主上运行，不会误读电池或操作电源。
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
