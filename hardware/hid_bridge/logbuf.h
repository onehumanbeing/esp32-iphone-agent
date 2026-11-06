#pragma once
#include <Arduino.h>

// A board log line: printed to USB serial and kept in the RAM log the app and the CLI read with `logs`.
// Never log secrets (Wi-Fi password, OTA token, pairing keys): the RAM log goes to anyone paired.
void board_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// Only into the RAM log (for lines already printed elsewhere, e.g. the AirPlay relay).
void board_log_keep(const char *line);
void relayLine(const char *msg);  // hid_bridge.ino: to the app over BLE ("blog"), at most 16 a second
// `logs <offset> [max chars]`: "ok <next> <end> <text>", '\n' escaped as \n; read until next == end.
String board_log_page(const String &arg);
