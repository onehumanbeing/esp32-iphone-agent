// The CLI's link over Wi-Fi (docs/cli-protocol.md, "Wi-Fi link"): TCP port 7202, one computer at a time, the
// same sealed frames as on BLE in records [u16 LE length][frame]. A zero-length record is a keepalive.
// Pairing stays BLE-only (it needs the board's pairing window); a session here is cli_link.cpp's slot CLI_TCP_SLOT.
#pragma once
#include <Arduino.h>

const int CLI_TCP_SLOT = 2;      // after ble_link's two peer slots
const size_t CLI_TCP_MTU = 1460; // largest frame we send in one record (the "MTU" cli_link.cpp plans chunks with)

bool cli_tcp_begin();                                            // listener + its task
bool cli_tcp_up();                                               // a computer is connected
bool cli_tcp_send(const uint8_t *p, size_t n, uint32_t timeout_ms);  // one record; false (and dropped) if it stalls
void cli_tcp_drop();                                             // closes the connection
uint32_t cli_tcp_kbps();                                         // bytes out, last second
