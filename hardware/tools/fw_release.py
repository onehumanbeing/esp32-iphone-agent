# /// script
# requires-python = ">=3.10"
# dependencies = ["cryptography>=42"]
# ///
"""Package a firmware build for the app's Update Board: a signed firmware.json next to the image.

    hardware/flash.sh --build-only
    uv run hardware/tools/fw_release.py          # -> hardware/dist/v<version>/{firmware.json, hid_bridge-<version>.bin}
    hardware/flash.sh --stopwatch --build-only
    uv run hardware/tools/fw_release.py --target stopwatch   # -> hardware/dist/v<version>/stopwatch/...

The version is FW_VERSION in hid_bridge/version.h; the board reports it as `fw` in its status. Publish the two
files at manina.ai/firmware/ (the only source the app reads; a StopWatch release at manina.ai/firmware/stopwatch/); tag the source commit v<version>.
The signing key stays on the release machine (~/.config/esp32agent/firmware-signing.pem); the app only trusts its public key (Firmware.swift).
"""
import argparse
import base64
import hashlib
import json
import re
from pathlib import Path

from cryptography.hazmat.primitives import serialization

from usb_ota_image import TARGETS, is_ota_app

HW = Path(__file__).resolve().parent.parent
KEY = Path.home() / ".config/esp32agent/firmware-signing.pem"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="usb-8m", choices=sorted(TARGETS),
                    help="the release channel: usb-8m (firmware.json) or stopwatch (stopwatch/firmware.json, signed with its target)")
    ap.add_argument("--bin", type=Path)
    ap.add_argument("--notes", default="")
    ap.add_argument("--min-app", help="the oldest app version that may install it, e.g. 1.0.7 (older apps ask to update)")
    ap.add_argument("--version", help="override FW_VERSION (the --crash-test build is 9.9.9)")
    ap.add_argument("--out", type=Path, default=HW / "dist")
    a = ap.parse_args()

    version = a.version or re.search(r'#define FW_VERSION "([0-9.]+)"\n#endif', (HW / "hid_bridge/version.h").read_text()).group(1)
    usb = a.target == "usb-8m"
    image = (a.bin or HW / ("build/hid_bridge.ino.bin" if usb else f"build/{a.target}/hid_bridge.ino.bin")).read_bytes()
    if not is_ota_app(image, a.target):
        ap.error(f"Not an ESP32-S3 application image for the {a.target} channel.")
    name = f"hid_bridge-{version}.bin"
    r = {"version": version, "size": len(image), "sha256": hashlib.sha256(image).hexdigest(),
         "md5": hashlib.md5(image).hexdigest(), "url": name}
    signed = f"esp32agent-firmware\nversion={version}\nsize={r['size']}\nsha256={r['sha256']}\nmd5={r['md5']}"
    if not usb:  # another board's channel: its target is signed too, so a release can't be moved to another board
        r["target"] = a.target
        signed += f"\ntarget={a.target}"
    signed = signed.encode()
    key = serialization.load_pem_private_key(KEY.read_bytes(), password=None)
    r["sig"] = base64.b64encode(key.sign(signed)).decode()
    if a.notes:
        r["notes"] = a.notes
    if a.min_app:  # unsigned on purpose: it can only hold an update back, never let another image in
        r["min_app"] = a.min_app

    out = a.out / f"v{version}" / ("" if usb else a.target)
    out.mkdir(parents=True, exist_ok=True)
    (out / name).write_bytes(image)
    (out / "firmware.json").write_text(json.dumps(r, indent=2) + "\n")
    print(f"fw v{version}: {len(image)} bytes -> {out}")


if __name__ == "__main__":
    main()
