/*
 * Bonjour advertising of the AirPlay receiver, ported from UxPlay lib/dnssd.c and
 * lib/dns_sd/dns_sd.c (TXT records). Copyright (C) 2012 Juho Vähä-Herttua,
 * (C) 2021-2022 F. Duncanh; ESP32 port (esp mdns component instead of dns_sd) 2026.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#include <stdio.h>
#include <string.h>
#include "mdns.h"
#include "ap_internal.h"

typedef struct { const char *k, *v; } kv;

static char pk_hex[65], features[24], deviceid[18];

static const kv *raop_txt(size_t *n) {
  static kv t[] = {
    {"ch", "2"}, {"cn", "0,1,2,3"}, {"da", "true"}, {"et", "0,3,5"}, {"vv", "2"}, {"ft", features},
    {"am", AP_MODEL}, {"md", "0,1,2"}, {"rhd", "5.6.0.0"}, {"pw", "false"}, {"sf", "0x4"},
    {"sr", "44100"}, {"ss", "16"}, {"sv", "false"}, {"tp", "UDP"}, {"txtvers", "1"},
    {"vs", AP_VERSION}, {"vn", "65537"}, {"pk", pk_hex},
  };
  *n = sizeof t / sizeof t[0];
  return t;
}

static const kv *airplay_txt(size_t *n) {
  static kv t[] = {
    {"deviceid", deviceid}, {"features", features}, {"pw", "false"}, {"flags", "0x4"},
    {"model", AP_MODEL}, {"pk", pk_hex}, {"pi", AP_PI}, {"srcvers", AP_VERSION}, {"vv", "2"},
  };
  *n = sizeof t / sizeof t[0];
  return t;
}

void ap_deviceid(char out[18]) {
  const uint8_t *m = ap_cfg.hwaddr;
  snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void init_strings(void) {
  for (int i = 0; i < 32; i++) snprintf(pk_hex + 2 * i, 3, "%02x", ap_pk[i]);
  snprintf(features, sizeof features, "0x%X,0x%X", (unsigned)(AP_FEATURES & 0xFFFFFFFF), (unsigned)(AP_FEATURES >> 32));
  ap_deviceid(deviceid);
}

size_t ap_txt_record(bool airplay, uint8_t *out, size_t cap) {
  size_t n, o = 0;
  const kv *t = airplay ? airplay_txt(&n) : raop_txt(&n);
  init_strings();
  for (size_t i = 0; i < n; i++) {
    size_t kl = strlen(t[i].k), vl = strlen(t[i].v);
    if (o + 2 + kl + vl > cap) break;
    out[o++] = (uint8_t)(kl + 1 + vl);
    memcpy(out + o, t[i].k, kl);
    o += kl;
    out[o++] = '=';
    memcpy(out + o, t[i].v, vl);
    o += vl;
  }
  return o;
}

static bool add_service(const char *instance, const char *type, const kv *t, size_t n) {
  mdns_txt_item_t items[20];
  for (size_t i = 0; i < n && i < 20; i++) items[i] = (mdns_txt_item_t){t[i].k, t[i].v};
  esp_err_t e = mdns_service_add(instance, type, "_tcp", AP_RTSP_PORT, items, n);
  ap_log("mdns %s %s: %d", type, instance, e);
  return e == ESP_OK;
}

bool ap_mdns_start(void) {
  size_t n;
  char raop_name[96];
  init_strings();
  if (mdns_init() != ESP_OK) return false;
  mdns_hostname_set("iphone-agent");
  mdns_instance_name_set(ap_cfg.name);
  const uint8_t *m = ap_cfg.hwaddr;
  snprintf(raop_name, sizeof raop_name, "%02X%02X%02X%02X%02X%02X@%s", m[0], m[1], m[2], m[3], m[4], m[5], ap_cfg.name);
  const kv *a = airplay_txt(&n);
  bool ok = add_service(ap_cfg.name, "_airplay", a, n);
  const kv *r = raop_txt(&n);
  return add_service(raop_name, "_raop", r, n) && ok;
}
