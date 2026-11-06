/*
 * RTSP request handlers of the AirPlay receiver (mirroring only), ported from UxPlay
 * lib/raop.c (conn_request) and lib/raop_handlers.h. Copyright (C) 2011-2018 Juho Vähä-Herttua,
 * (C) 2021-2025 F. Duncanh; ESP32 port (own bplist codec instead of libplist) 2026.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../bplist/bplist.h"
#include "ap_internal.h"
#include "audio.h"

ap_conn *ap_mirror_owner;

typedef void (*handler_t)(ap_conn *c, const ap_req *req, ap_resp *res);

static void set_body(ap_resp *res, const char *type, const void *p, size_t n) {
  res->body = malloc(n ? n : 1);
  if (!res->body) return;
  memcpy(res->body, p, n);
  res->body_len = n;
  ap_resp_header(res, "Content-Type", type);
}

static void set_plist(ap_resp *res, bp_writer *w) {
  size_t n = 0;
  uint8_t *b = bp_w_finish(w, &n);
  bp_writer_free(w);
  if (!b) { res->code = 500; res->reason = "Internal Server Error"; return; }
  res->body = b;
  res->body_len = n;
  ap_resp_header(res, "Content-Type", "application/x-apple-binary-plist");
}

static bool is_bplist(const ap_req *req) {
  const char *t = ap_header(req, "Content-Type");
  return t && strstr(t, "application/x-apple-binary-plist");
}

static void info_txt(bp_writer *w, int root, bool airplay) {
  uint8_t txt[512];
  size_t n = ap_txt_record(airplay, txt, sizeof txt);
  bp_w_set(w, root, airplay ? "txtAirPlay" : "txtRAOP", bp_w_data(w, txt, n));
}

static void audio_entries(bp_writer *w, int root) {
  int lat = bp_w_array(w), fmt = bp_w_array(w);
  bp_w_set(w, root, "audioLatencies", lat);
  bp_w_set(w, root, "audioFormats", fmt);
  for (int type = 100; type <= 101; type++) {
    int l = bp_w_dict(w), f = bp_w_dict(w);
    bp_w_append(w, lat, l);
    bp_w_set(w, l, "type", bp_w_uint(w, type));
    bp_w_set(w, l, "audioType", bp_w_string(w, "default"));
    bp_w_set(w, l, "inputLatencyMicros", bp_w_uint(w, 0));
    bp_w_set(w, l, "outputLatencyMicros", bp_w_bool(w, false));
    bp_w_append(w, fmt, f);
    bp_w_set(w, f, "type", bp_w_uint(w, type));
    bp_w_set(w, f, "audioInputFormats", bp_w_uint(w, 0x3fffffc));
    bp_w_set(w, f, "audioOutputFormats", bp_w_uint(w, 0x3fffffc));
  }
}

static void handle_info(ap_conn *c, const ap_req *req, ap_resp *res) {
  bool txt_airplay = false, txt_raop = false, cseq = ap_header(req, "CSeq") != NULL;
  if (is_bplist(req)) {  // initial GET /info asks for {"qualifier": ["txtAirPlay"]}
    bp_reader r;
    char q[32];
    int top = bp_open(&r, req->body, req->body_len);
    int qual = bp_dict_get(&r, top, "qualifier");
    if (bp_type(&r, qual) == BP_ARRAY && bp_get_string(&r, bp_array_get(&r, qual, 0), q, sizeof q)) {
      txt_airplay = !strcmp(q, "txtAirPlay");
      txt_raop = !strcmp(q, "txtRAOP");
    }
  }
  if (!cseq) {  // Bluetooth LE discovery request: /info?txtAirPlay&txtRAOP
    txt_airplay = strstr(req->url, "txtAirPlay") != NULL;
    txt_raop = strstr(req->url, "txtRAOP") != NULL;
  }
  bp_writer w;
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  if (txt_airplay) info_txt(&w, root, true);
  if (txt_raop) info_txt(&w, root, false);
  if (!ap_header(req, "Content-Type")) {
    char id[18];
    ap_deviceid(id);
    bp_w_set(&w, root, "deviceID", bp_w_string(&w, id));
    bp_w_set(&w, root, "macAddress", bp_w_string(&w, id));
    bp_w_set(&w, root, "pk", bp_w_data(&w, ap_pk, 32));
    bp_w_set(&w, root, "features", bp_w_uint(&w, AP_FEATURES));
    bp_w_set(&w, root, "name", bp_w_string(&w, ap_cfg.name));
    bp_w_set(&w, root, "pi", bp_w_string(&w, AP_PI));
    bp_w_set(&w, root, "vv", bp_w_uint(&w, 2));
    bp_w_set(&w, root, "statusFlags", bp_w_uint(&w, 68));
    bp_w_set(&w, root, "keepAliveLowPower", bp_w_uint(&w, 1));
    bp_w_set(&w, root, "sourceVersion", bp_w_string(&w, AP_VERSION));
    bp_w_set(&w, root, "keepAliveSendStatsAsBody", bp_w_bool(&w, true));
    bp_w_set(&w, root, "model", bp_w_string(&w, AP_MODEL));
    if (cseq) {
      bp_w_set(&w, root, "initialVolume", bp_w_real(&w, 0.0));
      audio_entries(&w, root);
      int displays = bp_w_array(&w), d = bp_w_dict(&w);
      bp_w_set(&w, root, "displays", displays);
      bp_w_append(&w, displays, d);
      bp_w_set(&w, d, "uuid", bp_w_string(&w, "e0ff8a27-6738-3d56-8a16-cc53aacee925"));
      bp_w_set(&w, d, "widthPhysical", bp_w_uint(&w, 0));
      bp_w_set(&w, d, "heightPhysical", bp_w_uint(&w, 0));
      bp_w_set(&w, d, "width", bp_w_uint(&w, ap_cfg.width));
      bp_w_set(&w, d, "height", bp_w_uint(&w, ap_cfg.height));
      bp_w_set(&w, d, "widthPixels", bp_w_uint(&w, ap_cfg.width));
      bp_w_set(&w, d, "heightPixels", bp_w_uint(&w, ap_cfg.height));
      bp_w_set(&w, d, "rotation", bp_w_bool(&w, false));
      bp_w_set(&w, d, "refreshRate", bp_w_real(&w, 1.0 / 60));
      bp_w_set(&w, d, "maxFPS", bp_w_uint(&w, ap_cfg.max_fps));
      bp_w_set(&w, d, "overscanned", bp_w_bool(&w, false));
      bp_w_set(&w, d, "features", bp_w_uint(&w, 14));
    }
  }
  ap_log("rtsp: GET /info (%s%s%s)", cseq ? "full" : "ble", txt_airplay ? " txtAirPlay" : "", txt_raop ? " txtRAOP" : "");
  set_plist(res, &w);
}

static void handle_pair_setup(ap_conn *c, const ap_req *req, ap_resp *res) {
  if (req->body_len != 32) { res->code = 400; res->reason = "Bad Request"; return; }
  c->pair.status = PAIR_SETUP;
  set_body(res, "application/octet-stream", ap_pk, 32);
  ap_log("pair-setup ok");
}

static void handle_pair_verify(ap_conn *c, const ap_req *req, ap_resp *res) {
  if (c->pair.status != PAIR_SETUP && c->pair.status != PAIR_HANDSHAKE) {
    ap_log("pair-verify before pair-setup");
    return;  // as UxPlay: empty 200 without pairing state
  }
  const uint8_t *d = req->body;
  if (req->body_len >= 4 && d[0] == 1 && req->body_len == 4 + 64) {
    uint8_t out[96] = {0};
    if (!ap_pair_verify1(&c->pair, d + 4, d + 36, out)) ap_log("pair-verify 1 failed");
    set_body(res, "application/octet-stream", out, sizeof out);
    ap_log("pair-verify 1 ok");
  } else if (req->body_len == 4 + 64 && d[0] == 0) {
    if (!ap_pair_verify2(&c->pair, d + 4)) {
      ap_log("pair-verify 2: bad signature");
      res->close = true;
      return;
    }
    ap_resp_header(res, "Content-Type", "application/octet-stream");
    ap_log("pair-verify 2 ok");
  } else {
    ap_log("pair-verify: invalid data (%u bytes)", (unsigned)req->body_len);
  }
}

static void handle_fp_setup(ap_conn *c, const ap_req *req, ap_resp *res) {
  uint8_t out[142];
  if (req->body_len == 16) {
    if (fairplay_setup(req->body, out)) { res->code = 501; res->reason = "Not Implemented"; return; }
    set_body(res, "application/octet-stream", out, 142);
    c->have_keymsg = false;
    ap_log("fp-setup 1 ok (mode %d)", req->body[14]);
  } else if (req->body_len == 164) {
    if (fairplay_handshake(c->keymsg, req->body, out)) { res->code = 501; res->reason = "Not Implemented"; return; }
    c->have_keymsg = true;
    set_body(res, "application/octet-stream", out, 32);
    ap_log("fp-setup 2 ok");
  } else {
    ap_log("fp-setup: invalid length %u", (unsigned)req->body_len);
  }
}

// First SETUP: FairPlay-decrypt the AES key and, after legacy pairing, hash it with the ECDH secret.
static void setup_session(ap_conn *c, bp_reader *r, int top, bp_writer *w, int root) {
  const uint8_t *ekey, *eiv;
  size_t ekey_len, eiv_len;
  uint64_t port = 0;
  if (!bp_get_data(r, bp_dict_get(r, top, "ekey"), &ekey, &ekey_len) || ekey_len < 72 ||
      !bp_get_data(r, bp_dict_get(r, top, "eiv"), &eiv, &eiv_len) || eiv_len < 16) return;
  if (!c->have_keymsg) { ap_log("setup: no FairPlay handshake"); return; }
  fairplay_decrypt(c->keymsg, ekey, c->aeskey);
  if (c->pair.status != PAIR_INITIAL) {
    uint8_t h[64];
    ap_sha512(c->aeskey, 16, c->pair.secret, 32, h);
    memcpy(c->aeskey, h, 16);
  }
  memcpy(c->eiv, eiv, 16);
  c->have_aes = true;
  bp_get_uint(r, bp_dict_get(r, top, "timingPort"), &port);
  c->timing_rport = (uint16_t)port;
  char model[48] = "", name[64] = "";
  bp_get_string(r, bp_dict_get(r, top, "model"), model, sizeof model);
  bp_get_string(r, bp_dict_get(r, top, "name"), name, sizeof name);
  ap_log("setup: session from %s (%s), timing port %u", name, model, (unsigned)port);
  bp_w_set(w, root, "timingPort", bp_w_uint(w, AP_TIMING_PORT));
  bp_w_set(w, root, "eventPort", bp_w_uint(w, 0));
}

static void handle_setup(ap_conn *c, const ap_req *req, ap_resp *res) {
  bp_reader r;
  bp_writer w;
  int top = bp_open(&r, req->body, req->body_len);
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  if (bp_dict_get(&r, top, "ekey") >= 0) setup_session(c, &r, top, &w, root);

  int streams = bp_dict_get(&r, top, "streams");
  if (bp_type(&r, streams) == BP_ARRAY) {
    int out = bp_w_array(&w);
    for (int i = 0; i < bp_count(&r, streams); i++) {
      int s = bp_array_get(&r, streams, i);
      uint64_t type = 0, id = 0;
      bp_get_uint(&r, bp_dict_get(&r, s, "type"), &type);
      int d = bp_w_dict(&w);
      if (type == 110) {  // mirroring
        bp_get_uint(&r, bp_dict_get(&r, s, "streamConnectionID"), &id);
        if (!c->have_aes || !ap_mirror_start(c->aeskey, id, c->remote_ip, c->timing_rport)) {
          ap_log("setup: mirror stream failed");
          res->close = true;
        } else {
          ap_mirror_owner = c;
          ap_log("setup: mirror stream on port %d", AP_MIRROR_PORT);
        }
        bp_w_set(&w, d, "dataPort", bp_w_uint(&w, AP_MIRROR_PORT));
      } else if (type == 96) {  // audio, sent while the phone plays sound
        uint64_t ct = 0, spf = 0, sr = 0;
        bp_get_uint(&r, bp_dict_get(&r, s, "ct"), &ct);
        bp_get_uint(&r, bp_dict_get(&r, s, "spf"), &spf);
        bp_get_uint(&r, bp_dict_get(&r, s, "sr"), &sr);
        if (c->have_aes) ap_mirror_audio(c->aeskey, c->eiv, (int)ct);
        bp_w_set(&w, d, "dataPort", bp_w_uint(&w, AP_AUDIO_DATA_PORT));
        bp_w_set(&w, d, "controlPort", bp_w_uint(&w, AP_AUDIO_CTRL_PORT));
        ap_log("setup: audio stream ct=%u spf=%u sr=%u%s", (unsigned)ct, (unsigned)spf, (unsigned)sr,
               ct == AP_AUDIO_CT_AAC_ELD ? "" : " (not AAC-ELD: counted, not forwarded)");
      } else {
        ap_log("setup: unknown stream type %u", (unsigned)type);
        res->close = true;
      }
      bp_w_set(&w, d, "type", bp_w_uint(&w, type));
      bp_w_append(&w, out, d);
    }
    bp_w_set(&w, root, "streams", out);
  }
  set_plist(res, &w);
}

static void handle_get_parameter(ap_conn *c, const ap_req *req, ap_resp *res) {
  const char *t = ap_header(req, "Content-Type");
  if (!t) { res->code = 451; res->reason = "Parameter not understood"; return; }
  if (!strcmp(t, "text/parameters") && req->body_len >= 6 && !memcmp(req->body, "volume", 6)) {
    const char *v = "volume: 0.000000\r\n";
    set_body(res, "text/parameters", v, strlen(v));
  }
}

static void handle_set_parameter(ap_conn *c, const ap_req *req, ap_resp *res) {
  const char *t = ap_header(req, "Content-Type");
  if (!t) { res->code = 451; res->reason = "Parameter not understood"; return; }
  // "volume: -NN.NNNNNN" in dB, -144 when muted
  char v[32];
  if (!strcmp(t, "text/parameters") && req->body_len > 7 && req->body_len < sizeof v && !memcmp(req->body, "volume:", 7)) {
    memcpy(v, req->body + 7, req->body_len - 7);
    v[req->body_len - 7] = 0;
    float db = strtof(v, NULL);
    ap_mirror_set_volume(db);
    ap_log("set_parameter: volume %.1f dB%s", db, db <= -144 ? " (muted)" : "");
  }
}

static void handle_options(ap_conn *c, const ap_req *req, ap_resp *res) {
  ap_resp_header(res, "Public", "SETUP, RECORD, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER");
}

static void handle_record(ap_conn *c, const ap_req *req, ap_resp *res) {
  ap_resp_header(res, "Audio-Latency", "0");
  ap_resp_header(res, "Audio-Jack-Status", "connected; type=analog");
  ap_log("record");
}

static void handle_ok(ap_conn *c, const ap_req *req, ap_resp *res) {}

static void handle_teardown(ap_conn *c, const ap_req *req, ap_resp *res) {
  bp_reader r;
  bool video = false, any = false;
  int top = bp_open(&r, req->body, req->body_len);
  int streams = bp_dict_get(&r, top, "streams");
  for (int i = 0; i < bp_count(&r, streams); i++) {
    uint64_t type = 0;
    bp_get_uint(&r, bp_dict_get(&r, bp_array_get(&r, streams, i), "type"), &type);
    any = true;
    video |= type == 110;
  }
  ap_resp_header(res, "Connection", "close");
  if ((video || !any) && ap_mirror_owner == c) {  // iOS >= 17 may send no stream list when mirroring stops
    ap_mirror_stop();
    ap_mirror_owner = NULL;
  }
  ap_log("teardown (%s)", video ? "video" : any ? "audio" : "session");
}

static handler_t find(const char *method, const char *url) {
  static const struct { const char *method, *url; handler_t fn; } routes[] = {
    {"GET", "/info", handle_info},
    {"POST", "/pair-setup", handle_pair_setup},
    {"POST", "/pair-verify", handle_pair_verify},
    {"POST", "/fp-setup", handle_fp_setup},
    {"POST", "/feedback", handle_ok},
    {"POST", "/audioMode", handle_ok},
    {"OPTIONS", NULL, handle_options},
    {"SETUP", NULL, handle_setup},
    {"GET_PARAMETER", NULL, handle_get_parameter},
    {"SET_PARAMETER", NULL, handle_set_parameter},
    {"RECORD", NULL, handle_record},
    {"FLUSH", NULL, handle_ok},
    {"TEARDOWN", NULL, handle_teardown},
  };
  for (size_t i = 0; i < sizeof routes / sizeof routes[0]; i++) {
    if (strcmp(method, routes[i].method)) continue;
    if (!routes[i].url || !strncmp(url, routes[i].url, strlen(routes[i].url))) return routes[i].fn;
  }
  return NULL;
}

void ap_handle(ap_conn *c, const ap_req *req, ap_resp *res) {
  const char *cseq = ap_header(req, "CSeq");
  handler_t fn = strcmp(req->proto, "RTSP/1.0") ? NULL : find(req->method, req->url);
  if (cseq && strcmp(req->method, "RECORD")) ap_resp_header(res, "Audio-Jack-Status", "connected; type=digital");
  if (fn) {
    fn(c, req, res);
  } else {
    ap_log("rtsp: unhandled %s %s %s", req->method, req->url, req->proto);
    if (strcmp(req->method, "GET") && strcmp(req->method, "POST")) { res->code = 501; res->reason = "Not Implemented"; }
  }
  ap_resp_header(res, "Server", "AirTunes/" AP_VERSION);
  if (cseq) {
    char n[12];
    snprintf(n, sizeof n, "%u", (unsigned)strtoul(cseq, NULL, 10));
    ap_resp_header(res, "CSeq", n);
  }
}
