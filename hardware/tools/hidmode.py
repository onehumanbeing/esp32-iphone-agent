# /// script
# requires-python = ">=3.10"
# dependencies = ["pyserial>=3.5"]
# ///
"""Show or switch the input mode of a --dual-hid board over its USB serial (docs/hid-mode-switch.md).

    uv run hardware/tools/hidmode.py                 # this boot's mode and the input fields of its status
    uv run hardware/tools/hidmode.py ble             # save BLE HID, restart, show the new status
    uv run hardware/tools/hidmode.py usb --port /dev/cu.usbmodem1101

Works in either mode (USB serial stays on in BLE mode), so it is the way back when the phone side is stuck.
The board must be plugged into this Mac, not the iPhone, while it runs.
"""
import argparse
import glob
import json
import time

import serial


def ask(port: serial.Serial, line: str, timeout: float = 3) -> str:
    port.reset_input_buffer()
    port.write((line + "\n").encode())
    end = time.time() + timeout
    while time.time() < end:
        text = port.readline().decode(errors="replace").strip()
        if text.startswith("0 "):
            return text[2:]
    raise TimeoutError(line)


def open_port(name: str | None) -> serial.Serial:
    names = [name] if name else sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    if not names:
        raise SystemExit("no board found (looked for /dev/cu.usbmodem* and /dev/ttyACM*); plug it into this Mac")
    if len(names) > 1:
        raise SystemExit(f"several ports, pick one with --port: {' '.join(names)}")
    return serial.Serial(names[0], 115200, timeout=0.3)


def show(port: serial.Serial) -> None:
    s = json.loads(ask(port, "0 status"))
    if "hidm" not in s:
        raise SystemExit(f"firmware {s.get('fw')} is not a --dual-hid build (no hidm in its status)")
    fields = {k: s.get(k) for k in ("fw", "hidm", "hid", "usb", "board")}
    print("status:", ", ".join(f"{k} {v}" for k, v in fields.items() if v is not None))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", nargs="?", choices=["usb", "ble"])
    ap.add_argument("--port")
    a = ap.parse_args()
    port = open_port(a.port)
    show(port)
    if not a.mode:
        return
    print("board:", ask(port, f"0 hidmode {a.mode}"))
    port.close()
    # The board restarts and its USB serial comes back, maybe under another name.
    time.sleep(4)
    for _ in range(20):
        try:
            port = open_port(a.port)
            show(port)
            return
        except (serial.SerialException, OSError, TimeoutError, SystemExit):
            time.sleep(1)
    raise SystemExit("the board did not come back on USB serial within 25 s")


if __name__ == "__main__":
    main()
