import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";

const source = await readFile(new URL("../src/shared/sessionReferences.ts", import.meta.url), "utf8");
const javascript = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 } }).outputText;
const mentions = await import(`data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}`);

test("session addresses survive duplicate titles and copied markdown", () => {
  const first = mentions.sessionMentionMarkdown({ agentId: "one", id: "session-a", title: "Review [UI]" });
  const second = mentions.sessionMentionMarkdown({ agentId: "two", id: "session-b", title: "Review [UI]" });
  assert.deepEqual(mentions.sessionReferencesInText(`${first} ${second} ${first}`), [
    { agentId: "one", sessionId: "session-a" }, { agentId: "two", sessionId: "session-b" }
  ]);
  assert.match(first, /Review \\\[UI\\\]/);
});

test("@ query works at the start or in the middle with unicode and following text", () => {
  assert.deepEqual(mentions.mentionQueryAtCursor("@", 1), { start: 0, end: 1, query: "" });
  assert.deepEqual(mentions.mentionQueryAtCursor("Read @ревью please", 11), { start: 5, end: 11, query: "ревью" });
  assert.equal(mentions.mentionQueryAtCursor("mail@example.org", 16), null);
});

test("ordinary mentions and unrelated URL schemes are not session references", () => {
  assert.deepEqual(mentions.sessionReferencesInText("@file.swift @skill mail@example.org"), []);
  assert.equal(mentions.sessionReferenceFromUrl("javascript:alert(1)"), null);
  assert.equal(mentions.sessionReferenceFromUrl("sloppy://session?agent=one"), null);
});

async function loadTypeScript(relative) {
  const source = await readFile(new URL(relative, import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 } }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
}

test("session links use the agent chat route, including hidden worker IDs", async () => {
  const navigation = await loadTypeScript("../src/app/routing/navigateToSessionScreen.ts");
  const routing = await loadTypeScript("../src/app/routing/dashboardRouteAdapter.ts");
  const route = routing.parseRouteFromPath(navigation.agentSessionPath({ agentId: "worker", sessionId: "session-hidden-worker" }));
  assert.equal(route.section, "agents");
  assert.equal(route.agentId, "worker");
  assert.equal(route.agentTab, "chat");
  assert.equal(route.agentInitialChatSessionId, "session-hidden-worker");
});
