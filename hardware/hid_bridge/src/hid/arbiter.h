#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// One side drives the phone at a time. The app wins: while its link is up the CLI is refused, and a CLI session
// that is up when the app connects is ended. docs/cli-protocol.md, "Sharing the phone with the app".
enum { ARB_NONE = -1, ARB_APP = 0, ARB_CLI = 1 };

typedef struct {
  int pressed;  // side holding the mouse button, ARB_NONE if none
} arb_state;

void arb_init(arb_state *s);
int arb_owner(bool app, bool cli);  // app link up / CLI session up -> ARB_APP, ARB_CLI or ARB_NONE
const char *arb_owner_name(int owner);
bool arb_allowed(int side, bool app);  // false: answer "err busy: the app is using the board"
void arb_after(arb_state *s, int side, const char *cmd, bool ok);
bool arb_gone(arb_state *s, int side);  // that side left: true if it held the button (release it)

#ifdef __cplusplus
}
#endif
