// BLE GATT link to the iOS app (docs/ble-protocol.md): cmd/reply, status heartbeat,
// video chunks and the encrypted `net` characteristic. h2zero NimBLE-Arduino; build with flash.sh
// (it force-includes nimble_cfg.h, the host buffer sizes).
#pragma once
#include <Arduino.h>

void ble_begin(const String &name);
bool ble_connected();
// Where a command came from, and where its reply goes.
const char FROM_APP = 'a', FROM_CLI = 'c';

void ble_push_cmd(char origin, const char *line, size_t n);
bool ble_pop_cmd(String &line, char &origin, uint32_t wait_ms);  // next command, oldest first
void ble_reply(const String &line, char dest = FROM_APP);         // queued; sent before any further video
void ble_status(const String &json);               // latest wins; sent before any further video
void ble_cli_status(const String &full, const String &compact);  // to the CLI, the form that fits its MTU
size_t ble_video_room();                           // payload bytes per video notify; 0 = nobody listening
bool ble_video_send(const uint8_t *p, size_t n);   // waits for free buffers; false = gave up
void ble_unpair();

uint16_t ble_mtu();
uint8_t ble_phy();       // 1 or 2 (Mbit)
uint32_t ble_kbps();     // video bytes out, last second
uint32_t ble_drops();    // video notifies we failed to send
uint32_t ble_reply_drops();  // replies that never got out to a subscribed peer
int ble_peers();         // connected centrals

// For cli_link.cpp (slot = the peer's connection slot).
bool ble_pair_window_open();
uint16_t ble_cli_mtu(int slot);
bool ble_cli_subscribed(int slot);
bool ble_cli_notify(int slot, const uint8_t *p, size_t n, bool video, uint32_t timeout_ms);
void ble_cli_drop(int slot);
void ble_cli_push_cmd(const char *line, size_t n);
