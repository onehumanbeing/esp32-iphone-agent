#pragma once
// The firmware's version, the same scheme as the repo's release tags (v0.2.0). Bump it for every firmware
// release (tools/fw_release.py). The board reports it as `fw` in its status: the app offers an update when it
// is older, and the tag names the source it was built from.
#if OTA_CRASH_TEST  // flash.sh --crash-test: an image that never comes up, versioned so the app offers it
#define FW_VERSION "9.9.9"
#else
#define FW_VERSION "0.2.1"
#endif
