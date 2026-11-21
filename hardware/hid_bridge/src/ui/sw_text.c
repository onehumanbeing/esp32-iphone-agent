#include "sw_text.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it

static const char *const TEXT[SW_LANGS][SWT_COUNT] = {
    [SW_EN] = {
        [SWT_BATTERY] = "Battery ", [SWT_BATTERY_NONE] = "Battery --",
        [SWT_BT_ON] = "Bluetooth: phone linked", [SWT_BT_OFF] = "Bluetooth: not linked",
        [SWT_PAIR_HINT] = "Hold blue: pair a phone", [SWT_PAIRING] = "Pairing - %u:%02u",
        [SWT_BT_CONNECTING] = "Bluetooth: connecting...", [SWT_WIFI_ON] = "Wi-Fi: phone joined", [SWT_WIFI_OFF] = "Wi-Fi: no phone",
        [SWT_MIRROR_ON] = "Screen Mirroring on", [SWT_MIRROR_WAIT] = "Mirroring: starting...", [SWT_MIRROR_OFF] = "Screen Mirroring off",
        [SWT_DOT_BT] = "Bluetooth", [SWT_DOT_WIFI] = "Wi-Fi", [SWT_DOT_MIRROR] = "Mirroring",
        [SWT_PAIR_TITLE] = "Pairing", [SWT_PAIR_HOW] = "Open Manina AI on the iPhone and pick", [SWT_PAIR_LEFT] = "%u:%02u left", [SWT_PAIR_KEYS] = "Yellow: cancel  Blue: back",
        [SWT_APP_ON] = "App connected", [SWT_APP_OFF] = "App not connected",
        [SWT_FIRMWARE] = "Firmware ", [SWT_LANGUAGE] = "Language: English",
        [SWT_PAUSED] = "Paused - yellow resumes", [SWT_HELP] = "Needs your help",
        [SWT_HELP_HINT] = "Tap to go on - swipe up to take over", [SWT_DONE] = "Done", [SWT_NOT_DONE] = "Not done",
        [SWT_STUCK] = "iOS paused the app - open it to go on",
        [SWT_CONFIRM] = "Send it?", [SWT_CONFIRM_HINT] = "Yellow again to send",
        [SWT_SHAKE] = "Shake to stop?", [SWT_SHAKE_HINT] = "Any button cancels", [SWT_RELEASE_CANCELS] = "Release to cancel",
        [SWT_LISTENING] = "Listening...", [SWT_LISTEN_HINT] = "Release when done - blue cancels",
        [SWT_TRANSCRIBING] = "Transcribing...", [SWT_RUN_HINT] = "Yellow: run - Blue: cancel",
        [SWT_TELL_HINT] = "Yellow: tell the task - Blue: cancel", [SWT_SENT] = "Sent",
        [SWT_ERR_NONE] = "Didn't catch that", [SWT_ERR_DENIED] = "Allow Speech Recognition in the app",
        [SWT_ERR_UNAVAILABLE] = "Speech recognition isn't available", [SWT_ERR_START] = "The task didn't start",
        [SWT_ERR_TIMEOUT] = "No answer from the app", [SWT_ERR_OTHER] = "Something went wrong",
        [SWT_TOTAL] = "%d steps - %s", [SWT_CONFIRM_STEP] = "OK to go on?", [SWT_HELP_KEYS] = "Yellow: go on - Blue: stop",
        [SWT_CONFIRM_KEYS] = "Yellow: go on - Blue: skip", [SWT_TAKEOVER_HINT] = "Swipe up to take over",
        [SWT_CHARGING] = "Charging %u%%", [SWT_LOW_BATTERY] = "Battery low %u%% - charge me",
        [SWT_W_MIRROR] = "Screen Mirroring stopped", [SWT_W_MIRROR_FIX] = "iPhone Control Center > Screen Mirroring, pick",
        [SWT_W_LOCKED] = "iPhone is locked", [SWT_W_LOCKED_FIX] = "Unlock it and the task goes on",
        [SWT_W_HID] = "Bluetooth lost", [SWT_W_HID_FIX] = "iPhone Settings > Bluetooth, connect",
        [SWT_W_HIDE] = "Blue: hide",
    },
    [SW_ZH] = {
        [SWT_BATTERY] = "电量 ", [SWT_BATTERY_NONE] = "电量 --",
        [SWT_BT_ON] = "蓝牙 已连接手机", [SWT_BT_OFF] = "蓝牙 未连接",
        [SWT_PAIR_HINT] = "长按蓝键 配对手机", [SWT_PAIRING] = "配对中 %u:%02u",
        [SWT_BT_CONNECTING] = "蓝牙 连接中...", [SWT_WIFI_ON] = "Wi-Fi 手机已连上", [SWT_WIFI_OFF] = "Wi-Fi 手机未连",
        [SWT_MIRROR_ON] = "投屏 已开启", [SWT_MIRROR_WAIT] = "投屏 连接中...", [SWT_MIRROR_OFF] = "投屏 未开启",
        [SWT_DOT_BT] = "蓝牙", [SWT_DOT_WIFI] = "Wi-Fi", [SWT_DOT_MIRROR] = "投屏",
        [SWT_PAIR_TITLE] = "配对中", [SWT_PAIR_HOW] = "在 iPhone 上打开 Manina AI，选择", [SWT_PAIR_LEFT] = "还剩 %u:%02u", [SWT_PAIR_KEYS] = "黄键取消  蓝键返回",
        [SWT_APP_ON] = "App 已连接", [SWT_APP_OFF] = "App 未连接",
        [SWT_FIRMWARE] = "固件 ", [SWT_LANGUAGE] = "语言 中文",
        [SWT_PAUSED] = "已暂停 · 黄键继续", [SWT_HELP] = "需要你帮忙",
        [SWT_HELP_HINT] = "点屏幕继续 · 上滑接手", [SWT_DONE] = "完成", [SWT_NOT_DONE] = "没有完成",
        [SWT_STUCK] = "App 被 iOS 暂停了 · 打开 App 继续",
        [SWT_CONFIRM] = "确认发送？", [SWT_CONFIRM_HINT] = "再按黄键发送",
        [SWT_SHAKE] = "摇一摇停止?", [SWT_SHAKE_HINT] = "按任意键取消", [SWT_RELEASE_CANCELS] = "松开取消",
        [SWT_LISTENING] = "正在听…", [SWT_LISTEN_HINT] = "说完松开 · 蓝色取消",
        [SWT_TRANSCRIBING] = "正在识别…", [SWT_RUN_HINT] = "黄色执行 · 蓝色取消",
        [SWT_TELL_HINT] = "黄色发给任务 · 蓝色取消", [SWT_SENT] = "已发送",
        [SWT_ERR_NONE] = "没听清", [SWT_ERR_DENIED] = "请在 App 里允许语音识别",
        [SWT_ERR_UNAVAILABLE] = "这台手机不能识别这种语言", [SWT_ERR_START] = "任务没能开始",
        [SWT_ERR_TIMEOUT] = "App 没有回应", [SWT_ERR_OTHER] = "出错了",
        [SWT_TOTAL] = "%d 步 · %s", [SWT_CONFIRM_STEP] = "可以继续吗？", [SWT_HELP_KEYS] = "黄色继续 · 蓝色停止",
        [SWT_CONFIRM_KEYS] = "黄色继续 · 蓝色跳过", [SWT_TAKEOVER_HINT] = "上滑自己接手",
        [SWT_CHARGING] = "充电中 %u%%", [SWT_LOW_BATTERY] = "电量低 %u%% · 请充电",
        [SWT_W_MIRROR] = "屏幕镜像断开了", [SWT_W_MIRROR_FIX] = "在 iPhone 控制中心打开屏幕镜像，选择",
        [SWT_W_LOCKED] = "iPhone 锁屏了", [SWT_W_LOCKED_FIX] = "解锁后任务会继续",
        [SWT_W_HID] = "蓝牙断开了", [SWT_W_HID_FIX] = "在 iPhone 设置 › 蓝牙 里连接",
        [SWT_W_HIDE] = "蓝色关闭",
    },
};

const char *sw_text(int lang, int id) {
  if (id < 0 || id >= SWT_COUNT) return "";
  const char *t = lang > 0 && lang < SW_LANGS ? TEXT[lang][id] : 0;
  return t ? t : TEXT[SW_EN][id] ? TEXT[SW_EN][id] : "";
}

int sw_lang_next(int lang) { return lang >= 0 && lang + 1 < SW_LANGS ? lang + 1 : 0; }

const char *sw_locale(int lang) { return lang == SW_ZH ? "zh-CN" : "en-US"; }
#endif
