// M5Stack StopWatch (flash.sh --stopwatch): the round screen, two buttons, touch, vibration and IMU, in a task of
// its own so loop() and its watchdog never wait on them. The app drives it with `ui <json>` lines and hears the
// buttons as `btn <verb>` lines (docs/ble-protocol.md, "StopWatch screen"). The model is src/ui/sw_model.h.
#pragma once
#ifdef M5_STOPWATCH
#include <stddef.h>
#include <stdint.h>

void stopwatch_begin();                       // board_begin(): M5.begin powers display, touch, IMU and vibration
uint8_t stopwatch_battery();                  // 0-100, the level the screen task last read (0: unknown)
void stopwatch_ui_start(const char *name);    // end of setup(); name: the Bluetooth name, shown until paired
bool stopwatch_ui_line(const char *arg);      // `ui <arg>` from the app; false: not a JSON object or `off`
bool stopwatch_voice_line(const char *arg);
bool stopwatch_picks_line(const char *arg);
bool stopwatch_answer_line(const char *arg, bool more);  // `answer <text>`, `answer+ <more>`: a done task's answer   // `picks ["name", ...]`: the quick intents (up to 5)
bool stopwatch_press(const char *arg);        // `swpress yellow|blue MS` (USB serial tests): a press held MS   // `voice heard <text>` | `voice fail <code>` from the app
void stopwatch_ui_link(bool hid, bool app);   // loop(): the phone's HID link, the app's link
void stopwatch_ui_net(bool connecting, bool wifi, int mirror);  // loop(): a link not yet encrypted, a phone on Wi-Fi, AirPlay 0 idle / 1 connected / 2 streaming
bool stopwatch_ui_next(char *out, size_t n);  // loop(): the next `btn ...` line for the app
#endif
