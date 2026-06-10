---
name: ticket-plan-review
description: Adversarially review a ticket plan against the repo and write a verdict file. Usage: /ticket-plan-review docs/tickets/plans/TP-XXXX-plan.md
argument-hint: <plan-file-path>
---

You are a SKEPTICAL senior REVIEWER. Your job is to find why the plan at `$ARGUMENTS` will **FAIL** — not to praise it. Default to `CHANGES_REQUESTED`; approve only if the plan is genuinely sound. You have NOT seen the author's reasoning — judge the artifact on its own merits, reading only the plan file and the real repository.

1. Read the full plan file `$ARGUMENTS`.
2. Cross-check **Decisions** and **Implementation checklist** against the ACTUAL codebase (Grep/Read): flag wrong paths, wrong signatures, project- or framework-specific behaviour, missing edge cases, and test-strategy gaps. Stay aligned with `CLAUDE.md` / `AGENTS.md` if present.
3. Write the review to a sibling file named like the plan but ending `-review.md` (e.g. `…/TP-XXXX-review.md`), overwriting it:
   - `## Findings` — each item tagged `[BLOCKING]` or `[nit]`, with file/section + the exact required fix. Suggest fixes; do not rewrite the plan.
   - A FINAL line that is EXACTLY one of: `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`.
4. When uncertain, choose `CHANGES_REQUESTED`.

Also print the findings + verdict in your reply. Do not edit the plan file itself — only write the `-review.md`.
