---
layout: doc
title: Agent chat (Dashboard)
---

# Agent chat (Dashboard)

The Dashboard gives you two ways to talk to an agent in a full-page chat: **Agents** (per-agent workspace) and **Project chats** (workspace tied to a project). Both use the same chat UI; the difference is how you arrive, how sessions are listed, and how new sessions are associated with a project.

## Open Agents chat

1. In the sidebar, choose **Agents** (support-agent icon).
2. Select an agent from the list.
3. Open the **Chat** tab.

You can also land on a specific session if the URL includes the chat tab and session id (for example `/agents/<agentId>/chat` with session state restored from navigation).

**What you see in the session list:** Sessions for that agent that are normal user chats. Task-linked threads can appear under a **Tasks** section in the sidebar when applicable; internal comment sessions are not mixed into the main list.

## Open Project chats

1. In the sidebar, use the **Project chats** rail (under the main nav when projects exist). Each chip is a project—click one to open project chat for that project.
2. The page shows the project name and an **Agent** field. Search or pick an agent; the chat loads once an agent is selected.

If no project is selected yet, choose a project from the rail first. If the rail is empty, add or load projects from **Projects** as usual.

**URL shape (deep links):** `/chats/<projectId>` and, once you pick an agent or session, `/chats/<projectId>/<agentId>` and optionally `/chats/<projectId>/<agentId>/<sessionId>`. The address updates when you change the active session so you can bookmark or share a link.

While you are on Project chats, no main sidebar tab is marked active (so **Projects** does not look selected); the **Project chats** rail shows which project you are in.

## Session list: Agents vs Project chats

| | **Agents chat** | **Project chats** |
| --- | --- | --- |
| Scope | All eligible sessions for the agent | Only sessions **for the selected project** |
| How scope is enforced | Listed from the agent | Sessions are requested with the project id; the UI also ignores updates for other projects so the list stays accurate when streams fire |
| Empty list | Generic “no sessions yet” guidance | Message tailored to having no sessions **for this project yet** |

New sessions created in Project chats **store the project** on the session so they stay in that project’s list.

## Starting and resetting sessions

- **New session** (toolbar plus in the session sidebar): Creates a session quickly. It does **not** wait on a memory checkpoint from the previous session.
- **`/new` or `/clear`** in the composer: Same as starting fresh, but uses the **checkpoint** flow tied to the current session when applicable (pair with “new session” behavior you expect from the CLI-style commands).

Project id is sent when creating a session from Project chats so the thread stays scoped.

## Header actions (Share, Debug, Delete)

- **Share** and **Debug** stay visible in the header for a consistent layout. Until you **select or create a session**, they are **disabled** (tooltips explain that you need a session). After a session is active, use **Share** for actions such as copying the session file path or downloading the session, and **Debug** for session-scoped debugging tools.
- **Delete** is always shown; it is disabled when there is no active session or while sending is in progress.

## Related

- [Dashboard Style](/dashboard-style) — UI tokens and layout notes for the shell
- [Project Context](/guides/project-context) — how project context fits the wider product

## Auto-approve unanswered agent questions

In **Agents → Config → Agent Runtime**, **Auto-approve unanswered questions** is
on by default and saved per agent. You can disable it for individual agents. New `planning.request_input`
questions wait for an answer for two minutes. If no answer arrives, Sloppy resumes
that task and asks the agent to choose using the task and conversation context.
The agent explains its decision; Sloppy does not pick the first option or invent a
user answer. The chat records the automatic continuation.

The timer runs on the server, so the Dashboard can be closed. Pending deadlines
are restored when the server restarts. Answering, cancelling, or interrupting the
session prevents automatic continuation. Disabling the setting also prevents
pending requests from being automatically resolved. Tool execution permissions
continue to use the agent's tool policy.
