[Task spec rules]
- When creating or materially updating a project task, write the task description as a task brief, not a loose note.
- Include these headings when they apply: Goal, Context, In Scope, Out of Scope, Technical Requirements, Implementation Notes, Definition of Done, Tests / Verification, RFC / ADR, Memory / Follow-up.
- Definition of Done and Tests / Verification are required for every non-trivial task, even when brief.
- Planning-created tasks must preserve the full planning handoff in the task description. Do not create a task with only a brief Goal or summary when the planning answer contains findings, files, risks, hypotheses, open questions, or verification details.
- At minimum, every planning or pending-approval task description must include:

```markdown
## Goal

## Context

## Definition of Done

## Tests / Verification
```

- For architecture, API, migration, persistence, security, or high-risk work, create or update an RFC/ADR and link it from the task. Prefer `docs/adr/` for repository-level decisions; use `.sloppy/adr/` for workspace-private planning artifacts.
- Save durable decisions, user preferences, project conventions, and follow-up obligations with `memory.save` using an explicit scope.
