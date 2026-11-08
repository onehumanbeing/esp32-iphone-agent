"""Identify 8 MiB ESP32-S3 application images for the upstream USB OTA channel."""


def is_usb_app(image: bytes) -> bool:
    # The app descriptor magic follows the image and 8-byte segment headers. Reject bootloaders and full-flash backups.
    if not (len(image) >= 304 and image[0] == 0xE9 and image[3] >> 4 == 3
            and image[12:14] == b"\x09\x00" and image[32:36] == b"\x32\x54\xcd\xab"):
        return False
    if image[288:293] == b"ESPA:":
        return image[288:304] == b"ESPA:usb-8m".ljust(16, b"\0")
    # Allow unmarked legacy USB releases, but never treat an unknown marked target as legacy.
    return image[80:112] == b"arduino-lib-builder".ljust(32, b"\0")
