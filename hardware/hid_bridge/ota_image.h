#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

// The app descriptor follows the 24-byte image and 8-byte segment headers. Bootloaders and full-flash images do not belong in an app slot.
constexpr size_t USB_APP_PREFIX_SIZE = 304;
inline bool usb_ota_app(const uint8_t *p, size_t n) {
  if (n < USB_APP_PREFIX_SIZE || p[0] != 0xe9 || (p[3] >> 4) != 3 ||
      p[12] != 9 || p[13] != 0 || p[32] != 0x32 || p[33] != 0x54 || p[34] != 0xcd || p[35] != 0xab) return false;
  const char usb[16] = "ESPA:usb-8m";
  if (memcmp(p + 288, "ESPA:", 5) == 0) return memcmp(p + 288, usb, sizeof usb) == 0;
  // Accept older Arduino USB releases, but never use the legacy check for a marked target.
  const char legacy[32] = "arduino-lib-builder";
  return memcmp(p + 80, legacy, sizeof legacy) == 0;
}
