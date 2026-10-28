/*
 * AirPlay mirror data channel: TCP stream of 128-byte headers + payloads, AES-128-CTR
 * decryption of the H.264 access units, AVCC -> Annex-B, SPS/PPS extraction; plus the
 * minimal NTP timing client and a drain for the (unused) audio ports.
 * Ported from UxPlay lib/raop_rtp_mirror.c, lib/mirror_buffer.c and lib/raop_ntp.c.
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
#include "ap_internal.h"

#define MAX_PAYLOAD (2 * 1024 * 1024)
#define NTP_INTERVAL_MS 3000

static struct {
  volatile bool run, done;
  volatile int64_t last_data_us;
  int64_t accepted_us;
  bool got_codec, logged_no_video;
  mbedtls_aes_context aes;
  uint8_t iv[16], stream[16];
  size_t off;
  uint32_t remote_ip;
  uint16_t timing_rport;
  int lfd, sfd, tfd, afd[2];
} m = {.lfd = -1, .sfd = -1, .tfd = -1, .afd = {-1, -1}};

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
static void handle_codec(const uint8_t *p, size_t n) {
  static const uint8_t sc[4] = {0, 0, 0, 1};
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

static void handle_packet(const uint8_t *hdr, uint8_t *p, size_t n) {
  m.last_data_us = esp_timer_get_time();
  if (hdr[4] == 0x01) { handle_codec(p, n); return; }
  if (hdr[4] != 0x00 || !n) return;  // 0x02/0x05: heartbeat and streaming reports
  // the keystream continues across packets, as in mirror_buffer_decrypt()
  mbedtls_aes_crypt_ctr(&m.aes, n, &m.off, m.iv, m.stream, p, p);
  if (!avcc_to_annexb(p, n)) { ap_log("mirror: undecodable payload (%u bytes)", (unsigned)n); return; }
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

static void mirror_task(void *arg) {
  uint8_t hdr[128], ntp[32] = {0x80, 0xd2, 0x00, 0x07}, scratch[128];
  uint8_t *payload = NULL;
  size_t got = 0, need = 128, cap = 0;
  bool in_payload = false;
  int64_t next_ntp = 0;
  while (m.run) {
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
      ap_log("mirror: no video received - AirPlay source must be an iPhone; macOS mirroring is not supported yet");
      m.logged_no_video = true;
    }
    struct timeval tv = {0, 100000};
    if (select(maxfd + 1, &rf, NULL, NULL, &tv) <= 0) continue;
    if (m.tfd >= 0 && FD_ISSET(m.tfd, &rf)) {
      int k = recv(m.tfd, scratch, sizeof scratch, 0);
      if (k >= 32) memcpy(ntp + 8, scratch + 24, 8);  // echo the client's transmit time as reference
    }
    for (int i = 0; i < 2; i++)
      if (m.afd[i] >= 0 && FD_ISSET(m.afd[i], &rf)) recv(m.afd[i], scratch, sizeof scratch, 0);
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
  heap_caps_free(payload);
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
  derive("AirPlayStreamIV", stream_id, aeskey, m.iv);
  mbedtls_aes_init(&m.aes);
  mbedtls_aes_setkey_enc(&m.aes, key, 128);
  m.off = 0;
  m.remote_ip = remote_ip;
  m.timing_rport = timing_rport;
  m.last_data_us = 0;
  m.accepted_us = 0;
  m.got_codec = false;
  m.logged_no_video = false;
  m.lfd = bind_sock(SOCK_STREAM, AP_MIRROR_PORT);
  m.tfd = bind_sock(SOCK_DGRAM, AP_TIMING_PORT);
  m.afd[0] = bind_sock(SOCK_DGRAM, AP_AUDIO_DATA_PORT);
  m.afd[1] = bind_sock(SOCK_DGRAM, AP_AUDIO_CTRL_PORT);
  m.run = true;
  m.done = false;
  if (m.lfd < 0 || xTaskCreatePinnedToCore(mirror_task, "mirror", 8 * 1024, NULL, 6, NULL, 0) != pdPASS) {
    m.run = false;
    m.done = true;
    close_fd(&m.lfd);
    close_fd(&m.tfd);
    close_fd(&m.afd[0]);
    close_fd(&m.afd[1]);
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
