#pragma once
#include <stdint.h>

// Voltage curve from Zectrix Lab's reference firmware; see LICENSE-ZECTRIX.
inline uint8_t note4_battery_percent(int mv) {
  if (mv <= 3300) return 0;
  if (mv >= 4200) return 100;
  int percent = (-mv * mv + 9016 * mv - 19189000) / 10000;
  return percent < 0 ? 0 : percent > 100 ? 100 : percent;
}
