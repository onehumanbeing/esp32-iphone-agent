#pragma once
#include <stdint.h>

void board_begin();
uint8_t board_battery_percent();
const char *board_status_fields();
bool board_supports_usb_release();
extern const char firmware_target[16];
