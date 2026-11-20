// Host unit tests for the board's pure-C parts: bplist codec, the GOP buffer / video chunker, and the
// mirroring keystream, the AirPlay audio packets and sound gate, the CLI link crypto, the app/CLI HID arbiter, the RAM log ring, mouse move pacing.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../hid_bridge/src/bplist/bplist.h"
#include "../hid_bridge/src/video/gop.h"
#include "../hid_bridge/src/airplay/keystream.h"
#include "../hid_bridge/src/airplay/audio.h"
#include "../hid_bridge/src/heard/heard.h"
#include "mbedtls/aes.h"
#include "../hid_bridge/src/cli/cli_proto.h"
#include "../hid_bridge/src/hid/arbiter.h"
#include "../hid_bridge/src/hid/pace.h"
#include "../hid_bridge/src/hid/type_budget.h"
#include "../hid_bridge/src/log/logring.h"
#include "mdns.h"  // stubs/: the host stand-in for ESP-IDF mdns
#include "../hid_bridge/src/airplay/ap_internal.h"
#include "../hid_bridge/src/net/lan_lock.h"
#include "../hid_bridge/src/ui/sw_model.h"
#include "../hid_bridge/src/ui/sw_face.h"
#include "../hid_bridge/src/ui/sw_text.h"
#include "../hid_bridge/src/ui/ima_adpcm.h"
#include "../hid_bridge/src/ui/sw_power.h"
#include "../hid_bridge/src/ui/sw_warn.h"
#include <math.h>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

static void test_bplist_roundtrip(void) {
  bp_writer w;
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  bp_w_set(&w, root, "features", bp_w_uint(&w, 0x5A7FFEE6ull));
  bp_w_set(&w, root, "big", bp_w_uint(&w, 0x123456789ull));
  bp_w_set(&w, root, "name", bp_w_string(&w, "ESP32 Agent with a long name"));
  bp_w_set(&w, root, "ok", bp_w_bool(&w, true));
  bp_w_set(&w, root, "rate", bp_w_real(&w, 1.0 / 60));
  uint8_t pk[32];
  for (int i = 0; i < 32; i++) pk[i] = (uint8_t)i;
  bp_w_set(&w, root, "pk", bp_w_data(&w, pk, 32));
  int arr = bp_w_array(&w);
  bp_w_set(&w, root, "displays", arr);
  int d0 = bp_w_dict(&w);
  bp_w_append(&w, arr, d0);
  bp_w_set(&w, d0, "width", bp_w_uint(&w, 480));
  size_t len = 0;
  uint8_t *buf = bp_w_finish(&w, &len);
  bp_writer_free(&w);
  CHECK(buf != NULL);

  bp_reader r;
  int top = bp_open(&r, buf, len);
  CHECK(top >= 0 && bp_type(&r, top) == BP_DICT && bp_count(&r, top) == 7);
  uint64_t u = 0;
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "features"), &u) && u == 0x5A7FFEE6ull);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "big"), &u) && u == 0x123456789ull);
  char s[64];
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "ESP32 Agent with a long name"));
  bool b = false;
  CHECK(bp_get_bool(&r, bp_dict_get(&r, top, "ok"), &b) && b);
  double d = 0;
  CHECK(bp_get_real(&r, bp_dict_get(&r, top, "rate"), &d) && d == 1.0 / 60);
  const uint8_t *p;
  size_t n;
  CHECK(bp_get_data(&r, bp_dict_get(&r, top, "pk"), &p, &n) && n == 32 && !memcmp(p, pk, 32));
  int a = bp_dict_get(&r, top, "displays");
  CHECK(bp_type(&r, a) == BP_ARRAY && bp_count(&r, a) == 1);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, bp_array_get(&r, a, 0), "width"), &u) && u == 480);
  CHECK(bp_dict_get(&r, top, "missing") < 0);
  CHECK(bp_array_get(&r, a, 5) < 0);

  // truncation and garbage never crash
  for (size_t cut = 0; cut < len; cut++) {
    bp_reader t;
    int tt = bp_open(&t, buf, cut);
    if (tt >= 0) bp_dict_get(&t, tt, "pk");
  }
  uint8_t junk[200];
  memcpy(junk, buf, len < 200 ? len : 200);
  for (int i = 8; i < 200 && (size_t)i < len - 32; i += 3) junk[i] ^= 0xA5;
  bp_reader t;
  int tt = bp_open(&t, junk, len < 200 ? len : 200);
  if (tt >= 0) { bp_dict_get(&t, tt, "pk"); bp_count(&t, tt); }
  free(buf);
}

// Hand-made plist as Apple writes it: UTF-16 string value and 1-byte refs.
static void test_bplist_utf16(void) {
  static const uint8_t pl[] = {
    'b','p','l','i','s','t','0','0',
    0xD1, 0x01, 0x02,                // dict {1: 2}         @8
    0x54, 'n','a','m','e',           // "name"              @11
    0x63, 0x00,'H', 0x20,0x19, 0x00,'s',  // u"H’s"        @16
    8, 11, 16,                       // offsets            @23
    0,0,0,0,0,0, 1, 1,
    0,0,0,0,0,0,0,3, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,23};
  bp_reader r;
  int top = bp_open(&r, pl, sizeof pl);
  char s[32];
  CHECK(top == 0);
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "H\xE2\x80\x99s"));
}

static void test_gop(void) {
  static uint8_t arena[100];
  static gop_au aus[4];
  gop_buf g;
  gop_init(&g, arena, sizeof arena, aus, 4);
  uint8_t au[40] = {0, 0, 0, 1, 0x41};
  CHECK(gop_push(&g, au, 10, false, 1) == -1);  // waits for the first IDR
  CHECK(gop_push(&g, au, 30, true, 2) == 0);
  CHECK(gop_push(&g, au, 30, false, 3) == 1);
  CHECK(gop_push(&g, au, 30, false, 4) == 2 && g.used == 90);
  uint32_t gen = g.gen;
  CHECK(gop_push(&g, au, 30, false, 5) == -1 && g.n == 3 && g.frozen && !g.wait_idr && g.overflows == 1);
  CHECK(gop_push(&g, au, 5, false, 6) == -1 && g.n == 3 && g.gen == gen);  // frozen: kept whole, nothing added
  CHECK(gop_push(&g, au, 10, true, 7) == 0 && !g.frozen && g.gen != gen);
  CHECK(gop_push(&g, arena, sizeof arena + 1, true, 8) == -1 && g.n == 0 && g.wait_idr && g.overflows == 2);

  static uint8_t tarena[20];
  static gop_au taus[2];
  gop_buf t;
  gop_init(&t, tarena, sizeof tarena, taus, 2);
  CHECK(gop_append(&t, au, 10, false, 1) == 0 && gop_append(&t, au, 10, false, 2) == 1);
  CHECK(gop_append(&t, au, 1, false, 3) == -1);
  gop_clear(&t);
  CHECK(t.n == 0 && t.used == 0 && gop_append(&t, au, 20, false, 4) == 0);
  CHECK(gop_find(&t, 4) == 0 && gop_find(&t, 9) == -1);
  gop_clear(&t);
  for (int i = 0; i < 2; i++) au[i] = (uint8_t)(10 + i);
  CHECK(gop_append(&t, au, 5, false, 11) == 0 && gop_append(&t, au + 1, 5, false, 12) == 1);
  gop_drop_front(&t, 1);  // keeps the newer AU, moved to the front
  CHECK(t.n == 1 && t.used == 5 && t.aus[0].off == 0 && t.aus[0].ts == 12 && t.arena[0] == 11 && gop_find(&t, 12) == 0);
  gop_drop_front(&t, 5);
  CHECK(t.n == 0 && t.used == 0);

  // the tail past a frozen GOP is a ring: full drops the oldest, never refuses (2026-11-06: it broke instead,
  // and the screen stayed frozen until mirroring restarted)
  static uint8_t rarena[40];
  static gop_au raus[8];
  gop_buf r;
  gop_init(&r, rarena, sizeof rarena, raus, 8);
  for (uint32_t ts = 1; ts <= 8; ts++) CHECK(gop_append_ring(&r, au, 5, ts) == 0);
  CHECK(r.n == 8 && gop_append_ring(&r, au, 5, 9) == 2);  // a quarter of 8 dropped
  CHECK(r.n == 7 && r.aus[0].ts == 3 && gop_find(&r, 9) == 6 && gop_find(&r, 2) == -1);
  CHECK(gop_append_ring(&r, au, 30, 10) == 7 && r.n == 1 && r.used == 30);  // bytes, not count, made it full
  CHECK(gop_append_ring(&r, au, 41, 11) == -1 && r.n == 1);  // larger than the whole ring: refused, nothing lost

  uint8_t idr[] = {0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 9};
  CHECK(annexb_has_idr(idr, sizeof idr));
  CHECK(!annexb_has_idr(idr, 6));

  uint8_t avcc[] = {0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41};
  uint8_t want[] = {0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41};
  CHECK(avcc_to_annexb(avcc, sizeof avcc) && !memcmp(avcc, want, sizeof want));
  uint8_t bad[] = {0, 0, 0, 9, 0x65};
  CHECK(!avcc_to_annexb(bad, sizeof bad));

  // The AU list fills before the arena: freeze the same way, the next IDR restarts (a still screen, tiny AUs).
  static uint8_t big[1000];
  gop_init(&g, big, sizeof big, aus, 4);
  for (uint32_t i = 0; i < 4; i++) CHECK(gop_push(&g, au, 5, i == 0, 10 + i) == (int)i);
  CHECK(gop_push(&g, au, 5, false, 14) == -1 && g.frozen && g.n == 4);
  CHECK(gop_find(&g, 13) == 3);  // what was kept stays findable while frozen
  CHECK(gop_push(&g, au, 5, true, 15) == 0 && !g.frozen && g.n == 1);
  // An IDR too big for the arena: wait for the next one that fits, never keep P-frames without their IDR.
  CHECK(gop_push(&g, big, sizeof big + 1, true, 16) == -1 && g.wait_idr && g.n == 0);
  CHECK(gop_push(&g, au, 5, false, 17) == -1 && g.n == 0);
  CHECK(gop_push(&g, au, 5, true, 18) == 0 && !g.wait_idr && g.n == 1);
}

static void test_chunker(void) {
  uint8_t data[100], out[64], got[100];
  for (int i = 0; i < 100; i++) data[i] = (uint8_t)i;
  vchunk c;
  vchunk_begin(&c, data, sizeof data, VF_IDR | VF_SNAP, 0xAABBCCDD);
  size_t n, got_len = 0;
  int chunks = 0;
  uint16_t seq = 65534;
  while ((n = vchunk_next(&c, out, 20, seq)) > 0) {
    CHECK(n <= VCHUNK_HDR + 20);
    CHECK(out[0] == (uint8_t)seq && out[1] == (uint8_t)(seq >> 8));
    CHECK(out[2] & VF_IDR && out[2] & VF_SNAP);
    size_t off = VCHUNK_HDR;
    if (chunks == 0) {
      CHECK(out[2] & VF_START);
      CHECK(out[3] == 0xDD && out[6] == 0xAA);
      off += 4;
    } else {
      CHECK(!(out[2] & VF_START));
    }
    memcpy(got + got_len, out + off, n - off);
    got_len += n - off;
    chunks++;
    seq++;
    if (got_len < 100) CHECK(!(out[2] & VF_END));
  }
  CHECK(out[2] & VF_END);
  CHECK(got_len == 100 && !memcmp(got, data, 100));
  CHECK(chunks == 6);  // 16 + 5 * 20 >= 100
  CHECK(seq == 4);     // wrapped

  vchunk_begin(&c, data, 3, VF_CONFIG, 1);  // tiny AU: one chunk is START and END
  n = vchunk_next(&c, out, 20, 0);
  CHECK(n == VCHUNK_HDR + 4 + 3 && (out[2] & (VF_START | VF_END | VF_CONFIG)) == (VF_START | VF_END | VF_CONFIG));
  CHECK(vchunk_next(&c, out, 20, 1) == 0);
}


// An AVCC frame of n bytes: one slice NAL (type 1) filling it, with random content.
static void make_frame(uint8_t *f, size_t n) {
  uint32_t len = (uint32_t)(n - 4);
  f[0] = len >> 24, f[1] = len >> 16, f[2] = len >> 8, f[3] = len;
  f[4] = 0x41;
  for (size_t i = 5; i < n; i++) f[i] = (uint8_t)rand();
}

// The sender encrypts every frame on one continuous CTR keystream but drops some before sending; the
// receiver must find where to pick up again, and then decode every following frame in step.
static void test_keystream_resync(void) {
  static const uint8_t k16[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
  mbedtls_aes_context aes;
  mbedtls_aes_init(&aes);
  mbedtls_aes_setkey_enc(&aes, k16, 128);
  ks_key key = {.aes = &aes};
  memset(key.iv0, 0xfe, 16);  // near a carry across all counter bytes
  key.iv0[0] = 0x11;

  // ks_at(pos) is where mbedtls leaves the keystream after pos bytes
  for (uint64_t pos = 0; pos < 70; pos += 7) {
    uint8_t iv[16], stream[16] = {0}, buf[80] = {0};
    size_t off = 0;
    memcpy(iv, key.iv0, 16);
    mbedtls_aes_crypt_ctr(&aes, pos, &off, iv, stream, buf, buf);
    keystream at;
    ks_at(&key, &at, pos);
    CHECK(at.off == off && !memcmp(at.iv, iv, 16) && (!off || !memcmp(at.stream, stream, 16)));
  }

  uint8_t snd_iv[16], snd_stream[16] = {0};
  size_t snd_off = 0;
  memcpy(snd_iv, key.iv0, 16);
  keystream rx = {.off = 0};
  memcpy(rx.iv, key.iv0, 16);
  static uint8_t frame[40000], cipher[40000], plain[40000];
  int decoded = 0, resynced = 0;
  for (int i = 0; i < 60; i++) {
    size_t n = 100 + (size_t)(rand() % (i % 9 == 0 ? 35000 : 3000));  // now and then a big keyframe
    make_frame(frame, n);
    mbedtls_aes_crypt_ctr(&aes, n, &snd_off, snd_iv, snd_stream, frame, cipher);
    bool dropped = i == 20 || i == 21 || i == 40;  // encrypted, never sent
    if (dropped) continue;
    keystream next;
    if (ks_try(&key, &rx, &next, cipher, plain, n) && avcc_to_annexb(plain, n)) {
      rx = next, decoded++;
    } else if (ks_resync(&key, &rx, &next, cipher, plain, n, 512 * 1024, NULL)) {
      CHECK(!memcmp(plain, frame, n));
      rx = next, decoded++, resynced++;
    }
  }
  CHECK(decoded == 57);
  CHECK(resynced == 2);
  mbedtls_aes_free(&aes);
}

static void hex(const char *s, uint8_t *out) {
  for (size_t i = 0; s[2 * i]; i++) sscanf(s + 2 * i, "%2hhx", &out[i]);
}

void cli_random(uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) p[i] = (uint8_t)rand();
}

// docs/cli-protocol.md vectors (cli/testdata/vectors.json, made with Python's cryptography).
static void test_cli_proto(void) {
  // Wi-Fi fits the full audio, board and HID status; small MTUs need the compact report.
  CHECK(cli_ctrl_room(1463) >= 519 && cli_ctrl_room(1463) == BOARD_STATUS_CAP - 1);
  CHECK(cli_ctrl_room(517) == 496 && cli_ctrl_room(247) == 226 && cli_ctrl_room(185) == 164);
  CHECK(cli_ctrl_room(23) == 2 && cli_ctrl_room(0) == 0);
  uint8_t b_priv[32], c_pub[32], b_pub[32], k[32], want[32], id[16], mac[16], cn[16], bn[16], c2b[16], b2c[16];
  hex("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384", b_priv);
  hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c", c_pub);
  CHECK(cli_pair(b_priv, c_pub, b_pub, k));
  hex("5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36", want);
  CHECK(!memcmp(b_pub, want, 32));
  hex("efcbf0a5e51d114b9d6c9570183c9e44cb623c0581ee3ae762c00d6acc18fbf9", want);
  CHECK(!memcmp(k, want, 32));
  hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf", id);
  cli_mac(k, "paired", id, 16, NULL, 0, mac);
  hex("53ce351ad116adba4688e0c848c1fc64", want);
  CHECK(!memcmp(mac, want, 16));
  uint8_t zero[32] = {0};
  CHECK(!cli_pair(b_priv, zero, b_pub, k));  // low-order point: refused

  hex("efcbf0a5e51d114b9d6c9570183c9e44cb623c0581ee3ae762c00d6acc18fbf9", k);
  hex("101112131415161718191a1b1c1d1e1f", cn);
  hex("202122232425262728292a2b2c2d2e2f", bn);
  CHECK(cli_session(k, cn, bn, c2b, b2c));
  hex("776bc8c110fb6e0440169cfef36ba161", want);
  CHECK(!memcmp(c2b, want, 16));
  hex("93478dfeacc3cf696f2764d316a5dff7", want);
  CHECK(!memcmp(b2c, want, 16));
  cli_mac(k, "hello", cn, 16, bn, 16, mac);
  hex("c204a4e56de057834bf60fba723d5ffa", want);
  CHECK(!memcmp(mac, want, 16));

  uint8_t frame[64], plain[64], expect[64];
  uint32_t ctr = 0;
  hex("100100000068afc0f78c919458f5b70b4012515053649a24", expect);
  int n = cli_open(c2b, 'C', expect, 24, &ctr, plain);
  CHECK(n == 7 && ctr == 1 && !memcmp(plain, "c7 ping", 7));
  CHECK(cli_open(c2b, 'B', expect, 24, &ctr, plain) == -1);  // wrong stream: other nonce
  expect[7] ^= 1;
  CHECK(cli_open(c2b, 'C', expect, 24, &ctr, plain) == -1);  // tampered
  CHECK(cli_seal(b2c, CLI_DATA, 'B', 2, (const uint8_t *)"r7 ok", 5, frame) == 22);
  hex("1002000000caf6fbb8977c45ee4dff70db24f7ebd04d", expect);
  CHECK(!memcmp(frame, expect, 22));
  uint8_t v[8];
  hex("0100050000000001", v);
  CHECK(cli_seal(b2c, CLI_VIDEO, 'V', 1, v, 8, frame) == 25);
  hex("110100000038443201752074c91e78396e0bca7521a4e30a63", expect);
  CHECK(!memcmp(frame, expect, 25));
}

static void test_arbiter(void) {
  // the app wins whenever its link is up; the CLI only alone
  CHECK(arb_owner(false, false) == ARB_NONE);
  CHECK(arb_owner(false, true) == ARB_CLI);
  CHECK(arb_owner(true, true) == ARB_APP);
  CHECK(!strcmp(arb_owner_name(ARB_APP), "app") && !strcmp(arb_owner_name(ARB_NONE), "none"));
  CHECK(!arb_allowed(ARB_CLI, true) && arb_allowed(ARB_CLI, false) && arb_allowed(ARB_APP, true));
  // only the side that left lets go of the button it held
  arb_state s;
  arb_init(&s);
  arb_after(&s, ARB_CLI, "press", true);
  CHECK(!arb_gone(&s, ARB_APP));
  CHECK(arb_gone(&s, ARB_CLI));
  CHECK(!arb_gone(&s, ARB_CLI));  // once
  arb_after(&s, ARB_APP, "press_for", true);  // a timed hold counts as held until it ends
  CHECK(!arb_gone(&s, ARB_CLI));
  arb_after(&s, ARB_APP, "release", true);
  CHECK(!arb_gone(&s, ARB_APP));
  arb_after(&s, ARB_APP, "press", true);
  arb_after(&s, ARB_APP, "click", true);
  CHECK(!arb_gone(&s, ARB_APP));
  arb_after(&s, ARB_APP, "press", false);  // failed: nothing held
  CHECK(!arb_gone(&s, ARB_APP));
  arb_after(&s, ARB_CLI, "press", true);
  arb_after(&s, ARB_APP, "reset", false);
  CHECK(s.pressed == ARB_CLI);
  arb_after(&s, ARB_APP, "reset", true);
  arb_after(&s, ARB_APP, "reset", true);
  CHECK(!arb_gone(&s, ARB_CLI));
}

static void test_pace(void) {
  // the move -158 -295 of 2026-11-06: every report the same speed, the sum exact, never above the step
  long moves[][2] = {{-158, -295}, {150, 0}, {8, 295}, {12, 0}, {1, 0}, {-3, 7}, {466, 1316}};
  for (unsigned m = 0; m < sizeof moves / sizeof moves[0]; m++) {
    pace_t p;
    pace_start(&p, moves[m][0], moves[m][1], 10);
    long x = 0, y = 0, n = 0;
    double lo = 1e9, hi = 0;
    int sx, sy;
    while (pace_next(&p, &sx, &sy)) {
      double v = sqrt((double)sx * sx + (double)sy * sy);
      lo = v < lo ? v : lo;
      hi = v > hi ? v : hi;
      x += sx, y += sy, n++;
    }
    CHECK(x == moves[m][0] && y == moves[m][1]);
    CHECK(hi <= 11);  // each axis rounds on its own: at most a unit over
    CHECK(n < 2 || hi - lo <= 1.5);  // one speed, give or take a unit of rounding
  }
  pace_t p;
  pace_start(&p, 0, 0, 10);
  int sx, sy;
  CHECK(!pace_next(&p, &sx, &sy));
}

static void test_logring(void) {
  char buf[32], out[64];
  logring r;
  logring_init(&r, buf, sizeof buf);
  CHECK(logring_read(&r, 0, out, sizeof out) == 0 && out[0] == 0);
  logring_add(&r, "boot a\\b");
  uint32_t next = logring_read(&r, 0, out, sizeof out);
  CHECK(next == 9 && strcmp(out, "boot a\\\\b\\n") == 0);
  logring_add(&r, "wifi: got ip");
  logring_add(&r, "ota: done");  // 9 + 13 + 10 = 32 bytes: still fits
  CHECK(r.start == 0 && r.end == 32);
  logring_add(&r, "cli up");  // wraps: the oldest line goes, whole
  logring_read(&r, 0, out, sizeof out);
  CHECK(strncmp(out, "wifi: got ip\\n", 14) == 0 && r.end - r.start <= sizeof buf);
  uint32_t from = r.start, pages = 0;  // paging: small pages join up to the same text
  char all[128] = "", page[6];
  while (from < r.end && pages++ < 40) { from = logring_read(&r, from, page, sizeof page); strcat(all, page); }
  CHECK(strcmp(all, out) == 0);
  CHECK(logring_read(&r, r.end, out, sizeof out) == r.end && out[0] == 0);  // caught up
  logring_add(&r, "0123456789012345678901234567890123456789");  // longer than the ring: its tail is kept
  logring_read(&r, 0, out, sizeof out);
  CHECK(strlen(out) > 0 && strstr(out, "789\\n") != NULL);
}

// What the iPhone sees in Screen Mirroring: the Bonjour services and TXT records (airplay/mdns.c).
mdns_stub_service mdns_stub[4];
int mdns_stub_count;
char mdns_stub_host[32];
esp_err_t mdns_init(void) { mdns_stub_count = 0; return ESP_OK; }
esp_err_t mdns_hostname_set(const char *name) { snprintf(mdns_stub_host, sizeof mdns_stub_host, "%s", name); return ESP_OK; }
esp_err_t mdns_instance_name_set(const char *name) { (void)name; return ESP_OK; }
esp_err_t mdns_service_add(const char *instance, const char *type, const char *proto, uint16_t port,
                           mdns_txt_item_t *txt, size_t n) {
  (void)proto;
  mdns_stub_service *s = &mdns_stub[mdns_stub_count++];
  snprintf(s->instance, sizeof s->instance, "%s", instance);
  snprintf(s->type, sizeof s->type, "%s", type);
  s->port = port;
  s->n = n;
  for (size_t i = 0; i < n; i++) {
    snprintf(s->keys[i], sizeof s->keys[i], "%s", txt[i].key);
    snprintf(s->values[i], sizeof s->values[i], "%s", txt[i].value);
  }
  return ESP_OK;
}
airplay_cfg ap_cfg;
uint8_t ap_pk[32];
void ap_log(const char *fmt, ...) { (void)fmt; }

static const char *txt_value(const mdns_stub_service *s, const char *key) {
  for (size_t i = 0; i < s->n; i++) if (!strcmp(s->keys[i], key)) return s->values[i];
  return NULL;
}

static void test_mdns(void) {
  ap_cfg.name = "ESP32 Agent";
  uint8_t mac[6] = {0x7C, 0x3E, 0x01, 0x02, 0xAB, 0xCD};
  memcpy(ap_cfg.hwaddr, mac, 6);
  for (int i = 0; i < 32; i++) ap_pk[i] = (uint8_t)i;
  CHECK(ap_mdns_start() && mdns_stub_count == 2);
  const mdns_stub_service *a = &mdns_stub[0], *r = &mdns_stub[1];
  CHECK(!strcmp(a->type, "_airplay") && !strcmp(a->instance, "ESP32 Agent"));
  CHECK(!strcmp(r->type, "_raop") && !strcmp(r->instance, "7C3E0102ABCD@ESP32 Agent"));
  CHECK(a->port == r->port && a->port > 0);
  CHECK(txt_value(a, "deviceid") && !strcmp(txt_value(a, "deviceid"), "7C:3E:01:02:AB:CD"));
  const char *pk = txt_value(a, "pk");
  CHECK(pk && strlen(pk) == 64 && !strncmp(pk, "000102", 6) && !strcmp(pk, txt_value(r, "pk")));
  CHECK(txt_value(a, "features") && !strcmp(txt_value(a, "features"), txt_value(r, "ft")));
  CHECK(txt_value(a, "pw") && !strcmp(txt_value(a, "pw"), "false"));  // no PIN prompt on the iPhone

  // The raw TXT record: length-prefixed "k=v" entries, whole entries only, never past cap.
  uint8_t rec[512];
  size_t len = ap_txt_record(true, rec, sizeof rec), o = 0, entries = 0;
  while (o < len) { o += 1 + rec[o]; entries++; }
  CHECK(o == len && entries == a->n && !memcmp(rec + 1, "deviceid=7C:3E:01:02:AB:CD", 26));
  size_t cut = ap_txt_record(true, rec, 40);
  CHECK(cut <= 40 && cut == 1u + rec[0]);  // only the first entry (28 bytes) fits
}

// Encrypt like the sender (CBC over the whole blocks, fresh IV per packet, tail in the clear) and decrypt back.
static void test_audio_packets(void) {
  uint8_t key[16], iv[16], plain[45], pkt[12 + 45];
  for (int i = 0; i < 16; i++) key[i] = (uint8_t)(i * 7), iv[i] = (uint8_t)(0xa0 + i);
  for (int i = 0; i < 45; i++) plain[i] = (uint8_t)(i * 3 + 1);
  pkt[0] = 0x80, pkt[1] = 0x60, pkt[2] = 0x12, pkt[3] = 0x34;
  pkt[4] = 0x00, pkt[5] = 0x01, pkt[6] = 0xe2, pkt[7] = 0x40;
  memset(pkt + 8, 0, 4);
  mbedtls_aes_context aes;
  mbedtls_aes_init(&aes);
  mbedtls_aes_setkey_enc(&aes, key, 128);
  uint8_t v[16];
  for (int round = 0; round < 2; round++) {  // the same IV again: nothing carries over between packets
    memcpy(v, iv, 16);
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, 32, v, plain, pkt + 12);
    memcpy(pkt + 12 + 32, plain + 32, 13);
    ap_rtp r;
    CHECK(ap_rtp_parse(pkt, sizeof pkt, &r));
    CHECK(r.seq == 0x1234 && r.ts == 123456 && r.len == 45 && r.payload == pkt + 12);
    CHECK(!ap_audio_no_data(r.payload, r.len));
    uint8_t out[45];
    ap_audio_decrypt(key, iv, r.payload, r.len, out);
    CHECK(!memcmp(out, plain, 45));
    ap_audio_decrypt(key, iv, pkt + 12, 45, pkt + 12);  // in place
    CHECK(!memcmp(pkt + 12, plain, 45));
  }
  mbedtls_aes_free(&aes);
  ap_rtp r;
  CHECK(!ap_rtp_parse(pkt, 11, &r));
  pkt[0] = 0x40;
  CHECK(!ap_rtp_parse(pkt, sizeof pkt, &r));  // RTP version 1
  const uint8_t marker[4] = {0x00, 0x68, 0x34, 0x00};
  CHECK(ap_audio_no_data(marker, 4) && ap_audio_no_data(NULL, 0) && !ap_audio_no_data(plain, 4));
  uint8_t short_tail[7] = {1, 2, 3, 4, 5, 6, 7}, out[7];
  ap_audio_decrypt(key, iv, short_tail, 7, out);  // under one block: all clear
  CHECK(!memcmp(out, short_tail, 7));
}

static void test_audio_gate(void) {
  ap_audio_gate g = {0};
  CHECK(ap_audio_gate_packet(&g, 0, true) == AP_GATE_SKIP && !g.active);   // no-data packets start nothing
  CHECK(ap_audio_gate_packet(&g, 10, false) == AP_GATE_START && g.active && g.segments == 1);
  CHECK(ap_audio_gate_packet(&g, 20, false) == AP_GATE_FRAME);
  CHECK(ap_audio_gate_packet(&g, 30, true) == AP_GATE_SKIP);               // silence inside a segment
  CHECK(!ap_audio_gate_idle(&g, 20 + AP_AUDIO_IDLE_MS - 1));
  CHECK(ap_audio_gate_idle(&g, 20 + AP_AUDIO_IDLE_MS) && !g.active);      // ends once, timed from the last sound
  CHECK(!ap_audio_gate_idle(&g, 5000));
  CHECK(ap_audio_gate_packet(&g, 6000, false) == AP_GATE_START && g.segments == 2 && g.frames == 3);
}

static void test_heard(void) {
  static heard_ring r;
  char out[600];
  heard_clear(&r);
  CHECK(heard_json(&r, 1000, false, out, sizeof out) && !strcmp(out, "{\"app\":0,\"lines\":[]}"));
  heard_add(&r, 1000, "[en] code \"5813\"", 17);
  heard_add(&r, 3000, "[zh] 验证码", strlen("[zh] 验证码"));
  heard_json(&r, 4000, true, out, sizeof out);
  CHECK(!strcmp(out, "{\"app\":1,\"lines\":[{\"ago\":1000,\"t\":\"[zh] 验证码\"},{\"ago\":3000,\"t\":\"[en] code \\\"5813\\\"\"}]}"));
  heard_json(&r, 62000, true, out, sizeof out);  // the first is over 60 s old
  CHECK(strstr(out, "验证码") && !strstr(out, "5813"));
  CHECK(heard_json(&r, 4000, true, out, 40) && !strcmp(out, "{\"app\":1,\"lines\":[]}"));  // only what fits
  for (int i = 0; i < HEARD_LINES + 3; i++) heard_add(&r, 5000 + i, "x", 1);
  CHECK(r.count == HEARD_LINES);
  char big[500];
  memset(big, 'a', sizeof big);
  memcpy(big + HEARD_TEXT - 1, "中", 3);  // split by the cut
  heard_add(&r, 6000, big, sizeof big);
  CHECK(strlen(r.text[(r.next + HEARD_LINES - 1) % HEARD_LINES]) == HEARD_TEXT - 1);
}

static void test_type_budget(void) {
  CHECK(type_before_char(0, 0, 1) == TYPE_GO);
  CHECK(type_before_char(15, 100, 0) == TYPE_GO);             // not a check point yet
  CHECK(type_before_char(16, 100, 0) == TYPE_STOP_ASLEEP);    // USB re-checked every 16
  CHECK(type_before_char(16, 100, 1) == TYPE_GO);
  CHECK(type_before_char(3, TYPE_BUDGET_MS, 1) == TYPE_STOP_BUDGET);
  CHECK(type_before_char(32, TYPE_BUDGET_MS + 1, 0) == TYPE_STOP_ASLEEP);  // asleep wins at a check point
  CHECK(type_before_char(17, TYPE_BUDGET_MS, 0) == TYPE_STOP_BUDGET);
  char out[64];
  CHECK(type_reply(out, sizeof out, 48, 48, TYPE_GO) > 0 && !strcmp(out, "ok"));
  CHECK(type_reply(out, sizeof out, 12, 48, TYPE_STOP_BUDGET) > 0 && !strcmp(out, "err typed 12 of 48: budget"));
  CHECK(type_reply(out, sizeof out, 16, 80, TYPE_STOP_ASLEEP) > 0 && !strcmp(out, "err typed 16 of 80: asleep"));
  // a 500-byte command cannot be one watchdog window: the budget stops it first
  int typed = 0;
  for (int i = 0; i < 500; i++) {
    uint32_t elapsed = (uint32_t)i * 20;  // slower than 8 s / 500
    type_stop_t stop = type_before_char(i, elapsed, 1);
    if (stop != TYPE_GO) {
      CHECK(stop == TYPE_STOP_BUDGET && typed == i && elapsed >= TYPE_BUDGET_MS);
      break;
    }
    typed++;
  }
  CHECK(typed > 0 && typed < 500);
}

// The LAN lock (src/net/lan_lock.h). The vectors are shared with the app's LanAuthTests (openssl, 2026-11-17).
static void test_lan_lock(void) {
  char mac[LAN_MAC_HEX + 1];
  lan_mac("Jefe", "what do ya want for nothing?", mac);  // RFC 4231 test case 2
  CHECK(!strcmp(mac, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
  const char *tok = "00112233445566778899aabbccddeeff", *nonce = "0f0e0d0c0b0a09080706050403020100";
  CHECK(lan_mac_ok(tok, "video 0f0e0d0c0b0a09080706050403020100",
                   "df20947056845d461c448d63b048d4ba21b3d9bf15ca7fda2be7177c74184655"));
  CHECK(lan_mac_ok(tok, "video 0f0e0d0c0b0a09080706050403020100",
                   "DF20947056845D461C448D63B048D4BA21B3D9BF15CA7FDA2BE7177C74184655"));
  CHECK(!lan_mac_ok(tok, "video 0f0e0d0c0b0a09080706050403020101",
                    "df20947056845d461c448d63b048d4ba21b3d9bf15ca7fda2be7177c74184655"));
  CHECK(!lan_mac_ok(tok, "video x", "df20"));
  CHECK(!lan_mac_ok(tok, "video x", NULL));
  CHECK(lan_mac_ok(tok, "ota 0f0e0d0c0b0a09080706050403020100 1234 "
                        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                   "37fa45d2f82c619a4cef6dd88ac0978791255d6ca3acad4f54acc49442b6e3a2"));

  // one keystream across records: split anywhere, the same bytes as one piece
  const char *plain = "LAN video test: one stream, two records.";  // fixed vector: change it only with want
  static const uint8_t want[] = {0xb0, 0x37, 0xda, 0x61, 0x12, 0xe1, 0xe9, 0x44, 0xaa, 0x5f, 0xd0, 0xa4, 0xde, 0xec,
                                 0xca, 0xf1, 0xf0, 0x11, 0x60, 0xc0, 0x1d, 0xa9, 0x43, 0xa1, 0xd4, 0xcd, 0x0e, 0x90,
                                 0x79, 0x46, 0xef, 0x38, 0x4e, 0xfb, 0xd4, 0x18, 0x3b, 0x60, 0xb9, 0x3d};
  size_t n = strlen(plain);
  CHECK(n == sizeof want);
  uint8_t buf[64];
  memcpy(buf, plain, n);
  lan_ctr c = {0};
  lan_ctr_crypt(&c, buf, n);  // not started: nothing
  CHECK(!memcmp(buf, plain, n));
  lan_ctr_start(&c, tok, nonce);
  lan_ctr_crypt(&c, buf, 7);
  lan_ctr_crypt(&c, buf + 7, 0);
  lan_ctr_crypt(&c, buf + 7, n - 7);
  CHECK(!memcmp(buf, want, n));
  lan_ctr_start(&c, tok, nonce);  // a new session starts the stream over
  lan_ctr_crypt(&c, buf, n);
  CHECK(!memcmp(buf, plain, n));
  lan_ctr_stop(&c);

  char nh[LAN_NONCE_HEX + 1];
  const uint8_t r[16] = {0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0};
  lan_nonce(nh, r);
  CHECK(!strcmp(nh, nonce));

  uint32_t phone, other, ip;
  char back[16];
  CHECK(lan_parse_ip("192.168.1.23", &phone) && lan_parse_ip("192.168.1.24", &other));
  lan_format_ip(phone, back);
  CHECK(!strcmp(back, "192.168.1.23"));
  const uint8_t *bytes = (const uint8_t *)&phone;  // network order, as lwIP keeps sin_addr
  CHECK(bytes[0] == 192 && bytes[3] == 23);
  CHECK(!lan_parse_ip("192.168.1", &ip) && !lan_parse_ip("192.168.1.256", &ip) && !lan_parse_ip("1.2.3.4x", &ip));

  // hotspot: everyone; station without an owner: everyone; station with one: only the owner
  lan_set_station(false);
  lan_set_owner(phone);
  CHECK(!lan_locked() && lan_peer_ok(other));
  lan_set_station(true);
  CHECK(lan_locked() && lan_peer_ok(phone) && !lan_peer_ok(other));
  lan_set_owner(0);
  CHECK(!lan_locked() && lan_peer_ok(other));
  lan_set_station(false);
}

// The StopWatch's `ui` lines and buttons (src/ui/sw_model.h, docs/ble-protocol.md "StopWatch screen").
static void test_sw_parse(void) {
  sw_ui u;
  CHECK(sw_parse("{\"m\":\"thinking\",\"p\":\"help\",\"s\":3,\"l\":20,\"t\":\"打开设置\",\"d\":1,\"n\":4,\"f\":false,\"x\":{\"a\":[1,{}]}}", &u) == SW_PARSE_UI);
  CHECK(u.mood == SW_THINKING && u.phase == SW_HELP && u.step == 3 && u.limit == 20 && u.done == 1 && u.total == 4);
  CHECK(!u.finished && !strcmp(u.text, "打开设置") && !u.has_picks);
  CHECK(sw_progress(&u) == 250);
  CHECK(sw_parse(" off ", &u) == SW_PARSE_OFF);
  CHECK(sw_parse("offx", &u) == SW_PARSE_BAD && sw_parse("", &u) == SW_PARSE_BAD && sw_parse("{\"m\":", &u) == SW_PARSE_BAD);
  CHECK(sw_parse("{\"m\":\"x\"} junk", &u) == SW_PARSE_BAD);
  CHECK(sw_parse("{}", &u) == SW_PARSE_UI && u.mood == SW_IDLE && u.phase == SW_RUNNING && sw_progress(&u) == -1);
  CHECK(sw_parse("{\"m\":\"new-mood\",\"p\":7,\"s\":2.9,\"l\":4,\"f\":true}", &u) == SW_PARSE_UI);  // unknown values ignored
  CHECK(u.mood == SW_IDLE && u.phase == SW_RUNNING && u.step == 2 && u.finished && sw_progress(&u) == 500);
  // escapes, a surrogate pair, control characters as spaces, and the 80-byte cut on a character boundary
  CHECK(sw_parse("{\"t\":\"a\\\"b\\n\\u4e2d\\ud83d\\ude00\"}", &u) == SW_PARSE_UI && !strcmp(u.text, "a\"b 中\xF0\x9F\x98\x80"));
  char line[400] = "{\"t\":\"";
  for (int i = 0; i < 30; i++) strcat(line, "中");  // 90 bytes
  strcat(line, "\"}");
  CHECK(sw_parse(line, &u) == SW_PARSE_UI && strlen(u.text) == 78);
  CHECK(sw_parse("{\"k\":[\"Order coffee\",\"每日签到\",\"c\",\"d\"]}", &u) == SW_PARSE_UI);
  CHECK(u.has_picks && u.npicks == 4 && !strcmp(u.picks[1], "每日签到") && !strcmp(u.picks[3], "d"));
  CHECK(sw_parse("{\"k\":[]}", &u) == SW_PARSE_UI && u.has_picks && u.npicks == 0);
  CHECK(sw_parse("{\"k\":[\"abcdefghijklmnopqrstuvwxyz\"]}", &u) == SW_PARSE_UI && strlen(u.picks[0]) == 24);
}

static void test_sw_buttons(void) {
  sw_ctl c;
  sw_ui u;
  char out[48];
  sw_init(&c);
  // no app: idle; blue short press is still `btn home`, yellow with no picks does nothing
  CHECK(sw_screen(&c, 0) == SW_SCR_IDLE && !sw_running(&c, 0));
  CHECK(!sw_input(&c, SW_IN_YELLOW, 10, out, sizeof out));
  CHECK(!sw_input(&c, SW_IN_BLUE_DOWN, 10, out, sizeof out) && sw_input(&c, SW_IN_BLUE_UP, 200, out, sizeof out) && !strcmp(out, "btn home"));
  // blue held: the ring from 300 ms, `btn stop` at 2 s while still held, nothing on release
  sw_input(&c, SW_IN_BLUE_DOWN, 1000, out, sizeof out);
  CHECK(sw_hold(&c, 1100) == -1 && sw_hold(&c, 2000) == 500);
  CHECK(!sw_tick(&c, 2999, out, sizeof out) && sw_tick(&c, 3000, out, sizeof out) && !strcmp(out, "btn stop"));
  CHECK(sw_hold(&c, 3001) == -1 && !sw_input(&c, SW_IN_BLUE_UP, 3100, out, sizeof out));
  // released between 0.5 and 2 s: cancelled
  sw_input(&c, SW_IN_BLUE_DOWN, 4000, out, sizeof out);
  CHECK(!sw_input(&c, SW_IN_BLUE_UP, 5000, out, sizeof out) && !sw_tick(&c, 7000, out, sizeof out));

  // standby picks: select, confirm, send; the picks stay across lines without `k`
  sw_parse("{\"p\":\"standby\",\"k\":[\"a\",\"b\",\"c\"]}", &u);
  CHECK(sw_apply(&c, &u, false, 10000) == SW_BUZZ_NONE && !sw_running(&c, 10000));
  CHECK(!sw_input(&c, SW_IN_YELLOW, 10100, out, sizeof out) && c.sel == 0 && sw_screen(&c, 10100) == SW_SCR_IDLE);
  CHECK(!sw_input(&c, SW_IN_TAP, 10200, out, sizeof out) && c.sel == 1);  // a tap moves to the next one
  CHECK(!sw_input(&c, SW_IN_YELLOW, 10300, out, sizeof out) && sw_screen(&c, 10300) == SW_SCR_CONFIRM);
  CHECK(sw_input(&c, SW_IN_YELLOW, 10400, out, sizeof out) && !strcmp(out, "btn run 1") && c.sel == -1);
  // SW_PICK_MS without a press cancels; the next press goes on from the last pick
  sw_input(&c, SW_IN_YELLOW, 11000, out, sizeof out);
  CHECK(c.sel == 2);
  sw_tick(&c, 11000 + SW_PICK_MS - 1, out, sizeof out);
  CHECK(c.sel == 2);
  sw_tick(&c, 11000 + SW_PICK_MS, out, sizeof out);
  CHECK(c.sel == -1);
  sw_apply(&c, &u, false, 14000);
  sw_input(&c, SW_IN_YELLOW, 14100, out, sizeof out);
  CHECK(c.sel == 0);

  // running: the selection goes, yellow pauses, help buzzes once, tap continues, swipe up takes over
  sw_parse("{\"m\":\"acting\",\"p\":\"running\",\"s\":1,\"l\":10}", &u);
  CHECK(sw_apply(&c, &u, false, 15000) == SW_BUZZ_NONE && sw_running(&c, 15000) && c.sel == -1 && c.ui.npicks == 3);
  CHECK(sw_screen(&c, 15000) == SW_SCR_RUN && sw_progress(&c.ui) == 100);
  CHECK(sw_input(&c, SW_IN_YELLOW, 15100, out, sizeof out) && !strcmp(out, "btn pause"));
  CHECK(!sw_input(&c, SW_IN_TAP, 15100, out, sizeof out));
  sw_parse("{\"p\":\"paused\"}", &u);
  sw_apply(&c, &u, false, 15200);
  CHECK(sw_screen(&c, 15200) == SW_SCR_PAUSED);
  CHECK(sw_input(&c, SW_IN_YELLOW, 15300, out, sizeof out) && !strcmp(out, "btn unpause"));
  sw_parse("{\"p\":\"help\",\"t\":\"Need a code\"}", &u);
  CHECK(sw_apply(&c, &u, false, 16000) == SW_BUZZ_HELP && sw_screen(&c, 16000) == SW_SCR_HELP);
  CHECK(sw_apply(&c, &u, false, 16500) == SW_BUZZ_NONE);  // the same phase again: no second buzz
  CHECK(sw_input(&c, SW_IN_TAP, 16600, out, sizeof out) && !strcmp(out, "btn continue"));
  CHECK(sw_input(&c, SW_IN_SWIPE_UP, 16700, out, sizeof out) && !strcmp(out, "btn takeover"));
  // shake: 1 s warning then stop; a button cancels; one per 2 s
  sw_input(&c, SW_IN_SHAKE, 17000, out, sizeof out);
  CHECK(sw_screen(&c, 17000) == SW_SCR_SHAKE && !sw_tick(&c, 17999, out, sizeof out));
  CHECK(sw_tick(&c, 18000, out, sizeof out) && !strcmp(out, "btn stop") && sw_screen(&c, 18000) == SW_SCR_HELP);
  sw_apply(&c, &u, false, 18100);
  sw_input(&c, SW_IN_SHAKE, 18500, out, sizeof out);
  CHECK(sw_screen(&c, 18500) != SW_SCR_SHAKE);  // within 2 s of the last one
  sw_input(&c, SW_IN_SHAKE, 19000, out, sizeof out);
  CHECK(sw_screen(&c, 19000) == SW_SCR_SHAKE);
  CHECK(!sw_input(&c, SW_IN_BLUE_DOWN, 19100, out, sizeof out) && !sw_input(&c, SW_IN_BLUE_UP, 19200, out, sizeof out));
  CHECK(!sw_tick(&c, 20500, out, sizeof out) && sw_screen(&c, 20500) == SW_SCR_HELP);
  // no `ui` for 15 s mid-run: the island's stuck face (not running: a shake does nothing), until the app is gone
  CHECK(sw_running(&c, 33099) && !sw_running(&c, 33100) && sw_screen(&c, 33100) == SW_SCR_STUCK && !sw_alive(&c, 33100));
  sw_input(&c, SW_IN_SHAKE, 33200, out, sizeof out);
  CHECK(sw_screen(&c, 33200) == SW_SCR_STUCK);

  // finished: check (two buzzes) or cross (three) for 5 s, once per task
  sw_parse("{\"m\":\"success\",\"f\":true}", &u);
  CHECK(sw_apply(&c, &u, false, 40000) == SW_BUZZ_OK && sw_screen(&c, 40000) == SW_SCR_OK && !sw_running(&c, 40000));
  CHECK(sw_apply(&c, &u, false, 41000) == SW_BUZZ_NONE);
  sw_tick(&c, 45000, out, sizeof out);
  CHECK(sw_screen(&c, 45000) == SW_SCR_IDLE);
  sw_parse("{\"m\":\"acting\"}", &u);
  sw_apply(&c, &u, false, 46000);
  sw_parse("{\"m\":\"failure\",\"f\":true}", &u);
  CHECK(sw_apply(&c, &u, false, 47000) == SW_BUZZ_FAIL && sw_screen(&c, 47000) == SW_SCR_FAIL);
  // `ui off`: idle, picks gone; a help line straight after buzzes
  sw_apply(&c, NULL, true, 48000);
  CHECK(sw_screen(&c, 48000) == SW_SCR_IDLE && c.ui.npicks == 0);
  sw_parse("{\"p\":\"help\"}", &u);
  CHECK(sw_apply(&c, &u, false, 49000) == SW_BUZZ_HELP);
  // the millisecond clock wrapping does not end a run early
  sw_init(&c);
  sw_apply(&c, &u, false, 0xFFFFF000u);
  CHECK(sw_running(&c, 0x1000) && !sw_running(&c, 0xFFFFF000u + SW_STALE_MS));
}

// The phone's time and the island's look in `ui` lines; awake while the lines come.
static void test_sw_clock(void) {
  sw_ui u;
  sw_ctl c;
  char t[6];
  CHECK(sw_parse("{\"c\":\"23:58\",\"x\":0.5,\"y\":-3,\"p\":\"standby\"}", &u) == SW_PARSE_UI);
  CHECK(!strcmp(u.clock, "23:58") && u.look_x == 0.5f && u.look_y == -1);
  CHECK(sw_parse("{\"c\":\"24:00\"}", &u) == SW_PARSE_UI && !u.clock[0]);
  CHECK(sw_parse("{\"c\":\"9:05\"}", &u) == SW_PARSE_UI && !u.clock[0]);
  CHECK(sw_parse("{\"x\":\"a\"}", &u) == SW_PARSE_UI && u.look_x == 0);  // not a number: skipped
  sw_init(&c);
  CHECK(!sw_alive(&c, 0) && !sw_clock(&c, 0, t));
  sw_parse("{\"c\":\"23:58\",\"p\":\"standby\"}", &u);
  sw_apply(&c, &u, false, 1000);
  CHECK(sw_alive(&c, 1000) && !sw_running(&c, 1000) && sw_screen(&c, 1000) == SW_SCR_IDLE);
  CHECK(sw_clock(&c, 60999, t) && !strcmp(t, "23:58") && sw_clock(&c, 121000, t) && !strcmp(t, "00:00"));
  CHECK(!sw_alive(&c, 1000 + SW_STALE_MS) && sw_screen(&c, 1000 + SW_STALE_MS) == SW_SCR_IDLE);  // asleep, not stuck
  sw_apply(&c, NULL, true, 20000);
  CHECK(!sw_alive(&c, 20000) && !sw_clock(&c, 20000, t));
}


// Voice on the StopWatch: hold yellow to talk, the app's answer, yellow runs it, blue drops it.
static void test_sw_voice(void) {
  sw_ctl c;
  sw_ui u;
  char out[48];
  sw_init(&c);
  // an app without voice (no `v`): yellow is a press, as before
  sw_parse("{\"p\":\"standby\",\"k\":[\"a\"]}", &u);
  sw_apply(&c, &u, false, 0);
  CHECK(!u.voice && !sw_input(&c, SW_IN_YELLOW_DOWN, 100, out, sizeof out) && c.sel == 0 && !c.y_down && !sw_mic(&c));
  CHECK(!sw_input(&c, SW_IN_YELLOW_UP, 2000, out, sizeof out) && c.voice == SW_V_NONE);
  sw_init(&c);
  CHECK(sw_parse("{\"p\":\"standby\",\"v\":1,\"k\":[\"a\"]}", &u) == SW_PARSE_UI && u.voice);
  sw_apply(&c, &u, false, 0);
  // a short press: the pick, on release; the mic was on meanwhile, nothing recorded
  CHECK(!sw_input(&c, SW_IN_YELLOW_DOWN, 100, out, sizeof out) && sw_mic(&c) && c.sel == -1);
  CHECK(!sw_tick(&c, 100 + SW_HOLD_MS - 1, out, sizeof out) && c.voice == SW_V_NONE);
  CHECK(!sw_input(&c, SW_IN_YELLOW_UP, 300, out, sizeof out) && c.sel == 0 && !sw_mic(&c));
  // held: listening (the selection goes), released: waiting, the app's text, yellow runs it
  sw_input(&c, SW_IN_YELLOW_DOWN, 1000, out, sizeof out);
  sw_tick(&c, 1000 + SW_HOLD_MS, out, sizeof out);
  CHECK(c.voice == SW_V_LISTEN && sw_screen(&c, 1400) == SW_SCR_VOICE && c.sel == -1 && sw_mic(&c) && !c.voice_run);
  CHECK(sw_voice_line(&c, "heard too early", 1500) && c.voice == SW_V_LISTEN);
  CHECK(!sw_input(&c, SW_IN_YELLOW_UP, 4000, out, sizeof out) && c.voice == SW_V_WAIT && !sw_mic(&c));
  CHECK(!sw_input(&c, SW_IN_YELLOW_DOWN, 4100, out, sizeof out) && c.voice == SW_V_WAIT);  // waits for the text
  sw_input(&c, SW_IN_YELLOW_UP, 4200, out, sizeof out);
  CHECK(sw_voice_line(&c, "heard 打开微信", 5000) && c.voice == SW_V_RESULT && !strcmp(c.said, "打开微信"));
  CHECK(sw_input(&c, SW_IN_YELLOW_DOWN, 6000, out, sizeof out) && !strcmp(out, "btn voice go") && c.voice == SW_V_SENT);
  sw_input(&c, SW_IN_YELLOW_UP, 6100, out, sizeof out);
  CHECK(!sw_tick(&c, 6000 + SW_VOICE_SHOW_MS, out, sizeof out) && c.voice == SW_V_NONE && sw_screen(&c, 8600) == SW_SCR_IDLE);
  // a late `fail start`: the error shows, then goes
  CHECK(sw_voice_line(&c, "fail start", 9000) && c.voice == SW_V_ERROR && c.voice_err == SW_VE_START);
  sw_tick(&c, 9000 + SW_VOICE_SHOW_MS, out, sizeof out);
  CHECK(c.voice == SW_V_NONE);
  // blue drops the text (and its press does nothing else), nothing heard is an error, the app's silence too
  sw_input(&c, SW_IN_YELLOW_DOWN, 10000, out, sizeof out);
  sw_tick(&c, 10400, out, sizeof out);
  sw_input(&c, SW_IN_YELLOW_UP, 11000, out, sizeof out);
  sw_voice_line(&c, "heard hello", 11500);
  CHECK(sw_input(&c, SW_IN_BLUE_DOWN, 12000, out, sizeof out) && !strcmp(out, "btn voice cancel") && c.voice == SW_V_NONE);
  CHECK(!sw_input(&c, SW_IN_BLUE_UP, 12100, out, sizeof out));
  sw_input(&c, SW_IN_YELLOW_DOWN, 13000, out, sizeof out);
  sw_tick(&c, 13400, out, sizeof out);
  CHECK(sw_input(&c, SW_IN_BLUE_DOWN, 13500, out, sizeof out) && !strcmp(out, "btn voice cancel") && !sw_mic(&c));  // while talking
  sw_input(&c, SW_IN_BLUE_UP, 13600, out, sizeof out);
  CHECK(!sw_input(&c, SW_IN_YELLOW_UP, 14000, out, sizeof out) && c.voice == SW_V_NONE && c.sel == -1);
  sw_apply(&c, &u, false, 14500);  // the app's lines keep coming (15 s without one: no voice)
  sw_input(&c, SW_IN_YELLOW_DOWN, 15000, out, sizeof out);
  sw_tick(&c, 15400, out, sizeof out);
  sw_input(&c, SW_IN_YELLOW_UP, 16000, out, sizeof out);
  CHECK(sw_voice_line(&c, "heard", 16500) && c.voice == SW_V_ERROR && c.voice_err == SW_VE_NONE);
  CHECK(!sw_voice_line(&c, "what", 16500) && sw_voice_line(&c, "fail newcode", 16600) && c.voice_err == SW_VE_OTHER);
  sw_tick(&c, 20000, out, sizeof out);
  sw_parse("{\"p\":\"standby\",\"v\":1}", &u);
  sw_apply(&c, &u, false, 20000);
  sw_input(&c, SW_IN_YELLOW_DOWN, 20000, out, sizeof out);
  sw_tick(&c, 20400, out, sizeof out);
  sw_input(&c, SW_IN_YELLOW_UP, 21000, out, sizeof out);
  CHECK(!sw_tick(&c, 21000 + SW_VOICE_WAIT_MS - 1, out, sizeof out) && c.voice == SW_V_WAIT);
  sw_tick(&c, 21000 + SW_VOICE_WAIT_MS, out, sizeof out);
  CHECK(c.voice == SW_V_ERROR && c.voice_err == SW_VE_TIMEOUT);
  // the heard text waits SW_VOICE_KEEP_MS, then it is dropped and the app told
  sw_tick(&c, 50000, out, sizeof out);
  sw_apply(&c, &u, false, 50000);
  sw_input(&c, SW_IN_YELLOW_DOWN, 50000, out, sizeof out);
  sw_tick(&c, 50400, out, sizeof out);
  sw_input(&c, SW_IN_YELLOW_UP, 51000, out, sizeof out);
  char long_text[200] = "heard ";
  for (int i = 0; i < 50; i++) strcat(long_text, "中");  // 150 bytes: cut at 120 on a character boundary
  sw_voice_line(&c, long_text, 51000);
  CHECK(strlen(c.said) == 120);
  sw_apply(&c, &u, false, 51000 + SW_VOICE_KEEP_MS - 1);
  CHECK(sw_tick(&c, 51000 + SW_VOICE_KEEP_MS, out, sizeof out) && !strcmp(out, "btn voice cancel") && c.voice == SW_V_NONE);
  // during a run: a short yellow still pauses (on release), a hold records for the task
  sw_parse("{\"m\":\"acting\",\"p\":\"running\",\"v\":1}", &u);
  sw_apply(&c, &u, false, 120000);
  CHECK(!sw_input(&c, SW_IN_YELLOW_DOWN, 120000, out, sizeof out));
  CHECK(sw_input(&c, SW_IN_YELLOW_UP, 120100, out, sizeof out) && !strcmp(out, "btn pause"));
  sw_input(&c, SW_IN_YELLOW_DOWN, 121000, out, sizeof out);
  sw_tick(&c, 121400, out, sizeof out);
  CHECK(c.voice == SW_V_LISTEN && c.voice_run && sw_screen(&c, 121400) == SW_SCR_VOICE);
}

// Quick intents: the app's `picks` line (the newest 5), yellow selects, a tap moves on, blue drops the selection.
static void test_sw_picks(void) {
  sw_ctl c;
  sw_ui u;
  char out[48];
  sw_init(&c);
  sw_parse("{\"p\":\"standby\",\"k\":[\"old\"]}", &u);
  sw_apply(&c, &u, false, 0);
  CHECK(sw_picks_line(&c, "[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\"]") == 5 && c.ui.npicks == 5 && !strcmp(c.ui.picks[4], "e"));
  CHECK(sw_picks_line(&c, "a") == -1 && sw_picks_line(&c, "[1] x") == -1 && c.ui.npicks == 5);
  sw_apply(&c, &u, false, 100);  // `k` no longer counts once `picks` came
  CHECK(c.ui.npicks == 5 && !strcmp(c.ui.picks[0], "a"));
  sw_input(&c, SW_IN_YELLOW, 200, out, sizeof out);
  for (int i = 0; i < 4; i++) sw_input(&c, SW_IN_TAP, 300 + i, out, sizeof out);
  CHECK(c.sel == 4);
  CHECK(!sw_input(&c, SW_IN_BLUE_DOWN, 400, out, sizeof out) && c.sel == -1 && !sw_input(&c, SW_IN_BLUE_UP, 450, out, sizeof out));
  sw_input(&c, SW_IN_YELLOW, 500, out, sizeof out);
  sw_input(&c, SW_IN_YELLOW, 600, out, sizeof out);
  CHECK(sw_screen(&c, 600) == SW_SCR_CONFIRM && sw_input(&c, SW_IN_YELLOW, 700, out, sizeof out) && !strcmp(out, "btn run 0"));
  CHECK(sw_picks_line(&c, "[]") == 0 && c.ui.npicks == 0);
  sw_apply(&c, NULL, true, 800);  // the app gone: an older app's `k` counts again
  sw_apply(&c, &u, false, 900);
  CHECK(c.ui.npicks == 1 && !strcmp(c.ui.picks[0], "old"));
}

// A finished task's answer: it shows over idle, yellow or a tap turns its pages, blue closes it, a new run ends it.
static void test_sw_answer(void) {
  sw_ctl c;
  sw_ui u;
  char out[48];
  sw_init(&c);
  sw_parse("{\"m\":\"success\",\"f\":true,\"v\":1}", &u);
  sw_apply(&c, &u, false, 0);
  sw_answer(&c);
  c.pages = 3;
  CHECK(sw_screen(&c, 0) == SW_SCR_ANSWER && sw_screen(&c, 9000) == SW_SCR_ANSWER);  // past the 5 s check too
  CHECK(!sw_input(&c, SW_IN_TAP, 100, out, sizeof out) && c.page == 1);
  sw_input(&c, SW_IN_YELLOW_DOWN, 200, out, sizeof out);
  CHECK(!sw_input(&c, SW_IN_YELLOW_UP, 300, out, sizeof out) && c.page == 2);
  sw_input(&c, SW_IN_TAP, 400, out, sizeof out);
  CHECK(c.page == 0);
  CHECK(!sw_input(&c, SW_IN_BLUE_DOWN, 500, out, sizeof out) && !c.answer && !sw_input(&c, SW_IN_BLUE_UP, 600, out, sizeof out));
  CHECK(sw_screen(&c, 600) == SW_SCR_OK);
  sw_answer(&c);
  sw_parse("{\"m\":\"acting\",\"p\":\"running\"}", &u);
  sw_apply(&c, &u, false, 700);
  CHECK(!c.answer && sw_screen(&c, 700) == SW_SCR_RUN);
}

// Help and confirm: the buzz again every 3 s for a minute, then every 15 s, until answered; yellow goes on, blue
// stops (help) or skips the step (confirm).
static void test_sw_help(void) {
  sw_ctl c;
  sw_ui u;
  char out[48];
  sw_init(&c);
  sw_parse("{\"m\":\"acting\",\"p\":\"running\",\"v\":1}", &u);
  sw_apply(&c, &u, false, 0);
  CHECK(sw_buzz_due(&c, 5000) == SW_BUZZ_NONE);
  CHECK(sw_parse("{\"p\":\"help\",\"h\":1,\"v\":1}", &u) == SW_PARSE_UI && u.confirm);
  CHECK(sw_apply(&c, &u, false, 1000) == SW_BUZZ_HELP);
  CHECK(sw_buzz_due(&c, 1000 + SW_HELP_REPEAT_MS - 1) == SW_BUZZ_NONE && sw_buzz_due(&c, 1000 + SW_HELP_REPEAT_MS) == SW_BUZZ_HELP);
  CHECK(sw_buzz_due(&c, 1000 + SW_HELP_REPEAT_MS + 1) == SW_BUZZ_NONE);
  uint32_t t = 1000 + SW_HELP_FAST_MS + 1000;
  for (uint32_t at = 7000; at < t; at += 1000) sw_apply(&c, &u, false, at), sw_buzz_due(&c, at);  // the lines keep coming
  CHECK(sw_buzz_due(&c, t + SW_HELP_REPEAT_MS) == SW_BUZZ_NONE);
  sw_apply(&c, &u, false, t + 10000);
  CHECK(sw_buzz_due(&c, t + SW_HELP_SLOW_MS) == SW_BUZZ_HELP);
  sw_apply(&c, &u, false, t + 16000);
  sw_input(&c, SW_IN_BLUE_DOWN, t + 16000, out, sizeof out);
  CHECK(sw_input(&c, SW_IN_BLUE_UP, t + 16100, out, sizeof out) && !strcmp(out, "btn skip"));
  sw_input(&c, SW_IN_YELLOW_DOWN, t + 16200, out, sizeof out);
  CHECK(sw_input(&c, SW_IN_YELLOW_UP, t + 16300, out, sizeof out) && !strcmp(out, "btn continue"));
  sw_parse("{\"p\":\"help\"}", &u);
  sw_apply(&c, &u, false, t + 16400);
  sw_input(&c, SW_IN_BLUE_DOWN, t + 16500, out, sizeof out);
  CHECK(sw_input(&c, SW_IN_BLUE_UP, t + 16600, out, sizeof out) && !strcmp(out, "btn stop"));
  CHECK(sw_input(&c, SW_IN_YELLOW, t + 16700, out, sizeof out) && !strcmp(out, "btn continue"));
  sw_parse("{\"p\":\"running\"}", &u);
  sw_apply(&c, &u, false, t + 17000);
  CHECK(sw_buzz_due(&c, t + 40000) == SW_BUZZ_NONE);  // answered: quiet
}

// The run's time: counting on between the app's lines while it runs, frozen at the finish.
static void test_sw_elapsed(void) {
  sw_ctl c;
  sw_ui u;
  char d[12];
  sw_init(&c);
  CHECK(sw_elapsed(&c, 0) == -1);
  sw_parse("{\"p\":\"running\",\"e\":62}", &u);
  CHECK(u.elapsed == 62);
  sw_apply(&c, &u, false, 1000);
  CHECK(sw_elapsed(&c, 1000) == 62 && sw_elapsed(&c, 4500) == 65);
  sw_parse("{\"m\":\"success\",\"f\":true,\"e\":70}", &u);
  sw_apply(&c, &u, false, 9000);
  CHECK(sw_elapsed(&c, 30000) == 70);
  sw_parse("{\"p\":\"standby\"}", &u);
  sw_apply(&c, &u, false, 31000);
  CHECK(sw_elapsed(&c, 31000) == -1);
  sw_duration(65, d);
  CHECK(!strcmp(d, "1:05"));
  sw_duration(3725, d);
  CHECK(!strcmp(d, "1:02:05"));
  sw_duration(-3, d);
  CHECK(!strcmp(d, "0:00"));
}

// Screen power: dim, off, on again; a wrist turn wakes it, lying still or shaking does not.
static void test_sw_power(void) {
  sw_power p;
  swp_init(&p, 0);
  CHECK(swp_level(&p, SWP_DIM_MS - 1, false) == SWP_ON && swp_level(&p, SWP_DIM_MS, false) == SWP_DIM);
  CHECK(swp_level(&p, SWP_OFF_MS, false) == SWP_OFF && swp_level(&p, SWP_OFF_MS, true) == SWP_ON);
  swp_active(&p, 70000);
  CHECK(swp_level(&p, 70001, false) == SWP_ON);
  uint32_t t = 100000;
  for (int i = 0; i < 60; i++, t += 33) CHECK(!swp_motion(&p, 0, 0, 1, t));  // flat on a table
  for (int i = 0; i < 30; i++, t += 33) CHECK(!swp_motion(&p, 0.05f, 0, 1.4f, t));  // a bump, still face up
  for (int i = 0; i < 10; i++, t += 33) CHECK(!swp_motion(&p, 3, 1, 0, t));  // a shake: not read
  bool raised = false;
  uint32_t at = 0;
  for (int i = 0; i < 20 && !raised; i++, t += 33) raised = swp_motion(&p, 0, 0.8f, 0.6f, t), at = t;  // turned ~53 degrees
  CHECK(raised && swp_level(&p, at, false) == SWP_ON && at - 100000 < 4000);
  for (int i = 0; i < 40; i++, t += 33) CHECK(!swp_motion(&p, 0, 0.8f, 0.6f, t));  // held there: once

  // the battery: one warning under 15 %, one under 5 %, none while charging, again after charging back up
  swp_init(&p, 0);
  CHECK(swp_battery(&p, 40, false) == 0 && swp_battery(&p, 14, true) == 0 && swp_battery(&p, 14, false) == SWP_LOW);
  CHECK(swp_battery(&p, 13, false) == 0 && swp_battery(&p, 16, false) == 0 && swp_battery(&p, 14, false) == 0);
  CHECK(swp_battery(&p, 4, false) == SWP_EMPTY && swp_battery(&p, 3, false) == 0);
  CHECK(swp_battery(&p, 9, false) == 0 && swp_battery(&p, 4, false) == SWP_EMPTY);  // 5 % again after 8 %+
  CHECK(swp_battery(&p, 60, false) == 0 && swp_battery(&p, 12, false) == SWP_LOW && swp_battery(&p, -1, false) == 0);
}

static void test_sw_warn(void) {
  sw_ui u;
  CHECK(sw_parse("{\"m\":\"acting\",\"p\":\"running\",\"w\":\"mirror\"}", &u) == SW_PARSE_UI && !strcmp(u.warn, "mirror"));
  CHECK(sw_parse("{\"m\":\"acting\"}", &u) == SW_PARSE_UI && !u.warn[0] && u.local == 0);
  CHECK(sw_parse("{\"m\":\"idle\",\"z\":1795252800}", &u) == SW_PARSE_UI && u.local == 1795252800LL);
  CHECK(sw_parse("{\"m\":\"idle\",\"z\":42}", &u) == SW_PARSE_UI && u.local == 0);
  CHECK(sw_warn_parse("mirror") == SW_W_MIRROR && sw_warn_parse("locked") == SW_W_LOCKED && sw_warn_parse("hid") == SW_W_HID);
  CHECK(sw_warn_parse("wifi") == SW_W_NONE && sw_warn_parse("") == SW_W_NONE && sw_warn_parse(NULL) == SW_W_NONE);
  sw_warn w;
  sww_init(&w);
  CHECK(!sww_update(&w, SW_W_NONE, false, false) && !sww_shown(&w));  // no Bluetooth at boot: no alert
  CHECK(!sww_update(&w, SW_W_NONE, true, false));
  CHECK(sww_update(&w, SW_W_MIRROR, true, true) && sww_shown(&w) == SW_W_MIRROR);  // once
  CHECK(!sww_update(&w, SW_W_MIRROR, true, true) && sww_shown(&w) == SW_W_MIRROR);
  sww_hide(&w);
  CHECK(!sww_update(&w, SW_W_MIRROR, true, true) && !sww_shown(&w));  // blue: hidden while it lasts
  CHECK(sww_update(&w, SW_W_LOCKED, true, true) && sww_shown(&w) == SW_W_LOCKED);  // another: shown again
  CHECK(!sww_update(&w, SW_W_NONE, true, true) && !sww_shown(&w));  // fixed: gone
  CHECK(sww_update(&w, SW_W_NONE, false, true) && sww_shown(&w) == SW_W_HID);  // Bluetooth dropped while in use
  CHECK(!sww_update(&w, SW_W_NONE, false, false) && sww_shown(&w) == SW_W_HID);  // stays until it is back
  CHECK(!sww_update(&w, SW_W_NONE, true, false) && !sww_shown(&w));
  CHECK(!sww_update(&w, SW_W_NONE, false, false) && !sww_shown(&w));  // dropped while unused: nothing
}

static void test_sw_text(void) {
  for (int l = 0; l < SW_LANGS; l++)
    for (int i = 0; i < SWT_COUNT; i++) CHECK(sw_text(l, i) && sw_text(l, i)[0]);
  CHECK(!strcmp(sw_text(SW_EN, SWT_RUN_HINT), "Yellow: run - Blue: cancel") && !strcmp(sw_text(SW_ZH, SWT_RUN_HINT), "黄色执行 · 蓝色取消"));
  CHECK(!strcmp(sw_text(7, SWT_SENT), "Sent") && !strcmp(sw_text(SW_EN, 999), ""));
  for (int i = 0; i < SWT_COUNT; i++)  // English is drawn in a Latin-only font
    for (const char *p = sw_text(SW_EN, i); *p; p++) CHECK((unsigned char)*p < 0x80);
  CHECK(sw_lang_next(SW_EN) == SW_ZH && sw_lang_next(SW_ZH) == SW_EN && sw_lang_next(9) == SW_EN);
  CHECK(!strcmp(sw_locale(SW_EN), "en-US") && !strcmp(sw_locale(SW_ZH), "zh-CN"));
}

static void test_ima(void) {
  int16_t pcm[1600], back[1600];
  uint8_t enc[800];
  for (int i = 0; i < 1600; i++) pcm[i] = (int16_t)(8000 * sin(i * 2 * 3.14159265 * 440 / 16000) + 3000 * sin(i * 0.9));
  ima_state e = {0, 0}, d = {0, 0};
  CHECK(ima_encode(&e, pcm, 1600, enc) == 800);
  ima_decode(&d, enc, 800, back);
  CHECK(d.pred == e.pred && d.index == e.index);
  double err = 0, sig = 0;
  for (int i = 200; i < 1600; i++) err += (double)(pcm[i] - back[i]) * (pcm[i] - back[i]), sig += (double)pcm[i] * pcm[i];
  CHECK(10 * log10(sig / err) > 20);  // 4 bits a sample: speech stays clear (> 20 dB SNR once it settled)
  // a chunk decodes on its own from the state it carries
  ima_state at = {0, 0}, mid;
  ima_encode(&at, pcm, 800, enc);
  mid = at;
  ima_encode(&at, pcm + 800, 800, enc);
  ima_decode(&mid, enc, 400, back);
  CHECK(abs(back[799] - pcm[1599]) < 1500);
  // the vector the app's decoder test uses (ios/IPhoneAgentTests): 8 samples from state (0, 0)
  const int16_t v[8] = {0, 1000, 3000, 2000, -500, -4000, 100, 32000};
  uint8_t ve[4];
  ima_state vs = {0, 0};
  ima_encode(&vs, v, 8, ve);
  CHECK(ve[0] == 0x70 && ve[1] == 0x77 && ve[2] == 0xff && ve[3] == 0x75 && vs.pred == 1063 && vs.index == 52);
}

static void face_at(sw_face *f, uint32_t t) { swf_tick(f, t); }

static void tap(sw_face *f, uint32_t t) {
  swf_touch(f, true, 233, 233, 466, 466, t);
  swf_touch(f, false, 233, 233, 466, 466, t + 80);
}

// The character, as the app's AgentFace and PokeableFace (src/ui/sw_face.h).
static void test_sw_face(void) {
  sw_face f;
  swf_pose p;
  swf_init(&f, 1.6f, 0);
  swf_mood(&f, SW_IDLE, false, 0, 0,0);
  // idle: blinks every 4.3 s, breathes, looks left at 6-7 s of each 9 s
  face_at(&f, 1000);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE && p.blink == 1 && p.breathe != 1 && p.gaze_x == 0 && p.sx == 1 && p.dy == 0);
  face_at(&f, 4365);
  swf_pose_at(&f, &p);
  CHECK(p.blink < 0.2f);
  face_at(&f, 6500);
  swf_pose_at(&f, &p);
  CHECK(p.gaze_x < 0);
  // tap: happy and squished, a light buzz, back to idle after 0.7 s
  tap(&f, 10000);
  CHECK(swf_haptic(&f) > 0 && swf_haptic(&f) == 0);
  face_at(&f, 10150);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_SUCCESS && p.sx > 1.02f && p.sy < 0.95f);
  face_at(&f, 10779);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_SUCCESS);
  face_at(&f, 10781);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);
  face_at(&f, 12000);
  swf_pose_at(&f, &p);
  CHECK(fabsf(p.sx - 1) < 0.01f && fabsf(p.dy) < 0.5f);  // springs settled
  // double tap within 0.35 s: wink and a jump
  tap(&f, 20000);
  tap(&f, 20250);
  face_at(&f, 20390);  // the first tap's squash still pulls the lift back, as in the app
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_WINK && p.dy < -10);
  face_at(&f, 21200);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);
  // three taps within 1.2 s: dizzy for 1.3 s, shakes it off, then the real mood
  tap(&f, 30000);
  tap(&f, 30500);
  tap(&f, 31000);
  face_at(&f, 31500);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_DIZZY && p.tilt > 4);
  face_at(&f, 32400);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);  // shaking it off
  face_at(&f, 33200);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE && f.override == -1 && p.tilt == 0);
  // long press: petting (content), soft buzzes every 0.65 s while held, back after release
  swf_touch(&f, true, 233, 233, 466, 466, 40000);
  face_at(&f, 40399);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);
  face_at(&f, 40401);
  CHECK(swf_haptic(&f) > 0);
  face_at(&f, 41000);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_CONTENT && p.sx > 1.03f && p.tilt > 2);
  face_at(&f, 41100);
  CHECK(swf_haptic(&f) > 0);
  swf_touch(&f, false, 233, 233, 466, 466, 42000);
  face_at(&f, 42300);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_CONTENT);
  face_at(&f, 42400);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);
  // drag: the eyes look at the finger, the body leans after it (at most 22 points), springs back on release
  swf_touch(&f, true, 233, 233, 466, 466, 50000);
  swf_touch(&f, true, 433, 233, 466, 466, 50100);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_LISTENING && p.gaze_x > 0.8f && p.dx > 20 && p.dx <= 22 && p.tilt > 7);
  swf_touch(&f, true, 133, 433, 466, 466, 50200);
  swf_pose_at(&f, &p);
  CHECK(p.gaze_x < -0.3f && p.gaze_y > 0.8f && p.dx < 0);
  swf_touch(&f, false, 133, 433, 466, 466, 50300);
  face_at(&f, 52000);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE && fabsf(p.dx) < 0.5f && p.gaze_x == 0);
  // a run: a tap only glances up; the app's mood reacts (acting hops, failure shakes); the island's look
  swf_mood(&f, SW_ACTING, true, 0.5f, -0.5f,60000);
  face_at(&f, 60100);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_ACTING && p.dy < -5);
  face_at(&f, 61000);
  swf_pose_at(&f, &p);
  CHECK(fabsf(p.gaze_x - 0.5f) < 0.02f && fabsf(p.gaze_y + 0.5f) < 0.02f);
  tap(&f, 62000);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_ACTING && p.gaze_y < -0.7f);
  face_at(&f, 62700);
  swf_pose_at(&f, &p);
  CHECK(p.gaze_y > -0.6f);
  swf_mood(&f, SW_FAILURE, true, 0, 0,62750);
  face_at(&f, 62790);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_FAILURE && p.dx > 2);
  // a shake while idle: dizzy; not during a run
  swf_dizzy(&f, 63000);
  CHECK(f.override == -1);
  swf_mood(&f, SW_IDLE, false, 0, 0,63500);
  swf_dizzy(&f, 64000);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_DIZZY);
  // the millisecond clock wrapping keeps the timers
  swf_init(&f, 1.6f, 0xFFFFFF00u);
  swf_mood(&f, SW_IDLE, false, 0, 0,0xFFFFFF00u);
  tap(&f, 0xFFFFFF00u);
  face_at(&f, 0x200);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_SUCCESS);
  face_at(&f, 0x400);
  swf_pose_at(&f, &p);
  CHECK(p.mood == SW_IDLE);
}

int main(void) {
  test_sw_power();
  test_sw_warn();
  test_sw_elapsed();
  test_sw_help();
  test_sw_answer();
  test_sw_picks();
  test_sw_voice();
  test_sw_text();
  test_ima();
  test_sw_clock();
  test_sw_face();
  test_sw_parse();
  test_sw_buttons();
  test_lan_lock();
  test_heard();
  test_audio_packets();
  test_audio_gate();
  test_mdns();
  test_logring();
  test_bplist_roundtrip();
  test_bplist_utf16();
  test_gop();
  test_chunker();
  test_keystream_resync();
  test_cli_proto();
  test_arbiter();
  test_pace();
  test_type_budget();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
