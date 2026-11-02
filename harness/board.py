# /// script
# requires-python = ">=3.10"
# dependencies = ["bleak>=0.22", "pyserial>=3.5"]
# ///
"""One-time harness setup from the Mac over BLE: put the board on the Mac's Wi-Fi (or back on its hotspot).
Quit the app on the iPhone first: the Mac can't reach the board while the app is connected. Everything after
this goes through the app (harness/fw.sh, run.sh).

    uv run harness/board.py status
    uv run harness/board.py net sta            # join the Mac's Wi-Fi; SSID and password asked in a macOS dialog
    uv run harness/board.py net ap             # back to the board's own hotspot

Wi-Fi passwords are sent over the encrypted link only; they are never printed.
"""
import argparse
import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hardware" / "tools"))
from bleak import BleakClient  # noqa: E402
from board_test import NET, STATUS, Board, find_board  # noqa: E402


def dialog(prompt: str, default: str = "", hidden: bool = False) -> str:
    """A macOS dialog, so a password is typed by the user and never passes through a terminal or a log."""
    script = (f'text returned of (display dialog {json.dumps(prompt)} default answer {json.dumps(default)}'
              f'{" with hidden answer" if hidden else ""} with title "ESP32 Agent harness")')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("cancelled")
    return r.stdout.rstrip("\n")


def mac_ssid() -> str:
    r = subprocess.run(["ipconfig", "getsummary", "en0"], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.strip().startswith("SSID :"):
            ssid = line.split(":", 1)[1].strip()
            return "" if ssid == "<redacted>" else ssid
    return ""


async def raw_net(b: Board) -> dict:
    return json.loads(await b.c.read_gatt_char(NET))


async def status(b: Board) -> dict:
    return json.loads(await b.c.read_gatt_char(STATUS))


def summary(st: dict, net: dict) -> str:
    return (f"fw {st.get('fw')} up {st.get('up', 0) // 1000} s rst {st.get('rst')} ble {st.get('ble')} "
            f"net {net.get('mode')} {net.get('ssid') or ''} {net.get('ip') or ''}".strip())


async def connect(scan: float):
    client = BleakClient(await find_board(scan), timeout=20)
    await client.connect()
    await client.read_gatt_char(NET)  # encrypted: the first time, macOS asks to pair (board: 3 min after power-on)
    b = Board(client)
    await b.start()
    return b


async def wait_net(b: Board, mode: str, seconds: float = 30) -> dict:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        net = await raw_net(b)
        if net.get("mode") == mode and (mode != "sta" or net.get("ip")):
            return net
        await asyncio.sleep(1)
    return await raw_net(b)


async def cmd_net(b: Board, mode: str):
    if mode == "sta":
        ssid = dialog("Wi-Fi the board should join (same as this Mac and the iPhone):", mac_ssid())
        password = dialog(f"Password for {ssid}:", hidden=True)
        request = {"mode": "sta", "ssid": ssid, "pass": password}
    else:
        request = {"mode": "ap"}
    await b.c.write_gatt_char(NET, json.dumps(request).encode(), response=True)
    net = await wait_net(b, mode)
    print("board:", summary(await status(b), net))
    if net.get("mode") != mode or (mode == "sta" and not net.get("ip")):
        sys.exit("the board did not get there (wrong password? out of range?)")



async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["status", "net"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--scan", type=float, default=15)
    a = ap.parse_args()
    if a.what == "net" and a.args[:1] not in (["sta"], ["ap"]):
        sys.exit("net sta | net ap")
    b = await connect(a.scan)
    try:
        if a.what == "status":
            print(summary(await status(b), await raw_net(b)))
        elif a.what == "net":
            await cmd_net(b, a.args[0])
    finally:
        if b.c.is_connected:
            await b.c.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
