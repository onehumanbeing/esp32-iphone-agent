// OpenAI-compatible SSE mock: 1st call -> tool call tap(500, 300), 2nd -> done("ok"). Counts requests.
import http from "node:http";
let n = 0;
const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "m",
  choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
const call = (name, args) => [
  chunk({ role: "assistant", tool_calls: [{ index: 0, id: "c" + n, type: "function", function: { name, arguments: "" } }] }),
  chunk({ tool_calls: [{ index: 0, function: { arguments: JSON.stringify(args) } }] }),
  chunk({}, "tool_calls"), "data: [DONE]\n\n"];
http.createServer((req, res) => {
  let body = ""; req.on("data", (d) => (body += d)); req.on("end", () => {
    n += 1;
    process.stderr.write(`request ${n} ${req.url} tools=${(JSON.parse(body).tools || []).map((t) => t.function.name)}\n`);
    res.writeHead(200, { "content-type": "text/event-stream" });
    for (const line of n % 2 ? call("tap", { x: 500, y: 300 }) : call("done", { answer: "ok" })) res.write(line);
    res.end();
  });
}).listen(Number(process.env.PORT || 8787), "127.0.0.1");
