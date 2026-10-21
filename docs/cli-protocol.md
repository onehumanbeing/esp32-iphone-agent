# CLI protocol (ESP32 ⇄ computer, over BLE)

The `esp32agent` CLI talks to the board over BLE next to the iOS app (both can be connected at once). It never uses
OS-level BLE pairing: a stale bond on either side (macOS `CBError 14`, "Peer removed pairing information") cannot
break it, and Windows/Linux need no pairing dialog. Instead the link is authenticated and encrypted here, in the
application layer.

## Discovery
The board runs two advertising sets (legacy PDUs, connectable):
- set 0: the board's public address, service `...0000` — the iOS app (docs/ble-protocol.md).
- set 1: a random static address picked at every boot, service `...0010`, same name `ESP32 Agent XXXX`.
  No central can hold a bond for an address that changes every boot, so the OS never tries to encrypt.

Both addresses lead to the same GATT server. Full UUID = `6e400001-a9e8-4b1b-9c39-6d6f8a3c` + suffix.

Service `...0010`
| Characteristic | UUID suffix | Props | Purpose |
|---|---|---|---|
| `cli_in`  | `...0011` | write | frames from the computer |
| `cli_out` | `...0012` | notify | frames from the board |

A connection that is neither link-encrypted (the app) nor authenticated here within 15 s is dropped, so a stranger
cannot sit on one of the board's connection slots.

## Identity
- `board_id`: the board's 6-byte BT MAC. The CLI shows it as 12 hex digits (`device id`).
- `client_id`: 16 random bytes made by the CLI once per install.
- `K`: 32-byte key shared by one client and one board. The board keeps up to 4 (NVS, oldest replaced);
  `unpair` from the app forgets them all.

## Frames
`[type u8][body]`, one frame per write / notify (writes may be long writes; notifies are at most MTU-3 bytes).

| type | dir | body |
|---|---|---|
| `0x01` PAIR | → | `c_pub[32] client_id[16]` |
| `0x81` PAIRED | ← | `b_pub[32] board_id[6] mac[16]` |
| `0x02` HELLO | → | `client_id[16] c_nonce[16]` |
| `0x82` WELCOME | ← | `b_nonce[16] board_id[6] mac[16]` |
| `0x10` DATA (control) | ↔ | `ctr u32 LE, ciphertext, tag[12]` |
| `0x11` DATA (video) | ← | `ctr u32 LE, ciphertext, tag[12]` |
| `0xE0` ERROR | ← | UTF-8 reason, plain (only before a session exists) |

### Pairing (only within 3 min of board power-on, like the app's)
```
shared = X25519(b_priv, c_pub)                       # b_priv: fresh per pairing
K      = HKDF-SHA256(ikm=shared, salt="esp32agent-pair-v1", info=c_pub || b_pub, L=32)
mac    = HMAC-SHA256(K, "paired" || client_id)[0:16]
```
Outside the window the board answers `0xE0 "pairing window closed: unplug and replug the board, then pair within 3 minutes"`.
An unauthenticated exchange, like BLE Just Works: it guards against everyone who is not there during the window.

### Session (every connection)
```
okm   = HKDF-SHA256(ikm=K, salt=c_nonce || b_nonce, info="esp32agent-session-v1", L=32)
k_c2b = okm[0:16]   k_b2c = okm[16:32]               # AES-128-GCM keys
mac   = HMAC-SHA256(K, "hello" || c_nonce || b_nonce)[0:16]   # the board proves it holds K
```
Unknown `client_id`: `0xE0 "not paired"`. The client proves it holds K with its first DATA frame: until one decrypts,
the board sends it nothing else.

### DATA
```
nonce = stream u8 || 7 zero bytes || ctr u32 LE      # stream: 'C' client→board, 'B' board control, 'V' board video
aad   = the 5 header bytes (type, ctr)
key   = k_c2b for 'C', k_b2c for 'B' and 'V'
```
Each stream's `ctr` starts at 1 and must grow by exactly 1; anything else is dropped (replay or loss). A gap in `V` is
handled like a video seq gap (wait for the next IDR/CONFIG); a gap in `C` or `B` ends the session (reconnect).

Plaintext:
- `C`: `'c'` + one command line `<id> <command>`, exactly the app's command set (docs/ble-protocol.md). `stream on|off`
  and `snap` act on the CLI's own video, independent of the app's.
- `B`: `'r'` + reply line `<id> ok…|<id> err…` (only replies to the CLI's own commands), or `'s'` + status JSON
  (once a second; the compact form when the full one does not fit).
- `V`: one video chunk exactly as on the app's `video` characteristic: `[seq u16 LE][flags u8][payload]`.

Test vectors: `cli/testdata/vectors.json` (checked by `hardware/tests` and `go test ./cli/...`).
