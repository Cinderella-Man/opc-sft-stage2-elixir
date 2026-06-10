// Tunex pi extension: register the Mimo chat-completions endpoint as a pi
// provider so the agentic implement stage can run on the same token plan the
// other LLM stages use. Loaded headless via `pi -e pi/mimo_provider.ts
// --provider mimo`. The API key is injected by the Elixir runner through the
// TUNEX_MIMO_KEY env var (never written to disk or the command line).
//
// Why a custom provider: pi is a harness, not a model — it must be pointed at a
// backend. Mimo is OpenAI-Chat-Completions compatible, so `openai-completions`
// works; Mimo names the output cap `max_completion_tokens` (compat below).
export default function (pi) {
  pi.registerProvider("mimo", {
    name: "Mimo (Xiaomi)",
    baseUrl: "https://token-plan-sgp.xiaomimimo.com/v1",
    apiKey: "$TUNEX_MIMO_KEY",
    api: "openai-completions",
    models: [
      {
        id: "mimo-v2.5-pro",
        name: "MiMo v2.5 Pro",
        reasoning: true,
        input: ["text"],
        // $/million tokens (mirrors config.exs budget.prices.xiaomi_mimo_2_5_pro).
        cost: { input: 0.435, output: 0.87, cacheRead: 0.0036, cacheWrite: 0.435 },
        contextWindow: 256000,
        maxTokens: 32768,
        compat: { maxTokensField: "max_completion_tokens", supportsReasoningEffort: true },
      },
    ],
  });
}
