// The computer's link (esp32agent CLI, docs/cli-protocol.md): pairing, session keys and sealed frames on the
// cli_in / cli_out characteristics, next to the app's bonded link. ble_link.cpp owns the radio side.
#pragma once
#include <Arduino.h>

void cli_begin();                                         // loads the paired clients from NVS
void cli_on_frame(int slot, const uint8_t *p, size_t n);  // a cli_in write (NimBLE host task)
void cli_reset(int slot);                                 // that peer disconnected
bool cli_authed(int slot);                                // its first sealed frame verified
int cli_slot();                                           // the authenticated CLI's slot, -1 if none
void cli_forget_all();                                    // unpair: every client must pair again
// Sealed board → CLI frames. Control (replies, status) only from the BLE TX task; video only from the video task:
// each stream's counter then grows in send order.
bool cli_send_ctrl(char kind, const char *text, size_t n, uint32_t timeout_ms);
bool cli_send_video(const uint8_t *chunk, size_t n);
size_t cli_video_room();                                  // payload bytes per video chunk (as ble_video_room); 0 = no CLI
