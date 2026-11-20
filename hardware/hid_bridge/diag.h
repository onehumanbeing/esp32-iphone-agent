// Periodic `diag` lines while mirroring is up: the radio's share between BLE (app link, and the mouse and keyboard
// on a BLE HID board) and Wi-Fi (AirPlay in, video out to the app), so one app log tells a BLE HID board's video
// stalls from a USB one's. Every 5 s, four lines, each the change over that window unless marked "since boot":
//   diag hid <usb|ble> <ok|off|asleep>: cmd N err N rep N fail N wait N max Nms | ble itvl MS lat N to MS phy N mtu N coex MODE
//   diag ap: au N kb N gap Nms idr Ns +N lost N conn N | wifi <ap|sta|none> ch N rssi DBM sta N
//   diag vlink: wifi <0|1> ch N fail N rec N wmax Nms sdrop N | ble ch N fail N kb N nwait N nmax Nms drop N rdrop N | flip N
//   diag gop: N AUs N KB ovf N fz <0|1> Ns | resync N resume N miss N tb N | fol <0|1> uf <w|r|n|c|g|t|b|->
// To USB serial and the app ("blog", into its debug log) only: four lines every 5 s would push the events out of
// the 8 KB RAM log (`logs`). What each field means: the comments in diag.cpp.
#pragma once
#include <Arduino.h>

void diag_tick();                  // statusTask, every second
void diag_hid_command(bool ok);    // drive(): one mouse/keyboard command ran (ping and pace not counted)
