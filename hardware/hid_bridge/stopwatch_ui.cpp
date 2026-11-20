#ifdef M5_STOPWATCH
#include "stopwatch_ui.h"
#include "logbuf.h"
#include "version.h"
#include <M5Unified.h>
#include <atomic>
#include "src/ui/sw_face.h"
#include "src/ui/sw_model.h"
#include "src/ui/sw_text.h"
#include "voice_rec.h"
#include "stopwatch_draw.h"
#include <Preferences.h>

// Everything on the internal I2C bus (touch, IMU, PMIC, RTC, the IO expander behind the display power and the
// motor) and the display are only touched from this task once it runs; loop() reads cached values.
static TaskHandle_t task;
static SemaphoreHandle_t lock;
static sw_ui pending;
static bool hasPending, pendingOff;
static QueueHandle_t buttons;  // `btn` lines for loop()
static std::atomic<uint8_t> battery{0};
static std::atomic<bool> hidLinked{false}, appLinked{false};
static char boardName[32];
// The app's other lines for the task (latest wins), in PSRAM: `voice ...`, `picks [...]`, `answer ...`.
enum { L_VOICE, L_PICKS, L_ANSWER, L_KINDS };
static constexpr size_t LINE_CAP[L_KINDS] = {SW_SAID_MAX + 40, 256, SW_ANSWER_MAX + 1};
static char *answerText;  // the task's copy of the answer (PSRAM)
static const int ANSWER_ROWS = 5, ANSWER_GAP = 38, ANSWER_W = 360, ANSWER_LINES = 64;
static int answerStart[ANSWER_LINES + 1], answerLines;  // where each wrapped line starts
static char *lineBuf[L_KINDS];
static bool lineHas[L_KINDS];
static std::atomic<int> lang{SW_EN};
static std::atomic<int> fakeBtn{-1};  // `swpress`: 0 yellow, 1 blue, held fakeMs
static std::atomic<uint32_t> fakeMs{0};  // the screen's language (NVS "sw"/"lang"), English by default

static const int BTN_LINE = 32;
static const uint32_t SLEEP_AFTER_MS = 180000;  // no app, no touch, no button for 3 min: it falls asleep
static const uint32_t FRAME_MS = 33, SLEEP_FRAME_MS = 66;  // ~30 fps; the sleeping face only drifts its z
static const float SHAKE_G = 2.5f;  // acceleration magnitude of a deliberate shake; a wrist turn stays under 1.5 g
static const int SWIPE_PX = 60;

void stopwatch_begin() {
  auto cfg = M5.config();
  cfg.fallback_board = m5::board_t::board_M5StopWatch;
  cfg.pmic_button = false;  // its events fire on their own
  cfg.internal_mic = true;   // the ES8311 codec's mic, started only while yellow is held (voice_rec.h)
  cfg.internal_spk = false;  // the speaker shares the codec's I2S clocks: off, so the mic has them
  cfg.serial_baudrate = 0;  // setup() opens Serial
  cfg.output_power = false;  // the port's 5 V out: nothing is plugged in
  M5.begin(cfg);
  auto mic = M5.Mic.config();  // its I2S DMA comes out of internal RAM, of which ~15 KB is free: 8 x 128 frames took 11.5 KB
  mic.dma_buf_count = 4;
  mic.dma_buf_len = 128;
  mic.task_priority = 4;  // over the voice task (3), so a slow BLE send never lets the DMA overrun
  mic.task_pinned_core = 1;
  M5.Mic.config(mic);
  M5.Display.setBrightness(160);
  M5.Display.fillScreen(TFT_BLACK);
  int32_t level = M5.Power.getBatteryLevel();
  if (level >= 0 && level <= 100) battery = (uint8_t)level;
}

uint8_t stopwatch_battery() { return battery; }

void stopwatch_ui_link(bool hid, bool app) {
  hidLinked = hid;
  appLinked = app;
}

bool stopwatch_ui_line(const char *arg) {
  sw_ui u;
  int r = sw_parse(arg, &u);
  if (r == SW_PARSE_BAD || !lock) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  if (r == SW_PARSE_UI && hasPending && !u.has_picks) {  // the task has not seen the last line yet: keep its picks
    if (pendingOff) u.has_picks = true, u.npicks = 0;
    else if (pending.has_picks) u.has_picks = true, u.npicks = pending.npicks, memcpy(u.picks, pending.picks, sizeof u.picks);
  }
  pending = u;
  pendingOff = r == SW_PARSE_OFF;
  hasPending = true;
  xSemaphoreGive(lock);
  if (task) xTaskNotifyGive(task);
  return true;
}

static bool appLine(int kind, const char *arg, bool append = false) {
  if (!lock || !lineBuf[kind]) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  if (append) strlcat(lineBuf[kind], arg, LINE_CAP[kind]);  // cut at the cap; the screen cuts on a character
  else strlcpy(lineBuf[kind], arg, LINE_CAP[kind]);
  lineHas[kind] = true;
  xSemaphoreGive(lock);
  if (task) xTaskNotifyGive(task);
  return true;
}

// The task's copy of a line; false: none waiting.
static bool takeLine(int kind, char *out) {
  bool got = false;
  xSemaphoreTake(lock, portMAX_DELAY);
  if (lineHas[kind]) memcpy(out, lineBuf[kind], LINE_CAP[kind]), lineHas[kind] = false, got = true;
  xSemaphoreGive(lock);
  return got;
}

bool stopwatch_voice_line(const char *arg) {
  if (strncmp(arg, "heard", 5) && strncmp(arg, "fail", 4)) return false;
  return appLine(L_VOICE, arg);
}

bool stopwatch_answer_line(const char *arg, bool more) { return appLine(L_ANSWER, arg, more); }

bool stopwatch_picks_line(const char *arg) {
  sw_ctl probe;  // checked here, so a bad line gets its `err` reply
  sw_init(&probe);
  return sw_picks_line(&probe, arg) >= 0 && appLine(L_PICKS, arg);
}

bool stopwatch_press(const char *arg) {
  char b[8];
  unsigned ms = 0;
  if (sscanf(arg, "%7s %u", b, &ms) != 2 || ms > 600000 || (strcmp(b, "yellow") && strcmp(b, "blue"))) return false;
  fakeMs = ms;
  fakeBtn = !strcmp(b, "blue");
  return true;
}

static const char *T(int id) { return sw_text(lang, id); }

static void setLang(int l) {
  lang = l;
  Preferences p;
  if (p.begin("sw", false)) p.putUChar("lang", (uint8_t)l), p.end();
  board_log("stopwatch: language %s", sw_locale(l));
}

bool stopwatch_ui_next(char *out, size_t n) {
  char line[BTN_LINE];
  if (!buttons || xQueueReceive(buttons, line, 0) != pdTRUE) return false;
  strlcpy(out, line, n);
  return true;
}

// Vibration patterns: on/off durations in ms, starting with on. A poke's haptic is a single pulse.
struct Buzz {
  const uint16_t *steps = nullptr;
  int n = 0, at = 0;
  uint32_t since = 0;
  uint16_t pulse[1];
};
static const uint16_t BUZZ_HELP[] = {400};
static const uint16_t BUZZ_OK[] = {80, 120, 80};
static const uint16_t BUZZ_FAIL[] = {80, 120, 80, 120, 80};

static void buzzStart(Buzz &b, int kind, uint32_t now) {
  if (kind == SW_BUZZ_HELP) b.steps = BUZZ_HELP, b.n = 1;
  else if (kind == SW_BUZZ_OK) b.steps = BUZZ_OK, b.n = 3;
  else if (kind == SW_BUZZ_FAIL) b.steps = BUZZ_FAIL, b.n = 5;
  else return;
  b.at = 0;
  b.since = now;
  M5.Power.setVibration(200);
}

static void buzzPulse(Buzz &b, uint8_t ms, uint32_t now) {
  if (!ms || b.steps) return;  // a pattern is playing: it says more
  b.pulse[0] = ms, b.steps = b.pulse, b.n = 1, b.at = 0, b.since = now;
  M5.Power.setVibration(255);  // short pulses need the full kick to be felt
}

static void buzzRun(Buzz &b, uint32_t now) {
  if (!b.steps || now - b.since < b.steps[b.at]) return;
  b.since = now;
  if (++b.at >= b.n) {
    b.steps = nullptr;
    M5.Power.setVibration(0);
    return;
  }
  M5.Power.setVibration(b.at % 2 ? 0 : 200);
}

// Drawing. One canvas in PSRAM; a frame is drawn into it and only the part that changed is pushed, so a frame never
// shows half drawn and the eyes can move at 30 fps without sending the whole screen.
M5Canvas *canvas;  // stopwatch_draw.h
static int W, H, CX, CY;
static const uint16_t C_AMBER = 0xFD80, C_GREY = 0x8410, C_DIM = 0x4208, C_GREEN = 0x2E8A, C_RED = 0xF186,
                      C_ORANGE = 0xFC60;

static void font(const lgfx::IFont *f, float size = 1) {
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
static void fontFor(const char *s, int big = 1) {
  if (ascii(s)) font(big == 3 ? &fonts::FreeSansBold24pt7b : big == 2 ? &fonts::FreeSansBold18pt7b : &fonts::FreeSans12pt7b);
  else font(&fonts::efontCN_24, big == 3 ? 2 : big == 2 ? 1.5f : 1);
}

static int utf8Back(const String &s) {  // start of the last character
  int i = s.length() - 1;
  while (i > 0 && ((uint8_t)s[i] & 0xC0) == 0x80) i--;
  return i < 0 ? 0 : i;
}

static String fit(String s, int width) {
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
static void layoutAnswer() {
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

static void ring(int permille, uint16_t color, uint16_t track, int r0, int r1) {
  canvas->fillArc(CX, CY, r0, r1, 0, 360, track);
  if (permille > 0) canvas->fillArc(CX, CY, r0, r1, -90, -90 + 360.0f * permille / 1000, color);
}

// ---- the character (ios/Shared/AgentFace.swift; the pose comes from src/ui/sw_face.c) ----

// Where a point of the face lands: breathing about the centre, the squish and tilt anchored at the bottom of the
// face (PokeableFace's anchor: .bottom), then the lean / lift / hop offset.
static const int SW_SCR_STATUS = 100;
struct View {
  int screen, hold, sel;
  uint8_t battery;
  bool hid, alive;
  uint8_t lang;
  int16_t level;  // the mic's, while listening (in 50ths)
  char clock[6];
  sw_ui ui;
};

static const uint16_t GLOW_INK = lgfx::color565(255, 245, 219);  // AgentFace.glow

static void line(const char *text, int y, uint16_t color, int lines = 2, int width = 330) {
  canvas->setTextColor(color);
  fontFor(text);
  wrapped(text, y, width, lines, 32);
}

static const int STATUS_Y = 140, STATUS_GAP = 42, STATUS_LANG = 5;  // the language row: a tap there switches

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

static void statusPage(const View &v) {
  canvas->setTextColor(TFT_WHITE);
  font(&fonts::Font4);
  canvas->drawString(v.clock[0] ? v.clock : "--:--", CX, 80);
  char bat[32], fw[32];
  if (v.battery) snprintf(bat, sizeof bat, "%s%u%%", T(SWT_BATTERY), v.battery);
  else strlcpy(bat, T(SWT_BATTERY_NONE), sizeof bat);
  snprintf(fw, sizeof fw, "%s%s", T(SWT_FIRMWARE), FW_VERSION);
  const char *rows[] = {bat, T(v.hid ? SWT_BT_ON : SWT_BT_OFF), T(v.alive ? SWT_APP_ON : SWT_APP_OFF), fw, boardName,
                        T(SWT_LANGUAGE)};
  for (int i = 0; i < 6; i++) {
    bool ok = i == 1 ? v.hid : i == 2 ? v.alive : true;
    canvas->setTextColor(i == 4 ? C_GREY : i == STATUS_LANG ? C_AMBER : ok ? (i == 1 || i == 2 ? C_GREEN : TFT_WHITE) : C_GREY);
    fontFor(rows[i]);
    canvas->drawString(fit(rows[i], 330), CX, STATUS_Y + i * STATUS_GAP);
  }
}

static void draw(const View &v, const sw_ctl &c, const swf_pose &pose) {
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
  switch (v.screen) {
    case SW_SCR_RUN: case SW_SCR_PAUSED:
      if (count >= 0) ring(count, C_GREEN, scaled(C_GREEN, 0.25f), 220, 230);
      canvas->setTextColor(count >= 0 ? C_GREEN : C_GREY);
      font(&fonts::Font4);
      canvas->drawString(v.screen == SW_SCR_PAUSED ? "" : counter, CX, 62);
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
    default:  // idle: the character, awake while the app is there (AppModel.mood), the picks when selecting
      face(pose, CX, CY - 10, GLOW_INK, true);
      font(&fonts::efontCN_24);
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
      } else if (!v.hid) {
        fontFor(boardName);
        canvas->setTextColor(C_DIM);
        canvas->drawString(fit(boardName, 300), CX, H - 70);  // what to look for in the phone's Bluetooth list
      } else if (v.battery && v.battery < 15) {
        char b[8];
        snprintf(b, sizeof b, "%u%%", v.battery);
        canvas->setTextColor(C_RED);
        canvas->drawString(b, CX, H - 70);
      }
  }
  if (v.hold >= 0) {  // blue held during a run: the stop countdown over whatever is on screen
    ring(v.hold * 20, C_RED, C_DIM, 200, 230);
    line(T(SWT_RELEASE_CANCELS), H - 50, TFT_WHITE, 1);
  }
}

// The face's motion as integers: a frame is drawn only when one of them changed.
struct PoseKey {
  int mood, gx, gy, sx, sy, tilt, dx, dy, blink, breathe, spin;
};

static PoseKey key(const swf_pose &p) {
  int spin = p.mood == SW_DIZZY ? (int)(p.t * 9 * 12) : p.mood == SW_SLEEPING ? (int)(fmodf(p.t, 3) * 15) : 0;
  return {p.mood, (int)lroundf(p.gaze_x * 60), (int)lroundf(p.gaze_y * 60), (int)lroundf(p.sx * 400), (int)lroundf(p.sy * 400),
          (int)lroundf(p.tilt * 4), (int)lroundf(p.dx * PX), (int)lroundf(p.dy * PX + p.float_y * PX), (int)lroundf(p.blink * 40),
          (int)lroundf(p.breathe * 800), spin};
}

static void send(const char *line) {
  char b[BTN_LINE] = {};
  strlcpy(b, line, sizeof b);
  xQueueSend(buttons, b, 0);  // 8 waiting: loop() is stuck, and a late press is worth nothing
}

static void uiTask(void *) {
  sw_ctl c;
  sw_init(&c);
  sw_face f;
  swf_init(&f, PX, millis());
  Buzz buzz;
  View last;
  memset(&last, 0xff, sizeof last);
  PoseKey lastKey;
  memset(&lastKey, 0xff, sizeof lastKey);
  int lx0 = 0, ly0 = 0, lx1 = W, ly1 = H;  // the face's area in the last frame (with no face: empty, not used)
  bool wasApp = false, micOn = false, streamed = false;
  uint32_t activeAt = millis();
  uint32_t batteryAt = millis(), statusUntil = 0, statAt = millis(), frames = 0, drawMs = 0, drawMax = 0;
  char out[BTN_LINE];
  // The codec's mic gives only zeros for ~0.85 s after its first start since power-on (measured 2026-11-21), later
  // starts are live at once: start it once now, so the first press records from the press.
  bool warming = voice_press("en-US");
  uint32_t warmAt = millis();
  for (;;) {
    TickType_t start = xTaskGetTickCount();
    uint32_t now = millis();
    M5.update();
    // the app's lines
    sw_ui u;
    bool got = false, off = false;
    xSemaphoreTake(lock, portMAX_DELAY);
    if (hasPending) u = pending, off = pendingOff, got = true, hasPending = false;
    xSemaphoreGive(lock);
    char said[LINE_CAP[L_VOICE]], picks[LINE_CAP[L_PICKS]];
    bool gotVoice = takeLine(L_VOICE, said);
    if (got) buzzStart(buzz, sw_apply(&c, &u, off, now), now);
    if (takeLine(L_PICKS, picks)) sw_picks_line(&c, picks);
    if (takeLine(L_ANSWER, answerText)) {
      layoutAnswer();
      sw_answer(&c);
      c.pages = (uint8_t)max(1, (answerLines + ANSWER_ROWS - 1) / ANSWER_ROWS);
      board_log("stopwatch: answer of %u bytes, %d lines, %d pages", (unsigned)strlen(answerText), answerLines, c.pages);
    }
    if (gotVoice) {
      uint8_t was = c.voice;
      sw_voice_line(&c, said, now);
      if (c.voice != was) buzzPulse(buzz, c.voice == SW_V_RESULT ? 60 : 0, now);  // the text is there
    }
    bool app = appLinked;
    if (wasApp && !app) sw_apply(&c, nullptr, true, now);  // the phone's link is gone: idle, as after `ui off`
    wasApp = app;
    bool running = sw_running(&c, now), alive = sw_alive(&c, now);
    // buttons, touch, shake
    // the buttons, or a test press from USB serial (`swpress`)
    bool yDown = M5.BtnA.wasPressed(), yUp = M5.BtnA.wasReleased(), bDown = M5.BtnB.wasPressed(), bUp = M5.BtnB.wasReleased();
    static uint32_t fakeUntil;
    static int fakeHeld = -1;
    int fb = fakeBtn.exchange(-1);
    if (fb >= 0 && fakeHeld < 0) (fb ? bDown : yDown) = true, fakeHeld = fb, fakeUntil = now + fakeMs;
    if (fakeHeld >= 0 && (int32_t)(now - fakeUntil) >= 0) (fakeHeld ? bUp : yUp) = true, fakeHeld = -1;
    bool voiceBefore = c.voice != SW_V_NONE || c.sel >= 0, legacy = !(alive && c.ui.voice) && !c.y_down;
    bool pokeIdle = !running && !c.ui.npicks;  // yellow with nothing to pick: it reacts
    if (statusUntil && yDown) {  // yellow on the status page: the other language (Henry 2026-11-21)
      setLang(sw_lang_next(lang));
      statusUntil = now + 5000;
    } else {
      if (yDown && sw_input(&c, SW_IN_YELLOW_DOWN, now, out, sizeof out)) send(out);
      bool shortUp = yUp && c.y_down && c.voice == SW_V_NONE;
      if (yUp && sw_input(&c, SW_IN_YELLOW_UP, now, out, sizeof out)) send(out);
      if (pokeIdle && (legacy ? yDown : shortUp)) swf_poke(&f, now);
    }
    if (bDown && sw_input(&c, SW_IN_BLUE_DOWN, now, out, sizeof out)) send(out);
    if (bUp && sw_input(&c, SW_IN_BLUE_UP, now, out, sizeof out)) send(out);
    if (yDown) board_log("stopwatch: yellow");
    if (bDown) board_log("stopwatch: blue");
    if (!running && !voiceBefore && bDown) {  // blue while nothing runs: the status page, on and off (Henry 2026-11-20)
      statusUntil = statusUntil ? 0 : now + 5000;
      c.blue_ignore = true;  // no `home`, no `stop` from this press
    }
    if (got || M5.BtnA.isPressed() || M5.BtnB.isPressed() || M5.Touch.getCount()) activeAt = now;
    int screen = sw_screen(&c, now);
    // the face's mood: the run's, the outcome's, or AppModel.mood (idle with the app, asleep without)
    int mood = screen == SW_SCR_OK ? SW_SUCCESS : screen == SW_SCR_FAIL ? SW_FAILURE
               : c.voice == SW_V_LISTEN ? SW_LISTENING : c.voice == SW_V_WAIT ? SW_THINKING
               : c.voice == SW_V_SENT ? SW_SUCCESS : c.voice == SW_V_ERROR ? SW_FAILURE
               : running || screen == SW_SCR_STUCK ? c.ui.mood
               : alive || now - activeAt < SLEEP_AFTER_MS ? SW_IDLE : SW_SLEEPING;  // awake, looking around; asleep when left alone
    swf_mood(&f, mood, running, c.ui.look_x, c.ui.look_y, now);
    bool down = false;
    int tx = 0, ty = 0;
    for (int i = 0; i < M5.Touch.getCount(); i++) {
      auto &t = M5.Touch.getDetail(i);
      if (i == 0 && t.isPressed()) down = true, tx = t.x, ty = t.y;
      if (t.wasClicked() && statusUntil && abs(t.y - (STATUS_Y + STATUS_LANG * STATUS_GAP)) < STATUS_GAP / 2 + 6) {
        setLang(sw_lang_next(lang));  // a tap on the language row
        statusUntil = now + 5000;
        continue;
      }
      if (t.wasClicked() && sw_input(&c, SW_IN_TAP, now, out, sizeof out)) send(out);
      bool ended = t.wasFlicked() || t.state == m5::touch_state_t::drag_end;
      if (ended && t.distanceY() < -SWIPE_PX && abs(t.distanceY()) > abs(t.distanceX()) &&
          sw_input(&c, SW_IN_SWIPE_UP, now, out, sizeof out))
        send(out);
    }
    swf_touch(&f, down, tx, ty, W, H, now);
    float ax, ay, az;
    if (M5.Imu.getAccel(&ax, &ay, &az) && ax * ax + ay * ay + az * az > SHAKE_G * SHAKE_G) {
      if (running) sw_input(&c, SW_IN_SHAKE, now, out, sizeof out);
      else swf_dizzy(&f, now);
    }
    if (statusUntil && (running || c.voice != SW_V_NONE || (int32_t)(now - statusUntil) >= 0)) statusUntil = 0;
    if (sw_tick(&c, now, out, sizeof out)) send(out);
    buzzStart(buzz, sw_buzz_due(&c, now), now);  // help: again and again until answered
    // the mic: on from yellow's press (voice_rec.h), sent once the hold is a recording, off at release or blue
    if (warming && now - warmAt >= 1200) voice_release(), warming = false;
    bool mic = sw_mic(&c);
    if (mic && !micOn) micOn = voice_press(sw_locale(lang));
    if (micOn && c.voice == SW_V_LISTEN && !streamed) voice_stream(), streamed = true;
    if (micOn && !mic) voice_release(), micOn = streamed = false;
    voice_poll();
    buzzPulse(buzz, swf_haptic(&f), now);
    buzzRun(buzz, now);
    if (now - batteryAt >= 10000) {
      int32_t level = M5.Power.getBatteryLevel();
      if (level >= 0 && level <= 100) battery = (uint8_t)level;
      batteryAt = now;
    }
    // draw: everything when the view changed, else only the face's area when it moved
    View v;
    memset(&v, 0, sizeof v);
    v.screen = statusUntil ? SW_SCR_STATUS : screen;
    v.hold = running && sw_hold(&c, now) >= 0 ? sw_hold(&c, now) / 20 : -1;
    v.sel = c.sel;
    v.battery = battery;
    v.hid = hidLinked;
    v.alive = alive;
    v.lang = lang;
    v.level = c.voice == SW_V_LISTEN ? voice_level() / 50 : 0;
    if (v.screen == SW_SCR_STATUS) sw_clock(&c, now, v.clock);
    v.ui = c.ui;
    v.ui.look_x = v.ui.look_y = 0;  // the face's motion, not the view
    swf_pose pose;
    swf_pose_at(&f, &pose);
    PoseKey k = key(pose);
    bool full = memcmp(&v, &last, sizeof v) != 0, moved = place.on && memcmp(&k, &lastKey, sizeof k) != 0;
    if (full || moved) {
      uint32_t t0 = millis();
      int x0 = 0, y0 = 0, x1 = W, y1 = H;
      if (!full) {  // only the face moved: redraw and send the area of its old and new place
        measuring = true;
        bx0 = by0 = 1e9f, bx1 = by1 = -1e9f;
        face(pose, place.cx, place.cy, place.color, place.glow, place.crossed);
        measuring = false;
        x0 = min(lx0, (int)floorf(bx0) - 2), y0 = min(ly0, (int)floorf(by0) - 2);
        x1 = max(lx1, (int)ceilf(bx1) + 2), y1 = max(ly1, (int)ceilf(by1) + 2);
        x0 = max(0, x0 & ~1), y0 = max(0, y0 & ~1), x1 = min(W, (x1 + 1) & ~1), y1 = min(H, (y1 + 1) & ~1);
        canvas->setClipRect(x0, y0, x1 - x0, y1 - y0);
      }
      draw(v, c, pose);
      canvas->clearClipRect();
      lx0 = (int)floorf(bx0) - 2, ly0 = (int)floorf(by0) - 2, lx1 = (int)ceilf(bx1) + 2, ly1 = (int)ceilf(by1) + 2;
      M5.Display.setClipRect(x0, y0, x1 - x0, y1 - y0);
      canvas->pushSprite(0, 0);
      M5.Display.clearClipRect();
      last = v, lastKey = k;
      uint32_t took = millis() - t0;
      drawMs += took, drawMax = max(drawMax, took), frames++;
    }
    if (now - statAt >= 60000) {  // how hard the screen works, once a minute
      board_log("stopwatch: %u frames/min, draw avg %u ms max %u ms, stack left %u, internal heap %u\n",
                (unsigned)frames, (unsigned)(frames ? drawMs / frames : 0), (unsigned)drawMax,
                (unsigned)uxTaskGetStackHighWaterMark(nullptr), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
      statAt = now, frames = drawMs = drawMax = 0;
    }
    // a `ui` line wakes the task early; otherwise the next frame
    uint32_t frame = pose.mood == SW_SLEEPING && v.screen == SW_SCR_IDLE ? SLEEP_FRAME_MS : FRAME_MS;
    TickType_t next = start + pdMS_TO_TICKS(frame), nowT = xTaskGetTickCount();
    if ((int32_t)(next - nowT) <= 0) next = nowT + 1;  // late (a long draw): never spin, other tasks get the core
    ulTaskNotifyTake(pdTRUE, next - nowT);
  }
}

void stopwatch_ui_start(const char *name) {
  strlcpy(boardName, name, sizeof boardName);
  Preferences p;
  if (p.begin("sw", true)) lang = p.getUChar("lang", SW_EN) < SW_LANGS ? p.getUChar("lang", SW_EN) : SW_EN, p.end();
  W = M5.Display.width(), H = M5.Display.height(), CX = W / 2, CY = H / 2;
  canvas = new M5Canvas(&M5.Display);
  canvas->setPsram(true);
  canvas->setColorDepth(16);
  if (!canvas->createSprite(W, H)) log_e("stopwatch: no PSRAM for the screen");
  canvas->setTextWrap(false);
  lock = xSemaphoreCreateMutex();
  for (int i = 0; i < L_KINDS; i++) lineBuf[i] = (char *)heap_caps_calloc(1, LINE_CAP[i], MALLOC_CAP_SPIRAM);
  answerText = (char *)heap_caps_calloc(1, LINE_CAP[L_ANSWER], MALLOC_CAP_SPIRAM);
  buttons = xQueueCreate(8, BTN_LINE);
  // Core 1 next to loop(), at its priority: drawing shares the core instead of starving it (NimBLE and Wi-Fi run
  // on core 0). The stack holds no frame: the canvas is in PSRAM.
  xTaskCreatePinnedToCore(uiTask, "screen", 8192, nullptr, 1, &task, 1);
}
#endif
