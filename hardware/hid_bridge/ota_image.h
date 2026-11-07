#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

// 24 字节 ESP 镜像头和 8 字节段头之后是应用描述。引导程序或整片镜像不能写入应用槽。
constexpr size_t USB_APP_PREFIX_SIZE = 304;
inline bool usb_ota_app(const uint8_t *p, size_t n) {
  if (n < USB_APP_PREFIX_SIZE || p[0] != 0xe9 || (p[3] >> 4) != 3 ||
      p[12] != 9 || p[13] != 0 || p[32] != 0x32 || p[33] != 0x54 || p[34] != 0xcd || p[35] != 0xab) return false;
  const char usb[16] = "ESPA:usb-8m";
  if (memcmp(p + 288, "ESPA:", 5) == 0) return memcmp(p + 288, usb, sizeof usb) == 0;
  // 保留既有 Arduino USB 发布镜像；新目标带标记后不能退回旧格式判断。
  const char legacy[32] = "arduino-lib-builder";
  return memcmp(p + 80, legacy, sizeof legacy) == 0;
}
