// One agent turn loop with a fake `tap` tool, driven from Swift: PiSpike.run(config) -> Promise<JSON string>.
import { Type } from "typebox";

export async function run({ baseUrl, apiKey, modelId, prompt }) {
  // Dynamic imports: pi-ai's lazy providers make esbuild wrap its modules in init functions, and a static import
  // reaches createModels before its module ran (ModelsImpl is not a constructor).
  const { Agent } = await import("@earendil-works/pi-agent-core");
  const { createModels, createProvider } = await import("@earendil-works/pi-ai");
  const { openAICompletionsApi } = await import("@earendil-works/pi-ai/api/openai-completions.lazy");
  const model = {
    id: modelId, name: modelId, api: "openai-completions", provider: "app", baseUrl,
    reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000, maxTokens: 2000,
  };
  const models = createModels();
  models.setProvider(createProvider({
    id: "app", name: "App", baseUrl,
    auth: { apiKey: { name: "App", resolve: async () => ({ auth: { apiKey } }) } },
    models: [model], api: openAICompletionsApi(),
  }));
  const taps = [];
  const tap = {
    name: "tap", label: "Tap", description: "Tap the iPhone screen at x, y (0-1000 from the top left).",
    parameters: Type.Object({ x: Type.Number(), y: Type.Number() }),
    execute: async (_id, p) => { taps.push(p); return { content: [{ type: "text", text: "tapped; the screen changed" }], details: p }; },
  };
  const done = {
    name: "done", label: "Done", description: "The task is finished.",
    parameters: Type.Object({ answer: Type.String() }),
    execute: async (_id, p) => ({ content: [{ type: "text", text: "ok" }], details: p, terminate: true }),
  };
  const agent = new Agent({
    initialState: { systemPrompt: "You operate an iPhone with tools. Call tap, then done.", model, tools: [tap, done] },
    streamFn: models.streamSimple.bind(models),
  });
  const events = [];
  agent.subscribe((e) => events.push(e.type));
  await agent.prompt(prompt);
  const last = agent.state.messages[agent.state.messages.length - 1];
  return JSON.stringify({ taps, events: events.filter((t) => t !== "message_update"), error: agent.state.error ?? last?.errorMessage ?? null });
}
