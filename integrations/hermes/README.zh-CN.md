# Hermes Agent 的 Manina AI 插件

[English](README.md) · 简体中文

一个 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 插件，让 Agent 通过 ESP32 Agent（Manina AI）板子看到并操作一部真实的、没越狱的 iPhone：板子当 iPhone 的鼠标和键盘，同时接收它的 AirPlay 屏幕镜像。它是一个 Agent Plugins v1 便携插件包，包含：

- `esp32agent` MCP 服务器（`npx -y esp32agent mcp`）：`screenshot`、`tap`、`longpress`、`swipe`、`type_text`、`press_key`、`press_button`、`device_info`、`phone_audio`，以及保存的意图和历史记录。工具在 Hermes 里显示为 `mcp__esp32agent__<tool>`，截图会以图片形式交给模型。
- `manina:manina` 技能：「看一眼 → 做一步 → 再看」的循环、怎么保存做成功的流程，以及安全规则。

[![Manina AI 控制真实 iPhone（YouTube）](https://img.youtube.com/vi/Ly4im-P4jYg/maxresdefault.jpg)](https://www.youtube.com/watch?v=Ly4im-P4jYg)

**[▶ 看演示视频](https://www.youtube.com/watch?v=Ly4im-P4jYg)** ·
**[⚡ 在浏览器里烧录固件](https://manina.ai/zh/install?build=testflight)** ·
**[📖 设置指南](https://manina.ai/zh/docs/cli)**

基于 Henry Yuan 的 [ESP32 iPhone Agent](https://github.com/onehumanbeing/esp32-iphone-agent)（MIT）。

## 快速上手

1. **准备板子。** Seeed Studio XIAO ESP32S3（标准版，8 MB 闪存 / 8 MB PSRAM），接好天线；再准备一根短的 USB-C 数据线（Lightning 接口的 iPhone XS 到 14 用蓝牙模式：板子接任意 USB 电源，不用连手机）。见[硬件购买指南](https://manina.ai/zh/docs/hardware)。
2. **在浏览器里烧录固件**（Chrome 或 Edge，板子用 USB 连电脑）：[manina.ai/zh/install?build=testflight](https://manina.ai/zh/install?build=testflight)。需要固件 v0.2.3 或更新版本（v0.2.2 只能走蓝牙）。
3. **配对电脑**：板子通电（USB 模式：插到 iPhone 上）后三分钟内运行（电脑需要 Node.js 18+ 和 `ffmpeg`）。蓝牙模式下，在同一个三分钟内在 iPhone 上配对板子（设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备）：

   ```sh
   npx -y esp32agent pair
   ```

4. **设置 iPhone**：连接板子的 Wi-Fi 热点（`npx -y esp32agent net` 会显示热点名和密码），打开<strong>控制中心 → 屏幕镜像 → ESP32 Agent</strong>，再开启<strong>设置 → 辅助功能 → 触控 → 辅助触控</strong>。
   可选：运行 `npx -y esp32agent net join`，让板子改连家里的 Wi-Fi，命令和截图就走 Wi-Fi，不再走蓝牙。
5. **安装插件**，然后开一个新的 Hermes 会话：

   ```sh
   hermes plugins install onehumanbeing/esp32-iphone-agent/integrations/hermes --enable
   ```

6. **在 Hermes 里试一个小任务**：

   > Use the esp32agent tools to control my iPhone. Take a screenshot first, then open Settings, go into WLAN, and
   > tell me which Wi-Fi network the phone is connected to. Finally press Home.

完整设置、排错和所有命令见 [manina.ai/zh/docs/cli](https://manina.ai/zh/docs/cli)。

检查是否加载成功：`hermes plugins list` 里 `manina` 显示为 enabled，会话启动时会列出 `esp32agent` 的 MCP 工具。有多块板子时，把 `ESP32AGENT_DEVICE` 设为板子的 ID（写在 shell 里或 Hermes profile 的 `.env` 里），插件会把它传给 MCP 服务器。

## 安全

这些工具操作的是一部真实的手机，Hermes 默认不会每一步都问你。`manina` 技能要求 Agent 在花钱、发消息、打电话、删除数据或修改安全设置之前先问你，并把密码和验证码交给你本人输入。在给 Agent 开放式任务之前，请先看一遍这个[技能](skills/manina/SKILL.md)。

想每一步都由你批准，可以在 `config.yaml` 里覆盖这个服务器（同名条目会替换插件里的）：

```yaml
mcp_servers:
  esp32agent:
    command: npx
    args: [-y, esp32agent@0.1.5, mcp]
    timeout: 120
    trust: untrusted   # 每次点击、滑动、输入和截图前 Hermes 都会问你
```

## 开发

`skills/manina/SKILL.md` 的正文和仓库根目录的 [`skills/manina/SKILL.md`](../../skills/manina/SKILL.md) 相同（插件无法引用自己目录以外的文件），只有 frontmatter 不同，因为 Agent Skills 的 metadata 只能是扁平的字符串。改了其中任何一个，都要运行 `./check-skill-sync.sh`。命令行工具发新版时，`mcp.json` 里的 `esp32agent@` 版本和 dsh 插件一起升。

```sh
hermes plugins validate integrations/hermes
hermes plugins install "file://$PWD#integrations/hermes" --enable   # 从本地提交安装
```
