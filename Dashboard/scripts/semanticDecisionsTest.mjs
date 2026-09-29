import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";
import { createRequire } from "node:module";

const bundle = await build({
  stdin: {
    contents: `
      export { normalizeConfig } from "./src/features/config/configModel";
      export * from "./src/features/config/semanticDecisions";
      export { SemanticDecisionsEditor } from "./src/features/config/components/SemanticDecisionsEditor";
      export { createElement } from "react";
      export { renderToStaticMarkup } from "react-dom/server";
    `,
    resolveDir: new URL("..", import.meta.url).pathname,
    loader: "ts"
  },
  bundle: true,
  write: false,
  format: "cjs",
  platform: "node",
  define: { "import.meta.env": "{}", "process.env.NODE_ENV": '"production"' }
});
const module = { exports: {} };
new Function("require", "module", "exports", bundle.outputFiles[0].text)(createRequire(import.meta.url), module, module.exports);
const api = module.exports;

test("saved Laya config survives Dashboard normalization and reopening", () => {
  const semanticDecisions = {
    provider: "laya", baseURL: "http://laya.test:8000/v1/systemone", model: "multilingual",
    apiKey: "", apiKeyEnvironmentVariable: "LAYA_API_KEY", maxInputTokens: 8192,
    executorModelRouting: "shadow", minimumConfidence: 0.85, timeoutMs: 5000,
    modelProfiles: { fast: { model: "mock:fast", description: "Routine" }, senior: { model: "mock:senior", description: "Complex" } }
  };
  const saved = api.normalizeConfig({ semanticDecisions });
  const reopened = api.normalizeConfig(JSON.parse(JSON.stringify(saved)));
  assert.equal(reopened.semanticDecisions.provider, "laya");
  assert.equal(reopened.semanticDecisions.inputCostPerMillionTokensUSD, 0);
  for (const [key, value] of Object.entries(semanticDecisions)) {
    assert.deepEqual(reopened.semanticDecisions[key], value);
  }
});

test("switching to Laya clears Jev credentials and endpoints and preserves profiles", () => {
  const jev = api.normalizeConfig({ semanticDecisions: {
    provider: "vercel", baseURL: "https://custom-jev.test", apiKey: "jev-secret", model: "typesafe-ai/jev",
    executorModelRouting: "active", modelProfiles: { fast: { model: "mock:fast", description: "Routine" } }
  } }).semanticDecisions;
  const laya = api.changeSemanticProvider(jev, "laya");
  assert.equal(laya.provider, "laya");
  assert.equal(laya.apiKey, "");
  assert.equal(laya.baseURL, "");
  assert.equal(laya.model, "");
  assert.equal(laya.apiKeyEnvironmentVariable, "LAYA_API_KEY");
  assert.equal(laya.inputCostPerMillionTokensUSD, 0);
  assert.equal(laya.maxInputTokens, 8192);
  assert.equal(laya.timeoutMs, 5000);
  assert.equal(laya.executorModelRouting, "active");
  assert.deepEqual(laya.modelProfiles, jev.modelProfiles);
  assert.equal(api.changeSemanticProvider(laya, "laya"), laya);

  const restored = api.changeSemanticProvider(laya, "vercel");
  assert.equal(restored.apiKeyEnvironmentVariable, "AI_GATEWAY_API_KEY");
  assert.equal(restored.maxInputTokens, null);
  assert.equal(restored.inputCostPerMillionTokensUSD, 0.042);
});

for (const provider of ["typesafe", "vercel"]) {
  test(`${provider} legacy config keeps its model, key, and pricing`, () => {
    const config = api.normalizeConfig({ semanticDecisions: { provider, model: "existing-jev", apiKey: "existing-key" } });
    assert.equal(config.semanticDecisions.provider, provider);
    assert.equal(config.semanticDecisions.model, "existing-jev");
    assert.equal(config.semanticDecisions.apiKey, "existing-key");
    assert.equal(config.semanticDecisions.inputCostPerMillionTokensUSD, 0.042);
    assert.equal(config.semanticDecisions.maxInputTokens, null);
  });
}

test("Laya editor renders its endpoint, optional key and input limit", () => {
  const html = api.renderToStaticMarkup(api.createElement(api.SemanticDecisionsEditor, {
    draftConfig: api.normalizeConfig({ semanticDecisions: { provider: "laya" } }),
    mutateDraft: () => {}, modelCatalog: [], modelCatalogStatus: ""
  }));
  assert.match(html, /value="Laya"/);
  assert.match(html, /127\.0\.0\.1:8000\/v1\/systemone/);
  assert.match(html, /Optional Laya API key/);
  assert.match(html, /Input token limit/);
  assert.match(html, /placeholder="multilingual"/);
  assert.doesNotMatch(html, /Input price per 1M/);
});
