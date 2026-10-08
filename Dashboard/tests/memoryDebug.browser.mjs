import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { tmpdir } from "node:os";
import { chromium } from "playwright";

const root = fileURLToPath(new URL("../", import.meta.url));
const harness = await mkdtemp(path.join(root, ".memory-debug-test-"));
const port = 25114;
const server = spawn(process.execPath, ["node_modules/vite/bin/vite.js", "--host", "127.0.0.1", "--port", String(port), "--strictPort"], { cwd: root, stdio: "pipe" });
const recordedAt = "2026-10-06T12:00:00Z";
const hit = { ref: { id: "memory-1", score: 0.9, kind: "fact", class: "semantic" }, note: "Aurora uses Swift actors" };
const queries = [
  { id: "auto", recordedAt, operationId: "operation-1", source: "automatic", query: "How does Aurora work?", queryCharacters: 21,
    scope: { type: "agent", id: "helper" }, limit: 8, durationMs: 10, resultCount: 1, resultCharacters: 24, estimatedResultTokens: 6, hits: [hit], truncated: false,
    stages: [{ name: "keyword", durationMs: 2, candidateCount: 1 }] },
  { id: "search", recordedAt, source: "memory.search", query: "Aurora", queryCharacters: 6,
    scope: { type: "project", id: "aurora" }, limit: 8, durationMs: 30, resultCount: 0, resultCharacters: 0, estimatedResultTokens: 0, hits: [], truncated: false,
    stages: [{ name: "provider", durationMs: 29, candidateCount: 0, error: "Provider unavailable; local fallback used" }] }
];
const fixture = {
  agentId: "helper", sessionId: "session-1", channelId: "agent:helper:session:session-1", bootstrapContent: "Curated bootstrap", bootstrapChars: 17,
  documentSizes: { agentsMarkdown: 10, userMarkdown: 20, identityMarkdown: 10, soulMarkdown: 10, memoryMarkdown: 24 }, skillsCount: 0, installedSkillIds: [],
  contextUtilization: 0.1, channelMessageCount: 2, activeWorkerIds: [], selectedModel: "mock", runtimeType: "native",
  conversationHistoryChars: 20, conversationHistoryMessageCount: 1,
  memoryDiagnostics: { collectionStartedAt: recordedAt, retentionLimit: 200, queries,
    modelContext: { recordedAt, model: "mock", entryCount: 2, characters: 90, estimatedTokens: 30, imageCount: 0, toolNames: ["memory_search"], truncated: true,
      entries: [
        { id: "instructions", kind: "instructions", content: "Prepared bootstrap and tool definitions", characters: 50, estimatedTokens: 15, truncated: false },
        { id: "prompt", kind: "user", content: "[Recalled scoped memory]\nAurora uses Swift actors\n[Current user message]\nHow does Aurora work?", characters: 200, estimatedTokens: 50, truncated: true }
      ], memoryInjection: { operationId: "operation-1", durationMs: 11, hitIds: ["memory-1"], content: "[Recalled scoped memory]\nAurora uses Swift actors", characters: 47, estimatedTokens: 12 } } },
  contextLedger: { contextWindowTokens: 32000, reservedOutputTokens: 2000, entries: [{ category: "current_turn", label: "current user message", estimatedTokens: 50, cachePolicy: "uncacheable" }], lastTurnUsage: { prompt: 70, completion: 10, cachedInput: 20 } }
};

let browser;
try {
  await writeFile(path.join(harness, "index.html"), '<html><meta name="viewport" content="width=device-width, initial-scale=1"><div id="root"></div><script type="module" src="./main.tsx"></script></html>');
  await writeFile(path.join(harness, "main.tsx"), `import React from "react";
import { createRoot } from "react-dom/client";
import { DebugView } from "../src/views/DebugView";
import "../src/styles/index.css";
const state = (window as any).debugFixture = { data: ${JSON.stringify(fixture)}, fail: false, calls: 0 };
const coreApi = {
  fetchAgents: async () => [{ id: "helper", displayName: "Helper" }],
  fetchAgentSessions: async () => [{ id: "session-1", title: "Memory session" }],
  fetchChannelSessions: async () => [],
  fetchDebugChannels: async () => ({ channels: [] }),
  fetchDebugPromptTemplates: async () => ({ templates: [] }),
  fetchDebugSessionContext: async () => { state.calls++; return state.fail ? null : structuredClone(state.data); }
};
createRoot(document.getElementById("root")!).render(<div style={{maxWidth:1000,padding:16,margin:"auto"}}><DebugView coreApi={coreApi as any} /></div>);`);
  for (let attempt = 0; ; attempt++) {
    try { if ((await fetch(`http://127.0.0.1:${port}`)).ok) break; } catch {}
    if (attempt === 100) throw new Error("Vite did not start");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}) });
  const page = await browser.newPage({ viewport: { width: 1100, height: 1000 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${port}/${path.basename(harness)}/index.html`);
  await page.getByRole("button", { name: "Debug agent", exact: true }).click();
  await page.getByRole("button", { name: "Helper", exact: true }).click();
  await page.getByRole("button", { name: "Debug session", exact: true }).click();
  await page.getByRole("button", { name: "Memory session", exact: true }).click();
  await page.getByRole("heading", { name: "Memory requests", exact: true }).waitFor();
  const diagnostics = page.getByRole("region", { name: "Memory diagnostics" });
  assert.match(await diagnostics.innerText(), /20\.0 ms \/ 30\.0 ms/);
  assert.match(await diagnostics.innerText(), /1\/2 \(50%\)/);
  await diagnostics.locator("summary").filter({ hasText: "automatic" }).click();
  await diagnostics.getByText("How does Aurora work?", { exact: true }).waitFor();
  await diagnostics.getByText("Aurora uses Swift actors", { exact: true }).waitFor();
  assert.match(await diagnostics.innerText(), /fact \/ semantic/);
  await diagnostics.locator("summary").filter({ hasText: "memory.search" }).click();
  await diagnostics.getByText("Provider unavailable; local fallback used", { exact: false }).waitFor();
  await diagnostics.locator("summary").filter({ hasText: "Injected memory text" }).click();
  await diagnostics.locator("summary").filter({ hasText: "1. instructions" }).click();
  await diagnostics.getByText("Prepared bootstrap and tool definitions", { exact: true }).waitFor();
  await diagnostics.locator("summary").filter({ hasText: "2. user" }).click();
  assert.match(await diagnostics.innerText(), /Preview truncated|preview truncated|truncated/);
  await diagnostics.locator("summary").filter({ hasText: "Context budget" }).click();
  await diagnostics.getByText("Provider-reported last turn", { exact: false }).waitFor();
  await page.screenshot({ path: path.join(tmpdir(), "sloppy-memory-debug-desktop.png"), fullPage: true, animations: "disabled" });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  await page.screenshot({ path: path.join(tmpdir(), "sloppy-memory-debug-mobile.png"), fullPage: true, animations: "disabled" });
  await page.evaluate(() => {
    const query = window.debugFixture.data.memoryDiagnostics.queries[0];
    window.debugFixture.data.memoryDiagnostics.queries = [{ ...query, id: "bootstrap", source: "bootstrap", query: "", queryCharacters: 0 }];
  });
  await page.getByRole("button", { name: "Inspect", exact: true }).click();
  await diagnostics.locator("summary").filter({ hasText: "bootstrap" }).click();
  await diagnostics.getByText("Bootstrap selection check", { exact: false }).waitFor();
  await page.evaluate(() => { window.debugFixture.data.memoryDiagnostics = { ...window.debugFixture.data.memoryDiagnostics, queries: [], modelContext: null }; });
  await page.getByRole("button", { name: "Inspect", exact: true }).click();
  await diagnostics.getByText("No recorded memory requests for this session.", { exact: true }).waitFor();
  await diagnostics.getByText("No model turn captured in this process for this session.", { exact: true }).waitFor();
  await page.evaluate(() => { window.debugFixture.fail = true; });
  await page.getByRole("button", { name: "Inspect", exact: true }).click();
  await page.getByRole("alert").filter({ hasText: "Could not load session diagnostics" }).waitFor();
  assert.deepEqual(errors, []);
  console.log("Memory debug UI passed: session selection, query metrics, backend errors, injected memory, prepared context, empty state, API failure, mobile layout.");
} finally {
  await browser?.close();
  server.kill("SIGTERM");
  await rm(harness, { recursive: true, force: true });
}
