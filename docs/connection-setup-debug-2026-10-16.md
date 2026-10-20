# Connection and model setup verification — 2026-10-16

Base: local main, e035e424f492225e1a84a75dc172da75bfdb73bc.
Branch: codex/diagnose-board-pairing.

## Findings

- Both the old and new iOS apps were installed and running. Their logs showed matching connection timeouts and encryption failures. Stopping the old app did not eliminate failures, so app contention was not established as the root cause.
- The board advertised the expected GATT service. Initial observed advertising RSSI was -95 to -99 dBm. USB enumeration alone did not prove BLE connectivity.
- The app remembered a device before connection succeeded, had no connection deadline, hid nearby alternatives when a device was remembered, and marked setup ready before reading the encrypted network characteristic.
- A board already connected through another app can be absent from scanning results; setup now also retrieves connected peripherals by service.

## Changes

- Bound scanning to 12 seconds and connection/pairing to 30 seconds; expose errors and a Scan Again action. Retain discovered peripheral references and ignore obsolete callbacks.
- Read encrypted configuration before marking the board ready and persisting its identity. Reconnect after disconnection with a delay.
- Firmware uses 9 dBm and 1M PHY instead of 0 dBm and forced 2M, favoring link reliability. Video throughput under this setting has not been re-benchmarked.
- Sample RSSI for diagnostics. Only weak signal displays a short proximity/antenna hint; no permanent antenna instructions or links in setup.
- Compact provider/key/model rows; Others exposes Base URL inline. Models remain editable when a list is available. OpenRouter Free presets use `openrouter/free`; OpenAI, Gemini, Qwen China/International, DeepSeek, and OpenRouter provide endpoints and key links.
- Do not automatically choose the first model in an API response. Connection testing sends a generated color image; configuration changes invalidate previous results. Keys do not carry across hosts.

## Validation and limits

- Firmware compiled, flashed over USB, and verified by the uploader's hash check.
- Debug iOS build installed on the connected phone; encrypted GATT setup and reconnect after app relaunch observed.
- With phone and Mac connected simultaneously: 60 ping commands, zero failures, median 24.2 ms, maximum 68.9 ms; board reported zero notification/reply drops.
- One observation window lasted over four minutes without a disconnect, but subsequent timeouts recurred. This is not proof that the RF problem is permanently resolved.
- After the phone was moved nearer, observed RSSI was approximately -78 to -83 dBm and connection/relaunch succeeded. Antenna installation was not verified.
- 71 iOS tests passed, including provider selection/custom-model coverage. Final small presentation changes compiled successfully. Onboarding layouts inspected on an iPhone 17 Pro simulator.
- No paid provider calls were made and no provider credentials were provisioned. Live provider model-list and inference compatibility require the user's key.

SwiftUI layout review used https://github.com/twostraws/SwiftUI-Agent-Skill.
