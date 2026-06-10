# examples

Drop-in pieces that adapt the stack-agnostic core to a specific project. Nothing
here is required — the core (`plan-loop.sh`, `code-run.sh`, the bot) runs without it.

## `rules/` — project rule files

House policies injected verbatim into every agent prompt (author, reviewer, coder).
Point the `RULES_FILE` env var at one of these, or copy it into a repo as
`.agent-workflow-rules.md` (auto-detected). See the top-level README → "Project rules".

- [`rules/laravel-no-ddl.md`](rules/laravel-no-ddl.md) — "the DB schema is managed by hand; never emit migrations/DDL".
- [`rules/no-new-dependencies.md`](rules/no-new-dependencies.md) — "don't add packages without human sign-off".

## `laravel/` — a complete deploy adapter

`deploy-run.sh` is pluggable: you give it a `GATE_CMD` (lint/build/test) and a
`DEPLOY_CMD` (the thing that actually ships). This folder is a worked example for a
Laravel app deployed with a `ship` script. See [`laravel/README.md`](laravel/README.md).
