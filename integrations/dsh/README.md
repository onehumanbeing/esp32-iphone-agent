# ESP32 Agent plugin for DeepSeek Harness

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) plugin that lets the agent see and drive
a real iPhone through an ESP32 Agent (Handsy) board. It adds:

- the `esp32agent` MCP server (`npx -y esp32agent mcp`): `screenshot`, `tap`, `longpress`, `swipe`, `type_text`,
  `press_key`, `press_button`, `device_info`, plus saved intents and history. Tools show up as
  `mcp__esp32agent__<tool>`.
- the `handsy` skill: the see-act loop, how to save what worked, and safety rules.

Based on [ESP32 iPhone Agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan (MIT).

## Requirements

- An ESP32 Agent board with firmware v0.2.2 or later, plugged into the iPhone, with AssistiveTouch and Screen
  Mirroring set up (see the [main README](../../README.md)).
- Node.js 18+ and `ffmpeg` on the computer running dsh. The board is reached over Bluetooth.
- Pair once: `npx -y esp32agent pair` within 3 minutes of plugging the board in.

## Install

```sh
# from npm
dsh plugin --profile web add dsh-esp32agent
# or straight from GitHub
dsh plugin --profile web add "github:onehumanbeing/esp32-iphone-agent#main&path:/integrations/dsh"
```

Restart `dsh web` (or use your own profile name), then check the layer is there:

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
