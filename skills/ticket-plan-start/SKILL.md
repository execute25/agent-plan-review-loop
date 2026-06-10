---
name: ticket-plan-start
description: Author or refine a ticket implementation plan in a file, verifying against the real repo. Usage: /ticket-plan-start docs/tickets/plans/TP-XXXX-plan.md
argument-hint: <plan-file-path>
---

You are the PLAN AUTHOR for the ticket whose plan file is at `$ARGUMENTS`. You write the plan, not production code.

1. Read the plan file `$ARGUMENTS`. If a sibling `*-review.md` exists, treat every `[BLOCKING]` item as mandatory — address it, do not argue.
2. Verify against the ACTUAL repo before writing: confirm file paths and method signatures with Grep/Read. Never guess — if a fact is uncertain, add a `VERIFY: ...` checklist item instead.
3. Fill, concretely (exact paths, exact changes): **Goal**, **Non-goals**, **Decisions** (final choices only — no debate prose), **Implementation checklist**, **API / behaviour notes**, **Testing notes**. Stay aligned with `CLAUDE.md` / `AGENTS.md` if present.
4. Edit ONLY the existing plan file — no rewrite from scratch, no new files.
5. Prepend ONE line to **## Plan changelog** (newest first): `YYYY-MM-DD — what changed and why` (delta only; never paste old plan text).
6. When the plan is solid and all prior `[BLOCKING]` items are resolved, end with exactly: `✓ Plan ready`
