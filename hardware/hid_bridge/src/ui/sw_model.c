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
    } else if (!strcmp(key, "k")) {
      ok = picks(&r, u);
    } else if (!strcmp(key, "f")) {
      int w = word(&r);
      ok = w >= 0 || num(&r, NULL);
      u->finished = w == 1;
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

bool sw_running(const sw_ctl *c, uint32_t now) {
  return c->live && !after(now, c->ui_at, SW_STALE_MS) && c->ui.phase != SW_STANDBY && !c->ui.finished;
}

int sw_apply(sw_ctl *c, const sw_ui *u, bool off, uint32_t now) {
  bool was = sw_running(c, now);
  uint8_t was_phase = c->ui.phase;
  bool was_finished = c->live && c->ui.finished;  // the check shows once per finished task
  if (off) {
    c->live = false;
    c->ui.npicks = 0;
    c->sel = -1;
    c->confirm = false;
    c->shaking = c->done = false;
    return SW_BUZZ_NONE;
  }
  sw_ui next = *u;
  if (!next.has_picks) {  // the picks stay until the app sends others
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
    c->sel = -1;
    c->confirm = false;
    c->done = false;
    if (c->ui.phase == SW_HELP && !(was && was_phase == SW_HELP)) buzz = SW_BUZZ_HELP;
  } else {
    c->shaking = false;
  }
  return buzz;
}

static bool say(char *out, size_t n, const char *line) {
  snprintf(out, n, "btn %s", line);
  return true;
}

bool sw_input(sw_ctl *c, int in, uint32_t now, char *out, size_t n) {
  bool running = sw_running(c, now);
  if (c->shaking && (in == SW_IN_YELLOW || in == SW_IN_BLUE_DOWN)) {  // any button cancels the shake stop
    c->shaking = false;
    if (in == SW_IN_BLUE_DOWN) c->blue_ignore = true;
    return false;
  }
  switch (in) {
    case SW_IN_YELLOW:
      if (running) return say(out, n, c->ui.phase == SW_PAUSED ? "unpause" : "pause");
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
    case SW_IN_BLUE_DOWN:
      c->blue_down = true;
      c->blue_fired = false;
      c->blue_ignore = false;
      c->blue_at = now;
      return false;
    case SW_IN_BLUE_UP: {
      bool was = c->blue_down && !c->blue_fired && !c->blue_ignore;
      c->blue_down = false;
      return was && !after(now, c->blue_at, SW_HOME_MS) && say(out, n, "home");
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
  if (c->shaking) return SW_SCR_SHAKE;
  if (c->done && !after(now, c->done_at, SW_DONE_MS)) return c->done_kind;
  if (sw_running(c, now)) return c->ui.phase == SW_HELP ? SW_SCR_HELP : c->ui.phase == SW_PAUSED ? SW_SCR_PAUSED : SW_SCR_RUN;
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
#endif
