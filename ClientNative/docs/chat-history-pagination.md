# Chat history loading

The main chat requests the latest 64 events rather than the full session. Earlier
pages load when the reader scrolls within 80 points of the top. Initial positioning
and layout changes do not start downloads. Prepending history preserves the visible
message and its offset on iOS and macOS.

`GET /v1/agents/{agentId}/sessions/{sessionId}?eventLimit=64` returns the usual
`summary` and `events`, plus:

- `historyPage.hasMore`: whether an older page exists.
- `historyPage.nextBefore`: an opaque cursor passed unchanged as `before` for the
  next request. The server uses an exclusive JSONL byte boundary, so appending new
  events does not shift existing pages.
- `stateEvents`: current run status, unanswered input request, and latest child
  session/task events. Current state remains available outside the history window.

The server accepts `eventLimit` from 1 through 200 and validates cursor boundaries.
Without pagination parameters the endpoint retains its full-history behavior.
Status-only consumers use `eventLimit=1` and `stateEvents` rather than downloading
whole transcripts. A maintained summary sidecar allows warm page reads without
decoding the complete log; older sidecars are rebuilt once.

Only one older-page request runs at a time. Leaving the chat cancels it, and late
responses cannot update another conversation. Failed requests keep the loaded
messages and cursor and expose Retry. Small native spinners indicate initial and
older-page loading. Control-only pages are skipped until a renderable page is found.

Servers that ignore the new query parameters still work through the existing local
64-message visibility window. Network and server-read savings require the updated
Core as well as the client.
