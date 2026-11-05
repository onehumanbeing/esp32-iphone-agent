#include "../hid_bridge/hid_keys.h"
#include "../hid_bridge/note4_battery.h"
#include "../hid_bridge/note4_hid_target.h"
#include "../hid_bridge/ota_image.h"
#include <cassert>
#include <cstring>
#include <cstdio>

int main() {
  uint8_t layout[128] = {}, report[8] = {};
  layout['h'] = 0x0b;
  layout['H'] = 0x8b;
  assert(hid_key_press(report, 0x83, layout));
  assert(hid_key_press(report, 'h', layout));
  assert(report[0] == 8 && report[2] == 0x0b);
  assert(hid_key_press(report, 'h', layout) && report[3] == 0);
  memset(report, 0, sizeof report);
  assert(hid_key_press(report, 'H', layout));
  assert(report[0] == 2 && report[2] == 0x0b);
  memset(report, 0, sizeof report);
  assert(hid_key_press(report, 0xb0, layout) && report[2] == 0x28);
  for (int i = 0; i < 8; i++) report[i] = i;
  uint8_t before[8];
  memcpy(before, report, sizeof report);
  assert(!hid_key_press(report, 0, layout));
  assert(memcmp(before, report, sizeof report) == 0);
  assert(!hid_key_press(report, 0xc2, layout));
  assert(memcmp(before, report, sizeof report) == 0);
  puts("蓝牙 HID 键码、修饰键、六键容量及错误状态检查通过");
  assert(note4_battery_percent(0) == 0);
  assert(note4_battery_percent(3300) == 0);
  assert(note4_battery_percent(3700) == 48);
  assert(note4_battery_percent(4200) == 100);
  assert(note4_battery_percent(65535) == 100);
  puts("电池电压估算范围检查通过");
  Note4HidTarget target;
  assert(!target.allows(1, false));
  assert(!target.subscribe(2, false, true));  // 未获认证的订阅者不能占用目标。
  assert(!target.subscribe(1, true, false));  // 已认证但尚未订阅也不能收取 HID。
  assert(target.subscribe(1, true, true));    // 订阅与认证以任意顺序到达，缺一不可。
  const auto first = target.session();
  assert(target.allows(1, true));
  assert(!target.allows(1, false));
  assert(!target.allows(2, true));  // 即使已配对，第二个中心连接也不能控制第一台手机。
  assert(!target.subscribe(2, true, true));
  target.disconnect(2);
  assert(target.session() == first);
  target.disconnect(1);
  assert(Note4HidTarget::peer(target.session()) == -1);
  assert(target.subscribe(1, true, true) && target.session() != first);  // 重连后丢弃旧队列命令。
  puts("蓝牙输入目标、其他写入者拒绝和断线重连检查通过");
  uint8_t header[USB_APP_PREFIX_SIZE] = {0xe9, 6, 2, 0x3f};
  header[12] = 9;
  memcpy(header + 32, "\x32\x54\xcd\xab", 4);
  assert(usb_ota_app(header, sizeof header));
  assert(!usb_ota_app(header, sizeof header - 1));
  header[3] = 0x4f;
  assert(!usb_ota_app(header, sizeof header));  // 拒绝 16 MiB Note 4 镜像。
  header[3] = 0x3f;
  header[32] = 0;
  assert(!usb_ota_app(header, sizeof header));  // 拒绝引导程序和整片镜像。
}
