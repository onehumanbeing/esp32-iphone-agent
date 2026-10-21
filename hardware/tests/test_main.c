// Host unit tests for the board's pure-C parts: bplist codec, the GOP buffer / video chunker, and the
// mirroring keystream.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hid_bridge/src/bplist/bplist.h"
#include "../hid_bridge/src/video/gop.h"
#include "../hid_bridge/src/airplay/keystream.h"

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

  uint8_t idr[] = {0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 9};
  CHECK(annexb_has_idr(idr, sizeof idr));
  CHECK(!annexb_has_idr(idr, 6));

  uint8_t avcc[] = {0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41};
  uint8_t want[] = {0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41};
  CHECK(avcc_to_annexb(avcc, sizeof avcc) && !memcmp(avcc, want, sizeof want));
  uint8_t bad[] = {0, 0, 0, 9, 0x65};
  CHECK(!avcc_to_annexb(bad, sizeof bad));
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

int main(void) {
  test_bplist_roundtrip();
  test_bplist_utf16();
  test_gop();
  test_chunker();
  test_keystream_resync();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
