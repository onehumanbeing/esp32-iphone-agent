// Video chunks to the app over the board's Wi-Fi: UDP port 7200, one app at a time, with resends of lost
// chunks on request (docs/ble-protocol.md, "Wi-Fi video"). BLE stays the command link and the fallback.
#pragma once
#include <Arduino.h>

// Transport for video over the board's Wi-Fi, chosen at build time; the app must match (VideoTransport.current).
// 1: TCP on port 7201 (wifi_video_tcp.cpp): ordered and lossless, the stack does flow control.
// 0: UDP on port 7200 with nack/resync (wifi_video.cpp): kept for later tests (TODO); weak links turned its
//    resyncs into storms that starved mirroring and BLE (2026-10-20).
#ifndef WV_TCP
#define WV_TCP 1
#endif

const size_t WV_PAYLOAD = 1380;   // chunk payload per datagram/record: header + this stays under one IP packet

bool wv_begin();                  // socket, resend buffer and the control task
String wv_token();                // per-boot secret; only a bonded app reads it (encrypted `net` value)
bool wv_active();                 // an app with the token was heard within the last 3 s
bool wv_send(const uint8_t *chunk, size_t n);  // one chunk (seq in its header), kept for resends
bool wv_take_resync();            // a new app session, or it gave up on a gap: restart from the GOP's IDR
bool wv_take_resume(uint32_t *ts);  // the new session's app is in step up to the AU with this timestamp (TCP)
uint32_t wv_kbps();               // bytes out, last second (resends included)
uint32_t wv_nacks();              // resend requests since boot (UDP only)
uint32_t wv_drops();              // UDP: datagrams the driver had no room for; TCP: sessions dropped on a stalled send

// AirPlay audio to the app (TCP only, and only after the app sent "audio"): records like video chunks,
// [seq u16 LE][flags][payload] with WV_AUDIO set in flags and their own seq. Payload: [u32 LE board ms]
// [u32 LE RTP ts][AAC-ELD frame]; the first frame of a segment carries VF_START, the segment's end is an
// empty VF_END record. See docs/ble-protocol.md, "Wi-Fi audio".
const uint8_t WV_AUDIO = 0x80;
void wv_audio(int event, const uint8_t *frame, size_t len, uint32_t ts);  // airplay_cfg.on_audio; never blocks
uint32_t wv_audio_drops();        // audio records lost because the queue was full or no app wanted them
