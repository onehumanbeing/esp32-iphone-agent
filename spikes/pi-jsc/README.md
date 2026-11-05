# pi-jsc spike

English · [简体中文](README.zh-CN.md)

pi-agent-core + pi-ai bundled for a bare JavaScriptCore context, with a Swift host (timers, streaming fetch).
Findings: [docs/pi-spike.md](../../docs/pi-spike.md).

```bash
npm install && npm run build && npm run host
npm run mock &                                   # OpenAI-compatible SSE mock on :8787
dist/pi-jsc-host dist http://127.0.0.1:8787/v1 m
PI_API_KEY=… dist/pi-jsc-host dist https://dashscope.aliyuncs.com/compatible-mode/v1 qwen3.8-flash
```
