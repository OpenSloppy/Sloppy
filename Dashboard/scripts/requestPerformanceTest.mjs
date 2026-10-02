import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";

const bundle = await build({
  stdin: {
    contents: 'export * from "./src/shared/api/httpClient"; export * from "./src/shared/api/dashboardAuth"; export * from "./src/shared/api/requestPerformance";',
    resolveDir: new URL("..", import.meta.url).pathname,
    loader: "ts"
  },
  bundle: true, write: false, format: "esm", platform: "browser",
  define: { "import.meta.env": "{}" }
});
globalThis.window = {
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  location: { search: "" },
  __SLOPPY_CONFIG__: { apiBase: "http://sloppy.test" },
  dispatchEvent() {}
};
const api = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString("base64")}`);

test("identical concurrent reads make one request, record one sample, and retry after completion", async () => {
  let calls = 0;
  let respond;
  globalThis.fetch = () => { calls++; return new Promise((resolve) => { respond = resolve; }); };
  const options = { path: "/v1/agents/private/sessions?search=private" };
  const first = api.requestJson(options);
  const second = api.requestJson(options);
  assert.equal(calls, 1);
  assert.equal(api.requestPerformanceSnapshot().active, 1);
  respond(Response.json([1], { headers: { "server-timing": "core;dur=42.5", "x-sloppy-route": "/v1/agents/:agentId/sessions" } }));
  assert.deepEqual(await first, await second);
  const snapshot = api.requestPerformanceSnapshot();
  assert.equal(snapshot.active, 0);
  assert.equal(snapshot.coalesced, 1);
  assert.equal(snapshot.samples.at(-1).serverMs, 42.5);
  assert.equal(JSON.stringify(snapshot).includes("private"), false);
  const retry = api.requestJson(options);
  assert.equal(calls, 2);
  respond(Response.json([]));
  await retry;
});

test("credentials, destination, mutation, and cancellation isolate requests", async () => {
  const responses = [];
  globalThis.fetch = () => new Promise((resolve) => responses.push(resolve));
  const pending = [api.requestJson({ path: "/v1/config" })];
  api.setDashboardAuthToken("new-session");
  pending.push(api.requestJson({ path: "/v1/config" }));
  pending.push(api.requestJson({ path: "/v1/config", apiBase: "http://other.test" }));
  pending.push(api.requestJson({ path: "/v1/config", method: "POST", body: {} }));
  pending.push(api.requestJson({ path: "/v1/config", method: "POST", body: {} }));
  pending.push(api.requestJson({ path: "/v1/config", signal: new AbortController().signal }));
  assert.equal(responses.length, 6);
  responses.forEach((respond) => respond(Response.json({})));
  await Promise.all(pending);
});

test("cancelled reads finish accounting and keep the session", async () => {
  const controller = new AbortController();
  globalThis.fetch = async (_url, options) => {
    controller.abort();
    assert.equal(options.signal.aborted, true);
    throw new DOMException("Aborted", "AbortError");
  };
  await api.requestJson({ path: "/v1/config", signal: controller.signal });
  const snapshot = api.requestPerformanceSnapshot();
  assert.equal(snapshot.active, 0);
  assert.equal(snapshot.samples.at(-1).outcome, "aborted");
  assert.equal(api.getDashboardAuthToken(), "new-session");
});

test("a stalled GET reaches its deadline and records a failure without clearing credentials", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  globalThis.fetch = (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
  });
  const pending = api.requestJson({ path: "/v1/memories?limit=1" });
  t.mock.timers.tick(30000);
  assert.deepEqual(await pending, { ok: false, status: 0, data: null });
  assert.equal(api.requestPerformanceSnapshot().active, 0);
  assert.equal(api.requestPerformanceSnapshot().samples.at(-1).outcome, "failed");
  assert.equal(api.getDashboardAuthToken(), "new-session");
});
