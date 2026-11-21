#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

// The app descriptor follows the 24-byte image and 8-byte segment headers. Bootloaders and full-flash images do not belong in an app slot.
constexpr size_t USB_APP_PREFIX_SIZE = 304;
// An app image for one release channel: its target marker (board_support.cpp) and flash size (the high nibble of
// byte 3: 3 = 8 MiB, 4 = 16 MiB).
inline bool ota_app_for(const uint8_t *p, size_t n, const char *target, uint8_t flash) {
  if (n < USB_APP_PREFIX_SIZE || p[0] != 0xe9 || (p[3] >> 4) != flash ||
      p[12] != 9 || p[13] != 0 || p[32] != 0x32 || p[33] != 0x54 || p[34] != 0xcd || p[35] != 0xab) return false;
  char want[16] = {0};
  strncpy(want, target, sizeof want - 1);
  if (memcmp(p + 288, "ESPA:", 5) == 0) return memcmp(p + 288, want, sizeof want) == 0;
  // Accept older Arduino USB releases, but never use the legacy check for a marked target.
  const char legacy[32] = "arduino-lib-builder";
  return !strcmp(target, "ESPA:usb-8m") && memcmp(p + 80, legacy, sizeof legacy) == 0;
}
inline bool usb_ota_app(const uint8_t *p, size_t n) { return ota_app_for(p, n, "ESPA:usb-8m", 3); }
// The M5Stack StopWatch (16 MiB, BLE HID): its own channel, never a USB image and never one for another board.
inline bool stopwatch_ota_app(const uint8_t *p, size_t n) { return ota_app_for(p, n, "ESPA:stopwatch", 4); }
