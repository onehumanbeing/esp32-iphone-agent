#pragma once
// Per-command typing budget. The task watchdog is 8 s and is reset at the top of loop(); a long
// `type` used to run inside that loop without feeding it. These limits keep one command well under
// the watchdog. Initial estimates: 4 s is half the watchdog, and USB is re-checked every 16 characters.
// Host-tested. The firmware feeds the watchdog itself after each character.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

enum { TYPE_BUDGET_MS = 4000, TYPE_USB_EVERY = 16 };

typedef enum { TYPE_GO = 0, TYPE_STOP_BUDGET = 1, TYPE_STOP_ASLEEP = 2 } type_stop_t;

// Before writing character `index` (0-based). `elapsed_ms` is time since the command started.
// `usb_ok` is 1 when the phone's USB is mounted and not suspended.
static inline type_stop_t type_before_char(int index, uint32_t elapsed_ms, int usb_ok) {
  if (index > 0 && (index % TYPE_USB_EVERY) == 0 && !usb_ok) return TYPE_STOP_ASLEEP;
  if (elapsed_ms >= (uint32_t)TYPE_BUDGET_MS) return TYPE_STOP_BUDGET;
  return TYPE_GO;
}

// "ok" when the whole string was typed, else "err typed N of M: budget|asleep".
// Old apps treat any err as a failed command; new apps type the rest as another command.
static inline int type_reply(char *out, size_t n, int typed, int total, type_stop_t why) {
  if (why == TYPE_GO) return snprintf(out, n, "ok");
  const char *reason = why == TYPE_STOP_ASLEEP ? "asleep" : "budget";
  return snprintf(out, n, "err typed %d of %d: %s", typed, total, reason);
}
