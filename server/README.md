# server/ (legacy)

This is the computer-side server of the original version (tag `v0.1.0`, branch `legacy`): UxPlay on a Mac or Linux
machine receives the screen, this Python server runs the agent and a web UI, and the ESP32 is only a USB mouse that
connects to it over Wi-Fi.

**The current version does not use it.** The board receives AirPlay itself and the agent runs in the iPhone app
(`ios/`), with its prompts in `prompts/`. This folder is kept so the legacy setup keeps working and its tests still
run in CI; it gets fixes, not new features. Its prompts are the older ones in `hidagent/agent.py` and are not synced
with `prompts/`.

Note: the current firmware takes commands and status over BLE, not the TCP line protocol this server expects. Video to the app is a separate Wi-Fi TCP channel (port 7201). To run the legacy setup, check out
`legacy` (or `v0.1.0`) and follow its README.
