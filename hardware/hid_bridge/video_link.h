// Mirrored H.264 from AirPlay to BLE: keeps the current GOP in PSRAM and sends it on `snap`,
// or every access unit while `stream on`. Also runs `bench` and computes the video stats.
#pragma once
#include <Arduino.h>

bool video_begin();
void video_on_config(const uint8_t *sps_pps, size_t len);  // AirPlay callbacks (mirror task)
void video_on_au(const uint8_t *au, size_t len, bool idr);
void video_on_lost();  // AirPlay dropped a video packet for good (status "lost")
void video_stream(bool on, char who);             // who: FROM_APP or FROM_CLI (ble_link.h); one is sent at a time, the app first
void video_snap(const String &id, char who);      // replies "<id> ok" when the GOP is sent, to who
void video_bench(const String &id, uint32_t kb, char who);  // replies "<id> ok <ms>"

struct VideoStats {
  uint32_t kbps, idr_ms, gop_bytes;
  uint32_t age_ms;  // since the last frame from AirPlay (0: none yet); grows on a still screen too
  float fps;
  uint32_t overflows;  // times the GOP filled up since boot
  bool frozen;         // GOP full and who's stream not going on from it: no new frame until the next IDR (#25)
  uint32_t lost;       // video packets dropped for good since boot: the picture may not decode until an IDR
};
VideoStats video_stats(char who);  // frozen is as seen by who's stream
String video_debug();              // `vdbg`: the tail and the app stream's state, for a frozen screen

// Running totals for the periodic `diag` lines (diag.cpp): it logs the change over each window.
struct VideoDiag {
  uint32_t aus, bytes, idrs;  // from AirPlay
  uint32_t maxGapMs;          // the longest wait between two AUs (or since the last one) since the last call
  uint32_t sinceIdrMs;        // 0: no IDR yet
  int gopAus;
  uint32_t gopKb, overflows, frozenMs;
  int gopUnref;                  // AUs a squeeze would drop (unreferenced, not the newest)
  uint32_t gopUnrefKb, squeezes;  // frozenMs: how long the GOP has been full (0: it isn't)
  bool frozen;                          // as the app's stream sees it (status fz)
  uint32_t wifiChunks, wifiFails, bleChunks, bleFails, flips;  // the app's chunks by link, and link switches
  uint32_t resyncs, resumes, resumeMisses, tailBreaks;
  bool following;  // the app's stream goes on AU after AU in this GOP (or its tail)
  char lastWhy;    // why it last stopped following (vdbg `uf`: w r n c g t b, '-' never)
};
VideoDiag video_diag();
