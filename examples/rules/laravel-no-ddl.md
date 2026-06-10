# Project rules: no DB migrations / no DDL

Hard constraints for the planning, review, and coding agents. When this file is
selected (via `RULES_FILE`, or dropped in a repo as `.agent-workflow-rules.md`),
its contents are injected verbatim into every agent prompt and OVERRIDE the plan.

## The database schema is managed BY HAND — never emit DDL

- The DB schema is changed manually by a human, NOT through framework migrations.
  Never propose, plan, or write a migration or any DDL — e.g. `Schema::`, `migrate`,
  `ALTER`, `CREATE TABLE`, `DROP` (the examples are Laravel/SQL; the rule is general).
- If code relies on a column or table that has no migration, ASSUME it already
  exists (added by hand) and record that under `## Assumptions` in the plan
  (e.g. "assumes `orders.refunded_at` exists; add by hand if missing").
- If a task genuinely needs a NEW schema change, do NOT plan the DDL. Raise it as a
  manual step for the human, and implement only the application code that depends on it.
- Reviewer: flag any proposed migration or DDL as `[BLOCKING]`.
