#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "mbedtls/aes.h"

#ifdef __cplusplus
extern "C" {
#endif

// LAN lock (docs/ble-protocol.md, "LAN mode"). On its own hotspot (WPA2, a random password only a bonded app reads)
// the board trusts whoever joined. On a home network every device there can see it, so in station mode:
// - the board belongs to one phone, its owner: the address of the last app that opened the Wi-Fi video with a
//   proof of the per-boot token (`auth`), or one set with `own`. Once there is an owner, AirPlay from any other
//   address is refused, and so are the plain-token `hello` and `ota` lines.
// - the token itself never goes over the network: the board sends a fresh nonce (`chal`) and the app answers with
//   HMAC-SHA256(token, message with that nonce). An `auth` video session is AES-128-CTR encrypted with a key from
//   the same nonce, and `ota2` carries the image's SHA-256 under the HMAC.
// Addresses are IPv4 in network byte order (lwIP's sin_addr.s_addr); 0 = none.

#define LAN_NONCE_HEX 32  // hex characters of a nonce (16 random bytes)
#define LAN_MAC_HEX 64    // hex characters of an HMAC-SHA256

void lan_set_station(bool station);  // the board is configured as a station (mode "sta"), connected or not
void lan_set_owner(uint32_t ip);
uint32_t lan_owner(void);
bool lan_locked(void);               // station mode with an owner
bool lan_peer_ok(uint32_t ip);       // may connect: not locked, or the owner

// 16 random bytes (the caller's RNG) as LAN_NONCE_HEX lower-case hex characters plus a NUL.
void lan_nonce(char out[LAN_NONCE_HEX + 1], const uint8_t random[16]);
// HMAC-SHA256(token, msg) as lower-case hex plus a NUL.
void lan_mac(const char *token, const char *msg, char out[LAN_MAC_HEX + 1]);
// `hex` is HMAC-SHA256(token, msg); constant time, either case.
bool lan_mac_ok(const char *token, const char *msg, const char *hex);

// The encrypted video session: one continuous AES-128-CTR keystream over every non-empty record, in order, from a
// zero counter block. Key: the first 16 bytes of HMAC-SHA256(token, "video key " + nonce).
typedef struct {
  mbedtls_aes_context aes;
  uint8_t counter[16], block[16];
  size_t off;
  bool on;
} lan_ctr;

void lan_ctr_start(lan_ctr *c, const char *token, const char *nonce);
void lan_ctr_crypt(lan_ctr *c, uint8_t *data, size_t len);  // in place; nothing when not started
void lan_ctr_stop(lan_ctr *c);

// IPv4 dotted quad -> network byte order; false if malformed. And back (out: at least 16 bytes).
bool lan_parse_ip(const char *s, uint32_t *ip);
void lan_format_ip(uint32_t ip, char out[16]);

#ifdef __cplusplus
}
#endif
