// CLI link crypto, see cli_proto.h.
#include "cli_proto.h"
#include <string.h>
#include <mbedtls/ecp.h>
#include <mbedtls/gcm.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>

static const mbedtls_md_info_t *sha256(void) { return mbedtls_md_info_from_type(MBEDTLS_MD_SHA256); }

static int rng(void *ctx, unsigned char *p, size_t n) {
  (void)ctx;
  cli_random(p, n);
  return 0;
}

// X25519 (RFC 7748): scalar k times point u, both 32 bytes little-endian.
static bool x25519(const uint8_t k[32], const uint8_t u[32], uint8_t out[32]) {
  mbedtls_ecp_group g;
  mbedtls_ecp_point p, r;
  mbedtls_mpi d;
  mbedtls_ecp_group_init(&g);
  mbedtls_ecp_point_init(&p);
  mbedtls_ecp_point_init(&r);
  mbedtls_mpi_init(&d);
  uint8_t kk[32], uu[32];
  memcpy(kk, k, 32);
  kk[0] &= 248;  // clamp
  kk[31] = (kk[31] & 127) | 64;
  memcpy(uu, u, 32);
  uu[31] &= 127;  // the top bit of u is ignored
  bool ok = mbedtls_ecp_group_load(&g, MBEDTLS_ECP_DP_CURVE25519) == 0 && mbedtls_mpi_read_binary_le(&d, kk, 32) == 0 &&
            mbedtls_mpi_read_binary_le(&p.MBEDTLS_PRIVATE(X), uu, 32) == 0 &&
            mbedtls_mpi_lset(&p.MBEDTLS_PRIVATE(Z), 1) == 0 && mbedtls_ecp_mul(&g, &r, &d, &p, rng, NULL) == 0 &&
            mbedtls_mpi_write_binary_le(&r.MBEDTLS_PRIVATE(X), out, 32) == 0;
  mbedtls_mpi_free(&d);
  mbedtls_ecp_point_free(&r);
  mbedtls_ecp_point_free(&p);
  mbedtls_ecp_group_free(&g);
  return ok;
}

bool cli_pair(const uint8_t b_priv[32], const uint8_t c_pub[32], uint8_t b_pub[32], uint8_t k[CLI_KEY_LEN]) {
  static const uint8_t base[32] = {9};
  uint8_t shared[32], info[64], zero = 0;
  if (!x25519(b_priv, base, b_pub) || !x25519(b_priv, c_pub, shared)) return false;
  for (int i = 0; i < 32; i++) zero |= shared[i];
  if (!zero) return false;  // a low-order point: no shared secret
  memcpy(info, c_pub, 32);
  memcpy(info + 32, b_pub, 32);
  static const char salt[] = "esp32agent-pair-v1";
  bool ok = mbedtls_hkdf(sha256(), (const uint8_t *)salt, sizeof salt - 1, shared, 32, info, 64, k, CLI_KEY_LEN) == 0;
  memset(shared, 0, sizeof shared);
  return ok;
}

bool cli_session(const uint8_t k[CLI_KEY_LEN], const uint8_t c_nonce[16], const uint8_t b_nonce[16],
                 uint8_t k_c2b[16], uint8_t k_b2c[16]) {
  uint8_t salt[32], okm[32];
  memcpy(salt, c_nonce, 16);
  memcpy(salt + 16, b_nonce, 16);
  static const char info[] = "esp32agent-session-v1";
  if (mbedtls_hkdf(sha256(), salt, 32, k, CLI_KEY_LEN, (const uint8_t *)info, sizeof info - 1, okm, 32)) return false;
  memcpy(k_c2b, okm, 16);
  memcpy(k_b2c, okm + 16, 16);
  memset(okm, 0, sizeof okm);
  return true;
}

void cli_mac(const uint8_t k[CLI_KEY_LEN], const char *label, const uint8_t *a, size_t alen, const uint8_t *b,
             size_t blen, uint8_t out[CLI_MAC_LEN]) {
  mbedtls_md_context_t c;
  uint8_t full[32];
  mbedtls_md_init(&c);
  mbedtls_md_setup(&c, sha256(), 1);
  mbedtls_md_hmac_starts(&c, k, CLI_KEY_LEN);
  mbedtls_md_hmac_update(&c, (const uint8_t *)label, strlen(label));
  if (alen) mbedtls_md_hmac_update(&c, a, alen);
  if (blen) mbedtls_md_hmac_update(&c, b, blen);
  mbedtls_md_hmac_finish(&c, full);
  mbedtls_md_free(&c);
  memcpy(out, full, CLI_MAC_LEN);
}

static void nonce(char stream, uint32_t ctr, uint8_t n[12]) {
  memset(n, 0, 12);
  n[0] = (uint8_t)stream;
  for (int i = 0; i < 4; i++) n[8 + i] = (uint8_t)(ctr >> (8 * i));
}

size_t cli_seal(const uint8_t key[16], uint8_t type, char stream, uint32_t ctr, const uint8_t *plain, size_t n,
                uint8_t *out) {
  uint8_t iv[12];
  nonce(stream, ctr, iv);
  out[0] = type;
  for (int i = 0; i < 4; i++) out[1 + i] = (uint8_t)(ctr >> (8 * i));
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  int rc = mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (!rc) rc = mbedtls_gcm_crypt_and_tag(&g, MBEDTLS_GCM_ENCRYPT, n, iv, 12, out, CLI_HDR_LEN, plain, out + CLI_HDR_LEN,
                                          CLI_TAG_LEN, out + CLI_HDR_LEN + n);
  mbedtls_gcm_free(&g);
  return rc ? 0 : n + CLI_OVERHEAD;
}

int cli_open(const uint8_t key[16], char stream, const uint8_t *frame, size_t n, uint32_t *ctr, uint8_t *plain) {
  if (n < CLI_OVERHEAD) return -1;
  uint32_t c = 0;
  for (int i = 0; i < 4; i++) c |= (uint32_t)frame[1 + i] << (8 * i);
  uint8_t iv[12];
  nonce(stream, c, iv);
  size_t len = n - CLI_OVERHEAD;
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  int rc = mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (!rc) rc = mbedtls_gcm_auth_decrypt(&g, len, iv, 12, frame, CLI_HDR_LEN, frame + CLI_HDR_LEN + len, CLI_TAG_LEN,
                                         frame + CLI_HDR_LEN, plain);
  mbedtls_gcm_free(&g);
  if (rc) return -1;
  *ctr = c;
  return (int)len;
}
