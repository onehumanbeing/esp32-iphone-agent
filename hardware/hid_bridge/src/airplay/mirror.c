/*
 * AirPlay mirror data channel: TCP stream of 128-byte headers + payloads, AES-128-CTR
 * decryption of the H.264 access units, AVCC -> Annex-B, SPS/PPS extraction; plus the
 * minimal NTP timing client; and the audio data port, whose AAC-ELD frames go to on_audio while there is sound.
 * Ported from UxPlay lib/raop_rtp_mirror.c, lib/mirror_buffer.c, lib/raop_rtp.c and lib/raop_ntp.c.
 * Copyright (C) 2019 dsafa22, (C) 2018 Juho Vähä-Herttua, (C) 2021-2025 F. Duncanh; ESP32 port 2026.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "mbedtls/aes.h"
#include "../video/gop.h"
#include "keystream.h"
#include "audio.h"
#include "ap_internal.h"

#define MAX_PAYLOAD (2 * 1024 * 1024)
#define NTP_INTERVAL_MS 3000

#define KS_MAX 4
#define AUDIO_PACKET_MAX 2048  // AAC-ELD frames are a few hundred bytes

static uint8_t key_copy[16], iv0_copy[16];  // kept apart from m: tells a corrupted context from a re-keyed sender  // keystreams kept at once (see decrypt())

static struct {
  volatile bool run, done;
  volatile int64_t last_data_us, last_video_us;
  int64_t accepted_us;
  bool got_codec, logged_no_video, quiet_logged;
  mbedtls_aes_context aes;
  uint8_t iv0[16];                      // the first counter: every keystream of this session starts there
  keystream ks[KS_MAX];
  int nks;
  uint8_t *copy;                        // ciphertext of the packet being decrypted (PSRAM)
  size_t copy_cap;
  uint8_t *held;                        // the last undecodable packet's ciphertext, then its plaintext (PSRAM)
  size_t held_n, held_cap;
  bool held_set, held_ready;            // kept / recovered (forward it before the packet that recovered it)
  uint8_t held_hdr[8];                  // its packet header (type, option), for the log when it stays lost
  uint32_t bad, bad_logged_ms;
  uint32_t remote_ip;
  uint16_t timing_rport;
  int lfd, sfd, tfd, afd[2];
} m = {.lfd = -1, .sfd = -1, .tfd = -1, .afd = {-1, -1}};

// The audio stream; set by SETUP type 96 after the mirror session started. Stats outlive sessions.
static struct {
  volatile bool on;          // AAC-ELD with a key: decrypt and forward
  uint8_t key[16], iv[16];
  ap_audio_gate gate;
  uint8_t *buf;              // one packet (PSRAM)
  uint32_t packets;
  uint32_t s_packets, s_frames, s_bad;  // this audio stream: packets, sounding frames, unparsed
  int ct;
  volatile float volume;
} a;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static int bind_sock(int type, uint16_t port) {
  int fd = socket(AF_INET, type, 0), one = 1;
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) || (type == SOCK_STREAM && listen(fd, 1))) {
    if (fd >= 0) close(fd);
    return -1;
  }
  return fd;
}

static void close_fd(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

// SPS + PPS from the unencrypted codec packet (an avcC record) -> Annex-B config.
static void handle_codec(const uint8_t *hdr, const uint8_t *p, size_t n) {
  static const uint8_t sc[4] = {0, 0, 0, 1};
  ap_log("mirror: codec packet, option %02x %02x, %u bytes", hdr[6], hdr[7], (unsigned)n);
  uint8_t cfg[GOP_CFG_MAX];
  if (n >= 8 && !memcmp(p + 4, "hvc1", 4)) { ap_log("mirror: H.265 stream not supported"); return; }
  if (n < 11) return;
  size_t sps = p[6] << 8 | p[7];
  if (8 + sps + 3 > n) return;
  size_t pps = p[sps + 9] << 8 | p[sps + 10];
  if (11 + sps + pps > n || 8 + sps + pps > sizeof cfg) return;
  memcpy(cfg, sc, 4);
  memcpy(cfg + 4, p + 8, sps);
  memcpy(cfg + 4 + sps, sc, 4);
  memcpy(cfg + 8 + sps, p + sps + 11, pps);
  ap_log("mirror: SPS %u + PPS %u bytes", (unsigned)sps, (unsigned)pps);
  m.got_codec = true;
  if (ap_cfg.on_config) ap_cfg.on_config(cfg, 8 + sps + pps);
}

static ks_key key(void) {
  ks_key k = {.aes = &m.aes};
  memcpy(k.iv0, m.iv0, 16);
  return k;
}

static void yield(void) { vTaskDelay(1); }  // lets the network tasks run during a long search

// Normally one AES-CTR keystream runs across all video packets (mirror_buffer_decrypt() in UxPlay). After our
// app goes to Home, iOS was seen (2026-10-19) to start a second keystream from the first counter with the same
// key and to interleave packets of both, so a single keystream fails on both from then on. Keep a few: each
// packet goes to the first whose plaintext starts like a frame (most recently used first) and advances it, or
// starts a new one from iv0. Returns the keystream's number (1-based), or 0 if none fits.
// A packet dropped for good (2026-11-12: "in step after all: not a frame", then the app decoded nothing for
// minutes): its header and first 32 plaintext bytes, so the next one shows what the sender put there, and
// on_lost() so the app can tell the picture may be broken.
static void lost(const uint8_t *hdr, const uint8_t *p, size_t n) {
  static int64_t logged_ms;
  if (ap_cfg.on_lost) ap_cfg.on_lost();
  if (now_ms() - logged_ms < 1000) return;  // at most once a second
  logged_ms = now_ms();
  char hex[65] = {0};
  for (size_t i = 0; i < 32 && i < n; i++) snprintf(hex + 2 * i, 3, "%02x", p[i]);
  ap_log("mirror: lost a %u-byte packet (header %02x%02x%02x%02x %02x%02x%02x%02x): %s", (unsigned)n, hdr[0], hdr[1],
         hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7], hex);
}

static int decrypt(uint8_t *p, size_t n) {
  static uint32_t clock;
  ks_key kk = key();
  keystream next, fresh = {.off = 0};
  int order[KS_MAX], cnt = 0;
  for (int i = 0; i < m.nks; i++) order[cnt++] = i;
  for (int i = 1; i < cnt; i++)  // most recently used first
    for (int j = i; j > 0 && m.ks[order[j]].used > m.ks[order[j - 1]].used; j--) { int t = order[j]; order[j] = order[j - 1]; order[j - 1] = t; }
  for (int i = 0; i < cnt; i++) {
    if (ks_try(&kk, &m.ks[order[i]], &next, m.copy, p, n)) {
      next.used = ++clock;
      m.ks[order[i]] = next;
      return order[i] + 1;
    }
  }
  memcpy(fresh.iv, m.iv0, 16);
  if (!ks_try(&kk, &fresh, &next, m.copy, p, n)) {
    if (!cnt) return 0;
    keystream *last = &m.ks[order[0]];
    int64_t t0 = esp_timer_get_time();
    if (!ks_resync(&kk, last, &next, m.copy, p, n, 512 * 1024, yield)) return 0;
    size_t skipped = (size_t)(next.pos - n - last->pos);
    if (m.held_set && skipped == m.held_n) {
      // Nothing was skipped: the one packet we gave up on sat right there and only failed ks_plausible(). Decrypt
      // it at that position; if it parses it is a real frame, and dropping it broke every P-frame after it until
      // the next IDR (the "frame"/"Mirror" stalls of 2026-10-20).
      keystream at = *last;
      mbedtls_aes_crypt_ctr(&m.aes, m.held_n, &at.off, at.iv, at.stream, m.held, m.held);
      uint8_t h[8] = {0};
      memcpy(h, m.held, m.held_n < 8 ? m.held_n : 8);
      m.held_ready = avcc_to_annexb(m.held, m.held_n);
      ap_log("mirror: the packet before (%u bytes) was in step after all: %s (starts %02x%02x%02x%02x %02x%02x%02x%02x)",
             (unsigned)m.held_n, m.held_ready ? "recovered" : "not a frame", h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
      if (!m.held_ready) lost(m.held_hdr, m.held, m.held_n);
    } else {
      ap_log("mirror: the sender skipped %u bytes of keystream (dropped frames); picked up again in %d ms",
             (unsigned)skipped, (int)((esp_timer_get_time() - t0) / 1000));
    }
    m.held_set = false;
    next.used = ++clock;
    *last = next;
    return order[0] + 1;
  }
  int slot = m.nks < KS_MAX ? m.nks++ : 0;
  for (int i = 0; i < m.nks; i++) if (m.ks[i].used < m.ks[slot].used) slot = i;  // full: replace the stalest
  next.used = ++clock;
  m.ks[slot] = next;
  ap_log("mirror: a new keystream from the first counter (%d in use)", m.nks);
  return slot + 1;
}

static void handle_packet(const uint8_t *hdr, uint8_t *p, size_t n) {
  m.last_data_us = esp_timer_get_time();
  if (hdr[4] == 0x01) { handle_codec(hdr, p, n); return; }
  if (hdr[4] != 0x00 || !n) return;  // 0x02/0x05: heartbeat and streaming reports
  int64_t gap = m.last_video_us ? (m.last_data_us - m.last_video_us) / 1000000 : 0;
  if (gap >= 10) ap_log("mirror: video again after %d s", (int)gap);
  m.last_video_us = m.last_data_us;
  m.quiet_logged = false;
  // the keystream continues across packets, as in mirror_buffer_decrypt()
  if (n > m.copy_cap) {
    heap_caps_free(m.copy);
    m.copy_cap = n < 256 * 1024 ? 256 * 1024 : n;
    m.copy = heap_caps_malloc(m.copy_cap, MALLOC_CAP_SPIRAM);
    if (!m.copy) m.copy_cap = 0;
  }
  if (!m.copy) return;
  memcpy(m.copy, p, n);
  static int last = 1;
  int k = decrypt(p, n);
  if (!k && m.bad % 50 == 0) {  // every 50th failure: is our AES state intact, and does a clean context decode?
    mbedtls_aes_context clean;
    keystream fresh = {.off = 0}, next;
    mbedtls_aes_init(&clean);
    mbedtls_aes_setkey_enc(&clean, key_copy, 128);
    memcpy(fresh.iv, iv0_copy, 16);
    memcpy(p, m.copy, n);
    mbedtls_aes_crypt_ctr(&clean, n, &fresh.off, fresh.iv, fresh.stream, p, p);
    bool clean_ok = ks_plausible(p, n);
    int ks_clean = 0;
    for (int i = 0; i < m.nks && !ks_clean; i++) {
      next = m.ks[i];
      memcpy(p, m.copy, n);
      mbedtls_aes_crypt_ctr(&clean, n, &next.off, next.iv, next.stream, p, p);
      if (ks_plausible(p, n)) ks_clean = i + 1;
    }
    mbedtls_aes_free(&clean);
    ap_log("mirror: check: iv0 %s, clean context from iv0 %s, keystream with clean key %d",
           memcmp(m.iv0, iv0_copy, 16) ? "CHANGED" : "intact", clean_ok ? "DECODES" : "fails", ks_clean);
    if (clean_ok || ks_clean) {  // our context was damaged: rebuild it
      mbedtls_aes_free(&m.aes);
      mbedtls_aes_init(&m.aes);
      mbedtls_aes_setkey_enc(&m.aes, key_copy, 128);
      memcpy(m.iv0, iv0_copy, 16);
    }
  }
  if (!k) {
    if (n > m.held_cap) {
      heap_caps_free(m.held);
      m.held_cap = n < 256 * 1024 ? 256 * 1024 : n;
      m.held = heap_caps_malloc(m.held_cap, MALLOC_CAP_SPIRAM);
      if (!m.held) m.held_cap = 0;
    }
    m.held_set = m.held != NULL;
    if (m.held_set) {
      memcpy(m.held, m.copy, n);
      memcpy(m.held_hdr, hdr, 8);
      m.held_n = n;
    }
    m.bad++;
    int64_t now = now_ms();
    if (now - m.bad_logged_ms >= 1000) {  // at most once a second
      uint8_t *c = m.copy;
      m.bad_logged_ms = now;
      ap_log("mirror: undecodable payload x%u (%u bytes, type %02x %02x, option %02x %02x, %d keystreams, cipher %02x%02x%02x%02x)",
             (unsigned)m.bad, (unsigned)n, hdr[4], hdr[5], hdr[6], hdr[7], m.nks, c[0], c[1], c[2], c[3]);
    }
    return;
  }
  if (!avcc_to_annexb(p, n)) {  // right keystream, but the frame doesn't parse: drop it, stay in step
    static uint32_t odd, odd_logged_ms;
    odd++;
    if (now_ms() - odd_logged_ms >= 1000) {
      odd_logged_ms = now_ms();
      ap_log("mirror: frame x%u on keystream %d doesn't parse (%u bytes, type %02x %02x)", (unsigned)odd, k, (unsigned)n, hdr[4], hdr[5]);
    }
    lost(hdr, p, n);
    return;
  }
  if (m.bad) ap_log("mirror: frames decode again after %u bad (keystream %d)", (unsigned)m.bad, k);
  else if (k != last) ap_log("mirror: keystream %d now (type %02x %02x)", k, hdr[4], hdr[5]);
  last = k;
  m.bad = 0;
  m.held_set = false;
  if (m.held_ready && ap_cfg.on_au) ap_cfg.on_au(m.held, m.held_n, annexb_has_idr(m.held, m.held_n));
  m.held_ready = false;
  if (ap_cfg.on_au) ap_cfg.on_au(p, n, annexb_has_idr(p, n));
}

static void send_ntp(uint8_t req[32]) {
  struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(m.timing_rport), .sin_addr.s_addr = m.remote_ip};
  uint64_t us = esp_timer_get_time();
  uint32_t sec = (uint32_t)(us / 1000000) + 2208988800u, frac = (uint32_t)(((us % 1000000) << 32) / 1000000);
  for (int i = 0; i < 4; i++) {
    req[24 + i] = (uint8_t)(sec >> (24 - 8 * i));
    req[28 + i] = (uint8_t)(frac >> (24 - 8 * i));
  }
  sendto(m.tfd, req, 32, 0, (struct sockaddr *)&to, sizeof to);
}

static void audio_packet(void) {
  uint8_t drop[16];
  int n = recv(m.afd[0], a.buf ? a.buf : drop, a.buf ? AUDIO_PACKET_MAX : sizeof drop, 0);
  ap_rtp rtp;
  if (n <= 0 || !a.buf) return;
  a.s_packets++;
  if (!ap_rtp_parse(a.buf, (size_t)n, &rtp)) { a.s_bad++; return; }
  a.packets++;
  if (!a.on) return;
  bool none = ap_audio_no_data(rtp.payload, rtp.len);
  int ev = ap_audio_gate_packet(&a.gate, now_ms(), none);
  if (ev == AP_GATE_SKIP || !ap_cfg.on_audio) return;
  a.s_frames++;
  uint8_t *frame = (uint8_t *)rtp.payload;
  ap_audio_decrypt(a.key, a.iv, frame, rtp.len, frame);
  ap_cfg.on_audio(ev == AP_GATE_START ? AIRPLAY_AUDIO_START : AIRPLAY_AUDIO_FRAME, frame, rtp.len, rtp.ts);
}

static void mirror_task(void *arg) {
  uint8_t hdr[128], ntp[32] = {0x80, 0xd2, 0x00, 0x07}, scratch[128];
  uint8_t *payload = NULL;
  size_t got = 0, need = 128, cap = 0;
  bool in_payload = false;
  int64_t next_ntp = 0;
  while (m.run) {
    // Heartbeats keep the session "streaming" while no video comes: a still screen, or a stalled sender.
    if (!m.quiet_logged && m.last_video_us && ap_mirror_streaming() && esp_timer_get_time() - m.last_video_us > 10000000) {
      ap_log("mirror: session alive, no video for 10 s");
      m.quiet_logged = true;
    }
    if (ap_audio_gate_idle(&a.gate, now_ms()) && ap_cfg.on_audio) ap_cfg.on_audio(AIRPLAY_AUDIO_END, NULL, 0, 0);
    if (m.timing_rport && now_ms() >= next_ntp) {
      send_ntp(ntp);
      next_ntp = now_ms() + NTP_INTERVAL_MS;
    }
    fd_set rf;
    FD_ZERO(&rf);
    int fds[4] = {m.sfd >= 0 ? m.sfd : m.lfd, m.tfd, m.afd[0], m.afd[1]}, maxfd = -1;
    for (int i = 0; i < 4; i++)
      if (fds[i] >= 0) { FD_SET(fds[i], &rf); if (fds[i] > maxfd) maxfd = fds[i]; }
    // Mac-as-source often completes RTSP/FairPlay then sends no H.264; surface that silence.
    if (m.sfd >= 0 && !m.got_codec && !m.logged_no_video && m.accepted_us &&
        esp_timer_get_time() - m.accepted_us >= 5000000) {
      ap_log("mirror: no video 5s after connect (AirPlay source must be an iPhone; macOS mirroring is not supported)");
      m.logged_no_video = true;
    }
    struct timeval tv = {0, 100000};
    if (select(maxfd + 1, &rf, NULL, NULL, &tv) <= 0) continue;
    if (m.tfd >= 0 && FD_ISSET(m.tfd, &rf)) {
      int k = recv(m.tfd, scratch, sizeof scratch, 0);
      if (k >= 32) memcpy(ntp + 8, scratch + 24, 8);  // echo the client's transmit time as reference
    }
    if (m.afd[0] >= 0 && FD_ISSET(m.afd[0], &rf)) audio_packet();
    if (m.afd[1] >= 0 && FD_ISSET(m.afd[1], &rf)) recv(m.afd[1], scratch, sizeof scratch, 0);  // sync, resends
    if (m.sfd < 0) {
      if (!FD_ISSET(m.lfd, &rf)) continue;
      m.sfd = accept(m.lfd, NULL, NULL);
      got = 0, need = 128, in_payload = false;
      m.got_codec = false;
      m.logged_no_video = false;
      m.accepted_us = m.sfd >= 0 ? esp_timer_get_time() : 0;
      ap_log("mirror: data connection %s", m.sfd >= 0 ? "accepted" : "failed");
      continue;
    }
    if (!FD_ISSET(m.sfd, &rf)) continue;
    int k = recv(m.sfd, in_payload ? payload + got : hdr + got, need - got, 0);
    if (k <= 0) {
      ap_log("mirror: data connection closed");
      close_fd(&m.sfd);
      continue;
    }
    got += k;
    if (got < need) continue;
    if (!in_payload) {
      need = le32(hdr);
      if (need > MAX_PAYLOAD) { ap_log("mirror: oversized packet"); close_fd(&m.sfd); continue; }
      if (need > cap) {
        heap_caps_free(payload);
        cap = need < 256 * 1024 ? 256 * 1024 : need;
        payload = heap_caps_malloc(cap, MALLOC_CAP_SPIRAM);
        if (!payload) { cap = 0; ap_log("mirror: out of PSRAM"); close_fd(&m.sfd); continue; }
      }
      got = 0;
      in_payload = need > 0;
      if (in_payload) continue;
    }
    handle_packet(hdr, payload, need);
    got = 0, need = 128, in_payload = false;
  }
  close_fd(&m.sfd);
  close_fd(&m.lfd);
  close_fd(&m.tfd);
  close_fd(&m.afd[0]);
  close_fd(&m.afd[1]);
  if (a.gate.active && ap_cfg.on_audio) ap_cfg.on_audio(AIRPLAY_AUDIO_END, NULL, 0, 0);
  a.gate.active = false;
  a.on = false;
  heap_caps_free(a.buf);
  a.buf = NULL;
  heap_caps_free(payload);
  heap_caps_free(m.copy);
  m.copy = NULL;
  m.copy_cap = 0;
  heap_caps_free(m.held);
  m.held = NULL;
  m.held_cap = m.held_n = 0;
  m.held_set = m.held_ready = false;
  mbedtls_aes_free(&m.aes);
  m.done = true;
  vTaskDelete(NULL);
}

static void derive(const char *label, uint64_t id, const uint8_t aeskey[16], uint8_t out[16]) {
  char s[64];
  uint8_t h[64];
  snprintf(s, sizeof s, "%s%" PRIu64, label, id);
  ap_sha512(s, strlen(s), aeskey, 16, h);
  memcpy(out, h, 16);
}

bool ap_mirror_start(const uint8_t aeskey[16], uint64_t stream_id, uint32_t remote_ip, uint16_t timing_rport) {
  uint8_t key[16];
  ap_mirror_stop();
  derive("AirPlayStreamKey", stream_id, aeskey, key);
  derive("AirPlayStreamIV", stream_id, aeskey, m.iv0);
  memset(m.ks, 0, sizeof m.ks);
  memcpy(m.ks[0].iv, m.iv0, 16);
  m.nks = 1;
  m.bad = 0;
  mbedtls_aes_init(&m.aes);
  mbedtls_aes_setkey_enc(&m.aes, key, 128);
  memcpy(key_copy, key, 16);
  memcpy(iv0_copy, m.iv0, 16);
  m.remote_ip = remote_ip;
  m.timing_rport = timing_rport;
  m.last_data_us = m.last_video_us = 0;
  m.accepted_us = 0;
  m.got_codec = false;
  m.logged_no_video = false;
  m.quiet_logged = false;
  m.lfd = bind_sock(SOCK_STREAM, AP_MIRROR_PORT);
  m.tfd = bind_sock(SOCK_DGRAM, AP_TIMING_PORT);
  m.afd[0] = bind_sock(SOCK_DGRAM, AP_AUDIO_DATA_PORT);
  m.afd[1] = bind_sock(SOCK_DGRAM, AP_AUDIO_CTRL_PORT);
  a.on = false;
  a.buf = heap_caps_malloc(AUDIO_PACKET_MAX, MALLOC_CAP_SPIRAM);  // NULL: packets are drained, not forwarded
  m.run = true;
  m.done = false;
  if (m.lfd < 0 || xTaskCreatePinnedToCore(mirror_task, "mirror", 8 * 1024, NULL, 6, NULL, 0) != pdPASS) {
    m.run = false;
    m.done = true;
    close_fd(&m.lfd);
    close_fd(&m.tfd);
    close_fd(&m.afd[0]);
    close_fd(&m.afd[1]);
    heap_caps_free(a.buf);
    a.buf = NULL;
    mbedtls_aes_free(&m.aes);
    return false;
  }
  return true;
}

void ap_mirror_stop(void) {
  if (!m.run) return;
  m.run = false;
  for (int i = 0; i < 50 && !m.done; i++) vTaskDelay(pdMS_TO_TICKS(10));
}

bool ap_mirror_running(void) { return m.run; }

bool ap_mirror_streaming(void) {
  return m.run && m.last_data_us && esp_timer_get_time() - m.last_data_us < 3000000;
}

void ap_mirror_audio(const uint8_t aeskey[16], const uint8_t eiv[16], int ct) {
  a.on = false;
  memcpy(a.key, aeskey, 16);
  memcpy(a.iv, eiv, 16);
  a.ct = ct;
  a.s_packets = a.s_frames = a.s_bad = 0;
  a.on = ct == AP_AUDIO_CT_AAC_ELD;
  if (!m.run) ap_log("audio: stream set up with no mirror session (dropped)");
}

void ap_mirror_audio_end(void) {
  ap_log("audio: stream ended, %u packets (%u unparsed), %u sounding frames, %u segments since boot, ct=%d%s",
         (unsigned)a.s_packets, (unsigned)a.s_bad, (unsigned)a.s_frames, (unsigned)a.gate.segments, a.ct,
         a.buf ? "" : ", no buffer");
}

void ap_mirror_set_volume(float db) { a.volume = db; }

airplay_audio_stats airplay_audio(void) {
  airplay_audio_stats s = {a.packets, a.gate.segments, a.gate.frames, a.gate.active, a.volume};
  return s;
}
