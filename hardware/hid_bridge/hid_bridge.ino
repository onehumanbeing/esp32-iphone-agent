// HID bridge: an ESP32-S3 (XIAO, 8 MB PSRAM) plugged into the iPhone. It is the phone's
// USB mouse + keyboard, an AirPlay screen-mirroring receiver, and a BLE peripheral for the
// iOS app on the same phone. It holds no logic; the app decides. Protocol: docs/ble-protocol.md.
//
// HID commands (unchanged from the old TCP protocol, the board answers "ok" or "err <why>"):
//   ping | pace | home | move <dx> <dy> [speed] | press | release | click
//   scroll <v> <h> | type <ascii text> | key <combo, e.g. cmd+h, enter>
//   homescreen (the consumer-control Home key, "AC Home": iOS goes to the Home Screen, like a keyboard's home key)

#include <esp_task_wdt.h>
#include <esp_mac.h>
#include <esp_wifi.h>
#include <esp_core_dump.h>
#include "USB.h"
#include "USBHIDMouse.h"
#include "USBHIDKeyboard.h"
#include "USBHIDConsumerControl.h"
#include "tusb.h"
#include "ble_link.h"
#include "netcfg.h"
#include "video_link.h"
#include "cli_link.h"
#include "cli_tcp.h"
#include "wifi_video.h"
#include "ota.h"
#include "version.h"
#include "src/airplay/airplay.h"
#include "src/hid/arbiter.h"
#include "src/hid/pace.h"
#include "src/heard/heard.h"
#include "src/cli/cli_proto.h"
#include "logbuf.h"

const int STEP = 10;      // pointer speed per report while moving (any direction, see pace.h)
const int STEP_MS = 8;    // report interval; constant pace keeps iOS acceleration predictable
const int HOME_REPORTS = 25;  // per axis
#ifndef DEBUG_SERIAL
#define DEBUG_SERIAL 0  // 1: echo commands and the AirPlay handshake over USB serial
#endif

const int WATCHDOG_MS = 8000;  // a hung loop (e.g. blocked USB) reboots the board instead of staying offline

USBHIDMouse mouse;
USBHIDKeyboard keyboard;
USBHIDConsumerControl consumer;
const uint16_t AC_HOME = 0x0223;  // HID consumer page: AC Home
static String receiverName = "ESP32 Agent";

void movePaced(long dx, long dy, int step = STEP) {
  pace_t p;
  pace_start(&p, dx, dy, step);
  int sx, sy;
  while (pace_next(&p, &sx, &sy)) {
    mouse.move(sx, sy);
    delay(STEP_MS);
  }
}

uint8_t keyCode(const String &k) {
  if (k == "enter") return KEY_RETURN;
  if (k == "esc") return KEY_ESC;
  if (k == "tab") return KEY_TAB;
  if (k == "backspace") return KEY_BACKSPACE;
  if (k == "space") return ' ';
  if (k == "up") return KEY_UP_ARROW;
  if (k == "down") return KEY_DOWN_ARROW;
  if (k == "left") return KEY_LEFT_ARROW;
  if (k == "right") return KEY_RIGHT_ARROW;
  if (k == "cmd") return KEY_LEFT_GUI;
  if (k == "ctrl") return KEY_LEFT_CTRL;
  if (k == "alt") return KEY_LEFT_ALT;
  if (k == "shift") return KEY_LEFT_SHIFT;
  return k.length() == 1 ? k[0] : 0;
}

bool pressCombo(String combo) {
  combo += '+';
  for (int i; (i = combo.indexOf('+')) >= 0; combo = combo.substring(i + 1)) {
    uint8_t c = keyCode(combo.substring(0, i));
    if (!c) { keyboard.releaseAll(); return false; }
    keyboard.press(c);
  }
  delay(30);
  keyboard.releaseAll();
  return true;
}

// A locked or sleeping phone suspends USB; sending HID reports then can stall. Ask it to wake up instead,
// and report "asleep" right away if it does not, so the board never hangs.
bool usbReady() {
  if (tud_suspended()) {
    tud_remote_wakeup();
    for (int i = 0; i < 50 && tud_suspended(); i++) delay(10);
  }
  return tud_mounted() && !tud_suspended();
}

String run(const String &line) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0, c = STEP;
  sscanf(arg.c_str(), "%ld %ld %ld", &a, &b, &c);

  if (cmd == "ping") return "ok";
  if (cmd == "pace") return "ok " + String(PACE_VERSION);  // how moves are paced: the app recalibrates on a change
  if (!usbReady()) return "err phone usb asleep (unlock the phone)";
  if (cmd == "home") {  // slam the pointer into the top-left corner: left first, then up along the left edge,
    // so it never rides the top edge from the right (that opened Control Center, 2026-11-06)
    for (int i = 0; i < HOME_REPORTS; i++) { mouse.move(-127, 0); delay(2); }
    for (int i = 0; i < HOME_REPORTS; i++) { mouse.move(0, -127); delay(2); }
    return "ok";
  }
  if (cmd == "move") { movePaced(a, b, constrain(c, 1, 40)); return "ok"; }  // c: speed per report (calibration)
  if (cmd == "press") { mouse.press(MOUSE_LEFT); return "ok"; }
  if (cmd == "release") { mouse.release(MOUSE_LEFT); return "ok"; }
  if (cmd == "click") { mouse.press(MOUSE_LEFT); delay(60); mouse.release(MOUSE_LEFT); return "ok"; }
  if (cmd == "scroll") { mouse.move(0, 0, a, b); return "ok"; }
  if (cmd == "type") { keyboard.print(arg); return "ok"; }
  if (cmd == "key") return pressCombo(arg) ? "ok" : "err unknown key";
  if (cmd == "homescreen") { consumer.press(AC_HOME); delay(40); consumer.release(); return "ok"; }
  return "err unknown command";
}

static arb_state arb;  // the app or the CLI drives the phone, never both: src/hid/arbiter.h
const char *const APP_BUSY = "err busy: the app is using the board";

// An HID command from who; the side that leaves lets go of the button it held (loop()).
String drive(const String &line, char who) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String reply = run(line);
  arb_after(&arb, who == FROM_CLI ? ARB_CLI : ARB_APP, cmd.c_str(), reply == "ok");
  return reply;
}

const char *resetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "power-on";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_TASK_WDT: case ESP_RST_INT_WDT: case ESP_RST_WDT: return "watchdog";
    case ESP_RST_PANIC: return "crash";
    case ESP_RST_SW: return "software";
    case ESP_RST_USB: return "usb";
    default: return "other";
  }
}

const char *usbState() {
  if (!tud_mounted()) return "off";
  return tud_suspended() ? "asleep" : "ok";
}

// The last crash saved in the core dump partition (kept until the next one): task, PC, backtrace. Read at boot,
// so a crash on a board plugged into the phone can be looked up over BLE (`crash`) without a serial cable.
static String lastCrash = "none";

void readCrash() {
  auto *c = (esp_core_dump_summary_t *)malloc(sizeof(esp_core_dump_summary_t));
  if (c && esp_core_dump_image_check() == ESP_OK && esp_core_dump_get_summary(c) == ESP_OK) {
    char b[200];
    int n = snprintf(b, sizeof b, "%.16s pc %08lx bt", c->exc_task, (unsigned long)c->exc_pc);
    for (int i = 0; i < (int)c->exc_bt_info.depth && i < 12 && n < (int)sizeof b - 10; i++)
      n += snprintf(b + n, sizeof b - n, " %08lx", (unsigned long)c->exc_bt_info.bt[i]);
    lastCrash = b;
  }
  free(c);
}

// Board-level commands from the app or the CLI (who); everything else is an HID command for run().
static bool appHears;  // the app listens and shares what it heard

// The app's transcripts for the CLI, ~3 KB in PSRAM once the app shares any.
static heard_ring *heardRing() {
  static heard_ring *r;
  if (!r && (r = (heard_ring *)heap_caps_calloc(1, sizeof *r, MALLOC_CAP_SPIRAM))) heard_clear(r);
  return r;
}

String board(const String &line, const String &id, char who) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0;
  int n = sscanf(arg.c_str(), "%ld %ld", &a, &b);
  if (who == FROM_CLI && !arb_allowed(ARB_CLI, ble_app_active()) && cmd != "crash") return APP_BUSY;
  if (cmd == "stream") {
    if (arg != "on" && arg != "off") return "err usage: stream on|off";
    video_stream(arg == "on", who);
    return "ok";
  }
  // The CLI must not change what the app relies on: the mirroring format, the radio, the pairing.
  if (who == FROM_CLI && (cmd == "app" || cmd == "log" || cmd == "unpair" || cmd == "res" || cmd == "fps" ||
                          cmd == "txpower" || cmd == "coex"))
    return "err not available from the CLI";
  if (cmd == "net" && who == FROM_CLI) {  // the board's Wi-Fi for the CLI's link (docs/cli-protocol.md, "Wi-Fi link")
    if (arg.length()) {
      if (!arg.startsWith("{")) return "err usage: net [{\"mode\":\"ap\"} | {\"mode\":\"sta\",\"ssid\":...,\"pass\":...}]";
      net_request(arg);  // applied by net_poll(): the reply goes out first
      return "ok";
    }
    return "ok " + net_json(false);
  }
  if (cmd == "app" || cmd == "log") {  // debug relay: Mac -> app ("app run ...") and app -> Mac ("log ...")
    ble_reply(cmd + " " + arg);         // every peer sees it; each side ignores lines it doesn't handle
    if (cmd == "log") Serial.println("log " + arg);  // and a Mac on USB serial
    return "ok";
  }
  // Phone audio for the CLI (docs/cli-protocol.md, "Phone audio"): the app shares what it heard, the CLI reads it
  // (`heard`) or asks for the raw audio to transcribe itself (`listen raw on`, Wi-Fi only).
  if (cmd == "hear" && who == FROM_APP) {
    appHears = arg == "on";
    if (!appHears && heardRing()) heard_clear(heardRing());
    return "ok";
  }
  if (cmd == "heard" && who == FROM_APP) {
    if (heardRing()) heard_add(heardRing(), millis(), arg.c_str(), arg.length());
    return "ok";
  }
  if (cmd == "heard") {
    static char out[HEARD_LINES * 64 + 64];
    int room = (int)cli_mtu() - 3 - CLI_OVERHEAD - 1 - 16;  // ATT, seal, kind byte, "<id> ok "
    static const heard_ring none = {};
    heard_json(heardRing() ? heardRing() : &none, millis(), appHears, out, room > 0 && room < (int)sizeof out ? room : sizeof out);
    return String("ok ") + out;
  }
  if (cmd == "listen" && who == FROM_CLI) {
    if (arg != "raw on" && arg != "raw off") return "err usage: listen raw on|off";
    if (arg == "raw on" && !cli_wifi()) return "err raw audio needs the Wi-Fi link (esp32agent net)";
    cli_audio(arg == "raw on");
    return "ok";
  }
  if (cmd == "logs") return board_log_page(arg);  // the RAM log, a page at a time (logbuf.h)
  if (cmd == "vdbg") return "ok " + video_debug();  // why a frozen screen stays frozen (video_link.cpp)
  if (cmd == "crash") return String("ok rst ") + resetReason() + ", last dump: " + lastCrash;
  if (cmd == "snap") { video_snap(id, who); return ""; }  // replies when the GOP is sent
  if (cmd == "bench") {
    if (n < 1 || a <= 0 || a > 4096) return "err usage: bench KB (1-4096)";
    video_bench(id, a, who);
    return "";
  }
  if (cmd == "res") {
    if (n < 2 || a < 160 || b < 160 || a > 1920 || b > 2560) return "err usage: res W H";
    cfg_set_res(a, b);
    airplay_set_display(a, b, cfg_fps());
    return "ok";
  }
  if (cmd == "fps") {
    if (n < 1 || a < 1 || a > 60) return "err usage: fps N (1-60)";
    cfg_set_fps(a);
    airplay_set_display(cfg_width(), cfg_height(), a);
    return "ok";
  }
  if (cmd == "txpower") {  // A/B knob in 0.25 dBm (8-84), not stored: every boot starts at 5 dBm
    if (n < 1 || a < 8 || a > 84 || esp_wifi_set_max_tx_power(a) != ESP_OK) return "err usage: txpower 8-84";
    return "ok";
  }
  if (cmd == "coex") {  // A/B knob, not stored: every boot starts at balance
    if (arg.length() && !net_coex(arg)) return "err usage: coex bt|balance|wifi";
    return String("ok ") + net_coex_mode();
  }
  if (cmd == "unpair") {
    ble_reply(id + " ok");  // answer before the link goes down
    ble_unpair();
    return "";
  }
  return drive(line, who);
}

String statusJson(bool full, char who) {
  static const char *apStates[] = {"idle", "connected", "streaming"};
  VideoStats v = video_stats(who);
  char s[704];
  snprintf(s, sizeof s,
           "{\"fw\":\"%s\",\"up\":%lu,\"rst\":\"%s\",\"heap\":%u,\"psram\":%u,\"usb\":\"%s\",\"net\":\"%s\",\"ip\":\"%s\",\"sta\":%d,"
           "\"ap\":\"%s\",\"w\":%u,\"h\":%u,\"kbps\":%lu,\"fps\":%.1f,\"idr\":%lu,\"gop\":%lu,\"vage\":%lu,\"ovf\":%lu,\"fz\":%d,"
           "\"ble\":{\"mtu\":%u,\"phy\":%u,\"kbps\":%lu,\"drop\":%lu,\"rdrop\":%lu,\"n\":%d},"
           "\"udp\":{\"n\":%d,\"kbps\":%lu,\"nack\":%lu,\"drop\":%lu}}",
           FW_VERSION, millis(), resetReason(), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), usbState(), net_mode(), net_ip().c_str(), net_peers(),
           apStates[airplay_state()], cfg_width(), cfg_height(), (unsigned long)v.kbps, v.fps, (unsigned long)v.idr_ms,
           (unsigned long)v.gop_bytes, (unsigned long)v.age_ms, (unsigned long)v.overflows, v.frozen, ble_mtu(), ble_phy(), (unsigned long)ble_kbps(), (unsigned long)ble_drops(),
           (unsigned long)ble_reply_drops(), ble_peers(), wv_active(), (unsigned long)wv_kbps(),
           (unsigned long)wv_nacks(), (unsigned long)wv_drops());
  // owner: who drives the phone (app, cli, none); the CLI's busy is 1 while that is the app
  bool app = ble_app_active();
  if (who == FROM_CLI) {  // the CLI's own link, not the app's (ble.mtu above is the app's)
    size_t l = strlen(s);
    snprintf(s + l - 1, sizeof s - l + 1, ",\"link\":{\"via\":\"%s\",\"mtu\":%u,\"kbps\":%lu}}", cli_wifi() ? "wifi" : "ble",
             cli_mtu(), (unsigned long)(cli_wifi() ? cli_tcp_kbps() : ble_kbps()));
  }
  const char *owner = arb_owner_name(arb_owner(app, cli_slot() >= 0));
  size_t len = strlen(s);
  snprintf(s + len - 1, sizeof s - len + 1, ",\"owner\":\"%s\"}", owner);
  // AirPlay audio: packets, sound segments, a segment going on, sender volume (dB), records lost to the app
  airplay_audio_stats au = airplay_audio();
  len = strlen(s);
  snprintf(s + len - 1, sizeof s - len + 1, ",\"aud\":{\"pk\":%lu,\"seg\":%lu,\"snd\":%d,\"vol\":%.0f,\"drop\":%lu,\"hear\":%d,\"raw\":%d}}",
           (unsigned long)au.packets, (unsigned long)au.segments, au.sound, au.volume, (unsigned long)wv_audio_drops(),
           appHears, cli_audio_wanted());
  if (who == FROM_CLI) {
    len = strlen(s);
    snprintf(s + len - 1, sizeof s - len + 1, ",\"busy\":%d}", app);
  }
  if (full) return s;
  // MTU below ~250 (before the MTU exchange): keep only the fields the app needs to stay alive
  snprintf(s, sizeof s, "{\"fw\":\"%s\",\"up\":%lu,\"rst\":\"%s\",\"usb\":\"%s\",\"net\":\"%s\",\"ap\":\"%s\",\"fz\":%d,\"ble\":{\"mtu\":%u}",
           FW_VERSION, millis(), resetReason(), usbState(), net_mode(), apStates[airplay_state()], v.frozen, ble_mtu());
  snprintf(s + strlen(s), sizeof s - strlen(s), ",\"owner\":\"%s\"", owner);
  if (who == FROM_CLI)
    snprintf(s + strlen(s), sizeof s - strlen(s), ",\"busy\":%d,\"ip\":\"%s\",\"link\":{\"via\":\"%s\",\"mtu\":%u}", app,
             net_ip().c_str(), cli_wifi() ? "wifi" : "ble", cli_mtu());
  strlcat(s, "}", sizeof s);
  return s;
}

void statusTask(void *) {
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    if (!ble_connected()) continue;
    String s = statusJson(true, FROM_APP);
    if (s.length() > ble_mtu() - 3u) s = statusJson(false, FROM_APP);
    ble_status(s);
    if (cli_slot() >= 0) ble_cli_status(statusJson(true, FROM_CLI), statusJson(false, FROM_CLI));
  }
}

// Board log lines to the app ("blog ...", into its debug.log) so a stall on a board plugged into the phone leaves
// evidence: the AirPlay log, and board_log (the video link's switches and resumes, which stayed in the 8 KB RAM log
// and were gone before anyone looked, 2026-11-06). At most 16 a second; the rest are counted and reported later.
void relayLine(const char *msg) {
  static uint32_t windowStart, sent, skipped;
  static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
  uint32_t now = millis();
  bool send = false;
  uint32_t dropped = 0;
  portENTER_CRITICAL(&mux);
  if (now - windowStart >= 1000) { windowStart = now; sent = 0; }
  if (sent < 16) { sent++; send = true; dropped = skipped; skipped = 0; } else skipped++;
  portEXIT_CRITICAL(&mux);
  if (!send || !ble_connected()) return;
  String line = String("blog ") + now + " " + msg;
  if (dropped) line += String(" (+") + dropped + " skipped)";
  ble_reply(line);
}

// AirPlay log lines: to USB serial, the RAM log and the app.
void logLine(const char *msg) {
#if DEBUG_SERIAL
  Serial.printf("[%lu] %s\n", millis(), msg);
#endif
  board_log_keep(msg);
  relayLine(msg);
}

void startAirplay() {
  static airplay_cfg cfg;
  cfg.name = receiverName.c_str();
  esp_read_mac(cfg.hwaddr, ESP_MAC_WIFI_STA);
  cfg_ed25519_seed(cfg.ed25519_seed);
  cfg.width = cfg_width();
  cfg.height = cfg_height();
  cfg.max_fps = cfg_fps();
  cfg.on_config = video_on_config;
  cfg.on_au = video_on_au;
  cfg.on_audio = wv_audio;
  cfg.log = logLine;
  if (!airplay_start(&cfg)) board_log("airplay: start failed");
}

void setup() {
  Serial.begin(115200);
#if OTA_CRASH_TEST  // flash.sh --crash-test: an image that never comes up, to check the rollback after an update
  delay(3000);
  abort();
#endif
#if DEBUG_SERIAL
  for (int i = 0; i < 30 && !Serial; i++) delay(100);  // give a serial monitor 3 s to catch the boot lines
#endif
  mouse.begin();
  keyboard.begin();
  consumer.begin();
  USB.productName("HID Bridge");
  USB.begin();
  esp_task_wdt_config_t wdt = {.timeout_ms = WATCHDOG_MS, .idle_core_mask = 0, .trigger_panic = true};
  esp_task_wdt_reconfigure(&wdt);
  esp_task_wdt_add(NULL);
  readCrash();

  net_begin();
  if (!video_begin()) board_log("video: no PSRAM for the GOP buffer");
  if (!wv_begin()) board_log("video: Wi-Fi video channel failed to start");
  if (!ota_begin()) board_log("ota: failed to start");
  arb_init(&arb);
  cli_begin();
  if (!cli_tcp_begin()) board_log("cli: Wi-Fi link failed to start");
  ble_begin("ESP32 Agent " + board_suffix());
  startAirplay();
  xTaskCreatePinnedToCore(statusTask, "status", 4096, NULL, 1, NULL, 1);
  board_log("boot %s fw %s: free internal heap %u (largest %u), PSRAM %u, reset %s\n", receiverName.c_str(), FW_VERSION,
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), resetReason());
}

void loop() {
  static bool linked = false, cliLinked = false;
  esp_task_wdt_reset();
  net_poll();
  bool cli = cli_slot() >= 0;
  // A gesture cut off mid-way must not leave the button held (long press); only the side that went holds it.
  bool app = ble_app_connected(), appActive = ble_app_active();
  if (linked && !app) {
    if (arb_gone(&arb, ARB_APP)) mouse.release(MOUSE_LEFT);
    keyboard.releaseAll();
    video_stream(false, FROM_APP);
    appHears = false;  // until the app says so again
  }
  if (cliLinked && !cli) {
    if (arb_gone(&arb, ARB_CLI)) mouse.release(MOUSE_LEFT);
    video_stream(false, FROM_CLI);
  }
  // The app wins: a CLI session up alongside it stops at once and is dropped shortly after, once its status
  // (owner app, busy 1) and the `err busy` replies to anything it sent are out, so it doesn't load the radio.
  static uint32_t cliDropAt = 0;
  if (appActive && cli) {
    if (!cliDropAt) {
      if (arb_gone(&arb, ARB_CLI)) mouse.release(MOUSE_LEFT);
      video_stream(false, FROM_CLI);
      ble_cli_status(statusJson(true, FROM_CLI), statusJson(false, FROM_CLI));
      cliDropAt = millis() + 300;
    } else if ((int32_t)(millis() - cliDropAt) >= 0) {
      cli_drop();
      cliDropAt = millis() + 2000;  // once more later if it's still there
    }
  } else {
    cliDropAt = 0;
  }
  linked = app;
  cliLinked = cli;
  // A freshly updated image is kept once it has run a while or the app got through; a crash or watchdog
  // reset before that makes the bootloader go back to the previous one.
  static bool confirmed = false;
  if (!confirmed && (linked || millis() > 30000)) { ota_confirm(); confirmed = true; }

  String line;
  // USB serial takes the same `<id> <command>` lines, for debugging from a Mac. Never wait for the rest of a line:
  // bytes without a newline (esptool's sync, say) held the loop until the watchdog reset the board.
  static String serialLine;
  bool serialDone = false;
  while (Serial.available() && !serialDone) {
    char ch = Serial.read();
    if (ch == '\n') serialDone = true;
    else if (serialLine.length() < 512) serialLine += ch;
  }
  if (serialDone) {
    line = serialLine;
    serialLine = "";
    line.trim();
    if (line.startsWith("0 net ")) { net_request(line.substring(6)); Serial.println("0 ok"); return; }
    if (line == "0 netinfo") { Serial.println("0 " + net_json(true)); return; }  // what the app reads over BLE (incl. vtok)
    if (line == "0 status") { Serial.println("0 " + statusJson(true, FROM_APP)); return; }
    int sp = line.indexOf(' ');
    String id = sp < 0 ? line : line.substring(0, sp);
    Serial.println(id + " " + board(sp < 0 ? "" : line.substring(sp + 1), id, FROM_APP));
    return;
  }
  char who;
  if (!ble_pop_cmd(line, who, 50)) return;
  int sp = line.indexOf(' ');
  String id = sp < 0 ? line : line.substring(0, sp);
  String rest = sp < 0 ? "" : line.substring(sp + 1);
  rest.trim();
#if DEBUG_SERIAL
  unsigned long started = millis();
#endif
  String reply = id.toInt() || id == "0" ? board(rest, id, who) : "err missing request id";
  if (reply.length()) ble_reply(id + " " + reply, who);
#if DEBUG_SERIAL
  Serial.printf("%s -> %s (%lu ms)\n", line.c_str(), reply.c_str(), millis() - started);
#endif
}
