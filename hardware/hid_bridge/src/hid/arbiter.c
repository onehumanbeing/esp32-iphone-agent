#include "arbiter.h"
#include <string.h>

void arb_init(arb_state *s) { s->pressed = ARB_NONE; }

int arb_owner(bool app, bool cli) { return app ? ARB_APP : cli ? ARB_CLI : ARB_NONE; }

const char *arb_owner_name(int owner) { return owner == ARB_APP ? "app" : owner == ARB_CLI ? "cli" : "none"; }

bool arb_allowed(int side, bool app) { return side == ARB_APP || !app; }

void arb_after(arb_state *s, int side, const char *cmd, bool ok) {
  if (!ok) return;
  if (strcmp(cmd, "press") == 0) s->pressed = side;
  else if ((strcmp(cmd, "release") == 0 || strcmp(cmd, "click") == 0) && s->pressed == side) s->pressed = ARB_NONE;
}

bool arb_gone(arb_state *s, int side) {
  if (s->pressed != side) return false;
  s->pressed = ARB_NONE;
  return true;
}
