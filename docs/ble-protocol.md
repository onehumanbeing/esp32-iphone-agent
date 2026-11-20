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

`type` (firmware 0.2.6) types one byte at a time and stops before a 4 s budget, or if USB suspends, so a long string cannot trip the 8 s task watchdog. A finished command still replies `ok`. Stopped early: `err typed N of M: budget` or `err typed N of M: asleep` (N and M are bytes). Older firmware only replies `ok`. Status includes `"tchunk":1` when the board speaks this reply. The app sends text in short chunks either way.

The iOS runner sends `reset` when a task finishes, fails, or is stopped. A stopped task retains its plan, steps, and notebook for resume. Turning off keyboard restoration in Settings skips the screenshot checks and `key eject`.

| Command | Behavior |
| --- | --- |
| `reset` | Takes no arguments. Releases all mouse buttons, keyboard keys (including modifiers), and consumer controls in place. Safe to retry. |
| `key eject` | Sends one Consumer Control Eject press and release (`0x00B8`) to toggle the iOS on-screen keyboard. Do not retry after a lost reply because a second press reverses the first. |

If older firmware explicitly rejects `reset` as an unknown command, the app sends `release` to release the left mouse button. Other held inputs remain unconfirmed. The app records this on every handoff and notifies the user once per connection.

New:
- `stream on|off` — continuously forward every access unit over `video` (default off).
- `snap` — send SPS/PPS + every AU since the last IDR (the current GOP), then reply `ok`.
- `res W H` — AirPlay resolution advertised in `/info` (default 480 1040), stored in NVS; takes effect on the next mirroring session. An iPhone streams 718×1560 from 480 1040. An iPad fits its screen into the display (480 1040 gives only 720×500), so the app sets a 1200 1200 square: 1200×834 in landscape and 834×1200 in portrait on an 11" iPad, the black bars around it cropped off in the app; an iPhone puts a board left in a display that is not taller than wide back to 480 1040.
- `fps N` — max fps advertised (default 5), stored in NVS.
- `bench KB` — send KB kilobytes of filler on `video` with the `bench` flag, then reply `ok <ms>`.
- `unpair` — erase all bonds and restart advertising.
- `coex [bt|balance|wifi]` — Wi-Fi/BLE radio-share preference (A/B knob, not stored; every boot starts at
  `balance`). Replies `ok <current>`; bare `coex` just reports it.
- `flick DX DY [SPEED]` (0.2.5) — press, move by DX DY (paced like `move`), release, with no pause between: a fast swipe such as the Home Screen flick from the home bar.
- `press_for MS` (0.2.5) — hold the left button; it comes up by itself after MS (1–60000), or at `release`,
  `click` or `reset`. Moves in between drag. A lost `release` never leaves the button held.
- `result ID` (0.2.5) — the reply this side got (or should have got) for request `ID`, as `ok <that reply>`,
  from the board's last 8; `err unknown id …` if it is not among them. Read only: ask it when a reply is late
  instead of sending the command again.
- `own [IP | off]` (LAN lock, see "LAN mode") — the phone this board belongs to on a home network: `own` shows it
  (`ok <ip>|none [locked]`), `own IP` sets it, `own off` forgets it. The app never needs it: an `auth` video
  session sets it. Also from the CLI.
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
`own` (LAN lock) = 1 when the board is on a home network and belongs to one phone (only it may mirror), else 0.
Firmware without the lock sends no `own`; it is in the reduced status too.

Send priority: replies and status are queued and always go out before further video; video keeps at most
~8 ACL packets (~2 KB) in the controller, so a reply waits behind at most that much video. In `stream on`,
a P-frame more than 800 ms old is skipped and the stream resumes at the next IDR (a slow link degrades to
IDR-only instead of building latency).

## StopWatch screen (M5Stack StopWatch, experimental)
`hardware/flash.sh --stopwatch --build-only` builds BLE HID for the M5Stack StopWatch (round 466×466 screen, two
buttons, touch, vibration, IMU). Its status carries `"board":"stopwatch","ui":1`; the app talks to the screen only
on such a board. Without an app that does (an older one), it is a plain Bluetooth mouse and keyboard with the character
asleep on screen.

App → board: `ui <json>` (answers `ok`; `err usage: …` when it is not a JSON object) or `ui off` (the app is gone: idle).
Every line is the whole state, except `k`, which stays until the app sends another. Unknown keys and values are ignored.

| Key | Value |
|---|---|
| `m` | mood: `sleeping`, `idle`, `listening`, `thinking`, `acting`, `success`, `failure`, `dizzy`, `content`, `wink` |
| `p` | phase: `running`, `help`, `countdown`, `recording`, `paused`, `resuming`, `standby` |
| `s`, `l` | step and step limit (a grey `s/l` counter when `d`/`n` are missing) |
| `d`, `n` | optional done and total: the island's green ring and `d/n` |
| `t` | what the character says (the island's words while running, else the line), UTF-8, up to 80 bytes |
| `c` | the phone's local time `HH:MM` (the status page's clock; the board has none set) |
| `x`, `y` | where the eyes look, -1…1 (the island's look; missing: 0) |
| `f` | `true`: the task finished (`m` `failure`: failed) |
| `k` | standby picks: up to 3 intent names of up to 24 bytes |

The screen is the app's character (`hardware/hid_bridge/src/ui/sw_face.c`, a port of `AgentFace` and `PokeableFace`).
Idle it is awake while `ui` lines come (the app sends its idle mood, `p` `standby`, every 5 s) and asleep without
them (15 s), after `ui off` or when the phone's link drops. Idle pokes as in the app: tap happy, double tap wink,
3 quick taps or a shake dizzy, long press petting, drag: the eyes follow the finger. A run shows its mood, the line
and, with a count, the green ring; `help` turns the screen amber. A run whose lines stop for 15 s while the link
stays shows the island's "×" eyes (iOS suspended the app). A finished task shows the outcome for 5 s. Blue held
0.8 s while nothing runs: a status page for 5 s (battery, Bluetooth, app, firmware, name). `ui` lines do not count
as the app using the board (the CLI is not kept out by them).

Board → app: unprompted reply lines `btn <verb> [arg]`, like the `app` relay (no request id; an app that does not know
them ignores them):

| Line | When |
|---|---|
| `btn pause` / `btn unpause` | yellow button while a task runs (`unpause` when `p` is `paused`) |
| `btn run <i>` | yellow button in idle: the 1st press selects a pick (a tap moves to the next), the 2nd asks "确认发送？", the 3rd sends; 3 s without a press cancels. `i` is 0-based into the last `k` |
| `btn home` | blue button, released within 0.5 s |
| `btn stop` | blue button held 2 s (a ring counts down, an earlier release cancels), or a shake while a task runs (1 s warning; any button cancels) |
| `btn continue` | tap on the screen while `p` is `help` |
| `btn takeover` | swipe up while a task runs |

Vibration: one 400 ms buzz on entering `help`, two short on success, three short on failure.

Language: the board's own words (status page, hints, voice states) are English by default or Chinese; the status
page's last row shows it, and a tap on that row or yellow while the page is open switches it (kept in NVS; flashing
the merged image resets it). Text the app sends is shown as it comes (ASCII in a Latin font, anything else in efontCN).

### StopWatch voice
Only with an app that sends `"v":1` in its `ui` lines (older apps never do: yellow stays a press as above).
- Yellow held 350 ms: recording (the mic is on from the press, so the first word is kept). Released earlier: the
  short press does what yellow did before, on release. Blue while recording or after: dropped, `btn voice cancel`.
- The mic goes to the app on the BLE `video` characteristic as voice chunks with their own u16 seq:
  `[seq u16 LE][flags][payload]`, flags `0xC0` (bit 7 as AirPlay audio, bit 6: the board's mic; never on video)
  plus `0x01` START or `0x02` END. START's payload is the board language's speech locale (`en-US`, `zh-CN`): the app
  transcribes in it. Sound chunks: `[pred i16 LE][step index u8][IMA ADPCM]`, 16 kHz mono, two samples a byte, low
  nibble first; each chunk carries the state it starts from (a lost chunk loses only itself). END: empty, after the
  last sound. 8 KB/s; the board keeps up to 8 s of sound the link falls behind (older sound is dropped, logged).
  No limit on the length of a recording.
- App → board: `voice heard <text>` (UTF-8, the board shows up to 120 bytes) or `voice fail <code>`, code `none`
  (nothing heard), `denied` (speech recognition not allowed), `unavailable` (no on-device model for the language),
  `start` (the task did not start), anything else: a generic error. No answer 20 s after release: "no answer".
- The text shows with "Yellow: run - Blue: cancel" (while a task runs: "tell the task"). Yellow: `btn voice go`, the
  app runs the text as a new task or adds it to the running one; blue: `btn voice cancel`. Untouched for 60 s: dropped
  (`btn voice cancel`).
- USB serial tests: `swpress yellow|blue MS` holds a button; with no app on BLE the chunks are printed as
  `vchunk <hex>` (`hardware/tools/voice_dump.py` writes them to a WAV).

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
An empty or missing `pass` is an open network. Going from a home network back to `{"mode":"ap"}` restarts the board
(firmware with the LAN lock): its AirPlay receiver was not found on the hotspot after a switch without one. Joining
a home network does not restart it; AirPlay is advertised again there once the board has an address.

## LAN mode (station) and the LAN lock
On its own hotspot (WPA2, a random password only a bonded app reads) the board trusts whoever joined. On a home
network every device there sees its AirPlay receiver, and the network may even be open. So in mode `sta`:
- **Owner.** The address of the last app that opened the Wi-Fi video with `auth` (below), or one set with `own`,
  kept in NVS for this network and forgotten when the network changes. Without an owner the board behaves as
  before. With one (`own` 1 in status), AirPlay (RTSP 7000 and the mirror data port) from any other address is
  closed at once, and so are the plain-token `hello` and `ota` headers.
- **Proof instead of the token.** The board sends a fresh nonce (16 random bytes as 32 hex characters) and the app
  answers with HMAC-SHA256(vtok, message), in lower-case hex:
  - video (TCP 7201): app `chal`, board record `chal<nonce>` (36 bytes), app `auth <hmac of "video <nonce>"> [at <ms>]`,
    board the zero-length ack. Every non-empty record after it is AES-128-CTR encrypted: one keystream over all
    records in order, from a zero counter block, key = the first 16 bytes of HMAC-SHA256(vtok, "video key <nonce>").
    `resume [at <ms>]` on the open session asks what `hello … at` asks, without the token.
  - update (TCP 7300, ota.h): app `chal`, board `chal <nonce>`, app `ota2 <size> <sha256> <hmac of
    "ota <nonce> <size> <sha256>">`; the board checks the image's SHA-256 before it boots it.
  A nonce is good for one answer. The vectors in `hardware/tests` (test_lan_lock) and the app's LanAuthTests agree.
- The app uses the proof whenever the board reports `own` and is not on its hotspot, and only offers LAN mode on
  such firmware. An open network is joined without a passphrase on the phone too.

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
