#ifdef M5_STOPWATCH
#include "stopwatch_ui.h"
#include <M5Unified.h>
#include <atomic>
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

static const int BTN_LINE = 32;
static const uint32_t FRAME_MS = 20;
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

// Vibration patterns: on/off durations in ms, starting with on.
struct Buzz {
  const uint16_t *steps = nullptr;
  int n = 0, at = 0;
  uint32_t since = 0;
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

// Drawing. One canvas in PSRAM, pushed whole, so a frame never shows half drawn.
static M5Canvas *canvas;
static int W, H, CX, CY;
static const uint16_t C_AMBER = 0xFD80, C_GREY = 0x4208, C_TRACK = 0x2124, C_RING = 0x5E7F, C_GREEN = 0x2E8A, C_RED = 0xF186;

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

static void ring(int permille, uint16_t color, int r0, int r1) {
  canvas->fillArc(CX, CY, r0, r1, 0, 360, C_TRACK);
  if (permille > 0) canvas->fillArc(CX, CY, r0, r1, -90, -90 + 360.0f * permille / 1000, color);
}

static void eye(int x, int y, int w, int h, uint16_t c) { canvas->fillSmoothRoundRect(x - w / 2, y - h / 2, w, h, w / 2 < h / 2 ? w / 2 : h / 2, c); }
static void happyEye(int x, int y, uint16_t c) { canvas->fillArc(x, y + 14, 26, 38, 180, 360, c); }

// Two rounded eyes, like the app's character, per mood. Blinks every 4 s.
static void face(int mood, uint32_t now, int y) {
  const int dx = 62;
  const uint16_t c = TFT_WHITE;
  bool blink = now % 4000 < 150;
  switch (mood) {
    case SW_SLEEPING:
      eye(CX - dx, y, 56, 10, c), eye(CX + dx, y, 56, 10, c);
      font(&fonts::Font4), canvas->setTextColor(c), canvas->drawString("z", CX + dx + 50, y - 50);
      break;
    case SW_SUCCESS: case SW_CONTENT: happyEye(CX - dx, y, c), happyEye(CX + dx, y, c); break;
    case SW_WINK: eye(CX - dx, y, 50, 80, c), happyEye(CX + dx, y, c); break;
    case SW_FAILURE:  // drooping lids
      eye(CX - dx, y + 10, 50, 64, c), eye(CX + dx, y + 10, 50, 64, c);
      canvas->fillTriangle(CX - dx - 40, y - 34, CX - dx + 40, y - 34, CX - dx - 40, y + 6, TFT_BLACK);
      canvas->fillTriangle(CX + dx + 40, y - 34, CX + dx - 40, y - 34, CX + dx + 40, y + 6, TFT_BLACK);
      break;
    case SW_DIZZY:
      for (int r = 10; r <= 34; r += 12) {
        canvas->drawCircle(CX - dx, y, r, c), canvas->drawCircle(CX - dx, y, r + 1, c);
        canvas->drawCircle(CX + dx, y, r, c), canvas->drawCircle(CX + dx, y, r + 1, c);
      }
      break;
    case SW_THINKING: {  // looking up, dots going round
      eye(CX - dx - 10, y - 16, 46, 70, c), eye(CX + dx - 10, y - 16, 46, 70, c);
      int lit = now / 400 % 3;
      for (int i = 0; i < 3; i++) canvas->fillSmoothCircle(CX - 30 + i * 30, y + 70, 7, i == lit ? c : C_GREY);
      break;
    }
    default: {
      int h = mood == SW_LISTENING ? 100 : mood == SW_ACTING ? 60 : 80;
      if (blink) h = 10;
      eye(CX - dx, y, 50, h, c), eye(CX + dx, y, 50, h, c);
    }
  }
}

static void check(uint16_t c) {
  canvas->drawWideLine(CX - 80, CY, CX - 20, CY + 60, 14, c);
  canvas->drawWideLine(CX - 20, CY + 60, CX + 90, CY - 60, 14, c);
}

static void cross(uint16_t c) {
  canvas->drawWideLine(CX - 70, CY - 70, CX + 70, CY + 70, 14, c);
  canvas->drawWideLine(CX + 70, CY - 70, CX - 70, CY + 70, 14, c);
}

static bool clockText(char *out) {  // "HH:MM" from the RTC, if it has been set
  static int8_t valid = -1;
  if (valid < 0) valid = M5.Rtc.isEnabled() && !M5.Rtc.getVoltLow();
  m5::rtc_datetime_t dt;
  if (!valid || !M5.Rtc.getDateTime(&dt) || dt.date.year < 2025) { strcpy(out, "--:--"); return false; }
  snprintf(out, 6, "%02d:%02d", dt.time.hours, dt.time.minutes);
  return true;
}

static void idle(const sw_ctl &c, const char *clock) {
  canvas->setTextColor(TFT_WHITE);
  font(&fonts::Font7, 1.6f);
  canvas->drawString(clock, CX, 140);
  font(&fonts::efontCN_24);
  char line[32];
  uint8_t level = battery;
  snprintf(line, sizeof line, level ? "电量 %u%%" : "电量 --", level);
  canvas->drawString(line, CX - 50, 232);
  canvas->fillSmoothCircle(CX + 50, 232, 8, hidLinked ? C_GREEN : C_GREY);
  canvas->drawString("蓝牙", CX + 90, 232);
  if (!c.ui.npicks) {
    canvas->setTextColor(C_GREY);
    canvas->drawString("待命", CX, 320);
    return;
  }
  for (int i = 0; i < c.ui.npicks; i++) {
    int y = 296 + i * 44;
    bool on = i == c.sel;
    if (on) canvas->fillSmoothRoundRect(CX - 150, y - 20, 300, 40, 20, TFT_WHITE);
    canvas->setTextColor(on ? TFT_BLACK : TFT_LIGHTGREY);
    canvas->drawString(fit(c.ui.picks[i], 270), CX, y);
  }
}

static void draw(const sw_ctl &c, int screen, uint32_t now, const char *clock) {
  canvas->fillScreen(TFT_BLACK);
  canvas->setTextDatum(lgfx::textdatum_t::middle_center);
  font(&fonts::efontCN_24);
  switch (screen) {
    case SW_SCR_RUN:
      ring(sw_progress(&c.ui) < 0 ? 0 : sw_progress(&c.ui), C_RING, 218, 230);
      face(c.ui.mood, now, CY - 30);
      canvas->setTextColor(TFT_WHITE);
      canvas->drawString(fit(c.ui.text, 330), CX, 360);
      break;
    case SW_SCR_HELP:
      canvas->fillScreen(C_AMBER);
      canvas->setTextColor(TFT_BLACK);
      font(&fonts::efontCN_24, 1.5f);
      canvas->drawString("需要你帮忙", CX, 120);
      font(&fonts::efontCN_24);
      wrapped(c.ui.text, CY, 340, 3, 32);
      canvas->drawString("点屏幕继续 · 上滑接手", CX, 350);
      break;
    case SW_SCR_PAUSED:
      canvas->fillScreen(C_GREY);
      canvas->setTextColor(TFT_WHITE);
      font(&fonts::efontCN_24, 2);
      canvas->drawString("已暂停", CX, CY - 20);
      font(&fonts::efontCN_24);
      canvas->drawString("黄键继续", CX, CY + 50);
      break;
    case SW_SCR_OK: case SW_SCR_FAIL: {
      bool ok = screen == SW_SCR_OK;
      ok ? check(C_GREEN) : cross(C_RED);
      canvas->setTextColor(ok ? C_GREEN : C_RED);
      canvas->drawString(ok ? "完成" : "失败", CX, CY + 130);
      break;
    }
    case SW_SCR_CONFIRM:
      canvas->setTextColor(TFT_WHITE);
      font(&fonts::efontCN_24, 1.5f);
      canvas->drawString("确认发送？", CX, CY - 60);
      font(&fonts::efontCN_24);
      canvas->drawString(fit(c.ui.picks[c.sel], 330), CX, CY + 10);
      canvas->setTextColor(TFT_LIGHTGREY);
      canvas->drawString("再按黄键发送", CX, CY + 70);
      break;
    case SW_SCR_SHAKE:
      canvas->fillScreen(C_RED);
      canvas->setTextColor(TFT_WHITE);
      font(&fonts::efontCN_24, 2);
      canvas->drawString("摇一摇停止?", CX, CY - 20);
      font(&fonts::efontCN_24);
      canvas->drawString("按任意键取消", CX, CY + 50);
      break;
    default:
      idle(c, clock);
  }
  int hold = sw_hold(&c, now);
  if (hold >= 0) {  // blue held: the stop countdown over whatever is on screen
    ring(hold, C_RED, 200, 230);
    canvas->setTextColor(TFT_WHITE);
    font(&fonts::efontCN_24);
    canvas->drawString("松开取消", CX, 420);
  }
  canvas->pushSprite(0, 0);
}

// What the screen shows; a new frame is drawn only when it changes.
struct View {
  int screen, hold, sel, frame;
  uint8_t battery;
  bool hid;
  char clock[6];
  sw_ui ui;
};

static void send(const char *line) {
  char b[BTN_LINE] = {};
  strlcpy(b, line, sizeof b);
  xQueueSend(buttons, b, 0);  // 8 waiting: loop() is stuck, and a late press is worth nothing
}

static void uiTask(void *) {
  sw_ctl c;
  sw_init(&c);
  Buzz buzz;
  View last;
  memset(&last, 0xff, sizeof last);
  bool wasApp = false;
  uint32_t batteryAt = millis(), clockAt = 0;
  char clock[6] = "--:--";
  char out[BTN_LINE];
  for (;;) {
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(FRAME_MS));
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
    if (wasApp && !app) sw_apply(&c, nullptr, true, now);  // the app is gone: idle, as after `ui off`
    wasApp = app;
    // buttons, touch, shake
    if (M5.BtnA.wasPressed() && sw_input(&c, SW_IN_YELLOW, now, out, sizeof out)) send(out);
    if (M5.BtnB.wasPressed() && sw_input(&c, SW_IN_BLUE_DOWN, now, out, sizeof out)) send(out);
    if (M5.BtnB.wasReleased() && sw_input(&c, SW_IN_BLUE_UP, now, out, sizeof out)) send(out);
    for (int i = 0; i < M5.Touch.getCount(); i++) {
      auto &t = M5.Touch.getDetail(i);
      if (t.wasClicked() && sw_input(&c, SW_IN_TAP, now, out, sizeof out)) send(out);
      bool ended = t.wasFlicked() || t.state == m5::touch_state_t::drag_end;
      if (ended && t.distanceY() < -SWIPE_PX && abs(t.distanceY()) > abs(t.distanceX()) &&
          sw_input(&c, SW_IN_SWIPE_UP, now, out, sizeof out))
        send(out);
    }
    float ax, ay, az;
    if (M5.Imu.getAccel(&ax, &ay, &az) && ax * ax + ay * ay + az * az > SHAKE_G * SHAKE_G)
      sw_input(&c, SW_IN_SHAKE, now, out, sizeof out);
    if (sw_tick(&c, now, out, sizeof out)) send(out);
    buzzRun(buzz, now);
    if (now - batteryAt >= 10000) {
      int32_t level = M5.Power.getBatteryLevel();
      if (level >= 0 && level <= 100) battery = (uint8_t)level;
      batteryAt = now;
    }
    if (!clockAt || now - clockAt >= 1000) { clockText(clock); clockAt = now; }
    // draw when something on screen changed
    View v;
    memset(&v, 0, sizeof v);
    v.screen = sw_screen(&c, now);
    v.hold = sw_hold(&c, now) / 20;
    v.sel = c.sel;
    v.frame = v.screen == SW_SCR_RUN ? (c.ui.mood == SW_THINKING ? now / 400 % 3 : now % 4000 < 150) : 0;
    v.battery = battery;
    v.hid = hidLinked;
    memcpy(v.clock, clock, sizeof v.clock);
    v.ui = c.ui;
    if (memcmp(&v, &last, sizeof v)) {
      draw(c, v.screen, now, clock);
      last = v;
    }
  }
}

void stopwatch_ui_start() {
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
