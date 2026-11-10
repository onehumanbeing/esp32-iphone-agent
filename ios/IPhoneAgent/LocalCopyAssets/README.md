# Generated local copy shortcut

Build the device-signed app containing `GetLocalInputIntent` and `CompleteLocalInputIntent`, then run
`tools/make_local_copy_shortcut.py --app /path/to/IPhoneAgent.app --output /tmp/local-copy-unsigned.shortcut`.
Sign the generated file with Apple's `shortcuts sign --mode anyone --input /tmp/local-copy-unsigned.shortcut
--output "ios/IPhoneAgent/LocalCopyAssets/Handsy Local Copy.shortcut"` and rebuild.

The signed, app-identity-specific file is ignored by Git. This folder remains a folder resource so a checkout
without that generated file still builds and reports setup as unavailable. The shortcut contains only seven
local actions; no network requests, credentials or user payloads. Review and import it on the iPhone, bind a
trigger, and pass Test Copy in Settings > Unicode Input before runtime use. Signing alone is not installation
or end-to-end verification. Based on ESP32 iPhone Agent by Henry Yuan (MIT), see root LICENSE and NOTICE.
