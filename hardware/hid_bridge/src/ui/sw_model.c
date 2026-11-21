#include "sw_model.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A small JSON reader for the one flat object `ui` takes: strings, numbers, booleans, null and arrays of strings;
// anything else (nested objects, unknown keys) is skipped.
typedef struct {
  const char *p;
} rd;

static void ws(rd *r) {
  while (*r->p == ' ' || *r->p == '\t' || *r->p == '\n' || *r->p == '\r') r->p++;
}

static int hex4(const char *p) {
  int v = 0;
  for (int i = 0; i < 4; i++) {
    char ch = p[i];
    int d = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
    if (d < 0) return -1;
    v = v * 16 + d;
  }
  return v;
}

// A JSON string into out (cap bytes with the terminator, NULL: skip it). Cut at a whole UTF-8 character; control
// characters become spaces (one line on the screen).
static bool str(rd *r, char *out, size_t cap) {
  if (*r->p != '"') return false;
  r->p++;
  size_t len = 0;
  bool full = false;
  for (;;) {
    unsigned char ch = (unsigned char)*r->p;
    if (!ch) return false;
    if (ch == '"') { r->p++; break; }
    char buf[4];
    size_t n = 0;
    if (ch == '\\') {
      char e = r->p[1];
      r->p += 2;
      switch (e) {
        case '"': case '\\': case '/': buf[n++] = e; break;
        case 'b': case 'f': case 'n': case 'r': case 't': buf[n++] = ' '; break;
        case 'u': {
          long cp = hex4(r->p);
          if (cp < 0) return false;
          r->p += 4;
          if (cp >= 0xD800 && cp < 0xDC00 && r->p[0] == '\\' && r->p[1] == 'u') {
            long lo = hex4(r->p + 2);
            if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); r->p += 6; }
          }
          if (cp >= 0xD800 && cp < 0xE000) cp = 0xFFFD;
          if (cp < 0x20) buf[n++] = ' ';
          else if (cp < 0x80) buf[n++] = (char)cp;
          else if (cp < 0x800) { buf[n++] = (char)(0xC0 | cp >> 6); buf[n++] = (char)(0x80 | (cp & 0x3F)); }
          else if (cp < 0x10000) {
            buf[n++] = (char)(0xE0 | cp >> 12); buf[n++] = (char)(0x80 | (cp >> 6 & 0x3F)); buf[n++] = (char)(0x80 | (cp & 0x3F));
          } else {
            buf[n++] = (char)(0xF0 | cp >> 18); buf[n++] = (char)(0x80 | (cp >> 12 & 0x3F));
            buf[n++] = (char)(0x80 | (cp >> 6 & 0x3F)); buf[n++] = (char)(0x80 | (cp & 0x3F));
          }
          break;
        }
        default: return false;
      }
    } else if (ch < 0x80) {
      buf[n++] = ch < 0x20 ? ' ' : (char)ch;
      r->p++;
    } else {  // a raw UTF-8 sequence, kept whole
      size_t want = ch >= 0xF0 ? 4 : ch >= 0xE0 ? 3 : ch >= 0xC0 ? 2 : 1;
      buf[n++] = (char)ch;
      r->p++;
      while (n < want && ((unsigned char)*r->p & 0xC0) == 0x80) buf[n++] = *r->p++;
    }
    if (out && !full) {
      if (len + n < cap) { memcpy(out + len, buf, n); len += n; }
      else full = true;
    }
  }
  if (out) out[len] = 0;
  return true;
}

static bool skip(rd *r, int depth);

static bool num(rd *r, int32_t *out) {
  char *end;
  double v = strtod(r->p, &end);
  if (end == r->p) return false;
  r->p = end;
  if (out) *out = v > 2147483647.0 ? 2147483647 : v < -2147483648.0 ? (-2147483647 - 1) : (int32_t)v;
  return true;
}

static int word(rd *r) {  // 1 true, 0 false or null, -1 neither
  if (!strncmp(r->p, "true", 4)) { r->p += 4; return 1; }
  if (!strncmp(r->p, "false", 5)) { r->p += 5; return 0; }
  if (!strncmp(r->p, "null", 4)) { r->p += 4; return 0; }
  return -1;
}

static bool skip(rd *r, int depth) {
  ws(r);
  if (depth > 8) return false;
  char ch = *r->p;
  if (ch == '"') return str(r, NULL, 0);
  if (ch == '{' || ch == '[') {
    char close = ch == '{' ? '}' : ']';
    r->p++;
    ws(r);
    if (*r->p == close) { r->p++; return true; }
    for (;;) {
      if (ch == '{') {
        ws(r);
        if (!str(r, NULL, 0)) return false;
        ws(r);
        if (*r->p++ != ':') return false;
      }
      if (!skip(r, depth + 1)) return false;
      ws(r);
      if (*r->p == ',') { r->p++; continue; }
      if (*r->p == close) { r->p++; return true; }
      return false;
    }
  }
  if (word(r) >= 0) return true;
  return num(r, NULL);
}

static int lookup(const char *s, const char *const *names, int n) {
  for (int i = 0; i < n; i++)
    if (!strcmp(s, names[i])) return i;
  return -1;
}

static const char *const MOODS[] = {"sleeping", "idle", "listening", "thinking", "acting", "success", "failure", "dizzy",
                                    "content", "wink"};
static const char *const PHASES[] = {"running", "help", "countdown", "recording", "paused", "resuming", "standby"};

static bool picks(rd *r, sw_ui *u) {
  ws(r);
  if (*r->p != '[') return skip(r, 0);
  u->has_picks = true;
  u->npicks = 0;
  r->p++;
  ws(r);
  if (*r->p == ']') { r->p++; return true; }
  for (;;) {
    ws(r);
    if (*r->p == '"' && u->npicks < SW_PICKS) {
      if (!str(r, u->picks[u->npicks], sizeof u->picks[0])) return false;
      u->npicks++;
    } else if (!skip(r, 1)) {
      return false;
    }
    ws(r);
    if (*r->p == ',') { r->p++; continue; }
    if (*r->p == ']') { r->p++; return true; }
    return false;
  }
}

int sw_parse(const char *arg, sw_ui *u) {
  memset(u, 0, sizeof *u);
  u->mood = SW_IDLE;
  u->phase = SW_RUNNING;
  u->elapsed = -1;
  rd r = {arg};
  ws(&r);
  if (!strncmp(r.p, "off", 3)) {
    r.p += 3;
    ws(&r);
    return *r.p ? SW_PARSE_BAD : SW_PARSE_OFF;
  }
  if (*r.p != '{') return SW_PARSE_BAD;
  r.p++;
  ws(&r);
  if (*r.p == '}') { r.p++; goto end; }
  for (;;) {
    char key[8];
    ws(&r);
    if (!str(&r, key, sizeof key)) return SW_PARSE_BAD;
    ws(&r);
    if (*r.p++ != ':') return SW_PARSE_BAD;
    ws(&r);
    bool ok;
    if ((!strcmp(key, "m") || !strcmp(key, "p")) && *r.p == '"') {
      char v[16];
      ok = str(&r, v, sizeof v);
      int i = !strcmp(key, "m") ? lookup(v, MOODS, 10) : lookup(v, PHASES, 7);
      if (ok && i >= 0) *(key[0] == 'm' ? &u->mood : &u->phase) = (uint8_t)i;
    } else if (!strcmp(key, "t") && *r.p == '"') {
      ok = str(&r, u->text, sizeof u->text);
    } else if (!strcmp(key, "c") && *r.p == '"') {
      char v[8];
      ok = str(&r, v, sizeof v);
      bool hhmm = strlen(v) == 5 && v[2] == ':' && v[0] >= '0' && v[0] <= '2' && v[1] >= '0' && v[1] <= '9' &&
                  v[3] >= '0' && v[3] <= '5' && v[4] >= '0' && v[4] <= '9' && (v[0] - '0') * 10 + v[1] - '0' < 24;
      if (ok && hhmm) memcpy(u->clock, v, 6);
    } else if ((!strcmp(key, "x") || !strcmp(key, "y")) && (*r.p == '-' || (*r.p >= '0' && *r.p <= '9'))) {
      char *end;
      double v = strtod(r.p, &end);
      ok = end != r.p;
      r.p = end;
      float f = v < -1 ? -1 : v > 1 ? 1 : (float)v;
      *(key[0] == 'x' ? &u->look_x : &u->look_y) = f;
    } else if (!strcmp(key, "z") && *r.p >= '0' && *r.p <= '9') {
      char *end;
      double v = strtod(r.p, &end);
      ok = end != r.p;
      r.p = end;
      u->local = v >= 1e9 && v < 1e11 ? (int64_t)v : 0;  // 2001 to 5138: anything else is not a clock
    } else if (!strcmp(key, "w") && *r.p == '"') {
      ok = str(&r, u->warn, sizeof u->warn);
    } else if (!strcmp(key, "k")) {
      ok = picks(&r, u);
    } else if (!strcmp(key, "h")) {
      int w = word(&r);
      int32_t v = 0;
      ok = w >= 0 || num(&r, &v);
      u->confirm = w == 1 || v != 0;
    } else if (!strcmp(key, "v")) {
      int w = word(&r);
      int32_t v = 0;
      ok = w >= 0 || num(&r, &v);
      u->voice = w == 1 || v != 0;
    } else if (!strcmp(key, "f")) {
      int w = word(&r);
      ok = w >= 0 || num(&r, NULL);
      u->finished = w == 1;
    } else if (!strcmp(key, "e") && (*r.p >= '0' && *r.p <= '9')) {
      ok = num(&r, &u->elapsed);
    } else if (strlen(key) == 1 && strchr("sldn", key[0]) && (*r.p == '-' || (*r.p >= '0' && *r.p <= '9'))) {
      int32_t *at = key[0] == 's' ? &u->step : key[0] == 'l' ? &u->limit : key[0] == 'd' ? &u->done : &u->total;
      ok = num(&r, at);
    } else {
      ok = skip(&r, 0);
    }
    if (!ok) return SW_PARSE_BAD;
    ws(&r);
    if (*r.p == ',') { r.p++; continue; }
    if (*r.p == '}') { r.p++; break; }
    return SW_PARSE_BAD;
  }
end:
  ws(&r);
  return *r.p ? SW_PARSE_BAD : SW_PARSE_UI;
}

static bool after(uint32_t now, uint32_t at, uint32_t ms) { return (uint32_t)(now - at) >= ms; }

void sw_init(sw_ctl *c) {
  memset(c, 0, sizeof *c);
  c->sel = -1;
}

bool sw_alive(const sw_ctl *c, uint32_t now) { return c->live && !after(now, c->ui_at, SW_STALE_MS); }

bool sw_running(const sw_ctl *c, uint32_t now) {
  return sw_alive(c, now) && c->ui.phase != SW_STANDBY && !c->ui.finished;
}

bool sw_clock(const sw_ctl *c, uint32_t now, char out[6]) {
  if (!c->live || !c->ui.clock[0]) return false;
  int m = ((c->ui.clock[0] - '0') * 10 + c->ui.clock[1] - '0') * 60 + (c->ui.clock[3] - '0') * 10 + c->ui.clock[4] - '0';
  m = (m + (int)((now - c->ui_at) / 60000)) % (24 * 60);  // the minute it was sent, plus the time since
  snprintf(out, 6, "%02d:%02d", m / 60, m % 60);
  return true;
}

int sw_apply(sw_ctl *c, const sw_ui *u, bool off, uint32_t now) {
  bool was = sw_running(c, now);
  uint8_t was_phase = c->ui.phase;
  bool was_finished = c->live && c->ui.finished;  // the check shows once per finished task
  if (off) {
    c->live = false;
    c->ui.npicks = 0;
    c->own_picks = false;
    c->sel = -1;
    c->confirm = false;
    c->shaking = c->done = false;
    return SW_BUZZ_NONE;
  }
  sw_ui next = *u;
  if (!next.has_picks || c->own_picks) {  // the picks stay until the app sends others (a `picks` line beats `k`)
    next.npicks = c->ui.npicks;
    memcpy(next.picks, c->ui.picks, sizeof next.picks);
  }
  c->ui = next;
  c->live = true;
  c->ui_at = now;
  if (c->sel >= c->ui.npicks) { c->sel = -1; c->confirm = false; }
  int buzz = SW_BUZZ_NONE;
  if (c->ui.finished && !was_finished) {
    c->done = true;
    c->done_at = now;
    c->done_kind = c->ui.mood == SW_FAILURE ? SW_SCR_FAIL : SW_SCR_OK;
    c->shaking = false;
    buzz = c->done_kind == SW_SCR_FAIL ? SW_BUZZ_FAIL : SW_BUZZ_OK;
  }
  if (sw_running(c, now)) {
    c->answer = false;  // a new task: the last one's answer goes
    c->sel = -1;
    c->confirm = false;
    c->done = false;
    if (c->ui.phase == SW_HELP && !(was && was_phase == SW_HELP)) buzz = SW_BUZZ_HELP, c->help_at = c->help_buzz_at = now;
  } else {
    c->shaking = false;
  }
  return buzz;
}

static bool say(char *out, size_t n, const char *line) {
  snprintf(out, n, "btn %s", line);
  return true;
}

// A short press during a run: a second one within SW_DOUBLE_MS stops it; alone, sw_tick sends its own action.
static bool tap(sw_ctl *c, uint8_t kind, uint32_t now, char *out, size_t n) {
  if (c->tap && !after(now, c->tap_at, SW_DOUBLE_MS)) {
    c->tap = 0;
    return say(out, n, "stop");
  }
  c->tap = kind;
  c->tap_at = now;
  return false;
}

static bool yellow(sw_ctl *c, bool running, uint32_t now, char *out, size_t n) {
  if (running && c->ui.phase == SW_HELP) return say(out, n, "continue");  // help or confirm: yellow goes on
  if (running) return tap(c, 1, now, out, n);
  if (!c->ui.npicks) return false;
  c->sel_at = now;
  if (c->sel < 0) {
    c->sel = (int8_t)(c->next_pick % c->ui.npicks);
    c->next_pick = (uint8_t)(c->sel + 1);
    return false;
  }
  if (!c->confirm) { c->confirm = true; return false; }
  snprintf(out, n, "btn run %d", c->sel);
  c->sel = -1;
  c->confirm = false;
  return true;
}

bool sw_input(sw_ctl *c, int in, uint32_t now, char *out, size_t n) {
  bool running = sw_running(c, now);
  if (c->shaking && (in == SW_IN_YELLOW || in == SW_IN_YELLOW_DOWN || in == SW_IN_BLUE_DOWN)) {  // any button cancels the shake stop
    c->shaking = false;
    if (in == SW_IN_BLUE_DOWN) c->blue_ignore = true;
    return false;
  }
  if (c->answer && !running && c->voice == SW_V_NONE) {  // the answer: yellow or a tap turns the page, blue closes
    bool legacy = in == SW_IN_YELLOW_DOWN && !(sw_alive(c, now) && c->ui.voice);
    if (in == SW_IN_TAP || in == SW_IN_YELLOW || legacy ||
        (in == SW_IN_YELLOW_UP && c->y_down && !after(now, c->y_at, SW_HOLD_MS))) {
      c->y_down = false;
      c->page = (uint8_t)(c->pages > 1 ? (c->page + 1) % c->pages : 0);
      return false;
    }
    if (in == SW_IN_BLUE_DOWN) {
      c->answer = false;
      c->blue_down = c->blue_ignore = true;
      return false;
    }
  }
  switch (in) {
    case SW_IN_YELLOW:
      return yellow(c, running, now, out, n);
    case SW_IN_YELLOW_DOWN:
      if (c->voice == SW_V_RESULT) {
        snprintf(out, n, "btn voice go");
        c->voice = SW_V_SENT;
        c->voice_at = now;
        return true;
      }
      if (c->voice == SW_V_LISTEN || c->voice == SW_V_WAIT) return false;
      c->voice = SW_V_NONE;  // "sent" or an error is dismissed
      c->y_voice = sw_alive(c, now) && c->ui.voice;
      if (!c->y_voice) return yellow(c, running, now, out, n);
      c->y_down = true;
      c->y_at = now;
      return false;
    case SW_IN_YELLOW_UP:
      if (!c->y_down) return false;
      c->y_down = false;
      if (c->voice == SW_V_LISTEN) {
        c->voice = SW_V_WAIT;
        c->voice_at = now;
        return false;
      }
      return yellow(c, running, now, out, n);
    case SW_IN_BLUE_DOWN:
      if (c->sel >= 0 && !running) {  // blue drops the selected intent (and does nothing else)
        c->sel = -1;
        c->confirm = false;
        c->blue_down = true;
        c->blue_ignore = true;
        return false;
      }
      c->blue_down = true;
      c->blue_fired = false;
      c->blue_ignore = false;
      c->blue_at = now;
      if (c->voice != SW_V_NONE) {  // blue drops the recording or the heard text; "sent" or an error just goes
        bool tell = c->voice == SW_V_LISTEN || c->voice == SW_V_WAIT || c->voice == SW_V_RESULT;
        c->voice = SW_V_NONE;
        c->y_down = false;
        c->blue_ignore = true;
        return tell && say(out, n, "voice cancel");
      }
      return false;
    case SW_IN_BLUE_UP: {
      bool was = c->blue_down && !c->blue_fired && !c->blue_ignore;
      c->blue_down = false;
      if (!was || after(now, c->blue_at, SW_HOME_MS)) return false;
      if (running && c->ui.phase == SW_HELP) return say(out, n, c->ui.confirm ? "skip" : "stop");  // blue answers no
      if (running) return tap(c, 2, now, out, n);
      return say(out, n, "home");
    }
    case SW_IN_TAP:
      if (running && c->ui.phase == SW_HELP) return say(out, n, "continue");
      if (!running && c->sel >= 0 && !c->confirm && c->ui.npicks) {  // a tap moves to the next pick
        c->sel = (int8_t)((c->sel + 1) % c->ui.npicks);
        c->next_pick = (uint8_t)(c->sel + 1);
        c->sel_at = now;
      }
      return false;
    case SW_IN_SWIPE_UP:
      return running && say(out, n, "takeover");
    case SW_IN_SHAKE:
      if (running && !c->shaking && (!c->shook || after(now, c->shake_at, SW_SHAKE_GAP_MS))) {
        c->shaking = c->shook = true;
        c->shake_at = now;
      }
      return false;
  }
  return false;
}

bool sw_tick(sw_ctl *c, uint32_t now, char *out, size_t n) {
  if (c->tap && after(now, c->tap_at, SW_DOUBLE_MS)) {  // one press, no second: its own action
    uint8_t kind = c->tap;
    c->tap = 0;
    if (sw_running(c, now) && c->ui.phase != SW_HELP)
      return say(out, n, kind == 2 ? "home" : c->ui.phase == SW_PAUSED ? "unpause" : "pause");
  }
  if (c->y_down && c->voice == SW_V_NONE && after(now, c->y_at, SW_HOLD_MS)) {
    c->voice = SW_V_LISTEN;
    c->voice_at = now;
    c->voice_run = sw_running(c, now);
    c->sel = -1;
    c->confirm = false;
  }
  if (c->voice == SW_V_WAIT && after(now, c->voice_at, SW_VOICE_WAIT_MS)) {
    c->voice = SW_V_ERROR;
    c->voice_err = SW_VE_TIMEOUT;
    c->voice_at = now;
  }
  if ((c->voice == SW_V_SENT || c->voice == SW_V_ERROR) && after(now, c->voice_at, SW_VOICE_SHOW_MS)) c->voice = SW_V_NONE;
  if (c->voice == SW_V_RESULT && after(now, c->voice_at, SW_VOICE_KEEP_MS)) {
    c->voice = SW_V_NONE;
    return say(out, n, "voice cancel");
  }
  if (c->blue_down && !c->blue_fired && !c->blue_ignore && after(now, c->blue_at, SW_STOP_MS)) {
    c->blue_fired = true;
    return say(out, n, "stop");
  }
  if (c->shaking && after(now, c->shake_at, SW_SHAKE_MS)) {
    c->shaking = false;
    return say(out, n, "stop");
  }
  if (c->sel >= 0 && after(now, c->sel_at, SW_PICK_MS)) {
    c->sel = -1;
    c->confirm = false;
  }
  if (c->done && after(now, c->done_at, SW_DONE_MS)) c->done = false;
  return false;
}

int sw_screen(const sw_ctl *c, uint32_t now) {
  if (c->voice != SW_V_NONE) return SW_SCR_VOICE;
  if (c->shaking) return SW_SCR_SHAKE;
  if (c->answer && !sw_running(c, now)) return SW_SCR_ANSWER;
  if (c->done && !after(now, c->done_at, SW_DONE_MS)) return c->done_kind;
  if (sw_running(c, now)) return c->ui.phase == SW_HELP ? SW_SCR_HELP : c->ui.phase == SW_PAUSED ? SW_SCR_PAUSED : SW_SCR_RUN;
  // A run's lines stopped while the link stays (iOS suspended the app): the island's "×" eyes, until the link drops
  if (c->live && c->ui.phase != SW_STANDBY && !c->ui.finished) return SW_SCR_STUCK;
  return c->confirm && c->sel >= 0 ? SW_SCR_CONFIRM : SW_SCR_IDLE;
}

int sw_progress(const sw_ui *u) {
  int32_t num = u->total > 0 ? u->done : u->step, den = u->total > 0 ? u->total : u->limit;
  if (den <= 0) return -1;
  if (num <= 0) return 0;
  return num >= den ? 1000 : (int)((int64_t)num * 1000 / den);
}

int sw_hold(const sw_ctl *c, uint32_t now) {
  if (!c->blue_down || c->blue_fired || c->blue_ignore || !after(now, c->blue_at, SW_RING_MS)) return -1;
  uint32_t held = now - c->blue_at;
  return held >= SW_STOP_MS ? 1000 : (int)(held * 1000 / SW_STOP_MS);
}

int sw_picks_line(sw_ctl *c, const char *arg) {
  rd r = {arg};
  sw_ui u;
  memset(&u, 0, sizeof u);
  ws(&r);
  if (*r.p != '[' || !picks(&r, &u)) return -1;
  ws(&r);
  if (*r.p) return -1;
  c->own_picks = true;
  c->ui.npicks = u.npicks;
  memcpy(c->ui.picks, u.picks, sizeof u.picks);
  if (c->sel >= c->ui.npicks) c->sel = -1, c->confirm = false;
  return u.npicks;
}

int32_t sw_elapsed(const sw_ctl *c, uint32_t now) {
  if (!c->live || c->ui.elapsed < 0) return -1;
  return c->ui.elapsed + (sw_running(c, now) ? (int32_t)((now - c->ui_at) / 1000) : 0);
}

void sw_duration(int32_t s, char out[12]) {
  if (s < 0) s = 0;
  if (s >= 3600) snprintf(out, 12, "%d:%02d:%02d", (int)(s / 3600), (int)(s / 60 % 60), (int)(s % 60));
  else snprintf(out, 12, "%d:%02d", (int)(s / 60), (int)(s % 60));
}

int sw_buzz_due(sw_ctl *c, uint32_t now) {
  if (!sw_running(c, now) || c->ui.phase != SW_HELP) return SW_BUZZ_NONE;
  uint32_t gap = after(now, c->help_at, SW_HELP_FAST_MS) ? SW_HELP_SLOW_MS : SW_HELP_REPEAT_MS;
  if (!after(now, c->help_buzz_at, gap)) return SW_BUZZ_NONE;
  c->help_buzz_at = now;
  return SW_BUZZ_HELP;
}

void sw_answer(sw_ctl *c) {
  c->answer = true;
  c->page = 0;
  c->pages = 1;
}

bool sw_mic(const sw_ctl *c) { return (c->y_down && c->y_voice) || c->voice == SW_V_LISTEN; }

static const char *const VOICE_ERRS[] = {"none", "denied", "unavailable", "start", "timeout"};

bool sw_voice_line(sw_ctl *c, const char *arg, uint32_t now) {
  if (!strncmp(arg, "heard ", 6) || !strcmp(arg, "heard")) {
    const char *t = arg[5] ? arg + 6 : "";
    while (*t == ' ') t++;
    if (c->voice != SW_V_WAIT) return true;  // dropped meanwhile (blue) or too late: nothing to show
    size_t len = strlen(t);
    if (len > SW_SAID_MAX) {  // cut on a character boundary
      len = SW_SAID_MAX;
      while (len && ((unsigned char)t[len] & 0xC0) == 0x80) len--;
    }
    memcpy(c->said, t, len);
    c->said[len] = 0;
    c->voice = len ? SW_V_RESULT : SW_V_ERROR;
    c->voice_err = SW_VE_NONE;
    c->voice_at = now;
    return true;
  }
  if (!strncmp(arg, "fail", 4) && (!arg[4] || arg[4] == ' ')) {
    const char *code = arg[4] ? arg + 5 : "";
    int e = lookup(code, VOICE_ERRS, 5);
    if (c->voice == SW_V_LISTEN) return true;  // a new recording goes on: the old one's failure is stale
    c->voice = SW_V_ERROR;  // also after "sent" (the task did not start), however late
    c->voice_err = (uint8_t)(e < 0 ? SW_VE_OTHER : e);
    c->voice_at = now;
    return true;
  }
  return false;
}
#endif
