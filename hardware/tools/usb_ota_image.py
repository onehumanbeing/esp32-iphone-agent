"""检查上游 OTA 发布通道的 8 MiB ESP32-S3 应用镜像。"""


def is_usb_app(image: bytes) -> bool:
    # ESP 镜像头后是 8 字节段头，再跟应用描述魔数；引导程序和整片备份不能用于 OTA。
    return (len(image) >= 36 and image[0] == 0xE9 and image[3] >> 4 == 3
            and image[12:14] == b"\x09\x00" and image[32:36] == b"\x32\x54\xcd\xab")
