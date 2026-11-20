"""Check board and transport selection, separate build outputs and build-only BLE targets."""
import os
from pathlib import Path
import subprocess
import tempfile
import sys

hardware = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(hardware / "tools"))
from usb_ota_image import is_ota_app, is_usb_app

flash = hardware / "flash.sh"
with tempfile.TemporaryDirectory() as directory:
    cli = Path(directory) / "arduino-cli"
    cli.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
    cli.chmod(0o755)
    for options in ([], ["--abs"], ["--ble-hid"], ["--note4"], ["--debug", "--note4"], ["--name", "Lab1", "--ble-hid"],
                    ["--ble-hid", "--note4"], ["--note4", "--ble-hid"], ["--stopwatch"], ["--ble-hid", "--stopwatch"],
                    ["--debug", "--stopwatch"]):
        note4 = "--note4" in options
        stopwatch = "--stopwatch" in options
        ble = note4 or stopwatch or "--ble-hid" in options
        size = "16M" if note4 or stopwatch else "8M"
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
        assert ("-DM5_STOPWATCH=1" in result.stdout) == stopwatch
        assert ("-DHID_TRANSPORT_BLE=1" in result.stdout) == ble
        assert ("-DBOARD_NAME=Lab1" in result.stdout) == ("--name" in options)
        assert ("-DABS_POINTER=1" in result.stdout) == ("--abs" in options)
        assert ("-DDEBUG_SERIAL=1" in result.stdout) == ("--debug" in options)
        output = "build/note4" if note4 else "build/stopwatch" if stopwatch else "build/ble-hid" if ble else "build"
        assert arguments[arguments.index("--output-dir") + 1] == output
    for target in ("--ble-hid", "--note4", "--stopwatch"):
        for flags in (["--abs", target], [target, "--abs"]):
            refused = subprocess.run([str(flash), *flags, "--build-only"], capture_output=True,
                                     env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]})
            assert refused.returncode != 0 and b"--abs requires USB HID" in refused.stderr and not refused.stdout
    env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]}
    # --dual-hid: one standard 8 MB image with both transports; flashed like the USB build, never mixed
    dual = subprocess.run(["bash", str(flash), "--dual-hid", "--build-only"], env=env, capture_output=True,
                          text=True, check=True)
    args = dual.stdout.splitlines()
    assert "-DHID_DUAL=1" in dual.stdout and "-DHID_TRANSPORT_BLE=1" in dual.stdout
    assert "FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB" in args[2]
    assert args[args.index("--output-dir") + 1] == "build/dual-hid"
    for other in ("--ble-hid", "--note4", "--stopwatch", "--abs"):
        refused = subprocess.run(["bash", str(flash), "--dual-hid", other, "--build-only"], env=env, capture_output=True)
        assert refused.returncode != 0 and b"--dual-hid is its own target" in refused.stderr and not refused.stdout
    for flags in (["--note4", "--stopwatch"], ["--stopwatch", "--note4"]):
        refused = subprocess.run(["bash", str(flash), *flags, "--build-only"], env=env, capture_output=True)
        assert refused.returncode != 0 and b"different boards" in refused.stderr and not refused.stdout
    for args in [["--note4"], ["--ble-hid"], ["--stopwatch"], ["--stopwatch", "/dev/cu.usbmodem1"], ["--note-4", "--build-only"]]:
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
for target in (b"ESPA:ble-8m", b"ESPA:note4-ble", b"ESPA:dual-8m", b"ESPA:stopwatch", b"ESPA:unknown", b"ESPA:"):
    image[288:304] = target.ljust(16, b"\0")
    assert not is_usb_app(image)
assert not is_usb_app(image[:300])
image[288:304] = b"ESPA:usb-8m".ljust(16, b"\0")
image[3] = 0x4f
assert not is_usb_app(image)
assert not is_usb_app(image[:12])
image[3], image[32] = 0x3f, 0
assert not is_usb_app(image)
image[32] = 0x32
image[288:304] = b"ESPA:stopwatch".ljust(16, b"\0")
assert not is_ota_app(image, "stopwatch")  # 8 MiB header: not the StopWatch's
image[3] = 0x4f
assert is_ota_app(image, "stopwatch") and not is_usb_app(image) and not is_ota_app(image, "usb-8m")
assert not is_ota_app(image, "note4-ble") and not is_ota_app(image, "unknown")
image[288:304] = b"ESPA:note4-ble".ljust(16, b"\0")
assert not is_ota_app(image, "stopwatch")
print("Build target isolation, flash safeguards and OTA image checks passed")

if "--built-images" in sys.argv:
    for directory, target in (("", b"ESPA:usb-8m"), ("ble-hid", b"ESPA:ble-8m"), ("note4", b"ESPA:note4-ble")):
        for suffix in ("bin", "bootloader.bin", "merged.bin"):
            path = hardware / "build" / directory / f"hid_bridge.ino.{suffix}"
            data = path.read_bytes()
            if suffix == "bin":
                assert data[288:304] == target.ljust(16, b"\0"), path
            assert is_usb_app(data) == (directory == "" and suffix == "bin"), path
    print("Target marker and USB OTA checks passed for all nine images across three targets")
    dual = hardware / "build/dual-hid/hid_bridge.ino.bin"
    if dual.exists():  # flash.sh --dual-hid --build-only
        data = dual.read_bytes()
        assert data[288:304] == b"ESPA:dual-8m".ljust(16, b"\0") and not is_usb_app(data), dual
        print("Dual-HID image carries its own marker and is refused by the USB OTA channel")
    stopwatch = hardware / "build/stopwatch/hid_bridge.ino.bin"
    if stopwatch.exists():  # flash.sh --stopwatch --build-only
        data = stopwatch.read_bytes()
        assert data[288:304] == b"ESPA:stopwatch".ljust(16, b"\0") and not is_usb_app(data), stopwatch
        assert is_ota_app(data, "stopwatch"), stopwatch
        print("StopWatch image carries its own marker: refused by the USB OTA channel, taken by its own")
