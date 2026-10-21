#pragma once
// Who drives the phone: the app and the CLI share one USB mouse and keyboard. The app always wins (it runs
// unchanged and must never see a new error); the CLI is refused while the app is active. Each side keeps its own
// idea of where the pointer is (dead reckoning from its last `home`), so the board puts the pointer back where
// a side left it before that side's next pointer command, and neither notices the other.
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { ARB_APP = 0, ARB_CLI = 1 };
#define ARB_LEASE_MS 20000  // the app counts as active this long after its last HID command (a run thinks between steps)

typedef struct {
  bool known;  // the side homed since its link came up, and every move since succeeded
  long x, y;   // mouse units from the top-left corner
} arb_pointer;

typedef struct {
  arb_pointer p[2];
  int mover;    // side that moved the pointer last, -1 none
  int pressed;  // side holding the mouse button, -1 none
  bool appSeen;
  uint32_t appAt;
} arb_state;

typedef struct {
  bool refuse;   // the app holds the phone: answer "err busy"
  bool release;  // let go of the button the other side left held
  bool restore;  // home, then move (x, y): the pointer where this side left it
  long x, y;
} arb_plan;

void arb_init(arb_state *s);
// Before HID command cmd (its first word) from side; a refused command must not run.
arb_plan arb_before(arb_state *s, int side, const char *cmd, uint32_t now);
// After it ran (ok: the board answered "ok"); a, b: the move's deltas.
void arb_after(arb_state *s, int side, const char *cmd, long a, long b, bool ok);
// The side's link went down: true when it held the button (the caller releases it).
bool arb_gone(arb_state *s, int side);
// 1 while the app holds the phone (for the CLI's status).
bool arb_app_busy(const arb_state *s, uint32_t now);

#ifdef __cplusplus
}
#endif
