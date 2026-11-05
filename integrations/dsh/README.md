# ESP32 Agent plugin for DeepSeek Harness

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) plugin that lets the agent see and drive
a real iPhone through an ESP32 Agent (Handsy) board. It adds:

- the `esp32agent` MCP server (`npx -y esp32agent mcp`): `screenshot`, `tap`, `longpress`, `swipe`, `type_text`,
  `press_key`, `press_button`, `device_info`, plus saved intents and history. Tools show up as
  `mcp__esp32agent__<tool>`.
- the `handsy` skill: the see-act loop, how to save what worked, and safety rules.

[![DeepSeek Harness drives a real iPhone over Wi-Fi (YouTube)](https://img.youtube.com/vi/DzYv0QVk_No/maxresdefault.jpg)](https://www.youtube.com/watch?v=DzYv0QVk_No)

**[▶ Watch the demo](https://www.youtube.com/watch?v=DzYv0QVk_No)** ·
**[⚡ Flash the firmware in your browser](https://handsy.tech/install?build=testflight)** ·
**[📖 Setup guide](https://handsy.tech/docs/cli)**

Based on [ESP32 iPhone Agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan (MIT).

## Quick start

1. **Get a board.** Seeed Studio XIAO ESP32S3 (standard 8 MB flash / 8 MB PSRAM) with its antenna, and a short
   USB-C data cable (Lightning iPhones: a Lightning to USB Camera Adapter):
   [hardware guide](https://handsy.tech/docs/hardware).
2. **Flash the firmware** from your browser (Chrome or Edge, board on USB):
   [handsy.tech/install?build=testflight](https://handsy.tech/install?build=testflight). Firmware v0.2.3 or
   later (v0.2.2 works over Bluetooth only).
3. **Pair the computer** within 3 minutes of plugging the board into the iPhone (needs Node.js 18+ and `ffmpeg`):

   ```sh
   npx -y esp32agent pair
   ```

4. **Set up the iPhone:** join the board's Wi-Fi hotspot (`npx -y esp32agent net` shows its name and password),
   turn on **Control Center → Screen Mirroring → ESP32 Agent**, and enable
   **Settings → Accessibility → Touch → AssistiveTouch**.
   Optional: `npx -y esp32agent net join` puts the board on your home Wi-Fi instead, so dsh's commands and screenshots
   go over Wi-Fi rather than Bluetooth.
5. **Install the plugin** and restart `dsh web`:

   ```sh
   dsh plugin --profile web add dsh-esp32agent
   # or straight from GitHub
   dsh plugin --profile web add "github:onehumanbeing/esp32-iphone-agent#main&path:/integrations/dsh"
   ```

6. **Try a small task** in dsh:

   > Use the esp32agent tools to control my iPhone. Take a screenshot first, then open Settings, go into WLAN, and
   > tell me which Wi-Fi network the phone is connected to. Finally press Home.

Full setup, troubleshooting and every command: [handsy.tech/docs/cli](https://handsy.tech/docs/cli).

Check that the layer is loaded (use your own profile name):

```sh
dsh --profile web --dump-config | grep esp32agent
```

With several boards, set `ESP32AGENT_DEVICE` to the board id before starting dsh; the plugin passes it to the MCP
server (dsh drops the rest of the inherited environment).

## Safety

dsh has no per-action confirmation for MCP tools, and these tools act on a real phone. The `handsy` skill tells the
agent to ask before anything that spends money, sends a message, calls someone, deletes data or changes security
settings, and to hand passwords and one-time codes to you. Review
the [skill](skills/handsy/SKILL.md) before you give the agent open-ended tasks.

## Development

`skills/handsy/SKILL.md` is a copy of [`skills/handsy/SKILL.md`](../../skills/handsy/SKILL.md) (a package can't
reach files outside its folder). Run `./check-skill-sync.sh` after editing either one.

```sh
dsh plugin --profile test add link:$PWD
```
