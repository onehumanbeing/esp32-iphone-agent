"""确认仅构建模式不会刷机，且 NOTE4 不会误用 XIAO 的 Flash 配置。"""
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
    for options, size in (([], "8M"), (["--note4"], "16M"), (["--debug", "--note4"], "16M")):
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
        assert ("-DDEBUG_SERIAL=1" in result.stdout) == ("--debug" in options)
        assert arguments[arguments.index("--output-dir") + 1] == ("build/note4" if size == "16M" else "build")
    for args in [["--note4"], ["--note-4", "--build-only"]]:
        refused = subprocess.run(["bash", str(flash), *args], capture_output=True,
                                 env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]})
        assert refused.returncode != 0 and b"compile" not in refused.stdout and b"upload" not in refused.stdout

image = bytearray(36)
image[0], image[3], image[12] = 0xe9, 0x3f, 9
image[32:] = bytes.fromhex("3254cdab")
assert is_usb_app(image)
image[3] = 0x4f
assert not is_usb_app(image)
assert not is_usb_app(image[:12])
image[3], image[32] = 0x3f, 0
assert not is_usb_app(image)
print("板型构建隔离、禁止自动刷写与 OTA 镜像识别检查通过")
