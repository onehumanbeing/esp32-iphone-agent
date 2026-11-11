# BLE protocol (ESP32 ⇄ iOS app)

The board is a BLE peripheral named `ESP32 Agent XXXX` (XXXX = last 2 MAC bytes, hex).
Security: LE Secure Connections, bonding, Just Works. `net` requires an encrypted link,
so reading it triggers the iOS pairing prompt.

Service `6e400001-a9e8-4b1b-9c39-6d6f8a3c0000`

| Characteristic | UUID suffix | Props | Purpose |
|---|---|---|---|
| `cmd`    | `...0001` | write, write-no-rsp | one command line, UTF-8, `<id> <command>` |
| `reply`  | `...0002` | notify | `<id> ok` or `<id> err <reason>` |
| `status` | `...0003` | notify, read | JSON heartbeat, every 1 s (also keeps the app alive in background) |
| `video`  | `...0004` | notify | H.264 chunks, see below |
| `net`    | `...0005` | read, write (encrypted) | network config JSON |

Full UUID = `6e400001-a9e8-4b1b-9c39-6d6f8a3c` + 4-hex suffix, e.g. cmd = `6e400001-a9e8-4b1b-9c39-6d6f8a3c0001`.

A computer (the `esp32agent` CLI) can be connected at the same time on its own service `...0010`, with its own
video stream and replies: see [cli-protocol.md](cli-protocol.md).

## cmd
`<id>` is a decimal request id chosen by the app; the reply echoes it.
Existing HID commands, unchanged semantics from the old TCP protocol:
`ping`, `home`, `move DX DY`, `press`, `release`, `click`, `scroll A B`, `type TEXT`, `key COMBO`.
New:
- `stream on|off` — continuously forward every access unit over `video` (default off).
- `snap` — send SPS/PPS + every AU since the last IDR (the current GOP), then reply `ok`.
- `res W H` — AirPlay resolution advertised in `/info` (default 480 1040), stored in NVS; takes effect on the next mirroring session.
- `fps N` — max fps advertised (default 5), stored in NVS.
- `bench KB` — send KB kilobytes of filler on `video` with the `bench` flag, then reply `ok <ms>`.
- `unpair` — erase all bonds and restart advertising.
- `coex [bt|balance|wifi]` — Wi-Fi/BLE radio-share preference (A/B knob, not stored; every boot starts at
  `balance`). Replies `ok <current>`; bare `coex` just reports it.
- `press_for MS` (0.2.5) — hold the left button; it comes up by itself after MS (1–60000), or at `release`,
  `click` or `reset`. Moves in between drag. A lost `release` never leaves the button held.
- `result ID` (0.2.5) — the reply this side got (or should have got) for request `ID`, as `ok <that reply>`,
  from the board's last 8; `err unknown id …` if it is not among them. Read only: ask it when a reply is late
  instead of sending the command again.
When the link drops, the board releases all buttons/keys (same as before).

## status (JSON, one notify per second, must fit one MTU; keep short keys)
```json
{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok|asleep|off",
 "net":"ap|sta|none","ip":"192.168.4.1","sta":1,
 "ap":"idle|connected|streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"gop":42000,
 "ble":{"mtu":247,"phy":2,"kbps":350,"drop":0,"rdrop":0,"n":1},
 "udp":{"n":1,"kbps":2400,"nack":3,"drop":0}}
```
`kbps` = AirPlay video bitrate in, `ble.kbps` = video bytes out over BLE, `idr` = ms between IDRs, `gop` = bytes buffered since last IDR.
`rst` = reset reason of the current boot (`power-on|brownout|watchdog|crash|software|usb|other`), `up` = ms since boot.
`ble.drop` = video notifies given up, `ble.rdrop` = replies that never reached a subscribed peer (should stay 0),
`ble.n` = connected centrals.
`udp` = the Wi-Fi video channel (below): `n` 1 while video goes over UDP, `kbps` bytes out (resends included),
`nack` resend requests and `drop` datagrams the Wi-Fi driver had no room for, both since boot.
`lost` (0.2.5) = AirPlay video packets the board dropped for good since boot (decrypted in step but not a
frame). After one, the frames that follow may not decode until the next IDR: if decoding fails right after
`lost` goes up, ask for screen mirroring to be restarted instead of waiting.

Send priority: replies and status are queued and always go out before further video; video keeps at most
~8 ACL packets (~2 KB) in the controller, so a reply waits behind at most that much video. In `stream on`,
a P-frame more than 800 ms old is skipped and the stream resumes at the next IDR (a slow link degrades to
IDR-only instead of building latency).

## video
Each notify: `[seq u16 LE][flags u8][payload]`, payload up to MTU-3-3 bytes.
flags: bit0 START of access unit, bit1 END of access unit, bit2 IDR, bit3 CONFIG (payload is SPS+PPS),
bit4 BENCH (filler, ignore), bit5 SNAP (part of a snap reply), bit6 RESUME (Wi-Fi TCP: the first unit after a
reconnect that goes on from the app's last one; the app takes it after the gap without waiting for an IDR).
Payload is Annex-B (`00 00 00 01` start codes). On a START chunk the first 4 payload bytes are a u32 LE
board timestamp (ms) for latency stats, followed by the Annex-B data.
`seq` increments per notify; the app counts gaps as drops and waits for the next IDR/CONFIG after a gap.

## Wi-Fi video (UDP)
BLE (1M PHY, ~140 kbps) can't keep up with the H.264 of animations, and P-frames can't be skipped, so video
moves to the board's Wi-Fi when the app can reach it. BLE stays the command link, keeps the app alive in the
background, and carries the video again whenever no Wi-Fi session is up.

- Board: UDP port 7200 on `ip` from `net` (192.168.4.1 on its hotspot); one app at a time.
- App → board, text: `hello <vtok>` opens the session (answered `ok`; a wrong token is ignored), `ka` every
  1 s (answered `ok`; the board drops the session after 3 s without a datagram), `nack <from> <to>` resends
  that inclusive seq range (at most 256 chunks), `resync` resends config + GOP from the latest IDR.
- Board → app: each datagram is one `video` chunk exactly as above (`[seq][flags][payload]`), payload up to
  1380 bytes. The same seq counter as BLE; a new session or a switch of transport starts again from the IDR.
- The board keeps the last 1024 chunks (PSRAM) for resends. The app orders datagrams by seq, nacks a gap at
  once and again after 80 ms, and after 250 ms skips it and sends `resync` (the assembler waits for the IDR).
- `vtok` is random per boot and only in the encrypted `net` read, so only a bonded app can watch the screen.
- USB serial (Mac tests): `0 netinfo` prints the `net` JSON, `0 status` the full status;
  `hardware/tools/board_test.py udp --serial <port>` benches the channel.

## Wi-Fi video (TCP, current firmware)
Port 7201, one app at a time. App → board text lines: `hello <vtok>` or `hello <vtok> at <ms>`, then `ka` every
1 s and `resync` if the assembler lost its place. Board → app: records `[u16 LE length][chunk]`, the chunk as
above; a zero-length record answers hello and ka.
- `at <ms>`: the app's decoder is in step up to the unit stamped `<ms>` (board timestamp from its START chunk).
  The board goes on right after it, in the GOP or in the tail past a full GOP, and flags that unit RESUME.
  Without it, or when that unit is gone (new IDR, the board rebooted, the tail was trimmed), the stream starts
  again from the IDR. A reconnect therefore no longer resends minutes of P-frames, and a full (frozen) GOP no
  longer leaves a reconnecting app without a picture. A new app process has no decoder state: it still needs
  the IDR, so after the GOP filled it needs Screen Mirroring restarted.
- When the GOP fills, the board keeps a tail of later units for everyone; units the stream sent are dropped
  from it only once more than 64 are behind (kept for a resume: a dropped session loses what TCP buffered).

## Wi-Fi audio (TCP)
AirPlay audio rides the same TCP link, only after the app sends the line `audio` (on each new session, after the
hello ack; older firmware ignores it). Records are chunks with flag `0x80` set (never set on video) and their own
u16 seq: `[seq u16 LE][flags][payload]`, payload `[u32 LE board ms][u32 LE RTP ts][AAC-ELD frame]`.
- The board decrypts the mirroring audio (SETUP type 96, `ct=8` AAC-ELD, 44.1 kHz stereo, 480 samples per frame,
  AudioSpecificConfig `F8 E8 50 00`): AES-128-CBC with the session key and the SETUP `eiv`, afresh per packet,
  whole blocks only. Other formats are only counted.
- Only sound goes out: the sender's no-data packets (empty, or the marker `00 68 34 00`) start nothing. A segment
  starts with the first sounding frame (`START`, 0x01) and ends 500 ms after the last one with an empty `END`
  (0x02) record. An app that joins mid-segment gets `START` on its first frame.
- Status `aud`: `pk` packets received, `seg` segments, `snd` 1 while one goes on, `vol` the sender's volume in dB
  (-144 muted, from SET_PARAMETER), `drop` records lost (queue full or no app).
- The app (Settings › Listen to phone audio, off by default) decodes them, ignores quiet segments (under -50 dBFS)
  and transcribes on the phone; the agent's step prompt then has a `Heard` block.

## net (JSON)
Read: `{"mode":"ap","ssid":"ESP32Agent-1A2B","pass":"<random 12 chars>","ip":"192.168.4.1","vtok":"<32 hex>"}`
(SoftAP credentials are generated once at first boot and kept in NVS; `vtok` is new every boot).
Write `{"mode":"ap"}` or `{"mode":"sta","ssid":"...","pass":"..."}` — stored in NVS, board restarts Wi-Fi.

## AirPlay
Receiver name `ESP32 Agent`, mirroring only, H.264 video plus AAC-ELD audio while there is sound (see Wi-Fi audio), resolution/fps from NVS.

## Deviations (firmware notes)
- `status`: if the negotiated MTU is too small for the full JSON (MTU-3 < ~255 bytes), the notify carries a
  reduced object `{"up","rst","usb","net","ap","ble":{"mtu"}}`; a `status` read always returns the last full JSON.
- `sta` in `status` = number of stations on the board's hotspot (mode `ap`), or 1/0 = connected (mode `sta`).
- `net` read in `sta` mode returns the station network's `ssid`/`pass`.
- `snap` while mirroring has stopped returns the last buffered GOP (check `"ap"` in status); `snap` without
  any video replies `err no video ...`.
- `snap` while AirPlay is `streaming` but the GOP is still empty (`wait_idr`, e.g. right after connect or
  when an IDR was too big for the buffer) replies `err waiting for keyframe` instead of `err no video ...`.
  Before mirroring starts (`ap` idle/connected), the same empty-GOP state still replies `err no video ...`
  so Diagnostics can tell "start screen mirroring" from "mirroring is up, waiting for an IDR".
