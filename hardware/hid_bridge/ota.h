#pragma once
#include <Arduino.h>

// Firmware update over Wi-Fi: TCP on port 7300, the same per-boot token as the video channel.
// The app sends "ota <token> <size> <md5>\n" (or, under the LAN lock, "chal\n", answered "chal <nonce>\n", then
// "ota2 <size> <sha256> <hmac>\n": docs/ble-protocol.md, "LAN mode") and then the image; the board answers "ok\n" to the header,
// writes the image to the other app slot and answers "done\n" (then reboots) or "err <reason>\n".
// A new image must call ota_confirm() once it runs well, or the bootloader goes back to the old one.
bool ota_begin();
// The StopWatch: no listener until the app asks (`ota on`): its internal RAM can't keep the 6 KB task up all the
// time. Listens for OTA_OPEN_MS after the last session, then frees it all. "" when started, else why not.
const char *ota_open();
static const uint32_t OTA_OPEN_MS = 120000;
static const size_t OTA_HEAP_MIN = 11000;  // internal heap needed to start: task 6 KB + Update's 4 KB buffer
bool ota_busy();
void ota_confirm();  // marks the running image good (no-op when it already is)
