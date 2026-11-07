# Harness: develop on a test iPhone and board without cables

English · [简体中文](README.zh-CN.md)

```
Mac ──Wi-Fi (devicectl)── iPhone (Debug build of the app) ──USB── board (HID, power)
                              └──── BLE + Wi-Fi :7300 OTA ──────── board

harness/app.sh          build + install + start the app
harness/fw.sh           build the firmware, copy it into the app, the app installs it on the board
harness/run.sh "<task>" start a task in the app, print how it ended
harness/logs.sh         the app's debug.log (+ --runs traces)
harness/hid.sh "…"      raw board commands through the app (key, type, move…), plus shot / gop / video-reconnect / point
harness/watch.sh        follow a run live: each step's action, thought, screen changed or not, pointer (run it in a Monitor)
harness/ctl.sh pause    hold the run to look into a step (continue | stop)
NO_LAUNCH=1 harness/hid.sh shot   during a run: without NO_LAUNCH the launch brings this app to the front mid-run
harness/board.py        one-time only: put the board on the Mac's Wi-Fi (net sta | net ap)
```

Everything goes through `devicectl` to the iPhone over Wi-Fi. The Mac never talks to the board after the setup:
while the app is connected, the board's app link is the app's alone, so firmware goes Mac → app → board, the same
way Update Board does. The board joins the Mac's Wi-Fi as a station (`net sta`) instead of opening its hotspot, so
the iPhone stays on the Mac's network and reaches the board there too.

## One-time setup

1. **iPhone**: Developer Mode on, paired with this Mac (Xcode › Devices, "Connect via network"), on the Mac's Wi-Fi.
   `export HARNESS_IPHONE=<name or id from xcrun devicectl list devices>` The app's bundle id is read
   from the last `harness/app.sh` build; set `HARNESS_BUNDLE` to use another.
2. **Lightning iPhones**: the board needs a USB host port. Use Apple's Lightning to USB 3 Camera Adapter with a
   USB-A → USB-C **data** cable to the board, and a charger in the adapter's Lightning port (it powers the iPhone
   and the board). USB-C iPhones plug the board in directly.
3. **Board on the Mac's Wi-Fi** (BLE from the Mac, this once): quit the app on the iPhone, replug the board and within
   3 minutes (new BLE peers pair only then) run `uv run harness/board.py net sta`; accept the macOS pairing prompt.
   The SSID and password are typed into a macOS dialog and go over the encrypted link to the board only.
   `net ap` goes back to the hotspot. Then open the app again.
4. On the iPhone, mirror the screen to "ESP32 Agent" again (Control Center › Screen Mirroring).

## Daily loop

```bash
harness/app.sh                     # build + install + start the Debug app (Wi-Fi)
harness/fw.sh                      # build + update the board through the app; "harness ota: done fw v0.2.1 up …"
harness/run.sh "Open Settings"     # run a task, print "finished: …"
harness/logs.sh [--runs]           # copy the log (and run traces) to /tmp/harness-logs/
harness/fw.sh --corrupt            # check: the app refuses a damaged image, the board keeps running
harness/fw.sh --crash-test         # check: an image that aborts (9.9.9) rolls back; "failed … went back …"
harness/fw.sh --small-gop          # test build: a 256 KB GOP that fills within minutes (then fw.sh again)
harness/hid.sh "key ctrl+space; type abc; shot"   # keys to the app in front; shot → /tmp/harness-shots/
harness/hid.sh "gop; video-reconnect; shot"       # GOP fill, then drop the Wi-Fi video: it must resume live
```

The scripts hand the app their arguments as `Documents/harness-inbox/<time>.json` (Debug builds read it every
second) and bring it up. Plain launch arguments got lost: after the board reconnects, iOS restores the app for
Bluetooth in the background and `devicectl`'s launch then only brings that process to the front.

Screen Mirroring has to be chosen again on the iPhone after the board restarts (every `fw.sh`), and after
`app.sh` once the board's GOP buffer is full (a new app process needs a keyframe; iOS sends one only when
mirroring starts). A Wi-Fi video reconnect within the same app process resumes and needs nothing.

`fw.sh` copies the image and a `firmware.json` (size, SHA-256, MD5, version from `hardware/hid_bridge/version.h`)
to `Documents/harness-fw-<time>/` (a new folder each run: `devicectl` never replaces a file it copied before;
never pass `--remove-existing-content`, it wipes the whole app container), then hands the app
`-harness-ota <folder>` and follows its log until the result line (3 minutes at most).

## Security

- **`-harness-ota`** and the app commands relayed by the board exist only in **Debug builds**; store builds ignore
  them. Only there may a firmware manifest be unsigned or the version the board already runs; size, SHA-256 and
  MD5 must still match. Store builds install signed releases only, as before.
- **Firmware updates** need the board's per-boot token, which only the connected app (or USB serial) can read,
  plus the image MD5. Nothing new listens on the network.
- **New BLE peers** can pair only in the 3 minutes after the board powers on (`ble_link.cpp`, `PAIR_WINDOW_MS`).
- **Wi-Fi passwords** are typed into a macOS dialog, sent only over the encrypted link and never logged or stored
  on the Mac; the board keeps them in NVS like its hotspot credentials.
- No device names, SSIDs or IDs in the repo: they come from the environment (`HARNESS_IPHONE`) or dialogs.
- The board doesn't check signatures (the app does, for releases); keep it on a trusted network and use `net ap`
  outside development.
