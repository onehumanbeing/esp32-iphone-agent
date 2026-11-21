#include "sw_warn.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it
#include <string.h>

int sw_warn_parse(const char *s) {
  if (!s) return SW_W_NONE;
  return !strcmp(s, "mirror") ? SW_W_MIRROR : !strcmp(s, "locked") ? SW_W_LOCKED : !strcmp(s, "hid") ? SW_W_HID : SW_W_NONE;
}

void sww_init(sw_warn *w) {
  memset(w, 0, sizeof *w);
  w->hid_was = true;  // the first frame's state is not a drop
}

bool sww_update(sw_warn *w, int app, bool hid, bool busy) {
  if (hid) w->local = SW_W_NONE;
  else if (w->hid_was && busy) w->local = SW_W_HID;
  w->hid_was = hid;
  w->app = (uint8_t)app;
  int cur = w->local ? w->local : w->app;
  if (cur == w->cur) return false;
  w->cur = (uint8_t)cur, w->hidden = false;  // another one (or none): shown again
  return cur != SW_W_NONE;
}

int sww_shown(const sw_warn *w) { return w->hidden ? SW_W_NONE : w->cur; }

void sww_hide(sw_warn *w) { w->hidden = true; }
#endif
