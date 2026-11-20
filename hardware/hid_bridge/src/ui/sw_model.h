#pragma once
// M5Stack StopWatch screen and buttons, without the hardware (stopwatch_ui.cpp draws and reads it): the app's
// `ui <json>` lines (docs/ble-protocol.md, "StopWatch screen"), what the screen shows, and which `btn` line a
// press sends. Pure C, host tested in hardware/tests.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum sw_mood { SW_SLEEPING, SW_IDLE, SW_LISTENING, SW_THINKING, SW_ACTING, SW_SUCCESS, SW_FAILURE, SW_DIZZY,
               SW_CONTENT, SW_WINK };
enum sw_phase { SW_RUNNING, SW_HELP, SW_COUNTDOWN, SW_RECORDING, SW_PAUSED, SW_RESUMING, SW_STANDBY };
enum { SW_TEXT_MAX = 80, SW_PICK_MAX = 24, SW_PICKS = 3 };

typedef struct {
  uint8_t mood, phase;
  int32_t step, limit, done, total;  // done/total: 0 when not sent
  bool finished;
  char text[SW_TEXT_MAX + 1];        // UTF-8, cut at a character boundary
  bool has_picks;                    // `k` was in this line (else the last picks stay)
  uint8_t npicks;
  char picks[SW_PICKS][SW_PICK_MAX + 1];
} sw_ui;

enum sw_parsed { SW_PARSE_BAD, SW_PARSE_UI, SW_PARSE_OFF };
int sw_parse(const char *arg, sw_ui *out);  // the argument of `ui`: a JSON object or `off`

enum sw_screen { SW_SCR_IDLE, SW_SCR_RUN, SW_SCR_HELP, SW_SCR_PAUSED, SW_SCR_OK, SW_SCR_FAIL, SW_SCR_CONFIRM,
                 SW_SCR_SHAKE };
enum sw_buzz { SW_BUZZ_NONE, SW_BUZZ_HELP, SW_BUZZ_OK, SW_BUZZ_FAIL };
enum sw_input { SW_IN_YELLOW, SW_IN_BLUE_DOWN, SW_IN_BLUE_UP, SW_IN_TAP, SW_IN_SWIPE_UP, SW_IN_SHAKE };

enum {
  SW_STALE_MS = 10000,     // no `ui` line this long: the screen goes idle
  SW_DONE_MS = 5000,       // the check or cross after a finished task
  SW_PICK_MS = 3000,       // a pick or its confirmation without a press is cancelled
  SW_HOME_MS = 500,        // blue released before this: `btn home`; later and before SW_STOP_MS: nothing
  SW_STOP_MS = 2000,       // blue held this long: `btn stop`
  SW_RING_MS = 300,        // the stop ring shows from here on
  SW_SHAKE_MS = 1000,      // "shake to stop?" shows this long before `btn stop`
  SW_SHAKE_GAP_MS = 2000,  // one shake per this
};

typedef struct {
  sw_ui ui;
  bool live;  // a `ui` line came and no `ui off` since
  uint32_t ui_at;
  bool done;
  uint32_t done_at;
  uint8_t done_kind;  // SW_SCR_OK or SW_SCR_FAIL
  int8_t sel;         // selected pick, -1: none
  bool confirm;
  uint32_t sel_at;
  uint8_t next_pick;
  bool blue_down, blue_fired, blue_ignore;
  uint32_t blue_at;
  bool shaking, shook;
  uint32_t shake_at;
} sw_ctl;

void sw_init(sw_ctl *c);
int sw_apply(sw_ctl *c, const sw_ui *ui, bool off, uint32_t now);  // a parsed line; returns an sw_buzz
bool sw_input(sw_ctl *c, int input, uint32_t now, char *out, size_t n);  // true: out holds a `btn ...` line
bool sw_tick(sw_ctl *c, uint32_t now, char *out, size_t n);             // timeouts; true: out holds a line
bool sw_running(const sw_ctl *c, uint32_t now);
int sw_screen(const sw_ctl *c, uint32_t now);
int sw_progress(const sw_ui *ui);                     // 0-1000 around the ring, -1: none
int sw_hold(const sw_ctl *c, uint32_t now);           // 0-1000 of the blue stop hold, -1: not shown

#ifdef __cplusplus
}
#endif
