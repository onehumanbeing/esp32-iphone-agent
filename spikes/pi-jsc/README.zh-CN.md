# pi-jsc 试验

[English](README.md) · 简体中文

把 pi-agent-core + pi-ai 打包到一个纯 JavaScriptCore 环境里运行，配一个 Swift 宿主（定时器、流式 fetch）。结论见 [docs/pi-spike.md](../../docs/pi-spike.md)。

```bash
npm install && npm run build && npm run host
npm run mock &                                   # 在 :8787 上的 OpenAI 兼容 SSE 模拟服务
dist/pi-jsc-host dist http://127.0.0.1:8787/v1 m
PI_API_KEY=… dist/pi-jsc-host dist https://dashscope.aliyuncs.com/compatible-mode/v1 qwen3.8-flash
```
