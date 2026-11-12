#include "keystream.h"
#include <string.h>
#include "../video/gop.h"

// The hardware AES runs on DMA. Straight on a PSRAM packet, it was seen (2026-11-13, a short-drama video with sound)
// to hand back a plaintext that does not parse at the right keystream position, now and then, and every P-frame
// after it stayed undecodable until the next keyframe. So the bytes go through internal RAM, 1 KB at a time;
// the counter state carries over between chunks as across packets.
void ks_ctr(const mbedtls_aes_context *aes, size_t n, size_t *off, uint8_t iv[16], uint8_t stream[16], uint8_t *buf) {
  static uint8_t bounce[1024];  // .bss: internal RAM
  for (size_t i = 0; i < n; i += sizeof bounce) {
    size_t k = n - i < sizeof bounce ? n - i : sizeof bounce;
    memcpy(bounce, buf + i, k);
    mbedtls_aes_crypt_ctr((mbedtls_aes_context *)aes, k, off, iv, stream, bounce, bounce);
    memcpy(buf + i, bounce, k);
  }
}

bool ks_plausible(const uint8_t *p, size_t n) {
  if (n < 5) return false;
  uint32_t len = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
  int type = p[4] & 0x1f;
  return len > 0 && len <= n - 4 && !(p[4] & 0x80) && type >= 1 && type <= 12;
}

// iv0 + block, as a 128-bit big-endian number.
static void counter_at(const ks_key *key, uint8_t out[16], uint64_t block) {
  memcpy(out, key->iv0, 16);
  for (int i = 15; i >= 0 && block; i--) {
    uint64_t sum = out[i] + (block & 0xff);
    out[i] = (uint8_t)sum;
    block = (block >> 8) + (sum >> 8);
  }
}

void ks_at(const ks_key *key, keystream *k, uint64_t pos) {
  uint8_t ctr[16];
  k->pos = pos;
  k->off = pos % 16;
  if (k->off) {
    counter_at(key, ctr, pos / 16);
    mbedtls_aes_crypt_ecb((mbedtls_aes_context *)key->aes, MBEDTLS_AES_ENCRYPT, ctr, k->stream);
    counter_at(key, k->iv, pos / 16 + 1);
  } else {
    counter_at(key, k->iv, pos / 16);
    memset(k->stream, 0, 16);
  }
}

bool ks_try(const ks_key *key, const keystream *k, keystream *out, const uint8_t *cipher, uint8_t *p, size_t n) {
  *out = *k;
  memcpy(p, cipher, n);
  ks_ctr(key->aes, n, &out->off, out->iv, out->stream, p);
  out->pos += n;
  return ks_plausible(p, n);
}

bool ks_resync(const ks_key *key, const keystream *from, keystream *out, const uint8_t *cipher, uint8_t *p, size_t n,
               size_t max_skip, void (*yield)(void)) {
  if (n < 5) return false;
  uint8_t a[16], b[16], ctr[16], head[5];
  uint64_t first = from->pos / 16, last = (from->pos + max_skip) / 16;
  counter_at(key, ctr, first);
  mbedtls_aes_crypt_ecb((mbedtls_aes_context *)key->aes, MBEDTLS_AES_ENCRYPT, ctr, a);
  for (uint64_t blk = first; blk <= last; blk++) {
    counter_at(key, ctr, blk + 1);
    mbedtls_aes_crypt_ecb((mbedtls_aes_context *)key->aes, MBEDTLS_AES_ENCRYPT, ctr, b);
    for (int i = 0; i < 16; i++) {  // keystream bytes at pos = blk*16 + i are a[i..15] then b
      uint64_t pos = blk * 16 + i;
      if (pos <= from->pos) continue;
      for (int j = 0; j < 5; j++) head[j] = cipher[j] ^ (i + j < 16 ? a[i + j] : b[i + j - 16]);
      if (!ks_plausible(head, n)) continue;
      keystream at;
      ks_at(key, &at, pos);
      at.used = from->used;
      if (!ks_try(key, &at, out, cipher, p, n) || !avcc_to_annexb(p, n)) continue;
      ks_try(key, &at, out, cipher, p, n);  // again: the check above rewrote p as Annex B
      return true;
    }
    memcpy(a, b, 16);
    if (yield && (blk & 1023) == 1023) yield();
  }
  return false;
}
