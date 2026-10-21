#include "arbiter.h"
#include <string.h>

static bool is(const char *cmd, const char *name) { return strcmp(cmd, name) == 0; }

// Commands whose effect depends on where the pointer is.
static bool aimed(const char *cmd) {
  return is(cmd, "move") || is(cmd, "press") || is(cmd, "click") || is(cmd, "scroll");
}

static bool hid(const char *cmd) { return !is(cmd, "ping"); }

void arb_init(arb_state *s) {
  memset(s, 0, sizeof *s);
  s->mover = s->pressed = -1;
}

bool arb_app_busy(const arb_state *s, uint32_t now) { return s->appSeen && now - s->appAt < ARB_LEASE_MS; }

arb_plan arb_before(arb_state *s, int side, const char *cmd, uint32_t now) {
  arb_plan plan = {0};
  if (!hid(cmd)) return plan;
  if (side == ARB_CLI && arb_app_busy(s, now)) {
    plan.refuse = true;
    return plan;
  }
  if (side == ARB_APP) {
    s->appSeen = true;
    s->appAt = now;
  }
  if (s->pressed >= 0 && s->pressed != side) {
    plan.release = true;
    s->pressed = -1;
  }
  arb_pointer *p = &s->p[side];
  if (aimed(cmd) && s->mover >= 0 && s->mover != side && p->known) {
    plan.restore = true;
    plan.x = p->x;
    plan.y = p->y;
  }
  if (aimed(cmd) || is(cmd, "home")) s->mover = side;
  return plan;
}

void arb_after(arb_state *s, int side, const char *cmd, long a, long b, bool ok) {
  arb_pointer *p = &s->p[side];
  if (!ok) {  // e.g. the phone's USB asleep: the side can't tell where the pointer went
    if (aimed(cmd) || is(cmd, "home")) p->known = false;
    return;
  }
  if (is(cmd, "home")) {
    p->known = true;
    p->x = p->y = 0;
  } else if (is(cmd, "move")) {
    p->x += a;
    p->y += b;
  } else if (is(cmd, "press")) {
    s->pressed = side;
  } else if (is(cmd, "release") || is(cmd, "click")) {
    if (s->pressed == side) s->pressed = -1;
  }
}

bool arb_gone(arb_state *s, int side) {
  s->p[side].known = false;  // mover stays: the pointer is still where that side left it
  if (side == ARB_APP) s->appSeen = false;
  if (s->pressed != side) return false;
  s->pressed = -1;
  return true;
}
