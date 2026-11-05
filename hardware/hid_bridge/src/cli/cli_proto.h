// CLI link crypto (docs/cli-protocol.md): X25519 pairing, HKDF session keys, AES-128-GCM frames.
// Plain C on mbedtls so it can be unit-tested on the host.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { CLI_PAIR = 0x01, CLI_PAIRED = 0x81, CLI_HELLO = 0x02, CLI_WELCOME = 0x82, CLI_DATA = 0x10, CLI_VIDEO = 0x11,
       CLI_ERROR = 0xE0 };
#define CLI_ID_LEN 16
#define CLI_KEY_LEN 32
#define CLI_NONCE_LEN 16
#define CLI_MAC_LEN 16
#define CLI_TAG_LEN 12
#define CLI_HDR_LEN 5          // type + ctr
#define CLI_OVERHEAD (CLI_HDR_LEN + CLI_TAG_LEN)

// Fills p with n random bytes; provided by the caller (the board's RNG, or a test's).
void cli_random(uint8_t *p, size_t n);
// Board side of pairing: b_priv is 32 random bytes. Writes b_pub and the shared key K. False on bad input.
bool cli_pair(const uint8_t b_priv[32], const uint8_t c_pub[32], uint8_t b_pub[32], uint8_t k[CLI_KEY_LEN]);
// Session keys from K and both nonces.
bool cli_session(const uint8_t k[CLI_KEY_LEN], const uint8_t c_nonce[16], const uint8_t b_nonce[16],
                 uint8_t k_c2b[16], uint8_t k_b2c[16]);
// HMAC-SHA256(key, a || b)[0:16].
void cli_mac(const uint8_t k[CLI_KEY_LEN], const char *label, const uint8_t *a, size_t alen, const uint8_t *b,
             size_t blen, uint8_t out[CLI_MAC_LEN]);
// Seals plain into out (room for n + CLI_OVERHEAD); stream is 'C', 'B' or 'V'. Returns the frame length.
size_t cli_seal(const uint8_t key[16], uint8_t type, char stream, uint32_t ctr, const uint8_t *plain, size_t n,
                uint8_t *out);
// Opens a frame into plain (room for n - CLI_OVERHEAD). Returns the plain length, or -1 if it does not verify.
int cli_open(const uint8_t key[16], char stream, const uint8_t *frame, size_t n, uint32_t *ctr, uint8_t *plain);

#ifdef __cplusplus
}
#endif
