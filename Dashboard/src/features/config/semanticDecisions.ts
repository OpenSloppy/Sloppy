export const SEMANTIC_PROVIDERS = [
  { value: "typesafe", label: "TypeSafe direct (Jev)", description: "Use api.typesafe.ai with a TypeSafe API key." },
  { value: "vercel", label: "Vercel AI Gateway (Jev)", description: "Use Vercel's TypeSafe-compatible Jev endpoint." },
  { value: "laya", label: "Laya", description: "Use a local or remote Laya System One server. API key is optional." }
];

export function semanticProviderDefaults(provider: string) {
  switch (provider) {
    case "laya":
      return { endpoint: "http://127.0.0.1:8000/v1/systemone", model: "multilingual", environmentVariable: "LAYA_API_KEY", inputPrice: 0 };
    case "vercel":
      return { endpoint: "https://ai-gateway.vercel.sh/typesafe/v1/systemone", model: "typesafe-ai/jev", environmentVariable: "AI_GATEWAY_API_KEY", inputPrice: 0.042 };
    default:
      return { endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-latest", environmentVariable: "TYPESAFE_API_KEY", inputPrice: 0.042 };
  }
}

export function changeSemanticProvider(config, provider: string) {
  if (config.provider === provider) return config;
  const defaults = semanticProviderDefaults(provider);
  return {
    ...config,
    provider,
    apiKey: "",
    apiKeyEnvironmentVariable: defaults.environmentVariable,
    baseURL: "",
    model: "",
    maxInputTokens: provider === "laya" ? 8192 : null,
    inputCostPerMillionTokensUSD: defaults.inputPrice,
    timeoutMs: provider === "laya" && config.timeoutMs === 2000 ? 5000 : config.timeoutMs
  };
}
