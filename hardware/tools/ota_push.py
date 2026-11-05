# /// script
# requires-python = ">=3.10"
# dependencies = ["pyserial>=3.5"]
# ///
"""Push a firmware image to the board over Wi-Fi, as the app's Update Board does (TCP 7300, see ota.h).

    uv run hardware/tools/ota_push.py --serial /dev/cu.usbmodem… hardware/build/hid_bridge.ino.bin
    uv run hardware/tools/ota_push.py --serial … --join FILE      # first join the board's hotspot (macOS, en0)
    uv run hardware/tools/ota_push.py --serial … --corrupt FILE   # one flipped byte: expect "err", no reboot

The token and the board's address come from `0 netinfo` on the USB serial; the Mac must reach that address
(on the board's hotspot, or the same Wi-Fi with a --sta build). Passwords are never printed.
"""
import argparse
import hashlib
import json
import socket
import subprocess
import time
from pathlib import Path

import serial

from usb_ota_image import is_usb_app


def ask(port: serial.Serial, line: str, timeout: float = 3) -> str:
    port.reset_input_buffer()
    port.write((line + "\n").encode())
    end = time.time() + timeout
    while time.time() < end:
        text = port.readline().decode(errors="replace").strip()
        if text.startswith("0 "):
            return text[2:]
    raise TimeoutError(line)


def status(port: serial.Serial, timeout: float = 3) -> dict:
    return json.loads(ask(port, "0 status", timeout))


def push(host: str, token: str, image: bytes, md5: str) -> str:
    started = time.time()
    with socket.create_connection((host, 7300), timeout=10) as c:
        f = c.makefile("rb")
        c.sendall(f"ota {token} {len(image)} {md5}\n".encode())
        head = f.readline().decode().strip()
        if head != "ok":
            return head
        c.sendall(image)
        tail = f.readline().decode().strip()
    secs = time.time() - started
    print(f"sent {len(image)} bytes in {secs:.1f} s ({len(image) * 8 / secs / 1000:.0f} kbps)")
    return tail


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("image", type=Path)
    ap.add_argument("--serial", required=True)
    ap.add_argument("--join", action="store_true", help="join the board's hotspot first (macOS en0)")
    ap.add_argument("--corrupt", action="store_true", help="flip one byte after computing the MD5")
    ap.add_argument("--token", help="use this token instead of the board's (expect err wrong token)")
    a = ap.parse_args()

    image = bytearray(a.image.read_bytes())
    if not is_usb_app(image):
        ap.error("此 OTA 工具仅接受 8 MiB USB 板的 ESP32-S3 应用镜像。")
    port = serial.Serial(a.serial, 115200, timeout=0.3)
    before = status(port)
    if before.get("board") == "note4":
        ap.error("Note 4 不支持此 OTA 通道。")
    net = json.loads(ask(port, "0 netinfo"))
    print(f"board fw {before.get('fw', 1)}, net {net.get('mode')} {net.get('ssid')} {net.get('ip')}")
    if a.join:
        subprocess.run(["networksetup", "-setairportnetwork", "en0", net["ssid"], net["pass"]], check=True)
        time.sleep(5)

    md5 = hashlib.md5(image).hexdigest()
    if a.corrupt:
        image[len(image) // 2] ^= 0xFF
    answer = push(net["ip"], a.token or net["vtok"], bytes(image), md5)
    print("board:", answer)
    if answer != "done":
        print("board still up:", status(port).get("up") is not None)
        return
    port.close()
    time.sleep(4)  # reboot; USB serial re-enumerates
    for _ in range(40):
        try:
            port = serial.Serial(a.serial, 115200, timeout=0.3)
            after = status(port, 2)
            print(f"after reboot: fw {after.get('fw', 1)}, reset {after.get('rst')}, up {after.get('up')} ms")
            return
        except (serial.SerialException, TimeoutError, OSError, json.JSONDecodeError):
            time.sleep(1)
    print("board did not answer on serial after the update")


if __name__ == "__main__":
    main()
