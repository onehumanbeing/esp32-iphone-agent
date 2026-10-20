// BLE HID bridge: an ESP32-S3 that presents itself to the phone as a Bluetooth
// mouse + keyboard and takes line commands over TCP (Wi-Fi). Same wire protocol
// as the USB hid_bridge (ping|home|move|press|release|click|scroll|type|key),
// but the pointer/keyboard goes over Bluetooth — no USB involved at all.
//
// Pairing: on the phone, Settings → Bluetooth (or AssistiveTouch → Devices) →
// tap "HID Bridge". Pointer appears when paired + AssistiveTouch is on.

#include <WiFi.h>
#include <esp_task_wdt.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include "secrets.h"  // WIFI_SSID, WIFI_PASS, SERVER_HOST, SERVER_PORT

const int PACE_MS = 8;      // delay between pointer reports (like the USB pace)
const int HOME_REPORTS = 70;

NimBLEHIDDevice* hid;
NimBLECharacteristic* mouseInput;
NimBLECharacteristic* keyInput;
volatile bool bleConnected = false;

// HID report descriptor: mouse (Report ID 1) + keyboard (Report ID 2)
static const uint8_t REPORT_MAP[] = {
  // --- Mouse (标准蓝牙鼠标格式, 无 Report ID) ---
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
  0x09, 0x01, 0xA1, 0x00,
  0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
  0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
  0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
  0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
  0xC0, 0xC0
};

uint8_t mouseButtons = 0;

void sendMouse(int8_t dx, int8_t dy, int8_t wheel) {
  if (!bleConnected) return;
  uint8_t r[4] = { mouseButtons, (uint8_t)dx, (uint8_t)dy, (uint8_t)wheel };
  mouseInput->notify(r, 4);
}

void pacedMove(long dx, long dy) {
  while (dx || dy) {
    int8_t sx = constrain(dx, -127, 127), sy = constrain(dy, -127, 127);
    sendMouse(sx, sy, 0);
    dx -= sx; dy -= sy;
    delay(PACE_MS);
  }
}

void sendKeyReport(uint8_t mods, const uint8_t keys[6]) {
  if (!bleConnected) return;
  uint8_t r[9] = { 0x02, mods, 0x00, keys[0], keys[1], keys[2], keys[3], keys[4], keys[5] };
  keyInput->notify(r, 9);
}

// ASCII (printable + \n \t \b) → HID keycode + shift
bool asciiToKey(char c, uint8_t &keycode, bool &shift) {
  shift = false; keycode = 0;
  if (c >= 'a' && c <= 'z') { keycode = 0x04 + (c - 'a'); return true; }
  if (c >= 'A' && c <= 'Z') { keycode = 0x04 + (c - 'A'); shift = true; return true; }
  if (c >= '1' && c <= '9') { keycode = 0x1E + (c - '1'); return true; }
  switch (c) {
    case '0': keycode = 0x27; return true;
    case ' ': keycode = 0x2C; return true;
    case '-': case '_': keycode = 0x2D; shift = (c == '_'); return true;
    case '=': case '+': keycode = 0x2E; shift = (c == '+'); return true;
    case '[': case '{': keycode = 0x2F; shift = (c == '{'); return true;
    case ']': case '}': keycode = 0x30; shift = (c == '}'); return true;
    case '\\': case '|': keycode = 0x31; shift = (c == '|'); return true;
    case ';': case ':': keycode = 0x33; shift = (c == ':'); return true;
    case '\'': case '"': keycode = 0x34; shift = (c == '"'); return true;
    case '`': case '~': keycode = 0x35; shift = (c == '~'); return true;
    case ',': case '<': keycode = 0x36; shift = (c == '<'); return true;
    case '.': case '>': keycode = 0x37; shift = (c == '>'); return true;
    case '/': case '?': keycode = 0x38; shift = (c == '?'); return true;
    case '!': keycode = 0x1E; shift = true; return true;
    case '@': keycode = 0x1F; shift = true; return true;
    case '#': keycode = 0x20; shift = true; return true;
    case '$': keycode = 0x21; shift = true; return true;
    case '%': keycode = 0x22; shift = true; return true;
    case '^': keycode = 0x23; shift = true; return true;
    case '&': keycode = 0x24; shift = true; return true;
    case '*': keycode = 0x25; shift = true; return true;
    case '(': keycode = 0x26; shift = true; return true;
    case ')': keycode = 0x27; shift = true; return true;
    case '\n': keycode = 0x58; return true;
    case '\t': keycode = 0x2B; return true;
    case '\b': keycode = 0x2A; return true;
  }
  return false;
}

uint8_t modifierFor(const String &name) {
  if (name == "cmd" || name == "gui") return 0x08;  // LGUI
  if (name == "ctrl" || name == "control") return 0x01;
  if (name == "alt" || name == "opt") return 0x04;
  if (name == "shift") return 0x02;
  return 0;
}

uint8_t keyCodeFor(const String &name) {
  if (name == "enter" || name == "return") return 0x58;
  if (name == "esc") return 0x29;
  if (name == "tab") return 0x2B;
  if (name == "backspace" || name == "del") return 0x2A;
  if (name == "space") return 0x2C;
  if (name == "up") return 0x52;
  if (name == "down") return 0x51;
  if (name == "left") return 0x50;
  if (name == "right") return 0x4F;
  if (name.length() == 1) { bool sh; uint8_t k; if (asciiToKey(name[0], k, sh) && !sh) return k; }
  return 0;
}

void typeText(const String &text) {
  for (unsigned int i = 0; i < text.length(); i++) {
    bool shift; uint8_t k;
    if (!asciiToKey(text[i], k, shift)) continue;
    uint8_t keys[6] = { k, 0, 0, 0, 0, 0 };
    sendKeyReport(shift ? 0x02 : 0x00, keys);
    delay(PACE_MS);
    uint8_t none[6] = { 0, 0, 0, 0, 0, 0 };
    sendKeyReport(0, none);
    delay(PACE_MS);
  }
}

bool pressCombo(String combo) {
  combo += '+';
  uint8_t mods = 0;
  uint8_t key = 0;
  bool ok = true;
  while (combo.length()) {
    int i = combo.indexOf('+');
    String part = (i >= 0) ? combo.substring(0, i) : combo;
    combo = (i >= 0) ? combo.substring(i + 1) : "";
    if (!part.length()) continue;
    uint8_t m = modifierFor(part);
    if (m) { mods |= m; continue; }
    uint8_t k = keyCodeFor(part);
    if (!k) { ok = false; continue; }
    key = k;
  }
  if (!ok) return false;
  uint8_t keys[6] = { key, 0, 0, 0, 0, 0 };
  sendKeyReport(mods, keys);
  delay(30);
  uint8_t none[6] = { 0, 0, 0, 0, 0, 0 };
  sendKeyReport(0, none);
  return true;
}

bool bleReady() {
  return bleConnected;
}

String run(const String &line) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0;
  sscanf(arg.c_str(), "%ld %ld", &a, &b);

  if (cmd == "ping") return "ok";
  if (!bleReady()) return "err ble not connected (pair 'HID Bridge' in the phone's bluetooth)";
  if (cmd == "home") { for (int i = 0; i < HOME_REPORTS; i++) { sendMouse(-127, -127, 0); delay(2); } return "ok"; }
  if (cmd == "move") { pacedMove(a, b); return "ok"; }
  if (cmd == "press") { mouseButtons |= 0x01; sendMouse(0, 0, 0); return "ok"; }
  if (cmd == "release") { mouseButtons &= ~0x01; sendMouse(0, 0, 0); return "ok"; }
  if (cmd == "click") { mouseButtons |= 0x01; sendMouse(0, 0, 0); delay(60); mouseButtons &= ~0x01; sendMouse(0, 0, 0); return "ok"; }
  if (cmd == "scroll") { sendMouse(0, 0, (int8_t)constrain(a, -127, 127)); return "ok"; }
  if (cmd == "type") return "err keyboard not supported (mouse-only build)";
  if (cmd == "key") return "err keyboard not supported (mouse-only build)";
  return "err unknown command";
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

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    bleConnected = true;
  }
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    bleConnected = false;
    mouseButtons = 0;  // a drop mid-gesture must not leave the button held
    NimBLEDevice::startAdvertising();
  }
};

WiFiClient server;

void setup() {
  esp_task_wdt_config_t wdt = { .timeout_ms = 8000, .idle_core_mask = 0, .trigger_panic = true };
  esp_task_wdt_reconfigure(&wdt);
  esp_task_wdt_add(NULL);

  WiFi.setHostname("hid-bridge-ble");
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  NimBLEDevice::init("HID Bridge");
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEServer* pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  hid = new NimBLEHIDDevice(pServer);
  hid->setReportMap((uint8_t *)REPORT_MAP, sizeof(REPORT_MAP));
  hid->setManufacturer("esp32-iphone-agent");
  hid->setPnp(0x02, 0x1234, 0xABCD, 0x0100);
  hid->setBatteryLevel(100);
  mouseInput = hid->getInputReport(1);
  keyInput = hid->getInputReport(2);

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->setAppearance(0x03C2);  // mouse
  adv->addServiceUUID(hid->getHidService()->getUUID());
  adv->start();

  server.setNoDelay(true);
}

void loop() {
  esp_task_wdt_reset();
  if (WiFi.status() != WL_CONNECTED) { delay(50); return; }
  if (!server.connected()) {
    mouseButtons = 0;
    if (!server.connect(SERVER_HOST, SERVER_PORT, 1000)) { delay(200); return; }
    server.setNoDelay(true);
    server.printf("hello %s %lu\n", resetReason(), millis());
  }
  if (server.available()) {
    String line = server.readStringUntil('\n');
    line.trim();
    if (!line.length()) return;
    unsigned long started = millis();
    String reply = run(line);
    server.print(reply + "\n");
  }
}
