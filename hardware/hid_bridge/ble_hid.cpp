#ifdef ZECTRIX_NOTE4
#include "ble_hid.h"
#include "ble_link.h"
#include "hid_keys.h"
#include "note4_battery.h"
#include "note4_hid_target.h"
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "USBHIDKeyboard.h"
#include "tusb.h"

static NimBLEHIDDevice *hidDevice;
static NimBLECharacteristic *inputs[3];
static Note4HidTarget target;
static unsigned lastGeneration;
static bool failed, releasePending;
static uint8_t mouseButtons, keys[8];
static uint32_t batteryAt, lastReportAt;

static void resetReports() {
  uint8_t zero[8] = {};
  inputs[0]->setValue(zero, 5);
  inputs[1]->setValue(zero, 8);
  inputs[2]->setValue(zero, 2);
}

static uint8_t batteryPercent() {
  uint32_t total = 0;
  for (int i = 0; i < 10; i++) total += 2 * analogReadMilliVolts(4);
  return note4_battery_percent(total / 10);
}

class HidSubscription : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic *, NimBLEConnInfo &info, uint16_t sub) override {
    ble_note4_subscribe(info.getConnHandle(), sub & 1);
  }
};
static HidSubscription hidSubscription;

void ble_hid_begin(NimBLEServer *server) {
  auto *hid = new NimBLEHIDDevice(server);
  hidDevice = hid;
  static uint8_t map[] = {
    TUD_HID_REPORT_DESC_MOUSE(HID_REPORT_ID(1)),
    TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(2)),
    TUD_HID_REPORT_DESC_CONSUMER(HID_REPORT_ID(3))
  };
  hid->setReportMap(map, sizeof map);
  hid->setManufacturer("Zectrix Note 4 / ESP32 iPhone Agent");
  hid->setPnp(2, 0x303a, 0x1001, 0x0101);
  hid->setHidInfo(0, 3);
  for (int i = 0; i < 3; i++) inputs[i] = hid->getInputReport(i + 1);
  resetReports();
  inputs[0]->setCallbacks(&hidSubscription);
  hid->getOutputReport(2)->setValue(uint8_t(0));
  // HOGP 要求电池服务；使用校准后的 ADC 电压与官方参考曲线估算电量。
  analogSetPinAttenuation(4, ADC_11db);
  hid->setBatteryLevel(batteryPercent());
  batteryAt = millis();
}

void ble_hid_disconnected(uint16_t handle) {
  target.disconnect(handle);
}

uint32_t ble_hid_session() { return target.session(); }

void ble_hid_claim(uint16_t handle, bool subscribed) {
  if (target.subscribe(handle, ble_note4_trusted(handle), subscribed)) resetReports();
}

bool ble_hid_allows(int handle) {
  return handle >= 0 && target.allows(handle, ble_note4_trusted(handle));
}

bool ble_hid_ready() {
  return ble_note4_trusted(Note4HidTarget::peer(target.session()));
}

bool ble_hid_command_begin(uint32_t session) {
  if (session != target.session()) return false;
  failed = false;
  if (lastGeneration != session) {
    mouseButtons = 0;
    memset(keys, 0, sizeof keys);
    releasePending = false;
    lastGeneration = session;
  }
  return true;
}

bool ble_hid_command_ok() {
  // 已发出按下报告后仍可能失败，交给主循环补发释放，避免残留拖动或组合键。
  if (failed) releasePending = true;
  return !failed;
}

static void send(int input, const void *data, size_t size) {
  if (failed) return;
  int handle = Note4HidTarget::peer(lastGeneration);
  uint32_t start = millis();
  for (;;) {
    if (handle < 0 || target.session() != lastGeneration || !ble_hid_ready()) { failed = true; return; }
    // 与现有视频通道使用同一 host API；只重试缓存不足，不掩盖断线或其他错误。
    os_mbuf *packet = ble_hs_mbuf_from_flat(data, size);
    int rc = packet ? ble_gatts_notify_custom(handle, inputs[input]->getHandle(), packet) : BLE_HS_ENOMEM;
    if (rc == 0) { lastReportAt = millis(); return; }
    if (rc != BLE_HS_ENOMEM || millis() - start >= 100) {
      failed = true;
#if DEBUG_SERIAL
      Serial.printf("蓝牙 HID 报告发送失败：rc=%d\n", rc);
#endif
      return;
    }
    vTaskDelay(1);
  }
}

void ble_hid_poll() {
  uint32_t now = millis();
  if (hidDevice && now - batteryAt >= 30000) {
    hidDevice->setBatteryLevel(batteryPercent(), true);
    batteryAt = now;
  }
  // shortcut: 静态按住超过五秒会释放，需要更长按住动作时延长租约。
  if (ble_hid_ready() && (releasePending || (mouseButtons && now - lastReportAt >= 5000))) {
    if (!ble_hid_command_begin(target.session())) return;
    uint8_t zero[8] = {};
    send(0, zero, 5);
    send(1, zero, 8);
    send(2, zero, 2);
    if (!failed) {
#if DEBUG_SERIAL
      if (releasePending) Serial.println("蓝牙 HID 异常命令后的按键释放完成");
#endif
      mouseButtons = 0;
      memset(keys, 0, sizeof keys);
      releasePending = false;
    } else {
      releasePending = true;
    }
  }
}

void BleHidMouse::move(int8_t x, int8_t y, int8_t wheel, int8_t pan) {
  int8_t report[] = {static_cast<int8_t>(mouseButtons), x, y, wheel, pan};
  send(0, report, sizeof report);
}
void BleHidMouse::press(uint8_t buttons) { mouseButtons |= buttons; move(0, 0); }
void BleHidMouse::release(uint8_t buttons) { mouseButtons &= ~buttons; move(0, 0); }

void BleHidKeyboard::press(uint8_t key) {
  if (!hid_key_press(keys, key, KeyboardLayout_en_US)) { failed = true; return; }
  send(1, keys, sizeof keys);
}
void BleHidKeyboard::releaseAll() { memset(keys, 0, sizeof keys); send(1, keys, sizeof keys); }
size_t BleHidKeyboard::write(uint8_t value) {
  if (value >= 128) { failed = true; return 0; }
  press(value);
  delay(8);
  releaseAll();
  delay(8);
  return failed ? 0 : 1;
}

void BleHidConsumer::press(uint16_t usage) {
  uint8_t report[] = {static_cast<uint8_t>(usage), static_cast<uint8_t>(usage >> 8)};
  send(2, report, sizeof report);
}
void BleHidConsumer::release() { press(0); }
#endif
