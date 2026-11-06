/*
 * AirPlay screen-mirroring receiver for ESP32 (H.264 video, plus the AAC-ELD audio while there is sound), ported from UxPlay
 * (https://github.com/FDH2/UxPlay, lib/), which builds on RPiPlay by Juho Vähä-Herttua et al.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { AIRPLAY_IDLE, AIRPLAY_CONNECTED, AIRPLAY_STREAMING };
// on_audio events: a segment of sound starts (with its first frame), one more frame, the segment ended (no data).
enum { AIRPLAY_AUDIO_START, AIRPLAY_AUDIO_FRAME, AIRPLAY_AUDIO_END };

typedef struct {
  uint32_t packets, segments, frames;  // since boot: audio packets received, sound segments, sounding frames
  bool sound;                          // a segment is going on
  float volume;                        // the sender's volume in dB (-144: muted), 0 until it sends one
} airplay_audio_stats;

typedef struct {
  const char *name;         // receiver name shown in Screen Mirroring
  uint8_t hwaddr[6];        // advertised deviceid
  uint8_t ed25519_seed[32]; // long-term pairing identity (keep stable across boots)
  uint16_t width, height;   // advertised display
  uint8_t max_fps;
  // H.264 out, Annex-B. Called from the mirror task; the data is only valid during the call.
  void (*on_config)(const uint8_t *sps_pps, size_t len);
  void (*on_au)(const uint8_t *au, size_t len, bool idr);
  // Decrypted AAC-ELD frames (44.1 kHz stereo, 480 samples each), only while there is sound; ts is the RTP
  // timestamp. Called from the mirror task: copy the data, don't block. Optional.
  void (*on_audio)(int event, const uint8_t *frame, size_t len, uint32_t ts);
  void (*log)(const char *msg);  // optional handshake trace
} airplay_cfg;

// Advertises over mDNS and starts the RTSP server task. Call once Wi-Fi is up (any mode).
bool airplay_start(const airplay_cfg *cfg);
int airplay_state(void);  // AIRPLAY_IDLE / _CONNECTED / _STREAMING
// Display advertised in /info from the next mirroring session on.
void airplay_set_display(uint16_t width, uint16_t height, uint8_t max_fps);
airplay_audio_stats airplay_audio(void);

#ifdef __cplusplus
}
#endif
