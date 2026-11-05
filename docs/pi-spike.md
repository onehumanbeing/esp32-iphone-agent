# pi in JavaScriptCore (spike, 2026-11-02)

Question: can the app run [pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-agent-core` + `pi-ai`, MIT)
in-process instead of the hand-written THINK/DO loop? Code: `spikes/pi-jsc/`. Not wired into the app.

## Result: yes, with polyfills

| Check | Result |
|---|---|
| Bundle (esbuild, IIFE, minified) | pi-agent-core + pi-ai (OpenAI-compatible API only): 600 KB, 160 KB gzip |
| Polyfills | 697 KB, 242 KB gzip (mostly core-js URL / structuredClone; can be trimmed) |
| Load into a fresh `JSContext` | 26–57 ms (macOS) |
| Mock OpenAI SSE server, `tap` + `done` tools | 2 streamed requests, both tools called, 0.18 s |
| DashScope `qwen3.8-flash`, native tool calling | `tap(500, 300)` then `done`, 2 requests, 2.5 s |

Run it: `cd spikes/pi-jsc && npm install && npm run build && npm run host`, then
`npm run mock` and `dist/pi-jsc-host dist http://127.0.0.1:8787/v1 m` (or a real base URL with `PI_API_KEY`).

## What a bare JSContext lacks

`fetch`, `Headers`, `Request`, `Response`, `ReadableStream`, `TextEncoder/Decoder`, `AbortController`
(and `throwIfAborted`, `AbortSignal.any/timeout`), `URL`, `setTimeout`, `crypto`, `structuredClone`, `atob/btoa`,
`FormData`, `Blob`, `navigator`. `polyfills.js` adds them; Swift (`host/main.swift`) provides timers, random bytes
and a streaming `URLSession` fetch (status/headers, then each chunk as bytes, then end/error; abort cancels the task).

## Gotchas

- esbuild + pi-ai's lazy providers: a static `import { createModels }` reaches it before its module ran
  (`ModelsImpl is not a constructor`). Import pi with `await import(...)` inside the entry function.
- The `abort-controller` package's browser entry reads `window.AbortController`; import its `.mjs` build.
- `WebAssembly` exists in a macOS JSContext; **not checked on an iPhone** (no JIT in third-party apps).
  `pi-codemode` (QuickJS-wasm) needs it, so code mode is unverified on device. Core + ai need no wasm.

## Not answered yet

- **On device**: the same host as an XCTest on the iPhone (engine is the same JavaScriptCore, but no JIT:
  expect slower parsing; a 600 KB bundle should still load well under a second).
- **Background**: JS runs in the app's process, so it lives exactly as long as the current Swift loop does
  in the background (Live Activity + audio session). No new limit, but nothing gained either.
- **Images**: screenshots as `image` content parts through pi-ai's OpenAI adapter (not tried).
- **Free models' tool calling**: DashScope qwen3.8-flash works. Self-hosted llama.cpp / vLLM need `--jinja` /
  a tool parser; models without tool calling would need the text protocol anyway.

## Recommendation

Feasible. Worth a follow-up plan only if we want pi's loop features (steering, follow-ups, tool hooks, sessions)
on the phone; the THINK/DO protocol stays the fallback for models without tool calling. Next step would be: the
host as an XCTest on device, one `screenshot` tool returning an image, then swap the actor behind a flag.
