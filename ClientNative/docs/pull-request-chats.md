# Pull request review and chats

Opening a PR loads its diff and saved review draft. It does not create or open a chat. **Send Review** collects the requested fixes and selected provider comments, resolves the associated chat, and sends one message directly. If no chat exists, Core creates one whose title contains the provider-scoped PR ID. Repeated sends reuse the associated chat; concurrent resolution creates a single chat.

PR identity consists of the provider ID, repository and provider-scoped review ID. Titles and displayed PR numbers are not used as identity. Associations live in Core's workspace in `code-review-sessions.json`; clients on the same Core share them.

A PR can have several working chats. The actions menu selects a chat as the review destination; **Link working chat…** attaches an existing chat without opening it or replacing its history. Other chats for the linked session's project task, and descendants of those chats, are also associated. Deleted sessions are omitted; when no associated session remains, opening the PR creates a replacement.

Agents call `code_review.link_session` after creating or discovering a PR for their task. The tool accepts `providerId` and `reviewId`; Core obtains the canonical repository and PR identity from the provider and assigns the caller's actual session. This is an explicit semantic action, not an inference from assistant text or PR titles. External CLI-created PRs cannot be discovered automatically unless the agent calls this tool or the user links the working chat.

Code view offers **Side by side** and **One side**. The choice is saved across PRs. Phones default to One side, with a separate mobile preference and a compact title/actions header. One side shows deletions followed by additions in each change block, with old/new line numbers in a single code column. Comments and requested fixes retain their original diff side in both modes.

In Code view, use the plus beside a diff line to write a requested fix. These editors appear under their lines. **Send Review** sends nonempty editors and included provider comments as one message. Only after Core accepts the message does the chat panel open and the submitted draft clear. Failed sends preserve the draft and reuse a persisted request ID on retry, preventing a transport retry from duplicating the review. Drafts are saved locally per Core endpoint and PR. The minus/plus side and original code are kept with each draft. Drafts whose original code no longer matches are listed outside the current diff instead of silently moving onto another change.

Provider comments are shown in Summary, where they can be selected for Send Review. Code shows the diff and local line editors only; it has no separate comments pane. Drafts outside the loaded diff are available in Summary. On phones, selecting a PR pushes a native NavigationStack destination with the system Back button; PR actions live in the navigation toolbar. Local requested fixes are separate from provider-published replies.

API:

- `GET /v1/code-reviews/:providerId/:reviewId/sessions?repository=...` lists associated session summaries.
- `POST /v1/code-reviews/:providerId/:reviewId/sessions` accepts `{ repository, agentId, sessionId?, title? }`. Without `sessionId`, it reopens or creates the PR chat. With `sessionId`, it attaches that existing session.

Core must support the PR session API and session message endpoint. Connection errors are reported on explicit linking or submission; opening a PR and editing its draft remain usable without a chat connection.

Debug iOS builds support `--review-ui-fixture` for isolated Simulator QA. It uses a mock PR and intercepted HTTP responses; no live account, model or provider publication is involved.
