import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";
import { createRequire } from "node:module";

const bundle = await build({
  stdin: { contents: 'export * from "./src/features/notifications/proactiveNotificationGroups"; export { parseRouteFromPath, buildPathFromRoute } from "./src/app/routing/dashboardRouteAdapter";',
    resolveDir: new URL("..", import.meta.url).pathname, loader: "ts" },
  bundle: true, write: false, format: "cjs", platform: "node"
});
const module = { exports: {} };
new Function("require", "module", "exports", bundle.outputFiles[0].text)(createRequire(import.meta.url), module, module.exports);
const { proactiveNotificationGroups } = module.exports;
const finding = (id, extra = {}) => ({ id, agentId: "a", source: { title: "Task" }, reason: "Review needed", sessionId: "s", deliveredAt: "2026-09-29T06:00:00Z", ...extra });

test("recovering history preserves the grouped live notification identity", () => {
  const groups = proactiveNotificationGroups([finding("2"), finding("1")]);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].id, "proactive:1:2");
  assert.equal(groups[0].metadata.source, "proactivity");
  assert.equal(groups[0].read, false);
});
test("quiet-hour findings do not become recovered notifications", () => {
  assert.deepEqual(proactiveNotificationGroups([finding("1", { deliveredAt: undefined })]), []);
});
test("read, dismissed and resolved findings recover without an unread badge", () => {
  const groups = proactiveNotificationGroups([finding("1", { readAt: "now" }), finding("2", { resolvedAt: "now" }), finding("3", { dismissedAt: "now" })]);
  assert.equal(groups[0].read, true);
});
test("findings from different deliveries or agents stay separate", () => {
  const groups = proactiveNotificationGroups([finding("1"), finding("2", { agentId: "b" }), finding("3", { deliveredAt: "2026-09-29T07:00:00Z" })]);
  assert.equal(groups.length, 3);
});

test("attention routes survive a reload", () => {
  const route = module.exports.parseRouteFromPath("/agents/my-agent/attention");
  assert.equal(route.agentTab, "attention");
  assert.equal(module.exports.buildPathFromRoute(route), "/agents/my-agent/attention");
});
