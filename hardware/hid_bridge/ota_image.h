#pragma once
#include <cstddef>
#include <cstdint>

// 24 字节 ESP 镜像头和 8 字节段头之后是应用描述。引导程序或整片镜像不能写入应用槽。
constexpr size_t USB_APP_PREFIX_SIZE = 36;
inline bool usb_ota_app(const uint8_t *p, size_t n) {
  return n >= USB_APP_PREFIX_SIZE && p[0] == 0xe9 && (p[3] >> 4) == 3 &&
         p[12] == 9 && p[13] == 0 && p[32] == 0x32 && p[33] == 0x54 && p[34] == 0xcd && p[35] == 0xab;
}
