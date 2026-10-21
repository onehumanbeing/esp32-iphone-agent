// Mirrored H.264 from AirPlay to BLE: keeps the current GOP in PSRAM and sends it on `snap`,
// or every access unit while `stream on`. Also runs `bench` and computes the video stats.
#pragma once
#include <Arduino.h>

bool video_begin();
void video_on_config(const uint8_t *sps_pps, size_t len);  // AirPlay callbacks (mirror task)
void video_on_au(const uint8_t *au, size_t len, bool idr);
void video_stream(bool on, char who);             // who: FROM_APP or FROM_CLI (ble_link.h); each has its own stream
void video_snap(const String &id, char who);      // replies "<id> ok" when the GOP is sent, to who
void video_bench(const String &id, uint32_t kb, char who);  // replies "<id> ok <ms>"

struct VideoStats {
  uint32_t kbps, idr_ms, gop_bytes;
  uint32_t age_ms;  // since the last frame from AirPlay (0: none yet); grows on a still screen too
  float fps;
  uint32_t overflows;  // times the GOP filled up since boot
  bool frozen;         // GOP full and who's stream not going on from it: no new frame until the next IDR (#25)
};
VideoStats video_stats(char who);  // frozen is as seen by who's stream
