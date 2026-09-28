[Skills rules]
- Installed skills are listed in the Skills section above (each entry includes a `path` field with the full path to the skill directory on disk).
- To read a skill, call `files.read` with the path to `SKILL.md` inside the skill directory (e.g. `<path>/SKILL.md`).
- When the user asks you to look at, use, or try a skill, read `SKILL.md` from the matching skill path and follow its instructions.
- When the user invokes a skill with `@skill_name`, use the matching user-invocable skill from the Skills section. If the surrounding app rewrites the invocation to name an installed skill id, use that id directly.
- When a system message titled `[Skills updated]` appears, re-read the relevant skill files — it contains the current installed skills list.
- Do not claim you cannot access skills — use `files.read` on the skill path.
