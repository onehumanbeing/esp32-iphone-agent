#ifdef M5_STOPWATCH
// The StopWatch's pages: the run, help, outcome, status, voice and answer, in the screen's language (sw_text.h).
#include "stopwatch_draw.h"
#include "src/ui/sw_warn.h"
#include "version.h"
#include "src/ui/sw_text.h"

M5Canvas *canvas;
namespace sw {
int W, H, CX, CY;
}
using namespace sw;
char *answerText;
int answerStart[ANSWER_LINES + 1], answerLines;

void font(const lgfx::IFont *f, float size) {
  canvas->setFont(f);
  canvas->setTextSize(size);
}

static bool ascii(const char *s) {
  for (; *s; s++)
    if ((uint8_t)*s >= 0x80) return false;
  return true;
}

// The font for this text: plain ASCII in a Latin font, anything else (Chinese, the app's words) in efontCN, at the
// same size. big: 1 normal, 2 a heading, 3 the largest.
void fontFor(const char *s, int big) {
  if (ascii(s)) font(big == 3 ? &fonts::FreeSansBold24pt7b : big == 2 ? &fonts::FreeSansBold18pt7b : &fonts::FreeSans12pt7b);
  else font(&fonts::efontCN_24, big == 3 ? 2 : big == 2 ? 1.5f : 1);
}

static int utf8Back(const String &s) {  // start of the last character
  int i = s.length() - 1;
  while (i > 0 && ((uint8_t)s[i] & 0xC0) == 0x80) i--;
  return i < 0 ? 0 : i;
}

String fit(String s, int width) {
  if (canvas->textWidth(s) <= width) return s;
  while (s.length() && canvas->textWidth(s + "…") > width) s.remove(utf8Back(s));
  return s + "…";
}

// Up to `lines` lines of at most `width` pixels, the last one cut with an ellipsis.
static void wrapped(const char *text, int y, int width, int lines, int gap) {
  String rest = text, out[4];
  lines = lines > 4 ? 4 : lines;
  int n = 0;
  while (rest.length() && n < lines) {
    if (n == lines - 1 || canvas->textWidth(rest) <= width) { out[n++] = fit(rest, width); break; }
    int cut = 0;
    for (int i = 1; i <= (int)rest.length(); i++) {
      if (i < (int)rest.length() && ((uint8_t)rest[i] & 0xC0) == 0x80) continue;
      if (canvas->textWidth(rest.substring(0, i)) > width) break;
      cut = i;
    }
    if (!cut) break;
    out[n++] = rest.substring(0, cut);
    rest = rest.substring(cut);
    rest.trim();
  }
  int top = y - (n - 1) * gap / 2;
  for (int i = 0; i < n; i++) canvas->drawString(out[i], CX, top + i * gap);
}

// The answer as lines of ANSWER_W pixels (in its font), once when it comes: where each starts.
void layoutAnswer() {
  fontFor(answerText);
  int n = (int)strlen(answerText);
  while (n && ((uint8_t)answerText[n - 1] & 0xC0) == 0x80) n--;  // a character cut at the cap
  if (n && (uint8_t)answerText[n - 1] >= 0xC0) n--;
  answerText[n] = 0;
  answerLines = 0;
  int at = 0, width = 0, lastSpace = -1;
  answerStart[0] = 0;
  for (int i = 0; i <= n && answerLines < ANSWER_LINES;) {
    if (i == n) { answerLines++; break; }
    int len = 1;
    while (i + len < n && ((uint8_t)answerText[i + len] & 0xC0) == 0x80) len++;
    char ch[5] = {};
    memcpy(ch, answerText + i, len);
    int w = canvas->textWidth(ch);
    if (ch[0] == ' ') lastSpace = i;
    if (width + w > ANSWER_W && i > at) {  // break before this character, at the last space when there is one
      int cut = lastSpace > at ? lastSpace + 1 : i;
      answerStart[++answerLines] = at = cut;
      width = 0, lastSpace = -1, i = cut;
      continue;
    }
    width += w;
    i += len;
  }
  answerStart[answerLines] = n;
}

static void answerPage(const sw_ctl &c) {
  canvas->setTextColor(C_GREEN);
  fontFor(T(SWT_DONE), 2);
  canvas->drawString(T(SWT_DONE), CX, 72);
  canvas->setTextColor(TFT_WHITE);
  fontFor(answerText);
  int first = c.page * ANSWER_ROWS, rows = min(ANSWER_ROWS, answerLines - first);
  int top = CY - (ANSWER_ROWS - 1) * ANSWER_GAP / 2;
  for (int i = 0; i < rows; i++) {
    int a = answerStart[first + i], b = answerStart[first + i + 1];
    String s = String(answerText).substring(a, b);
    s.trim();
    canvas->drawString(s, CX, top + i * ANSWER_GAP);
  }
  if (c.pages > 1) {
    char p[8];
    snprintf(p, sizeof p, "%d/%d", c.page + 1, (int)c.pages);
    canvas->setTextColor(C_GREY);
    font(&fonts::FreeSans12pt7b);
    canvas->drawString(p, CX, H - 62);
  }
}

void ring(int permille, uint16_t color, uint16_t track, int r0, int r1) {
  canvas->fillArc(CX, CY, r0, r1, 0, 360, track);
  if (permille > 0) canvas->fillArc(CX, CY, r0, r1, -90, -90 + 360.0f * permille / 1000, color);
}

// ---- the character (ios/Shared/AgentFace.swift; the pose comes from src/ui/sw_face.c) ----

// Where a point of the face lands: breathing about the centre, the squish and tilt anchored at the bottom of the
// face (PokeableFace's anchor: .bottom), then the lean / lift / hop offset.


void line(const char *text, int y, uint16_t color, int lines, int width) {
  canvas->setTextColor(color);
  fontFor(text);
  wrapped(text, y, width, lines, 32);
}


// Hold yellow: the level bar while it listens, the thinking face while the phone transcribes, the text with what
// yellow and blue do, then "sent" or what went wrong.
static void voicePage(const sw_ctl &c, const swf_pose &pose, int level) {
  switch (c.voice) {
    case SW_V_LISTEN: {
      face(pose, CX, CY - 50, GLOW_INK, true);
      int w = 220, x = CX - w / 2, y = CY + 85;
      canvas->fillSmoothRoundRect(x, y, w, 14, 7, C_DIM);
      if (level > 0) canvas->fillSmoothRoundRect(x, y, max(14, w * level / 1000), 14, 7, C_GREEN);
      line(T(SWT_LISTENING), CY + 130, TFT_WHITE, 1);
      line(T(SWT_LISTEN_HINT), CY + 170, C_GREY, 1, 300);
      break;
    }
    case SW_V_WAIT:
      face(pose, CX, CY - 40, GLOW_INK, true);
      line(T(SWT_TRANSCRIBING), CY + 130, C_GREY, 1);
      break;
    case SW_V_RESULT:
      line(c.said, CY - 20, TFT_WHITE, 4, 340);
      line(T(c.voice_run ? SWT_TELL_HINT : SWT_RUN_HINT), CY + 135, C_AMBER, 1, 320);
      break;
    case SW_V_SENT:
      face(pose, CX, CY - 30, GLOW_INK, true);
      line(T(SWT_SENT), CY + 130, C_GREEN, 1);
      break;
    default: {
      static const int ERR[] = {SWT_ERR_NONE, SWT_ERR_DENIED, SWT_ERR_UNAVAILABLE, SWT_ERR_START, SWT_ERR_TIMEOUT, SWT_ERR_OTHER};
      face(pose, CX, CY - 30, GLOW_INK, true);
      line(T(ERR[c.voice_err < 6 ? c.voice_err : 5]), CY + 130, C_ORANGE, 2);
    }
  }
}

// Under the idle face: Bluetooth, Wi-Fi, Mirroring, each with a dot, green when up, amber on the way (Henry 2026-11-21)
static void statusDots(const View &v) {
  const int ids[] = {SWT_DOT_BT, SWT_DOT_WIFI, SWT_DOT_MIRROR};
  const uint16_t col[] = {v.hid ? C_GREEN : v.connecting || v.pair ? C_AMBER : C_DIM, v.wifi ? C_GREEN : C_DIM,
                          v.mirror == 2 ? C_GREEN : v.mirror ? C_AMBER : C_DIM};
  font(&fonts::efontCN_24);
  for (int i = 0; i < 3; i++) {
    int x = CX + (i - 1) * 110, y = CY + 128;
    canvas->fillSmoothCircle(x, y - 14, 6, col[i]);
    canvas->setTextColor(col[i] == C_DIM ? C_GREY : col[i]);
    canvas->drawString(T(ids[i]), x, y + 6);
  }
}

// Pairing, opened with blue on the status page: big waves across the screen, the countdown on the rim, the
// board's name to pick in the app, and "connecting" once a phone is on the way.
static void pairingPage(const View &v) {
  uint32_t t = millis();
  for (int k = 0; k < 4; k++) {
    float p = ((t + k * 500) % 2000) / 2000.0f;
    uint8_t a = (uint8_t)(200 * (1 - p));
    int r = 40 + (int)(p * 175);
    canvas->fillArc(CX, CY, r, r + 4, 0, 360, lgfx::color565(a, a * 176 / 255, 0));
  }
  ring((int)(v.pair * 1000L / 180), C_AMBER, C_DIM, 222, 232);
  const char *title = v.connecting ? T(SWT_BT_CONNECTING) : T(SWT_PAIR_TITLE);
  canvas->setTextColor(C_AMBER);
  fontFor(title, 3);
  canvas->drawString(fit(title, 340), CX, CY - 90);
  line(T(SWT_PAIR_HOW), CY - 20, TFT_WHITE, 2, 320);
  fontFor(boardName, 2);
  canvas->setTextColor(C_AMBER);
  canvas->drawString(fit(boardName, 330), CX, CY + 50);
  char left[24];
  snprintf(left, sizeof left, T(SWT_PAIR_LEFT), v.pair / 60, v.pair % 60);
  font(&fonts::efontCN_24);
  canvas->setTextColor(C_GREY);
  canvas->drawString(left, CX, CY + 120);
}

// The status page's battery (Henry 2026-11-21: it matters): a battery drawn to its level, the percent beside it,
// green over 50 %, amber over 15 %, red under; a bolt while charging.
static void batteryBadge(const View &v, int y) {
  uint16_t col = !v.battery ? C_GREY : v.battery > 50 ? C_GREEN : v.battery > 15 ? C_AMBER : C_RED;
  int x = CX - 78;
  canvas->drawRoundRect(x, y - 15, 56, 30, 6, col);
  canvas->fillRoundRect(x + 56, y - 6, 5, 12, 2, col);
  if (v.battery) canvas->fillRoundRect(x + 4, y - 11, 48 * v.battery / 100 < 3 ? 3 : 48 * v.battery / 100, 22, 3, col);
  char pct[16];
  if (v.battery) snprintf(pct, sizeof pct, "%u%%%s", v.battery, v.charging ? " +" : "");
  else strlcpy(pct, "--", sizeof pct);
  font(&fonts::Font4);
  canvas->setTextColor(col);
  canvas->setTextDatum(lgfx::textdatum_t::middle_left);
  canvas->drawString(pct, x + 72, y);
  canvas->setTextDatum(lgfx::textdatum_t::middle_center);
}

static void statusPage(const View &v) {
  if (v.pair && !v.hid) {  // pairing: its own page, not one row (Henry 2026-11-21: the row was easy to miss)
    pairingPage(v);
    return;
  }
  canvas->setTextColor(TFT_WHITE);
  font(&fonts::Font4);
  canvas->drawString(v.clock[0] ? v.clock : "--:--", CX, 58);
  batteryBadge(v, 100);
  char fw[32], pairing[40];
  snprintf(fw, sizeof fw, "%s%s", T(SWT_FIRMWARE), FW_VERSION);
  snprintf(pairing, sizeof pairing, T(SWT_PAIRING), v.pair / 60, v.pair % 60);
  // each row: its text and its colour (green on, amber on the way, grey off)
  const char *bt = v.hid ? T(SWT_BT_ON) : v.connecting ? T(SWT_BT_CONNECTING) : v.pair ? pairing : T(SWT_BT_OFF);
  uint16_t btc = v.hid ? C_GREEN : v.connecting || v.pair ? C_AMBER : C_GREY;
  const char *rows[] = {bt, T(v.alive ? SWT_APP_ON : SWT_APP_OFF), T(v.wifi ? SWT_WIFI_ON : SWT_WIFI_OFF),
                        T(v.mirror == 2 ? SWT_MIRROR_ON : v.mirror ? SWT_MIRROR_WAIT : SWT_MIRROR_OFF), fw, boardName,
                        T(SWT_LANGUAGE)};
  const uint16_t colors[] = {btc, v.alive ? C_GREEN : C_GREY, v.wifi ? C_GREEN : C_GREY,
                             v.mirror == 2 ? C_GREEN : v.mirror ? C_AMBER : C_GREY, TFT_WHITE, C_GREY, C_AMBER};
  for (int i = 0; i < 7; i++) {
    canvas->setTextColor(colors[i]);
    fontFor(rows[i]);
    canvas->drawString(fit(rows[i], 330), CX, STATUS_Y + i * STATUS_GAP);
  }
  if (!v.hid && !v.pair) line(T(SWT_PAIR_HINT), H - 70, C_GREY, 1);
}

// A lost link the user has to fix (sw_warn.h): what happened, what to do, the board's name where it is picked.
static void warnPage(const View &v) {
  static const int TITLE[] = {0, SWT_W_MIRROR, SWT_W_LOCKED, SWT_W_HID}, FIX[] = {0, SWT_W_MIRROR_FIX, SWT_W_LOCKED_FIX, SWT_W_HID_FIX};
  int w = v.warn < 4 ? v.warn : SW_W_HID;
  ring(1000, C_ORANGE, C_ORANGE, 222, 230);
  canvas->setTextColor(C_ORANGE);
  fontFor(T(TITLE[w]), 2);
  canvas->drawString(fit(T(TITLE[w]), 340), CX, CY - 70);
  line(T(FIX[w]), CY + 5, TFT_WHITE, 2, 340);
  if (w != SW_W_LOCKED) {
    fontFor(boardName);
    canvas->setTextColor(C_AMBER);
    canvas->drawString(fit(boardName, 320), CX, CY + 85);
  }
  line(T(SWT_W_HIDE), H - 70, C_GREY, 1);
}

void draw(const View &v, const sw_ctl &c, const swf_pose &pose) {
  if (v.screen == SW_SCR_VOICE) {
    canvas->fillScreen(TFT_BLACK);
    canvas->setTextDatum(lgfx::textdatum_t::middle_center);
    bx0 = by0 = 1e9f, bx1 = by1 = -1e9f;
    place.on = false;
    voicePage(c, pose, v.level * 50);
    return;
  }
  const sw_ui &u = c.ui;
  uint16_t bg = v.screen == SW_SCR_HELP ? C_AMBER : v.screen == SW_SCR_SHAKE ? C_RED : TFT_BLACK;
  canvas->fillScreen(bg);
  canvas->setTextDatum(lgfx::textdatum_t::middle_center);
  bx0 = by0 = 1e9f, bx1 = by1 = -1e9f;
  place.on = false;
  int count = u.total > 0 ? sw_progress(&u) : -1;  // the island's green ring: the task's own count only
  char counter[24];
  if (u.total > 0) snprintf(counter, sizeof counter, "%d/%d", (int)u.done, (int)u.total);
  else snprintf(counter, sizeof counter, u.limit > 0 ? "%d/%d" : "", (int)u.step, (int)u.limit);
  char took[12] = "";
  if (v.elapsed >= 0) sw_duration(v.elapsed, took);
  char top[40];  // the step count and the run's time, as the island's counter and timer
  snprintf(top, sizeof top, "%s%s%s", counter, counter[0] && took[0] ? "   " : "", took);
  switch (v.screen) {
    case SW_SCR_RUN: case SW_SCR_PAUSED:
      if (count >= 0) ring(count, C_GREEN, scaled(C_GREEN, 0.25f), 220, 230);
      canvas->setTextColor(count >= 0 ? C_GREEN : C_GREY);
      font(&fonts::Font4);
      canvas->drawString(v.screen == SW_SCR_PAUSED ? took : top, CX, 62);
      face(pose, CX, CY - 30, v.screen == SW_SCR_PAUSED ? C_GREY : GLOW_INK, v.screen != SW_SCR_PAUSED);
      if (v.screen == SW_SCR_PAUSED) line(T(SWT_PAUSED), CY + 130, C_GREY);
      else line(u.text, CY + 130, u.phase == SW_RECORDING ? C_RED : TFT_WHITE);
      break;
    case SW_SCR_HELP:
      canvas->setTextColor(TFT_BLACK);
      fontFor(T(u.confirm ? SWT_CONFIRM_STEP : SWT_HELP), 2);
      canvas->drawString(T(u.confirm ? SWT_CONFIRM_STEP : SWT_HELP), CX, 82);
      face(pose, CX, CY - 35, TFT_BLACK, false);
      line(u.text, CY + 95, TFT_BLACK);
      line(T(u.confirm ? SWT_CONFIRM_KEYS : SWT_HELP_KEYS), H - 88, TFT_BLACK, 1, 320);
      line(T(SWT_TAKEOVER_HINT), H - 52, scaled(TFT_BLACK, 1), 1, 260);
      break;
    case SW_SCR_OK: case SW_SCR_FAIL: {
      bool ok = v.screen == SW_SCR_OK;
      if (ok && count >= 0) ring(1000, C_GREEN, C_GREEN, 220, 230);
      face(pose, CX, CY - 30, GLOW_INK, true);
      line(u.text[0] ? u.text : T(ok ? SWT_DONE : SWT_NOT_DONE), CY + 130, ok ? C_GREEN : C_ORANGE);
      if (took[0]) {  // how long it took, and its steps
        char total[48];
        snprintf(total, sizeof total, T(SWT_TOTAL), (int)u.step, took);
        line(total, CY + 182, C_GREY, 1);
      }
      break;
    }
    case SW_SCR_ANSWER:
      answerPage(c);
      break;
    case SW_SCR_STUCK:
      face(pose, CX, CY - 30, GLOW_INK, true, true);
      line(T(SWT_STUCK), CY + 130, C_ORANGE);
      break;
    case SW_SCR_CONFIRM:
      canvas->setTextColor(TFT_WHITE);
      fontFor(T(SWT_CONFIRM), 2);
      canvas->drawString(T(SWT_CONFIRM), CX, CY - 60);
      fontFor(u.picks[c.sel]);
      canvas->drawString(fit(u.picks[c.sel], 330), CX, CY + 10);
      line(T(SWT_CONFIRM_HINT), CY + 70, C_GREY, 1);
      break;
    case SW_SCR_SHAKE:
      canvas->setTextColor(TFT_WHITE);
      fontFor(T(SWT_SHAKE), 3);
      canvas->drawString(T(SWT_SHAKE), CX, CY - 20);
      line(T(SWT_SHAKE_HINT), CY + 50, TFT_WHITE, 1);
      break;
    case SW_SCR_STATUS:
      statusPage(v);
      break;
    case SW_SCR_WARN:
      warnPage(v);
      break;
    default:  // idle: the character, awake while the app is there (AppModel.mood), the picks when selecting
      face(pose, CX, CY - 10, GLOW_INK, true);
      // all linked: only the character; the states are on the status page (blue). Until then, the dots (Henry 2026-11-21)
      bool linked = v.hid && v.alive && v.wifi && v.mirror == 2;
      if (c.sel < 0 && !u.npicks && !linked) statusDots(v);
      font(&fonts::efontCN_24);
      if (v.clock[0] && c.sel < 0) {  // asleep or without the app: the time (the RTC, set from the phone)
        font(&fonts::Font7);
        canvas->setTextColor(pose.mood == SW_SLEEPING ? C_GREY : TFT_WHITE);
        canvas->drawString(v.clock, CX, CY + 110);
        font(&fonts::efontCN_24);
      }
      if (c.sel >= 0 && u.npicks) {
        fontFor(u.picks[c.sel]);
        canvas->fillSmoothRoundRect(CX - 150, CY + 125, 300, 44, 22, TFT_WHITE);
        canvas->setTextColor(TFT_BLACK);
        canvas->drawString(fit(u.picks[c.sel], 270), CX, CY + 147);
        char n[8];
        snprintf(n, sizeof n, "%d/%d", c.sel + 1, (int)u.npicks);
        canvas->setTextColor(C_GREY);
        font(&fonts::FreeSans12pt7b);
        canvas->drawString(n, CX, CY + 190);
      } else if (v.charge >= 0) {  // charging: a slow pulse round the edge, and the level
        float k = 0.35f + 0.65f * fabsf(v.charge - 8) / 8.0f;
        ring(v.battery * 10, scaled(C_GREEN, k), scaled(C_GREEN, 0.15f), 222, 230);
        char b[32];
        snprintf(b, sizeof b, T(SWT_CHARGING), v.battery);
        fontFor(b);
        canvas->setTextColor(C_GREEN);
        if (!linked) canvas->drawString(b, CX, H - 70);  // linked: the ring alone, the level is on the status page
      } else if (!v.hid) {
        fontFor(boardName);
        canvas->setTextColor(C_DIM);
        canvas->drawString(fit(boardName, 300), CX, H - 70);  // what to look for in the phone's Bluetooth list
      } else if (v.battery && v.battery < 15 && !linked) {  // linked: the low-battery banner still comes
        char b[8];
        snprintf(b, sizeof b, "%u%%", v.battery);
        canvas->setTextColor(C_RED);
        canvas->drawString(b, CX, H - 70);
      }
  }
  if (v.low) {  // the battery fell under 15 % or 5 %: a red banner over whatever is on screen, a few seconds
    char b[48];
    snprintf(b, sizeof b, T(SWT_LOW_BATTERY), v.low);
    canvas->fillSmoothRoundRect(CX - 170, 76, 340, 56, 28, C_RED);  // inside the round screen
    fontFor(b);
    canvas->setTextColor(TFT_WHITE);
    canvas->drawString(fit(b, 310), CX, 104);
  }
  if (v.hold >= 0) {  // blue held during a run: the stop countdown over whatever is on screen
    ring(v.hold * 20, C_RED, C_DIM, 200, 230);
    line(T(SWT_RELEASE_CANCELS), H - 50, TFT_WHITE, 1);
  }
}

// The face's motion as integers: a frame is drawn only when one of them changed.
#endif
