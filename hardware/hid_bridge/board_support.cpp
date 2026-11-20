#include "board_support.h"
#ifdef ZECTRIX_NOTE4
#include <Arduino.h>
#include <driver/gpio.h>
#include "note4_battery.h"
#endif
#ifdef M5_STOPWATCH
#include "stopwatch_ui.h"
#endif

// ESP-IDF places this marker after the 256-byte app descriptor so OTA can check the target before writing.
extern const char firmware_target[16]
#ifdef ARDUINO_ARCH_ESP32
    __attribute__((section(".rodata_custom_desc"), used))
#endif
    =
#ifdef M5_STOPWATCH
    "ESPA:stopwatch";
#elif defined(ZECTRIX_NOTE4)
    "ESPA:note4-ble";
#elif defined(HID_DUAL)
    "ESPA:dual-8m";  // no release channel takes it yet
#elif defined(HID_TRANSPORT_BLE)
    "ESPA:ble-8m";
#else
    "ESPA:usb-8m";
#endif

void board_begin() {
#ifdef M5_STOPWATCH
  stopwatch_begin();  // M5Unified: power rails, display, touch, IMU and vibration (stopwatch_ui.h)
#endif
#ifdef ZECTRIX_NOTE4
  // Latch battery power before disabling idle peripherals to avoid noise and wasted power.
  gpio_hold_dis(GPIO_NUM_17);
  gpio_set_level(GPIO_NUM_17, 1);
  gpio_set_direction(GPIO_NUM_17, GPIO_MODE_OUTPUT);
  gpio_hold_en(GPIO_NUM_17);
  for (int pin : {6, 42, 46}) {
    gpio_hold_dis(static_cast<gpio_num_t>(pin));
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
  }
  gpio_hold_dis(GPIO_NUM_3);
  pinMode(3, OUTPUT);
  digitalWrite(3, HIGH);
  analogSetPinAttenuation(4, ADC_11db);
#endif
}

uint8_t board_battery_percent() {
#ifdef M5_STOPWATCH
  return stopwatch_battery();
#elif defined(ZECTRIX_NOTE4)
  uint32_t total = 0;
  for (int i = 0; i < 10; i++) total += 2 * analogReadMilliVolts(4);
  return note4_battery_percent(total / 10);
#else
  // This target has no battery monitor; BAS 3.1.1 specifies zero for a device without a battery.
  return 0;
#endif
}

const char *board_status_fields() {
#ifdef M5_STOPWATCH
  return ",\"board\":\"stopwatch\",\"ui\":1,\"ota\":1";  // ui: it takes `ui <json>` and sends `btn` lines; ota: `ota on`
#elif defined(ZECTRIX_NOTE4)
  return ",\"board\":\"note4\"";
#else
  return "";
#endif
}

bool board_supports_usb_release() {
#if defined(ZECTRIX_NOTE4) || defined(M5_STOPWATCH) || defined(HID_TRANSPORT_BLE)
  return false;
#else
  return true;
#endif
}
