// Host unit tests for the board's pure-C parts: bplist codec, the GOP buffer / video chunker, and the
// mirroring keystream, the CLI link crypto, the app/CLI HID arbiter, the RAM log ring.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hid_bridge/src/bplist/bplist.h"
#include "../hid_bridge/src/video/gop.h"
#include "../hid_bridge/src/airplay/keystream.h"
#include "../hid_bridge/src/cli/cli_proto.h"
#include "../hid_bridge/src/hid/arbiter.h"
#include "../hid_bridge/src/log/logring.h"
#include "mdns.h"  // stubs/: the host stand-in for ESP-IDF mdns
#include "../hid_bridge/src/airplay/ap_internal.h"

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

  // The tail past a full GOP: sent AUs beyond `keep` go first; with big AUs (a scrolling screen) more of the sent
  // ones go too, rather than breaking the tail of a stream that is in step. Unsent AUs never go.
  static uint8_t warena[100];
  static gop_au waus[8];
  gop_buf w;
  gop_init(&w, warena, sizeof warena, waus, 8);
  for (uint32_t i = 0; i < 4; i++) CHECK(gop_append(&w, au, 25, false, 20 + i) == (int)i);
  CHECK(gop_trim_sent(&w, 0, 2, 25) == 0 && w.n == 4);          // nothing sent: nothing to drop
  CHECK(gop_trim_sent(&w, 4, 2, 25) == 2 && w.n == 2 && w.aus[0].ts == 22);  // sent beyond the keep (as before)
  CHECK(gop_append(&w, au, 25, false, 24) == 2);
  CHECK(gop_trim_sent(&w, 2, 2, 75) == 2 && w.n == 1 && w.aus[0].ts == 24);  // the keep gives way to room
  CHECK(gop_trim_sent(&w, 0, 1, 100) == 0 && w.n == 1);         // only the unsent AU: no room
  gop_init(&w, warena, sizeof warena, waus, 2);                 // the AU list fills first
  CHECK(gop_append(&w, au, 5, false, 30) == 0 && gop_append(&w, au, 5, false, 31) == 1);
  CHECK(gop_trim_sent(&w, 2, 4, 5) == 1 && w.n == 1 && w.aus[0].ts == 31);

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
  arb_after(&s, ARB_APP, "press", true);
  arb_after(&s, ARB_APP, "click", true);
  CHECK(!arb_gone(&s, ARB_APP));
  arb_after(&s, ARB_APP, "press", false);  // failed: nothing held
  CHECK(!arb_gone(&s, ARB_APP));
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

int main(void) {
  test_mdns();
  test_logring();
  test_bplist_roundtrip();
  test_bplist_utf16();
  test_gop();
  test_chunker();
  test_keystream_resync();
  test_cli_proto();
  test_arbiter();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
