// What JavaScriptCore lacks and pi-ai / the openai SDK use. Timers, random bytes and HTTP come from Swift (__native).
import "core-js/actual/url";
import "core-js/actual/url-search-params";
import "core-js/actual/structured-clone";
import { ReadableStream, WritableStream, TransformStream } from "web-streams-polyfill";
import { TextEncoder, TextDecoder } from "@sinonjs/text-encoding";
import { AbortController, AbortSignal } from "abort-controller/dist/abort-controller.mjs";

const g = globalThis;
const N = g.__native;
Object.assign(g, { ReadableStream, WritableStream, TransformStream, TextEncoder, TextDecoder, AbortController, AbortSignal });
g.window = g.self = g;
// The polyfill is older than these AbortSignal helpers.
AbortSignal.prototype.throwIfAborted ??= function () { if (this.aborted) throw this.reason ?? new DOMException("aborted", "AbortError"); };
AbortSignal.abort ??= (reason) => { const c = new AbortController(); c.abort(reason); return c.signal; };
AbortSignal.timeout ??= (ms) => { const c = new AbortController(); setTimeout(() => c.abort(new DOMException("timeout", "TimeoutError")), ms); return c.signal; };
AbortSignal.any ??= (signals) => { const c = new AbortController(); for (const s of signals) { if (s.aborted) { c.abort(s.reason); break; } s.addEventListener("abort", () => c.abort(s.reason)); } return c.signal; };
g.console = { log: (...a) => N.log(a.map(String).join(" ")), warn: (...a) => N.log("warn " + a.join(" ")),
  error: (...a) => N.log("error " + a.join(" ")), info: (...a) => N.log(a.join(" ")), debug: () => {} };
g.setTimeout = (fn, ms = 0, ...args) => N.setTimeout(() => fn(...args), ms);
g.clearTimeout = (id) => N.clearTimeout(id ?? 0);
g.setInterval = (fn, ms) => { const tick = () => { id.v = N.setTimeout(() => { fn(); tick(); }, ms); }; const id = { v: 0 }; tick(); return id; };
g.clearInterval = (id) => id && N.clearTimeout(id.v);
g.queueMicrotask ??= (fn) => Promise.resolve().then(fn);
g.performance ??= { now: () => Date.now() };
g.crypto ??= {
  getRandomValues: (a) => { const b = N.randomBytes(a.length); for (let i = 0; i < a.length; i++) a[i] = b[i]; return a; },
  randomUUID: () => N.uuid(),
};
g.atob ??= (s) => N.atob(s);
g.btoa ??= (s) => N.btoa(s);
g.Event ??= class Event { constructor(type) { this.type = type; } };
g.EventTarget ??= class EventTarget { addEventListener() {} removeEventListener() {} dispatchEvent() { return true; } };
g.FormData ??= class FormData { constructor() { this.parts = []; } append(k, v) { this.parts.push([k, v]); } };
g.Blob ??= class Blob { constructor(parts = [], o = {}) { this.parts = parts; this.type = o.type ?? ""; } };
g.File ??= class File extends g.Blob { constructor(parts, name, o) { super(parts, o); this.name = name; } };
g.navigator ??= { userAgent: "JavaScriptCore" };
g.DOMException ??= class DOMException extends Error { constructor(m, name) { super(m); this.name = name ?? "Error"; } };

class Headers {
  constructor(init) {
    this.map = new Map();
    if (init instanceof Headers) init.forEach((v, k) => this.set(k, v));
    else if (Array.isArray(init)) init.forEach(([k, v]) => this.append(k, v));
    else if (init) Object.entries(init).forEach(([k, v]) => v != null && this.append(k, v));
  }
  append(k, v) { k = k.toLowerCase(); this.map.set(k, this.map.has(k) ? this.map.get(k) + ", " + v : String(v)); }
  set(k, v) { this.map.set(k.toLowerCase(), String(v)); }
  get(k) { return this.map.get(k.toLowerCase()) ?? null; }
  has(k) { return this.map.has(k.toLowerCase()); }
  delete(k) { this.map.delete(k.toLowerCase()); }
  forEach(f) { this.map.forEach((v, k) => f(v, k, this)); }
  entries() { return this.map.entries(); } keys() { return this.map.keys(); } values() { return this.map.values(); }
  [Symbol.iterator]() { return this.map.entries(); }
}

class Response {
  constructor(body, init = {}) {
    this.status = init.status ?? 200; this.ok = this.status >= 200 && this.status < 300;
    this.statusText = init.statusText ?? ""; this.headers = new Headers(init.headers); this.url = init.url ?? "";
    this.body = typeof body === "string" ? new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(body)); c.close(); } }) : body;
    this.bodyUsed = false;
  }
  async arrayBuffer() {
    this.bodyUsed = true; const parts = []; let n = 0;
    if (this.body) for (const r = this.body.getReader(); ;) { const { done, value } = await r.read(); if (done) break; parts.push(value); n += value.length; }
    const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out.buffer;
  }
  async text() { return new TextDecoder().decode(await this.arrayBuffer()); }
  async json() { return JSON.parse(await this.text()); }
  clone() { const [a, b] = this.body.tee(); this.body = a; return new Response(b, this); }
}

class Request {
  constructor(input, init = {}) {
    this.url = typeof input === "string" ? input : input.url; this.method = init.method ?? input.method ?? "GET";
    this.headers = new Headers(init.headers ?? input.headers); this.body = init.body ?? input.body ?? null;
    this.signal = init.signal ?? input.signal;
  }
}

let nextID = 0;
const pending = new Map();
g.__fetchHead = (id, status, headers) => pending.get(id)?.head(status, headers);
g.__fetchChunk = (id, bytes) => pending.get(id)?.chunk(Uint8Array.from(bytes));
g.__fetchEnd = (id, error) => pending.get(id)?.end(error);

g.fetch = (input, init = {}) => new Promise((resolve, reject) => {
  const req = new Request(input, init);
  const id = ++nextID;
  let controller;
  const body = new ReadableStream({ start(c) { controller = c; }, cancel() { N.cancel(id); } });
  pending.set(id, {
    head: (status, headers) => resolve(new Response(body, { status, headers, url: req.url })),
    chunk: (b) => controller.enqueue(b),
    end: (error) => { pending.delete(id); if (error) { reject(new TypeError(error)); controller.error(new TypeError(error)); } else controller.close(); },
  });
  req.signal?.addEventListener?.("abort", () => { N.cancel(id); pending.get(id)?.end("aborted"); });
  const text = req.body == null ? null : typeof req.body === "string" ? req.body : new TextDecoder().decode(req.body);
  N.fetch(id, req.url, req.method, Object.fromEntries(req.headers.entries()), text);
});
Object.assign(g, { Headers, Response, Request });
