// LAN lock, see lan_lock.h.
#include "lan_lock.h"
#include <stdio.h>
#include <string.h>
#include "mbedtls/md.h"

static volatile bool station;
static volatile uint32_t owner;

void lan_set_station(bool s) { station = s; }
void lan_set_owner(uint32_t ip) { owner = ip; }
uint32_t lan_owner(void) { return owner; }
bool lan_locked(void) { return station && owner != 0; }
bool lan_peer_ok(uint32_t ip) { return !lan_locked() || ip == owner; }

static void hex(const uint8_t *p, size_t n, char *out) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < n; i++) {
    out[2 * i] = digits[p[i] >> 4];
    out[2 * i + 1] = digits[p[i] & 15];
  }
  out[2 * n] = 0;
}

void lan_nonce(char out[LAN_NONCE_HEX + 1], const uint8_t random[16]) { hex(random, 16, out); }

static void hmac(const char *token, const char *msg, uint8_t out[32]) {
  mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), (const unsigned char *)token, strlen(token),
                  (const unsigned char *)msg, strlen(msg), out);
}

void lan_mac(const char *token, const char *msg, char out[LAN_MAC_HEX + 1]) {
  uint8_t m[32];
  hmac(token, msg, m);
  hex(m, 32, out);
}

bool lan_mac_ok(const char *token, const char *msg, const char *given) {
  if (!given || strlen(given) != LAN_MAC_HEX) return false;
  char want[LAN_MAC_HEX + 1];
  lan_mac(token, msg, want);
  unsigned diff = 0;
  for (int i = 0; i < LAN_MAC_HEX; i++) {
    char g = given[i];
    if (g >= 'A' && g <= 'F') g = (char)(g - 'A' + 'a');
    diff |= (unsigned)(g ^ want[i]);
  }
  return diff == 0;
}

void lan_ctr_start(lan_ctr *c, const char *token, const char *nonce) {
  char msg[16 + LAN_NONCE_HEX];
  snprintf(msg, sizeof msg, "video key %s", nonce);
  uint8_t key[32];
  hmac(token, msg, key);
  if (c->on) mbedtls_aes_free(&c->aes);
  mbedtls_aes_init(&c->aes);
  mbedtls_aes_setkey_enc(&c->aes, key, 128);
  memset(c->counter, 0, sizeof c->counter);
  memset(c->block, 0, sizeof c->block);
  memset(key, 0, sizeof key);
  c->off = 0;
  c->on = true;
}

void lan_ctr_crypt(lan_ctr *c, uint8_t *data, size_t len) {
  if (!c->on || !len) return;
  mbedtls_aes_crypt_ctr(&c->aes, len, &c->off, c->counter, c->block, data, data);
}

void lan_ctr_stop(lan_ctr *c) {
  if (c->on) mbedtls_aes_free(&c->aes);
  c->on = false;
}

bool lan_parse_ip(const char *s, uint32_t *ip) {
  unsigned a, b, c, d;
  char end;
  if (!s || sscanf(s, "%u.%u.%u.%u%c", &a, &b, &c, &d, &end) != 4 || a > 255 || b > 255 || c > 255 || d > 255)
    return false;
  uint8_t bytes[4] = {(uint8_t)a, (uint8_t)b, (uint8_t)c, (uint8_t)d};
  memcpy(ip, bytes, 4);
  return true;
}

void lan_format_ip(uint32_t ip, char out[16]) {
  uint8_t b[4];
  memcpy(b, &ip, 4);
  snprintf(out, 16, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
}
