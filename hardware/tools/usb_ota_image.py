"""检查上游 OTA 发布通道的 8 MiB ESP32-S3 应用镜像。"""


def is_usb_app(image: bytes) -> bool:
    # ESP 镜像头后是 8 字节段头，再跟应用描述魔数；引导程序和整片备份不能用于 OTA。
    if not (len(image) >= 304 and image[0] == 0xE9 and image[3] >> 4 == 3
            and image[12:14] == b"\x09\x00" and image[32:36] == b"\x32\x54\xcd\xab"):
        return False
    if image[288:293] == b"ESPA:":
        return image[288:304] == b"ESPA:usb-8m".ljust(16, b"\0")
    # 未加标记的既有 USB 发布版仍可更新；未知的新目标不能降级成旧格式。
    return image[80:112] == b"arduino-lib-builder".ljust(32, b"\0")
