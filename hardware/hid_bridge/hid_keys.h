#pragma once
#include <stdint.h>

// Use the Arduino layout. Invalid keys and a seventh held key leave the current report intact.
inline bool hid_key_press(uint8_t (&report)[8], uint8_t key, const uint8_t *layout) {
  if (key >= 128 && key < 136) {
    report[0] |= 1u << (key - 128);
    return true;
  }
  uint8_t modifiers = report[0];
  uint8_t usage = key >= 136 ? key - 136 : layout[key];
  if (key < 128 && (usage & 0x80)) modifiers |= 2;
  usage &= 0x7f;
  if (!usage) return false;
  for (int i = 2; i < 8; i++) {
    if (report[i] == usage) { report[0] = modifiers; return true; }
  }
  for (int i = 2; i < 8; i++) {
    if (!report[i]) { report[i] = usage; report[0] = modifiers; return true; }
  }
  return false;
}
