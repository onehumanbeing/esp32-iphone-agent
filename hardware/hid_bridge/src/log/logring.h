#pragma once
// The board's recent log in RAM: newest lines win, read back in pages over BLE (`logs <offset>`), so a board
// plugged into the phone can hand its history to the app or the CLI without a serial cable.
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  char *buf;
  size_t size;
  uint32_t start, end;  // absolute byte offsets of the oldest kept byte and of the next byte to write
} logring;

void logring_init(logring *r, char *buf, size_t size);
void logring_add(logring *r, const char *line);  // appends line + '\n'
// Copies kept bytes from absolute offset `from` (raised to the oldest kept line) into out, escaping '\n' as
// "\n" and '\\' as "\\\\", at most max - 1 chars plus a NUL. Returns the offset to read from next.
uint32_t logring_read(const logring *r, uint32_t from, char *out, size_t max);

#ifdef __cplusplus
}
#endif
