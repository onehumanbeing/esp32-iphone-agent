# Manina AI plugin for Hermes Agent

English · [简体中文](README.zh-CN.md)

A [Hermes Agent](https://github.com/NousResearch/hermes-agent) plugin that lets the agent see and drive a real,
non-jailbroken iPhone through an ESP32 Agent (Manina AI) board: the board is the iPhone's mouse and keyboard and
receives its AirPlay screen mirroring. It is a portable Agent Plugins v1 package and adds:

- the `esp32agent` MCP server (`npx -y esp32agent mcp`): `screenshot`, `tap`, `longpress`, `swipe`, `type_text`,
  `press_key`, `press_button`, `device_info`, `phone_audio`, plus saved intents and history. Tools show up as
  `mcp__esp32agent__<tool>`; screenshots reach the model as images.
- the `manina:manina` skill: the see-act loop, how to save what worked, and safety rules.

[![Manina AI drives a real iPhone (YouTube)](https://img.youtube.com/vi/Ly4im-P4jYg/maxresdefault.jpg)](https://www.youtube.com/watch?v=Ly4im-P4jYg)

**[▶ Watch the demo](https://www.youtube.com/watch?v=Ly4im-P4jYg)** ·
**[⚡ Flash the firmware in your browser](https://manina.ai/install?build=testflight)** ·
**[📖 Setup guide](https://manina.ai/docs/cli)**

Based on [ESP32 iPhone Agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan (MIT).

## Quick start

1. **Get a board.** Seeed Studio XIAO ESP32S3 (standard 8 MB flash / 8 MB PSRAM) with its antenna, and a short
   USB-C data cable (Lightning iPhones XS to 14: Bluetooth mode, the board on any USB power, no cable to the phone):
   [hardware guide](https://manina.ai/docs/hardware).
2. **Flash the firmware** from your browser (Chrome or Edge, board on USB):
   [manina.ai/install?build=testflight](https://manina.ai/install?build=testflight). Firmware v0.2.3 or
   later (v0.2.2 works over Bluetooth only).
3. **Pair the computer** within 3 minutes of powering the board up (USB mode: plugging it into the iPhone; needs
   Node.js 18+ and `ffmpeg`). In Bluetooth mode, pair the board on the iPhone in the same window
   (Settings → Accessibility → Touch → AssistiveTouch → Devices → Bluetooth Devices):

   ```sh
   npx -y esp32agent pair
   ```

4. **Set up the iPhone:** join the board's Wi-Fi hotspot (`npx -y esp32agent net` shows its name and password),
   turn on **Control Center → Screen Mirroring → ESP32 Agent**, and enable
   **Settings → Accessibility → Touch → AssistiveTouch**.
   Optional: `npx -y esp32agent net join` puts the board on your home Wi-Fi instead, so commands and screenshots
   go over Wi-Fi rather than Bluetooth.
5. **Install the plugin** and start a new Hermes session:

   ```sh
   hermes plugins install onehumanbeing/esp32-iphone-agent/integrations/hermes --enable
   ```

6. **Try a small task** in Hermes:

   > Use the esp32agent tools to control my iPhone. Take a screenshot first, then open Settings, go into WLAN, and
   > tell me which Wi-Fi network the phone is connected to. Finally press Home.

Full setup, troubleshooting and every command: [manina.ai/docs/cli](https://manina.ai/docs/cli).

Check that it loaded: `hermes plugins list` shows `manina` as enabled, and the session start lists the
`esp32agent` MCP tools. With several boards, set `ESP32AGENT_DEVICE` to the board id (in your shell or the Hermes
profile's `.env`); the plugin passes it to the MCP server.

## Safety

These tools act on a real phone, and Hermes runs them without asking each time. The `manina` skill tells the agent
to ask before anything that spends money, sends a message, calls someone, deletes data or changes security
settings, and to hand passwords and one-time codes to you. Review the [skill](skills/manina/SKILL.md) before you
give the agent open-ended tasks.

To approve every action yourself, override the server in `config.yaml` (a same-name entry replaces the plugin's):

```yaml
mcp_servers:
  esp32agent:
    command: npx
    args: [-y, esp32agent@0.1.5, mcp]
    timeout: 120
    trust: untrusted   # Hermes asks before each tap, swipe, type and screenshot
```

## Development

`skills/manina/SKILL.md` has the same body as [`skills/manina/SKILL.md`](../../skills/manina/SKILL.md) (a plugin
can't reach files outside its folder); only the frontmatter differs, because Agent Skills metadata must be flat
strings. Run `./check-skill-sync.sh` after editing either one. When the CLI is released, bump `esp32agent@` in
`mcp.json` along with the dsh plugin.

```sh
hermes plugins validate integrations/hermes
hermes plugins install "file://$PWD#integrations/hermes" --enable   # from a local commit
```
