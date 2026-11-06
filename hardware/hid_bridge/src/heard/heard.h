// What the app heard on the phone (its transcripts of AirPlay audio), kept for the CLI: the app sends
// `heard <text>`, the CLI asks `heard` (docs/cli-protocol.md, "Phone audio"). Plain C for the host tests.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HEARD_LINES 8
#define HEARD_TEXT 400
#define HEARD_KEEP_MS 60000u

typedef struct {
  uint32_t ms[HEARD_LINES];  // board millis when it arrived
  char text[HEARD_LINES][HEARD_TEXT + 1];
  unsigned next, count;
} heard_ring;

void heard_add(heard_ring *r, uint32_t now_ms, const char *text, size_t n);
void heard_clear(heard_ring *r);
// {"app":0|1,"lines":[{"ago":ms,"t":"..."},...]}, newest first, only lines under HEARD_KEEP_MS old and only as many
// as fit in cap (always a whole JSON object). Returns its length.
size_t heard_json(const heard_ring *r, uint32_t now_ms, bool app, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
