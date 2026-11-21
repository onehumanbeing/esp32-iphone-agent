#pragma once
// The StopWatch's connection alerts (docs/ble-protocol.md, "StopWatch screen"): a paused run's lost link the app
// reports (`w`: Screen Mirroring, the iPhone locked, the Bluetooth pointer) and the board's own Bluetooth dropping
// while it was in use. One buzz when one appears; blue hides it until another comes. Pure C, host tested.
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum sw_warn_code { SW_W_NONE, SW_W_MIRROR, SW_W_LOCKED, SW_W_HID };

typedef struct {
  uint8_t app;        // the app's `w`, while its lines come
  uint8_t local;      // SW_W_HID: Bluetooth to the phone dropped while a run or the app used it
  uint8_t cur;        // the alert now (local first)
  bool hidden;        // blue hid it (until another comes)
  bool hid_was;
} sw_warn;

int sw_warn_parse(const char *s);  // "mirror", "locked", "hid"; anything else: SW_W_NONE
void sww_init(sw_warn *w);
// Each frame: the app's code (SW_W_NONE without the app), whether Bluetooth HID is up, whether it was in use (a run,
// the app's lines). True: a new alert shows, buzz once.
bool sww_update(sw_warn *w, int app, bool hid, bool busy);
int sww_shown(const sw_warn *w);   // the alert on screen, SW_W_NONE: none
void sww_hide(sw_warn *w);         // blue

#ifdef __cplusplus
}
#endif
