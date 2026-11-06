"""确认板型与输入传输分别选择，构建产物隔离，蓝牙目标不会误刷 USB 固件。"""
import os
from pathlib import Path
import subprocess
import tempfile
import sys

hardware = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(hardware / "tools"))
from usb_ota_image import is_usb_app

flash = hardware / "flash.sh"
with tempfile.TemporaryDirectory() as directory:
    cli = Path(directory) / "arduino-cli"
    cli.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
    cli.chmod(0o755)
    for options in ([], ["--ble-hid"], ["--note4"], ["--debug", "--note4"],
                    ["--ble-hid", "--note4"], ["--note4", "--ble-hid"]):
        note4 = "--note4" in options
        ble = note4 or "--ble-hid" in options
        size = "16M" if note4 else "8M"
        result = subprocess.run(
            ["bash", str(flash), *options, "--build-only"],
            env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
            capture_output=True, text=True, check=True,
        )
        arguments = result.stdout.splitlines()
        assert arguments.count("compile") == 1 and "upload" not in arguments
        partition = "app3M_fat9M_16MB" if size == "16M" else "default_8MB"
        assert f"FlashSize={size},PSRAM=opi,PartitionScheme={partition}" in arguments[2]
        assert arguments[2].startswith("esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,")
        assert "-include " in result.stdout and "nimble_cfg.h" in result.stdout
        assert ("-DZECTRIX_NOTE4=1" in result.stdout) == ("--note4" in options)
        assert ("-DHID_TRANSPORT_BLE=1" in result.stdout) == ble
        assert ("-DDEBUG_SERIAL=1" in result.stdout) == ("--debug" in options)
        assert arguments[arguments.index("--output-dir") + 1] == ("build/note4" if note4 else "build/ble-hid" if ble else "build")
    for args in [["--note4"], ["--ble-hid"], ["--note-4", "--build-only"]]:
        refused = subprocess.run(["bash", str(flash), *args], capture_output=True,
                                 env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]})
        assert refused.returncode != 0 and b"compile" not in refused.stdout and b"upload" not in refused.stdout

image = bytearray(304)
image[0], image[3], image[12] = 0xe9, 0x3f, 9
image[32:36] = bytes.fromhex("3254cdab")
image[80:112] = b"arduino-lib-builder".ljust(32, b"\0")
assert is_usb_app(image)
image[80] = ord("X")
assert not is_usb_app(image)
image[80] = ord("a")
image[288:304] = b"ESPA:usb-8m".ljust(16, b"\0")
assert is_usb_app(image)
for target in (b"ESPA:ble-8m", b"ESPA:note4-ble", b"ESPA:unknown", b"ESPA:"):
    image[288:304] = target.ljust(16, b"\0")
    assert not is_usb_app(image)
assert not is_usb_app(image[:300])
image[288:304] = b"ESPA:usb-8m".ljust(16, b"\0")
image[3] = 0x4f
assert not is_usb_app(image)
assert not is_usb_app(image[:12])
image[3], image[32] = 0x3f, 0
assert not is_usb_app(image)
print("板型构建隔离、禁止自动刷写与 OTA 镜像识别检查通过")

if "--built-images" in sys.argv:
    for directory, target in (("", b"ESPA:usb-8m"), ("ble-hid", b"ESPA:ble-8m"), ("note4", b"ESPA:note4-ble")):
        for suffix in ("bin", "bootloader.bin", "merged.bin"):
            path = hardware / "build" / directory / f"hid_bridge.ino.{suffix}"
            data = path.read_bytes()
            if suffix == "bin":
                assert data[288:304] == target.ljust(16, b"\0"), path
            assert is_usb_app(data) == (directory == "" and suffix == "bin"), path
    print("三目标九个实际镜像的目标标记与 USB OTA 识别检查通过")
