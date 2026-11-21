#ifdef M5_STOPWATCH
#include "stopwatch_ui.h"
#include "logbuf.h"
#include "version.h"
#include <M5Unified.h>
#include <atomic>
#include "src/ui/sw_face.h"
#include "src/ui/sw_model.h"
#include "src/ui/sw_text.h"
#include "src/ui/sw_power.h"
#include "src/ui/sw_warn.h"
#include "ble_link.h"
#include "voice_rec.h"
#include "stopwatch_draw.h"
using namespace sw;
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
char boardName[32];  // stopwatch_draw.h
// The app's other lines for the task (latest wins), in PSRAM: `voice ...`, `picks [...]`, `answer ...`.
enum { L_VOICE, L_PICKS, L_ANSWER, L_KINDS };
static constexpr size_t LINE_CAP[L_KINDS] = {SW_SAID_MAX + 40, 256, SW_ANSWER_MAX + 1};
static char *lineBuf[L_KINDS];
static bool lineHas[L_KINDS];
static std::atomic<int> lang{SW_EN};
static std::atomic<int> fakeBtn{-1};  // `swpress`: 0 yellow, 1 blue, held fakeMs
static std::atomic<uint32_t> fakeMs{0};  // the screen's language (NVS "sw"/"lang"), English by default

static const int BTN_LINE = 32;
static const uint32_t SLEEP_AFTER_MS = 180000;  // no app, no touch, no button for 3 min: it falls asleep
static const uint32_t FRAME_MS = 33, SLEEP_FRAME_MS = 66;  // ~30 fps; the sleeping face only drifts its z
static const uint32_t DARK_FRAME_MS = 100;  // the screen off: buttons, touch and the raise still read
static const uint8_t BRIGHT[] = {160, 40, 0};  // SWP_ON, SWP_DIM, SWP_OFF
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

const char *T(int id) { return sw_text(lang, id); }

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

// The clock: the phone's local time (`z`) goes into the RTC, which keeps it without the app (and across reboots
// on battery); the screen reads it once a minute and counts on with millis().
static int32_t rtcDay = -1;  // seconds into the day at rtcAt, -1: unknown
static uint32_t rtcAt;
static bool rtcSet;  // set from the phone since boot

static void clockRead(uint32_t now) {
  m5::rtc_datetime_t dt;
  if (!M5.Rtc.isEnabled() || !M5.Rtc.getDateTime(&dt) || dt.date.year < 2025) return;  // never set: no clock
  rtcDay = dt.time.hours * 3600 + dt.time.minutes * 60 + dt.time.seconds, rtcAt = now;
}

static void clockFromApp(int64_t local, uint32_t now) {
  if (local <= 0 || !M5.Rtc.isEnabled()) return;
  int32_t day = (int32_t)(local % 86400), mine = rtcDay < 0 ? -1 : (int32_t)((rtcDay + (now - rtcAt) / 1000) % 86400);
  if (rtcSet && mine >= 0 && abs(mine - day) <= 2) return;  // already right
  time_t t = (time_t)local;
  struct tm tm;
  gmtime_r(&t, &tm);  // `z` is local time read as UTC: the wall clock
  M5.Rtc.setDateTime(&tm);
  board_log("stopwatch: clock %s from the phone: %04d-%02d-%02d %02d:%02d:%02d (was %d s off)", rtcSet ? "corrected" : "set",
            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, mine < 0 ? -1 : abs(mine - day));
  rtcSet = true, rtcDay = day, rtcAt = now;
}

static bool clockNow(uint32_t now, char out[6]) {
  if (rtcDay < 0) return false;
  int32_t d = (int32_t)((rtcDay + (now - rtcAt) / 1000) % 86400);
  snprintf(out, 6, "%02d:%02d", (int)(d / 3600), (int)(d / 60 % 60));
  return true;
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
  sw_power pw;  // dim after 20 s, off after 60 s with no run (sw_power.h); a press, touch or wrist raise wakes it
  swp_init(&pw, millis());
  int shown = SWP_ON, lastScreen = -1, lastVoice = -1;
  bool eatY = false, eatB = false, eatT = false, wasAlive = false;
  int8_t charging = -1;  // M5.Power.isCharging(), read every 3 s (-1 unknown)
  uint32_t chargeAt = 0, lowUntil = 0;
  uint8_t low = 0;
  sw_warn warn;  // mirroring lost, the iPhone locked, Bluetooth lost: a buzz, what to do (sw_warn.h)
  sww_init(&warn);
  uint32_t busyAt = 0;
  clockRead(millis());
  uint32_t clockAt = millis();
  char hhmm[6] = "--:--";
  clockNow(millis(), hhmm);
  board_log("stopwatch: rtc %s, time %s", M5.Rtc.isEnabled() ? "on" : "missing", hhmm);
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
    if (got && !off) clockFromApp(u.local, now);
    if (now - clockAt >= 60000) clockRead(now), clockAt = now;
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
    if (running || alive) busyAt = now;
    bool busy = busyAt && now - busyAt < 2000;  // in use just now: the app's link may drop with Bluetooth's
    if (sww_update(&warn, alive ? sw_warn_parse(c.ui.warn) : SW_W_NONE, hidLinked, busy)) {
      buzzStart(buzz, SW_BUZZ_HELP, now);
      board_log("stopwatch: alert %d", sww_shown(&warn));
    }
    // buttons, touch, shake
    // the buttons, or a test press from USB serial (`swpress`)
    bool yDown = M5.BtnA.wasPressed(), yUp = M5.BtnA.wasReleased(), bDown = M5.BtnB.wasPressed(), bUp = M5.BtnB.wasReleased();
    static uint32_t fakeUntil;
    static int fakeHeld = -1;
    int fb = fakeBtn.exchange(-1);
    if (fb >= 0 && fakeHeld < 0) (fb ? bDown : yDown) = true, fakeHeld = fb, fakeUntil = now + fakeMs;
    if (fakeHeld >= 0 && (int32_t)(now - fakeUntil) >= 0) (fakeHeld ? bUp : yUp) = true, fakeHeld = -1;
    // the screen off: a press or touch only wakes it, its release and click are dropped too
    bool dark = shown == SWP_OFF, touching = M5.Touch.getCount() > 0;
    if (yDown || bDown || touching) swp_active(&pw, now);
    if (dark && yDown) eatY = true;
    if (dark && bDown) eatB = true;
    if (dark && touching) eatT = true;
    if (eatY) eatY = !yUp, yDown = yUp = false;
    if (eatB) eatB = !bUp, bDown = bUp = false;
    bool skipTouch = eatT;
    if (eatT && !touching) eatT = false;
    bool voiceBefore = c.voice != SW_V_NONE || c.sel >= 0, legacy = !(alive && c.ui.voice) && !c.y_down;
    bool pokeIdle = !running && !c.ui.npicks;  // yellow with nothing to pick: it reacts
    bool paired = hidLinked || appLinked;
    static bool wasPaired;
    if (paired && !wasPaired && statusUntil && ble_pair_left_ms()) {  // linked while pairing: buzz, show it, then close
      buzzPulse(buzz, 60, now);
      statusUntil = now + 3000;
    }
    wasPaired = paired;
    if (!paired && !running && !statusUntil && yDown) {  // no phone yet: yellow opens the status page, where blue pairs (Henry 2026-11-21)
      statusUntil = now + 8000;
      eatY = true;  // its release starts nothing
      yDown = false;
    } else if (statusUntil && yDown) {  // yellow on the status page: the other language (Henry 2026-11-21)
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
    bool warned = sww_shown(&warn) && !voiceBefore;
    if (warned && bDown) {  // blue on an alert: hidden until another comes, nothing sent
      sww_hide(&warn);
      c.blue_ignore = true;
    } else if (statusUntil && !paired && bDown) {  // blue on the status page without a phone: a pairing window
      ble_pair_open();
      statusUntil = now + ble_pair_left_ms();  // the page stays, with the countdown, until it closes or a phone links
      c.blue_ignore = true;
    } else if (!running && !voiceBefore && bDown) {  // blue while nothing runs: the status page, on and off (Henry 2026-11-20)
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
    for (int i = 0; !skipTouch && i < M5.Touch.getCount(); i++) {
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
    if (M5.Imu.getAccel(&ax, &ay, &az)) {
      if (ax * ax + ay * ay + az * az > SHAKE_G * SHAKE_G) {
        if (running) sw_input(&c, SW_IN_SHAKE, now, out, sizeof out);
        else swf_dizzy(&f, now);
      }
      if (swp_motion(&pw, ax, ay, az, now)) {
        activeAt = now;  // the character wakes up with the screen
        if (shown != SWP_ON) board_log("stopwatch: raised, screen on");
      }
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
    if (now - chargeAt >= 3000) {
      auto ch = M5.Power.isCharging();
      int8_t was = charging;
      charging = ch == m5::Power_Class::is_charging ? 0 : ch == m5::Power_Class::is_discharging ? -1 : charging;
      if ((was >= 0) != (charging >= 0)) {
        swp_active(&pw, now);  // plugged in or out: shown
        board_log("stopwatch: %s", charging >= 0 ? "charging" : "not charging");
        batteryAt = 0;  // the level now
      }
      chargeAt = now;
    }
    if (now - batteryAt >= 10000) {
      int32_t level = M5.Power.getBatteryLevel();
      if (level >= 0 && level <= 100) battery = (uint8_t)level;
      batteryAt = now;
      if (int under = swp_battery(&pw, level, charging >= 0)) {  // under 15 % or 5 %: a buzz and a banner
        low = battery.load(), lowUntil = now + 4000;
        buzzStart(buzz, SW_BUZZ_FAIL, now);
        swp_active(&pw, now);
        board_log("stopwatch: battery under %d%% (%u%%)", under, (unsigned)battery.load());
      }
    }
    if (low && (int32_t)(now - lowUntil) >= 0) low = 0;
    // draw: everything when the view changed, else only the face's area when it moved
    View v;
    memset(&v, 0, sizeof v);
    v.screen = statusUntil ? SW_SCR_STATUS : sww_shown(&warn) && screen != SW_SCR_VOICE ? SW_SCR_WARN : screen;
    v.warn = (uint8_t)sww_shown(&warn);
    v.hold = running && sw_hold(&c, now) >= 0 ? sw_hold(&c, now) / 20 : -1;
    v.sel = c.sel;
    v.battery = battery;
    v.hid = hidLinked;
    v.alive = alive;
    v.lang = lang;
    v.level = c.voice == SW_V_LISTEN ? voice_level() / 50 : 0;
    v.elapsed = sw_elapsed(&c, now);
    // the time: the status page's, and under the face when it sleeps or no app is there (the RTC; the app's `c` else)
    if (!clockNow(now, v.clock)) sw_clock(&c, now, v.clock);
    if (v.screen != SW_SCR_STATUS) v.clock[0] = 0;
    v.pair = (ble_pair_left_ms() + 999) / 1000;  // the time only on the status page (blue), never on the face (Henry 2026-11-21)
    v.charge = charging < 0 || battery >= 100 ? -1 : v.screen == SW_SCR_IDLE && c.sel < 0 ? (int8_t)(now / 120 % 16) : 0;  // pulse on the face only
    v.low = low;
    v.ui = c.ui;
    // the screen's power: anything new on it is activity; a run, help, voice, a pick or the status page keep it on
    if (v.screen != lastScreen || c.voice != lastVoice || alive != wasAlive) swp_active(&pw, now);
    lastScreen = v.screen, lastVoice = c.voice, wasAlive = alive;
    bool keepOn = running || c.voice != SW_V_NONE || c.sel >= 0 || statusUntil || v.hold >= 0 || low || v.warn;
    int level = swp_level(&pw, now, keepOn);
    if (level == SWP_OFF) v.charge = -1;  // nothing to animate in the dark
    if (shown == SWP_OFF && level != SWP_OFF) memset(&last, 0xff, sizeof last);  // waking: all of it, fresh
    v.ui.look_x = v.ui.look_y = 0;  // the face's motion, not the view
    swf_pose pose;
    swf_pose_at(&f, &pose);
    PoseKey k = key(pose);
    bool full = memcmp(&v, &last, sizeof v) != 0, moved = place.on && memcmp(&k, &lastKey, sizeof k) != 0;
    if (level != SWP_OFF && (full || moved)) {
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
    if (level != shown) {  // after the frame: waking shows the new picture, not the one from before the dark
      M5.Display.setBrightness(BRIGHT[level]);
      board_log("stopwatch: screen %s", level == SWP_ON ? "on" : level == SWP_DIM ? "dim" : "off");
      shown = level;
    }
    if (now - statAt >= 60000) {  // how hard the screen works, once a minute
      board_log("stopwatch: %u frames/min, draw avg %u ms max %u ms, stack left %u, internal heap %u\n",
                (unsigned)frames, (unsigned)(frames ? drawMs / frames : 0), (unsigned)drawMax,
                (unsigned)uxTaskGetStackHighWaterMark(nullptr), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
      statAt = now, frames = drawMs = drawMax = 0;
    }
    // a `ui` line wakes the task early; otherwise the next frame
    uint32_t frame = level == SWP_OFF ? DARK_FRAME_MS
                     : pose.mood == SW_SLEEPING && v.screen == SW_SCR_IDLE ? SLEEP_FRAME_MS : FRAME_MS;
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
