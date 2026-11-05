// The AES-CTR keystream of AirPlay mirroring video, with a way back into step after the sender skips ahead.
// Pure C on mbedtls, so it builds on the host for tests (hardware/tests).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "mbedtls/aes.h"

typedef struct {
  const mbedtls_aes_context *aes;
  uint8_t iv0[16];  // the first counter of the stream
} ks_key;

typedef struct {
  uint8_t iv[16], stream[16];  // mbedtls_aes_crypt_ctr's nonce counter and stream block
  size_t off;
  uint64_t pos;   // bytes since iv0
  uint32_t used;  // when it last decoded a packet (for most-recently-used order)
} keystream;

// Does the plaintext start like an AVCC frame: a NAL length that fits, forbidden bit 0, an H.264 type 1-12?
bool ks_plausible(const uint8_t *p, size_t n);
// The keystream as mbedtls_aes_crypt_ctr leaves it after pos bytes.
void ks_at(const ks_key *key, keystream *k, uint64_t pos);
// Decrypt cipher into p with k (k unchanged; the advanced state goes to out); true if p looks like a frame.
bool ks_try(const ks_key *key, const keystream *k, keystream *out, const uint8_t *cipher, uint8_t *p, size_t n);
// Search positions after from->pos, up to max_skip bytes ahead, for one where the packet decrypts to a whole
// AVCC frame; p then holds the plaintext and out the advanced keystream. yield() runs now and then (may be NULL).
bool ks_resync(const ks_key *key, const keystream *from, keystream *out, const uint8_t *cipher, uint8_t *p, size_t n,
               size_t max_skip, void (*yield)(void));
