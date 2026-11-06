/*
 * AirPlay mirroring audio: RTP packets on the audio data port, AES-128-CBC encrypted AAC-ELD frames, and a
 * sound / no sound gate. Plain C (mbedtls only) so the host tests build it. Decryption as in UxPlay
 * lib/raop_buffer.c: key = the session aeskey, IV = the SETUP eiv, a fresh CBC pass per packet, whole 16-byte
 * blocks only (the tail is sent in the clear).
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AP_AUDIO_CT_AAC_ELD 8  // SETUP "ct" of mirroring audio (2 is ALAC, audio-only AirPlay)
#define AP_AUDIO_IDLE_MS 500   // no sounding frame for this long ends a segment

typedef struct {
  uint16_t seq;
  uint32_t ts;  // RTP timestamp, 44.1 kHz
  const uint8_t *payload;
  size_t len;
} ap_rtp;

// A 12-byte RTP header plus payload. False for anything shorter or not RTP version 2.
bool ap_rtp_parse(const uint8_t *p, size_t n, ap_rtp *out);
// No sound in this packet: the sender's empty packets (no payload, or the 4-byte no-data marker 00 68 34 00).
// These are not encrypted.
bool ap_audio_no_data(const uint8_t *payload, size_t len);
// in -> out (may be the same buffer), n bytes.
void ap_audio_decrypt(const uint8_t key[16], const uint8_t iv[16], const uint8_t *in, size_t n, uint8_t *out);

// Sound / no sound. A segment starts with the first sounding frame and ends AP_AUDIO_IDLE_MS after the last one.
typedef struct {
  bool active;
  int64_t last_ms;
  uint32_t segments, frames;
} ap_audio_gate;

enum { AP_GATE_SKIP, AP_GATE_START, AP_GATE_FRAME };
// A received packet. Returns AP_GATE_START for the first sounding frame of a segment, AP_GATE_FRAME for the
// others, AP_GATE_SKIP for no-data packets (not forwarded).
int ap_audio_gate_packet(ap_audio_gate *g, int64_t now_ms, bool no_data);
// Call regularly. True once when the current segment has ended.
bool ap_audio_gate_idle(ap_audio_gate *g, int64_t now_ms);

#ifdef __cplusplus
}
#endif
