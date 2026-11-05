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
    uv run harness/board.py net sta --serial /dev/cu.usbmodem…   # the board plugged into this Mac: no BLE pairing

Wi-Fi passwords are sent over the encrypted link (or the USB cable) only; they are never printed.
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


class BleLink:
    def __init__(self, b: Board):
        self.b = b

    async def net(self) -> dict:
        return json.loads(await self.b.c.read_gatt_char(NET))

    async def status(self) -> dict:
        return json.loads(await self.b.c.read_gatt_char(STATUS))

    async def write_net(self, request: dict):
        await self.b.c.write_gatt_char(NET, json.dumps(request).encode(), response=True)

    async def close(self):
        if self.b.c.is_connected:
            await self.b.c.disconnect()


class SerialLink:
    """The board on this Mac's USB: `0 netinfo`, `0 status`, `0 net <json>` (hid_bridge.ino)."""

    def __init__(self, port: str):
        import serial
        self.port = serial.Serial(port, 115200, timeout=0.3)

    def _ask(self, line: str) -> dict:
        self.port.reset_input_buffer()
        self.port.write((line + "\n").encode())
        end = time.monotonic() + 3
        while time.monotonic() < end:
            text = self.port.readline().decode(errors="replace").strip()
            if text.startswith("0 {"):
                return json.loads(text[2:])
        raise TimeoutError(line)

    async def net(self) -> dict:
        return self._ask("0 netinfo")

    async def status(self) -> dict:
        return self._ask("0 status")

    async def write_net(self, request: dict):
        self.port.write(("0 net " + json.dumps(request) + "\n").encode())

    async def close(self):
        self.port.close()


def summary(st: dict, net: dict) -> str:
    return (f"fw {st.get('fw')} up {st.get('up', 0) // 1000} s rst {st.get('rst')} ble {st.get('ble')} "
            f"net {net.get('mode')} {net.get('ssid') or ''} {net.get('ip') or ''}".strip())


async def connect(scan: float) -> BleLink:
    client = BleakClient(await find_board(scan), timeout=20)
    await client.connect()
    await client.read_gatt_char(NET)  # encrypted: the first time, macOS asks to pair (board: 3 min after power-on)
    b = Board(client)
    await b.start()
    return BleLink(b)


def has_ip(net: dict) -> bool:
    return (net.get("ip") or "0.0.0.0") != "0.0.0.0"


async def wait_net(link, mode: str, seconds: float = 30) -> dict:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        net = await link.net()
        if net.get("mode") == mode and (mode != "sta" or has_ip(net)):
            return net
        await asyncio.sleep(1)
    return await link.net()


async def cmd_net(link, mode: str):
    if mode == "sta":
        ssid = dialog("Wi-Fi the board should join (same as this Mac and the iPhone):", mac_ssid())
        password = dialog(f"Password for {ssid}:", hidden=True)
        request = {"mode": "sta", "ssid": ssid, "pass": password}
    else:
        request = {"mode": "ap"}
    await link.write_net(request)
    net = await wait_net(link, mode)
    print("board:", summary(await link.status(), net))
    if net.get("mode") != mode or (mode == "sta" and not has_ip(net)):
        sys.exit("the board did not get there (wrong password? out of range?)")


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["status", "net"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--scan", type=float, default=15)
    ap.add_argument("--serial", help="the board's USB serial port on this Mac (instead of BLE)")
    a = ap.parse_args()
    if a.what == "net" and a.args[:1] not in (["sta"], ["ap"]):
        sys.exit("net sta | net ap")
    link = SerialLink(a.serial) if a.serial else await connect(a.scan)
    try:
        if a.what == "status":
            print(summary(await link.status(), await link.net()))
        elif a.what == "net":
            await cmd_net(link, a.args[0])
    finally:
        await link.close()


if __name__ == "__main__":
    asyncio.run(main())
