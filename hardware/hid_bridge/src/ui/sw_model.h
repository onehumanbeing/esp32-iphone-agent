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
enum { SW_TEXT_MAX = 80, SW_PICK_MAX = 24, SW_PICKS = 5 };

typedef struct {
  uint8_t mood, phase;
  int32_t step, limit, done, total;  // done/total: 0 when not sent
  int32_t elapsed;                   // `e`: seconds since the run began (at the finish: its length), -1: not sent
  bool finished;
  char text[SW_TEXT_MAX + 1];        // UTF-8, cut at a character boundary
  char clock[6];                     // the phone's local time "HH:MM" when the line was sent ("": not sent)
  float look_x, look_y;              // where the eyes look, -1...1 (the island's lookX / lookY)
  bool voice;                        // `v` 1: the app takes voice (hold yellow to talk)
  bool confirm;                      // `h` 1: the help is a confirm (pay, delete): blue skips the step
  bool has_picks;                    // `k` was in this line (else the last picks stay)
  uint8_t npicks;
  char picks[SW_PICKS][SW_PICK_MAX + 1];
} sw_ui;

enum sw_parsed { SW_PARSE_BAD, SW_PARSE_UI, SW_PARSE_OFF };
int sw_parse(const char *arg, sw_ui *out);  // the argument of `ui`: a JSON object or `off`

enum sw_screen { SW_SCR_IDLE, SW_SCR_RUN, SW_SCR_HELP, SW_SCR_PAUSED, SW_SCR_OK, SW_SCR_FAIL, SW_SCR_CONFIRM,
                 SW_SCR_SHAKE, SW_SCR_STUCK, SW_SCR_VOICE, SW_SCR_ANSWER };
enum sw_buzz { SW_BUZZ_NONE, SW_BUZZ_HELP, SW_BUZZ_OK, SW_BUZZ_FAIL };
// SW_IN_YELLOW: a press as before voice. With an app that takes voice the board sends YELLOW_DOWN and YELLOW_UP:
// a short press does what YELLOW did (on release), a hold records.
enum sw_input { SW_IN_YELLOW, SW_IN_BLUE_DOWN, SW_IN_BLUE_UP, SW_IN_TAP, SW_IN_SWIPE_UP, SW_IN_SHAKE, SW_IN_YELLOW_DOWN,
                SW_IN_YELLOW_UP };

// Voice: hold yellow, talk, release; the app transcribes and answers `voice heard <text>` or `voice fail <code>`;
// then yellow runs it (`btn voice go`), blue drops it (`btn voice cancel`).
enum sw_voice { SW_V_NONE, SW_V_LISTEN, SW_V_WAIT, SW_V_RESULT, SW_V_SENT, SW_V_ERROR };
enum sw_voice_err { SW_VE_NONE, SW_VE_DENIED, SW_VE_UNAVAILABLE, SW_VE_START, SW_VE_TIMEOUT, SW_VE_OTHER };
enum { SW_SAID_MAX = 120, SW_ANSWER_MAX = 600 };

enum {
  SW_STALE_MS = 15000,     // no `ui` line this long (the app repeats it every 5 s): the app is gone or suspended
  SW_DONE_MS = 5000,       // the check or cross after a finished task
  SW_PICK_MS = 6000,       // a pick or its confirmation without a press is cancelled (5 to browse)
  SW_HOME_MS = 500,        // blue released before this: `btn home`; later and before SW_STOP_MS: nothing
  SW_STOP_MS = 2000,       // blue held this long: `btn stop`
  SW_RING_MS = 300,        // the stop ring shows from here on
  SW_SHAKE_MS = 1000,      // "shake to stop?" shows this long before `btn stop`
  SW_SHAKE_GAP_MS = 2000,  // one shake per this
  SW_HELP_REPEAT_MS = 3000,  // help: the buzz again this often, until answered (Henry 2026-11-21: strong alert)
  SW_HELP_FAST_MS = 60000,   // ... for this long, then every SW_HELP_SLOW_MS (a forgotten watch still nags, gentler)
  SW_HELP_SLOW_MS = 15000,
  SW_HOLD_MS = 350,        // yellow held this long: recording (the mic is on from the press, so no word is lost)
  SW_VOICE_WAIT_MS = 20000,  // released and no `voice` answer this long: "no answer from the app"
  SW_VOICE_KEEP_MS = 60000,  // the heard text waits this long for yellow or blue, then it is dropped
  SW_VOICE_SHOW_MS = 2500,   // "sent" or an error shows this long
};

typedef struct {
  sw_ui ui;
  bool live;  // a `ui` line came and no `ui off` since
  uint32_t ui_at;
  bool done;
  uint32_t done_at;
  uint8_t done_kind;  // SW_SCR_OK or SW_SCR_FAIL
  int8_t sel;         // selected pick, -1: none
  bool own_picks;     // a `picks` line came: the quick intents, `k` no longer counts
  bool confirm;
  uint32_t sel_at;
  uint8_t next_pick;
  bool blue_down, blue_fired, blue_ignore;
  uint32_t blue_at;
  bool shaking, shook;
  uint32_t shake_at;
  uint32_t help_at, help_buzz_at;  // help began, last buzzed
  bool y_down, y_voice;  // yellow is down; it went down with an app that takes voice
  uint32_t y_at;
  uint8_t voice, voice_err;  // sw_voice, sw_voice_err
  bool voice_run;            // the text was heard while a task ran: yellow tells it the words
  uint32_t voice_at;
  char said[SW_SAID_MAX + 1];  // what the app heard
  bool answer;               // a finished task's answer shows (the text is the screen's, `answer` lines)
  uint8_t page, pages;       // its page, and how many the screen made of it
} sw_ctl;

void sw_init(sw_ctl *c);
int sw_apply(sw_ctl *c, const sw_ui *ui, bool off, uint32_t now);  // a parsed line; returns an sw_buzz
bool sw_input(sw_ctl *c, int input, uint32_t now, char *out, size_t n);  // true: out holds a `btn ...` line
bool sw_tick(sw_ctl *c, uint32_t now, char *out, size_t n);             // timeouts; true: out holds a line
bool sw_running(const sw_ctl *c, uint32_t now);
bool sw_alive(const sw_ctl *c, uint32_t now);         // the app sent a line lately: awake (AppModel.mood idle)
bool sw_clock(const sw_ctl *c, uint32_t now, char out[6]);  // the phone's time now, from the last `c`
int sw_screen(const sw_ctl *c, uint32_t now);
int sw_progress(const sw_ui *ui);                     // 0-1000 around the ring, -1: none
int sw_hold(const sw_ctl *c, uint32_t now);           // 0-1000 of the blue stop hold, -1: not shown
int sw_picks_line(sw_ctl *c, const char *arg);         // `picks ["name", ...]`: the quick intents; -1 bad, else count
int32_t sw_elapsed(const sw_ctl *c, uint32_t now);    // the run's seconds now (counting on while it runs), -1: none
void sw_duration(int32_t s, char out[12]);            // "1:05", "1:02:05"
bool sw_voice_line(sw_ctl *c, const char *arg, uint32_t now);  // `voice heard <text>` | `voice fail <code>`
bool sw_mic(const sw_ctl *c);
void sw_answer(sw_ctl *c);
int sw_buzz_due(sw_ctl *c, uint32_t now);             // the help's repeated buzz (an sw_buzz), from sw_tick's caller                            // an `answer` came: it shows from its first page                         // the mic should be on: yellow down for voice, or recording

#ifdef __cplusplus
}
#endif
