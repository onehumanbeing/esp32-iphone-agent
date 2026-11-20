#ifdef M5_STOPWATCH
#include "stopwatch_ui.h"
#include "logbuf.h"
#include "version.h"
#include <M5Unified.h>
#include <atomic>
#include "src/ui/sw_face.h"
#include "src/ui/sw_model.h"

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

static const int BTN_LINE = 32;
static const uint32_t SLEEP_AFTER_MS = 180000;  // no app, no touch, no button for 3 min: it falls asleep
static const uint32_t FRAME_MS = 33, SLEEP_FRAME_MS = 66;  // ~30 fps; the sleeping face only drifts its z
static const float SHAKE_G = 2.5f;  // acceleration magnitude of a deliberate shake; a wrist turn stays under 1.5 g
static const int SWIPE_PX = 60;

void stopwatch_begin() {
  auto cfg = M5.config();
  cfg.fallback_board = m5::board_t::board_M5StopWatch;
  cfg.pmic_button = false;  // its events fire on their own
  cfg.internal_mic = false;
  cfg.internal_spk = false;
  cfg.serial_baudrate = 0;  // setup() opens Serial
  cfg.output_power = false;  // the port's 5 V out: nothing is plugged in
  M5.begin(cfg);
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
static M5Canvas *canvas;
static int W, H, CX, CY;
static const uint16_t C_AMBER = 0xFD80, C_GREY = 0x8410, C_DIM = 0x4208, C_GREEN = 0x2E8A, C_RED = 0xF186,
                      C_ORANGE = 0xFC60;
static const float FACE_S = 330;           // the face's size `s` in AgentFace, in pixels
static const float PX = FACE_S / 128;      // pixels per app point: the Home face is 128 points wide
static const float LOOK_RANGE = 1.6f;      // how far the eyes travel (Home 1, the tiny island 2.4)

static void font(const lgfx::IFont *f, float size = 1) {
  canvas->setFont(f);
  canvas->setTextSize(size);
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
  String rest = text, out[3];
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

static void ring(int permille, uint16_t color, uint16_t track, int r0, int r1) {
  canvas->fillArc(CX, CY, r0, r1, 0, 360, track);
  if (permille > 0) canvas->fillArc(CX, CY, r0, r1, -90, -90 + 360.0f * permille / 1000, color);
}

// ---- the character (ios/Shared/AgentFace.swift; the pose comes from src/ui/sw_face.c) ----

// Where a point of the face lands: breathing about the centre, the squish and tilt anchored at the bottom of the
// face (PokeableFace's anchor: .bottom), then the lean / lift / hop offset.
struct Xf {
  float cx, cy, a, sx, sy, cs, sn, dx, dy, br;
  void at(float x, float y, float &ox, float &oy) const {
    x *= br, y *= br;
    float X = x * sx, Y = (y - a) * sy;
    ox = cx + dx + X * cs - Y * sn;
    oy = cy + dy + a + X * sn + Y * cs;
  }
  float scale() const { return br * (sx + sy) / 2; }
};

static Xf xf;
static uint16_t ink;        // the eyes' colour
static bool glowOn;         // the soft glow around the eyes (on black only)
static bool measuring;      // only find what the face will cover (bx0...), draw nothing
static float bx0, by0, bx1, by1;  // what this frame's face covered, for the partial push

static void cover(float x0, float y0, float x1, float y1) {
  bx0 = fminf(bx0, x0), by0 = fminf(by0, y0), bx1 = fmaxf(bx1, x1), by1 = fmaxf(by1, y1);
}

static uint16_t scaled(uint16_t c, float k) {  // a colour dimmed toward black
  uint8_t r = (c >> 11) * 255 / 31, g = ((c >> 5) & 63) * 255 / 63, b = (c & 31) * 255 / 31;
  return lgfx::color565(r * k, g * k, b * k);
}

// AgentFace's glow is a shadow of radius 0.05 s: two dim halos, then the shape.
static const float GLOW1 = 0.045f * FACE_S, GLOW2 = 0.022f * FACE_S;

static void capsule(float x, float y, float w, float h, uint16_t c) {
  float ox, oy;
  xf.at(x, y, ox, oy);
  w *= xf.sx * xf.br, h *= xf.sy * xf.br;
  for (int pass = measuring ? 3 : glowOn ? 0 : 2; pass < 3; pass++) {
    float g = pass == 0 ? GLOW1 : pass == 1 ? GLOW2 : 0;
    float ww = w + 2 * g, hh = h + 2 * g;
    uint16_t col = pass == 0 ? scaled(c, 0.10f) : pass == 1 ? scaled(c, 0.24f) : c;
    canvas->fillSmoothRoundRect(lroundf(ox - ww / 2), lroundf(oy - hh / 2), lroundf(ww), lroundf(hh),
                                lroundf(fminf(ww, hh) / 2), col);
  }
  float g = glowOn ? GLOW1 : 0;
  cover(ox - w / 2 - g, oy - h / 2 - g, ox + w / 2 + g, oy + h / 2 + g);
}

// A stroked path with round caps and joins, in face coordinates.
static void stroke(const float *pts, int n, float width, uint16_t c) {
  static float sx[64], sy[64];
  n = n > 64 ? 64 : n;
  for (int i = 0; i < n; i++) xf.at(pts[2 * i], pts[2 * i + 1], sx[i], sy[i]);
  float r = width / 2 * xf.scale();
  for (int pass = measuring ? 3 : glowOn ? 0 : 2; pass < 3; pass++) {
    float g = pass == 0 ? GLOW1 : pass == 1 ? GLOW2 : 0;
    uint16_t col = pass == 0 ? scaled(c, 0.10f) : pass == 1 ? scaled(c, 0.24f) : c;
    for (int i = 0; i + 1 < n; i++) canvas->drawWideLine(sx[i], sy[i], sx[i + 1], sy[i + 1], r + g, col);
  }
  float g = r + (glowOn ? GLOW1 : 0);
  for (int i = 0; i < n; i++) cover(sx[i] - g, sy[i] - g, sx[i] + g, sy[i] + g);
}

static void caret(float x, float y, float w, float h, float width, uint16_t c) {  // "^"
  const float p[] = {x - w / 2, y + h / 2, x, y - h / 2, x + w / 2, y + h / 2};
  stroke(p, 3, width, c);
}

static void smile(float x, float y, float w, float h, float width, uint16_t c) {  // "‿", the quad curve of Smile
  float p[2 * 13];
  for (int i = 0; i <= 12; i++) {
    float t = i / 12.0f, top = y - h / 2, ctl = y + h / 2 * 3;  // control at maxY·2 − minY
    p[2 * i] = x - w / 2 + w * t;
    p[2 * i + 1] = (1 - t) * (1 - t) * top + 2 * (1 - t) * t * ctl + t * t * top;
  }
  stroke(p, 13, width, c);
}

static void spiral(float x, float y, float size, float turn, float width, uint16_t c) {
  float p[2 * 61];
  for (int i = 0; i <= 60; i++) {
    float a = i / 60.0f * 2.6f * 2 * PI + turn, rad = size / 2 * i / 60;
    p[2 * i] = x + rad * cosf(a), p[2 * i + 1] = y + rad * sinf(a);
  }
  stroke(p, 61, width, c);
}

static void cross(float x, float y, float size, float width, uint16_t c) {  // "×"
  const float a[] = {x - size / 2, y - size / 2, x + size / 2, y + size / 2};
  const float b[] = {x + size / 2, y - size / 2, x - size / 2, y + size / 2};
  stroke(a, 2, width, c), stroke(b, 2, width, c);
}

// Where the last full frame put the face: a frame where only the face moved redraws just around it.
static struct {
  bool on;
  int cx, cy;
  uint16_t color;
  bool glow, crossed;
} place;

// The face of AgentFace.moodEyes at (cx, cy), from a pose. crossed: the island's stuck "×" eyes.
static void face(const swf_pose &p, int cx, int cy, uint16_t color, bool glow, bool crossed = false) {
  if (!measuring) place = {true, cx, cy, color, glow, crossed};
  const float s = FACE_S, w = s * 0.14f, h = s * 0.25f, gap = s * 0.37f;
  float tilt = p.tilt * PI / 180;
  xf = {(float)cx, (float)cy, s * 0.62f, p.sx, p.sy, cosf(tilt), sinf(tilt), p.dx * PX, (p.dy + p.float_y) * PX,
        p.breathe};
  ink = color, glowOn = glow;
  const uint16_t c = ink;
  if (crossed) {
    for (int i = -1; i <= 1; i += 2) cross(i * gap / 2, -s * 0.02f, w * 1.5f, s * 0.055f, c);
    return;
  }
  switch (p.mood) {
    case SW_SLEEPING: {
      glowOn = false;
      uint16_t dim = scaled(c, 0.55f);
      for (int i = -1; i <= 1; i += 2) capsule(i * gap / 2, s * 0.05f, w, s * 0.025f, dim);
      float k = fmodf(p.t, 3) / 3, ox, oy;  // the z drifts up and fades
      xf.at(s * 0.24f + k * s * 0.08f, -s * 0.18f - k * s * 0.12f, ox, oy);
      if (!measuring) {
        font(&fonts::FreeSansBold18pt7b);
        canvas->setTextColor(scaled(c, 1 - k));
        canvas->drawString("z", ox, oy);
      }
      cover(ox - 20, oy - 24, ox + 20, oy + 24);
      break;
    }
    case SW_SUCCESS:
      for (int i = -1; i <= 1; i += 2) caret(i * (gap + 0.3f * w) / 2, -s * 0.02f, w * 1.3f, h * 0.45f, s * 0.05f, c);
      break;
    case SW_DIZZY:
      for (int i = -1; i <= 1; i += 2) spiral(i * (gap + 0.3f * w) / 2, 0, w * 1.7f, -i * p.t * 9, s * 0.03f, c);
      break;
    case SW_CONTENT:
      for (int i = -1; i <= 1; i += 2) smile(i * gap / 2, s * 0.04f, w * 1.3f, h * 0.28f, s * 0.045f, c);
      break;
    case SW_WINK:
      capsule(-gap / 2 - 0.075f * w, -s * 0.02f, w, h, c);
      caret(gap / 2 - 0.075f * w, -s * 0.02f, w * 1.3f, h * 0.35f, s * 0.05f, c);
      break;
    case SW_FAILURE:  // bottom-aligned, one eye smaller: sad
      capsule(-gap / 2 + 0.1f * w, s * 0.05f, w * 1.1f, h * 0.85f, c);
      capsule(gap / 2 + 0.05f * w, s * 0.05f + 0.15f * h, w * 0.8f, h * 0.55f, c);
      break;
    default: {
      float k = p.mood == SW_LISTENING ? 1.15f : 1;
      float dx = p.gaze_x * s * 0.05f * LOOK_RANGE, dy = p.gaze_y * s * 0.04f * LOOK_RANGE - s * 0.02f;
      for (int i = -1; i <= 1; i += 2) {
        float bob = p.mood == SW_THINKING ? i * s * 0.02f * sinf(p.t * 2.4f) : 0;
        capsule(i * (gap - w + w * k) / 2 + dx, dy + bob, w * k, h * k * p.blink, c);
      }
    }
  }
}

// What is on screen besides the face's motion; a change redraws everything.
static const int SW_SCR_STATUS = 100;
struct View {
  int screen, hold, sel;
  uint8_t battery;
  bool hid, alive;
  char clock[6];
  sw_ui ui;
};

static const uint16_t GLOW_INK = lgfx::color565(255, 245, 219);  // AgentFace.glow

static void line(const char *text, int y, uint16_t color) {
  canvas->setTextColor(color);
  font(&fonts::efontCN_24);
  wrapped(text, y, 330, 2, 32);
}

static void statusPage(const View &v) {
  canvas->setTextColor(TFT_WHITE);
  font(&fonts::Font4);
  canvas->drawString(v.clock[0] ? v.clock : "--:--", CX, 85);
  font(&fonts::efontCN_24);
  char bat[24];
  snprintf(bat, sizeof bat, v.battery ? "电量 %u%%" : "电量 --", v.battery);
  char name[48];
  snprintf(name, sizeof name, "%s", boardName);
  const char *rows[] = {bat, v.hid ? "蓝牙 已连接手机" : "蓝牙 未连接", v.alive ? "App 已连接" : "App 未连接",
                        "固件 " FW_VERSION, name};
  for (int i = 0; i < 5; i++) {
    bool ok = i == 1 ? v.hid : i == 2 ? v.alive : true;
    canvas->setTextColor(i == 4 ? C_GREY : ok ? (i == 1 || i == 2 ? C_GREEN : TFT_WHITE) : C_GREY);
    canvas->drawString(fit(rows[i], 330), CX, 155 + i * 46);
  }
}

static void draw(const View &v, const sw_ctl &c, const swf_pose &pose) {
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
      if (v.screen == SW_SCR_PAUSED) line("已暂停 · 黄键继续", CY + 130, C_GREY);
      else line(u.text, CY + 130, u.phase == SW_RECORDING ? C_RED : TFT_WHITE);
      break;
    case SW_SCR_HELP:
      canvas->setTextColor(TFT_BLACK);
      font(&fonts::efontCN_24, 1.5f);
      canvas->drawString("需要你帮忙", CX, 82);
      face(pose, CX, CY - 25, TFT_BLACK, false);
      line(u.text, CY + 115, TFT_BLACK);
      font(&fonts::efontCN_24);
      canvas->drawString("点屏幕继续 · 上滑接手", CX, H - 68);
      break;
    case SW_SCR_OK: case SW_SCR_FAIL: {
      bool ok = v.screen == SW_SCR_OK;
      if (ok && count >= 0) ring(1000, C_GREEN, C_GREEN, 220, 230);
      face(pose, CX, CY - 30, GLOW_INK, true);
      line(u.text[0] ? u.text : ok ? "完成" : "没有完成", CY + 130, ok ? C_GREEN : C_ORANGE);
      break;
    }
    case SW_SCR_STUCK:
      face(pose, CX, CY - 30, GLOW_INK, true, true);
      line("App 被 iOS 暂停了 · 打开 App 继续", CY + 130, C_ORANGE);
      break;
    case SW_SCR_CONFIRM:
      canvas->setTextColor(TFT_WHITE);
      font(&fonts::efontCN_24, 1.5f);
      canvas->drawString("确认发送？", CX, CY - 60);
      font(&fonts::efontCN_24);
      canvas->drawString(fit(u.picks[c.sel], 330), CX, CY + 10);
      canvas->setTextColor(C_GREY);
      canvas->drawString("再按黄键发送", CX, CY + 70);
      break;
    case SW_SCR_SHAKE:
      canvas->setTextColor(TFT_WHITE);
      font(&fonts::efontCN_24, 2);
      canvas->drawString("摇一摇停止?", CX, CY - 20);
      font(&fonts::efontCN_24);
      canvas->drawString("按任意键取消", CX, CY + 50);
      break;
    case SW_SCR_STATUS:
      statusPage(v);
      break;
    default:  // idle: the character, awake while the app is there (AppModel.mood), the picks when selecting
      face(pose, CX, CY - 10, GLOW_INK, true);
      font(&fonts::efontCN_24);
      if (c.sel >= 0 && u.npicks) {
        canvas->fillSmoothRoundRect(CX - 150, CY + 125, 300, 44, 22, TFT_WHITE);
        canvas->setTextColor(TFT_BLACK);
        canvas->drawString(fit(u.picks[c.sel], 270), CX, CY + 147);
      } else if (!v.hid) {
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
    canvas->setTextColor(TFT_WHITE);
    font(&fonts::efontCN_24);
    canvas->drawString("松开取消", CX, H - 50);
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
  bool wasApp = false;
  uint32_t activeAt = millis();
  uint32_t batteryAt = millis(), statusUntil = 0, statAt = millis(), frames = 0, drawMs = 0, drawMax = 0;
  char out[BTN_LINE];
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
    if (got) buzzStart(buzz, sw_apply(&c, &u, off, now), now);
    bool app = appLinked;
    if (wasApp && !app) sw_apply(&c, nullptr, true, now);  // the phone's link is gone: idle, as after `ui off`
    wasApp = app;
    bool running = sw_running(&c, now), alive = sw_alive(&c, now);
    // buttons, touch, shake
    if (M5.BtnA.wasPressed() && sw_input(&c, SW_IN_YELLOW, now, out, sizeof out)) send(out);
    if (M5.BtnB.wasPressed() && sw_input(&c, SW_IN_BLUE_DOWN, now, out, sizeof out)) send(out);
    if (M5.BtnB.wasReleased() && sw_input(&c, SW_IN_BLUE_UP, now, out, sizeof out)) send(out);
    if (M5.BtnA.wasPressed()) board_log("stopwatch: yellow");
    if (M5.BtnB.wasPressed()) board_log("stopwatch: blue");
    if (!running && M5.BtnB.wasPressed()) {  // blue while nothing runs: the status page, on and off (Henry 2026-11-20)
      statusUntil = statusUntil ? 0 : now + 5000;
      c.blue_ignore = true;  // no `home`, no `stop` from this press
    }
    if (!running && !c.ui.npicks && M5.BtnA.wasPressed()) swf_poke(&f, now);  // yellow with nothing to pick: it reacts
    if (got || M5.BtnA.isPressed() || M5.BtnB.isPressed() || M5.Touch.getCount()) activeAt = now;
    int screen = sw_screen(&c, now);
    // the face's mood: the run's, the outcome's, or AppModel.mood (idle with the app, asleep without)
    int mood = screen == SW_SCR_OK ? SW_SUCCESS : screen == SW_SCR_FAIL ? SW_FAILURE
               : running || screen == SW_SCR_STUCK ? c.ui.mood
               : alive || now - activeAt < SLEEP_AFTER_MS ? SW_IDLE : SW_SLEEPING;  // awake, looking around; asleep when left alone
    swf_mood(&f, mood, running, c.ui.look_x, c.ui.look_y, now);
    bool down = false;
    int tx = 0, ty = 0;
    for (int i = 0; i < M5.Touch.getCount(); i++) {
      auto &t = M5.Touch.getDetail(i);
      if (i == 0 && t.isPressed()) down = true, tx = t.x, ty = t.y;
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
    if (statusUntil && (running || M5.BtnA.wasPressed() || (int32_t)(now - statusUntil) >= 0)) statusUntil = 0;
    if (sw_tick(&c, now, out, sizeof out)) send(out);
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
  W = M5.Display.width(), H = M5.Display.height(), CX = W / 2, CY = H / 2;
  canvas = new M5Canvas(&M5.Display);
  canvas->setPsram(true);
  canvas->setColorDepth(16);
  if (!canvas->createSprite(W, H)) log_e("stopwatch: no PSRAM for the screen");
  canvas->setTextWrap(false);
  lock = xSemaphoreCreateMutex();
  buttons = xQueueCreate(8, BTN_LINE);
  // Core 1 next to loop(), at its priority: drawing shares the core instead of starving it (NimBLE and Wi-Fi run
  // on core 0). The stack holds no frame: the canvas is in PSRAM.
  xTaskCreatePinnedToCore(uiTask, "screen", 8192, nullptr, 1, &task, 1);
}
#endif
