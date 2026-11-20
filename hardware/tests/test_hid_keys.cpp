#include "../hid_bridge/hid_keys.h"
#include "../hid_bridge/ble_hid_target.h"
#include "../hid_bridge/ota_image.h"
#include <cassert>
#include <cstring>
#include <cstdio>

int main() {
  uint8_t layout[128] = {}, report[8] = {};
  layout['h'] = 0x0b;
  layout['H'] = 0x8b;
  assert(hid_key_press(report, 0x83, layout));
  assert(hid_key_press(report, 'h', layout));
  assert(report[0] == 8 && report[2] == 0x0b);
  assert(hid_key_press(report, 'h', layout) && report[3] == 0);
  memset(report, 0, sizeof report);
  assert(hid_key_press(report, 'H', layout));
  assert(report[0] == 2 && report[2] == 0x0b);
  memset(report, 0, sizeof report);
  assert(hid_key_press(report, 0xb0, layout) && report[2] == 0x28);
  for (int i = 0; i < 8; i++) report[i] = i;
  uint8_t before[8];
  memcpy(before, report, sizeof report);
  assert(!hid_key_press(report, 0, layout));
  assert(memcmp(before, report, sizeof report) == 0);
  assert(!hid_key_press(report, 0xc2, layout));
  assert(memcmp(before, report, sizeof report) == 0);
  puts("BLE HID keycode, modifier, six-key limit and error handling checks passed");
  BleHidTarget target;
  assert(!target.allows(1, false));
  assert(!target.subscribe(2, false, true));  // An untrusted subscriber cannot claim the target.
  assert(!target.subscribe(1, true, false));  // A trusted peer must subscribe before it can receive HID.
  assert(target.subscribe(1, true, true));    // Subscription and authentication can arrive in either order.
  const auto first = target.session();
  assert(target.allows(1, true));
  assert(!target.allows(1, false));
  assert(!target.allows(2, true));  // A second bonded central cannot control the first phone.
  assert(!target.subscribe(2, true, true));
  target.disconnect(2);
  assert(target.session() == first);
  target.disconnect(1);
  assert(BleHidTarget::peer(target.session()) == -1);
  assert(target.subscribe(1, true, true) && target.session() != first);  // Reconnect invalidates old queued commands.
  puts("BLE HID target selection, writer rejection and reconnect checks passed");
  uint8_t header[USB_APP_PREFIX_SIZE] = {0xe9, 6, 2, 0x3f};
  header[12] = 9;
  memcpy(header + 32, "\x32\x54\xcd\xab", 4);
  memcpy(header + 80, "arduino-lib-builder", 19);
  assert(usb_ota_app(header, sizeof header));
  memcpy(header + 288, "ESPA:usb-8m", 12);
  assert(usb_ota_app(header, sizeof header));
  memcpy(header + 288, "ESPA:ble-8m", 12);
  assert(!usb_ota_app(header, sizeof header));
  memcpy(header + 288, "ESPA:unknown", 13);
  assert(!usb_ota_app(header, sizeof header));
  memset(header + 288, 0, 16);
  header[80] = 'X';
  assert(!usb_ota_app(header, sizeof header));
  header[80] = 'a';
  assert(!usb_ota_app(header, sizeof header - 1));
  header[3] = 0x4f;
  assert(!usb_ota_app(header, sizeof header));  // Reject a 16 MiB Note 4 image.
  header[3] = 0x3f;
  header[32] = 0;
  assert(!usb_ota_app(header, sizeof header));  // Reject bootloaders and full-flash images.
}
