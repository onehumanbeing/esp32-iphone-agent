// NimBLE host buffer/config overrides. flash.sh force-includes this file into every C/C++ file
// (`-include`), so NimBLE-Arduino's host sources and ble_link.cpp see the same values.
// The core's prebuilt sdkconfig.h already #defines the CONFIG_BT_NIMBLE_* values (for its own BLE
// library) and NimBLE-Arduino reads them, so plain -D flags would be redefined back. sdkconfig.h is
// `#pragma once`: load it here first, then override. Checked by static_asserts in ble_link.cpp and
// printed at boot (`ble: msys ...`).
#pragma once
#include "sdkconfig.h"

// Notify mbufs: every queued notify holds ~2-3 blocks until the controller takes it. 12 x 256 ran out
// at ~300 kbps; 64 x 320 lets ~20 MTU-sized notifies wait in the host. ~22 KB internal RAM.
#undef CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT
#define CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT 64
#undef CONFIG_BT_NIMBLE_MSYS_1_BLOCK_SIZE
#define CONFIG_BT_NIMBLE_MSYS_1_BLOCK_SIZE 320
// msys_2 (sdkconfig: 24 x 320) only serves requests larger than an msys_1 block; with 320-byte
// msys_1 blocks nothing asks, so it would be ~8 KB of dead RAM.
#undef CONFIG_BT_NIMBLE_MSYS_2_BLOCK_COUNT
#define CONFIG_BT_NIMBLE_MSYS_2_BLOCK_COUNT 0
#undef CONFIG_BT_NIMBLE_TRANSPORT_ACL_FROM_LL_COUNT
#define CONFIG_BT_NIMBLE_TRANSPORT_ACL_FROM_LL_COUNT 24
#undef CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU
#define CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU 517
// One L2CAP connection-oriented channel (room for a CoC video path later).
#undef CONFIG_BT_NIMBLE_L2CAP_COC_MAX_NUM
#define CONFIG_BT_NIMBLE_L2CAP_COC_MAX_NUM 1
#define MYNEWT_VAL_BLE_L2CAP_COC_MPS 247
// Host and C++ wrapper logs off (5 = none for the host, 0 = none for the wrapper).
#undef CONFIG_BT_NIMBLE_LOG_LEVEL
#undef CONFIG_BT_NIMBLE_LOG_LEVEL_INFO
#define CONFIG_BT_NIMBLE_LOG_LEVEL 5
#define CONFIG_NIMBLE_CPP_LOG_LEVEL 0
// Room for the phone, a replacement phone and Macs running the debug harness: with 3, a new bond pushed out
// the oldest (the phone), which then failed to encrypt until it forgot the board (2026-10-20).
#undef CONFIG_BT_NIMBLE_MAX_BONDS
#define CONFIG_BT_NIMBLE_MAX_BONDS 8
#define MYNEWT_VAL_BLE_STORE_MAX_BONDS 8
#undef CONFIG_BT_NIMBLE_MAX_CCCDS
#define CONFIG_BT_NIMBLE_MAX_CCCDS 48
#define MYNEWT_VAL_BLE_STORE_MAX_CCCDS 48
// One legacy advertising set (ble_link.cpp): extended advertising also turns on the controller's BLE 5.0 features,
// ~9 KB of internal RAM in all (measured 2026-10-21).
#undef CONFIG_BT_NIMBLE_EXT_ADV
#define CONFIG_BT_NIMBLE_EXT_ADV 0
// The host sizes some per-handle arrays (ble_gap.c slave_conn, g_max_*) by MAX_CONNECTIONS + 1, while the controller
// hands out handles from a pool of MAX_CONNECTIONS + broadcaster + observer activities: with two advertising sets
// and MAX_CONNECTIONS 3 a connection got handle 4, wrote past them, and the next connect hit ble_gap_master_timer's
// assert (2026-10-21). We never scan, so without the observer role the pool is MAX_CONNECTIONS + 1 and every handle
// fits whatever MAX_CONNECTIONS is. Peers stay capped at 2.
#undef CONFIG_BT_NIMBLE_MAX_CONNECTIONS
#define CONFIG_BT_NIMBLE_MAX_CONNECTIONS 5
#undef CONFIG_NIMBLE_ROLE_OBSERVER  // else nimconfig_rename.h redefines the one below as empty
#undef CONFIG_BT_NIMBLE_ROLE_OBSERVER
#define CONFIG_BT_NIMBLE_ROLE_OBSERVER 0
