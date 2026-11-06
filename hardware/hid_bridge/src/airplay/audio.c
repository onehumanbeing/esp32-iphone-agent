/*
 * AirPlay mirroring audio, see audio.h. Ported from UxPlay lib/raop_buffer.c and lib/raop_rtp.c.
 * Copyright (C) 2011-2012 Juho Vähä-Herttua, (C) 2021-2025 F. Duncanh; ESP32 port 2026.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#include <string.h>
#include "mbedtls/aes.h"
#include "audio.h"

bool ap_rtp_parse(const uint8_t *p, size_t n, ap_rtp *out) {
  if (n < 12 || (p[0] >> 6) != 2) return false;
  out->seq = (uint16_t)(p[2] << 8 | p[3]);
  out->ts = (uint32_t)p[4] << 24 | p[5] << 16 | p[6] << 8 | p[7];
  out->payload = p + 12;
  out->len = n - 12;
  return true;
}

bool ap_audio_no_data(const uint8_t *payload, size_t len) {
  static const uint8_t marker[4] = {0x00, 0x68, 0x34, 0x00};
  return len == 0 || (len == 4 && !memcmp(payload, marker, 4));
}

void ap_audio_decrypt(const uint8_t key[16], const uint8_t iv[16], const uint8_t *in, size_t n, uint8_t *out) {
  size_t whole = n / 16 * 16;
  uint8_t v[16];
  memcpy(v, iv, 16);  // the IV restarts with every packet
  if (out != in) memcpy(out + whole, in + whole, n - whole);
  if (!whole) return;
  mbedtls_aes_context aes;
  mbedtls_aes_init(&aes);
  mbedtls_aes_setkey_dec(&aes, key, 128);
  mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_DECRYPT, whole, v, in, out);
  mbedtls_aes_free(&aes);
}

int ap_audio_gate_packet(ap_audio_gate *g, int64_t now_ms, bool no_data) {
  if (no_data) return AP_GATE_SKIP;
  g->last_ms = now_ms;
  g->frames++;
  if (g->active) return AP_GATE_FRAME;
  g->active = true;
  g->segments++;
  return AP_GATE_START;
}

bool ap_audio_gate_idle(ap_audio_gate *g, int64_t now_ms) {
  if (!g->active || now_ms - g->last_ms < AP_AUDIO_IDLE_MS) return false;
  g->active = false;
  return true;
}
