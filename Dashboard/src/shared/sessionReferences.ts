export interface SessionReference {
  agentId: string;
  sessionId: string;
}

export interface MentionSuggestion {
  id: string;
  group: "Sessions" | "Files" | "Skills";
  title: string;
  subtitle: string;
  insertion: string;
}

export function sessionReferenceFromUrl(value: string): SessionReference | null {
  try {
    const url = new URL(value);
    const agentId = url.searchParams.get("agent");
    const sessionId = url.searchParams.get("id");
    return url.protocol === "sloppy:" && url.hostname === "session" && agentId && sessionId
      ? { agentId, sessionId } : null;
  } catch {
    return null;
  }
}

export function sessionReferencesInText(text: string): SessionReference[] {
  const references = new Map<string, SessionReference>();
  for (const match of text.matchAll(/sloppy:\/\/session\?[^\s<>)\]]+/g)) {
    const reference = sessionReferenceFromUrl(match[0]);
    if (reference) references.set(JSON.stringify(reference), reference);
  }
  return [...references.values()];
}

export function sessionMentionMarkdown(session: { id: string; agentId: string; title?: string }): string {
  const label = (session.title || session.id).replace(/\\/g, "\\\\").replace(/[\[\]]/g, "\\$&").replace(/\n/g, " ");
  const query = new URLSearchParams({ agent: session.agentId, id: session.id });
  return `[@${label}](sloppy://session?${query})`;
}

export function mentionQueryAtCursor(text: string, caret: number) {
  const cursor = Math.max(0, Math.min(caret, text.length));
  const start = text.lastIndexOf("@", Math.max(0, cursor - 1));
  if (start < 0 || (start > 0 && !/\s/.test(text[start - 1]))) return null;
  const query = text.slice(start + 1, cursor);
  if (/\s/.test(query)) return null;
  let end = cursor;
  while (end < text.length && !/\s/.test(text[end])) end += 1;
  return { start, end, query };
}
