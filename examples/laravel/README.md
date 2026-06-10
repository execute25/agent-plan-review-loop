# Laravel + `ship` deploy adapter

`deploy-run.sh` in the core is stack-agnostic. It does the git plumbing — merge the
coder's `auto/<ticket>` branch into your main checkout, run a gate, push, deploy,
clean up — and delegates the two stack-specific steps to env vars:

- **`GATE_CMD`** — runs after the merge, before the push. Non-zero exit ⇒ merge is
  rolled back and nothing ships.
- **`DEPLOY_CMD`** — runs after a successful push; actually ships the code.

This folder wires both to a Laravel app deployed via a `ship` script.

## Files

| file | role |
|------|------|
| `laravel-gate.sh` | `GATE_CMD`: `php -l` on changed files → app boot (`artisan --version`) → opt-in `phpunit` on changed tests |
| `laravel-deploy.sh` | `DEPLOY_CMD`: runs `bash $SHIP_SCRIPT $SHIP_PROJECT prod` |
| `pull-vendor.sh` | helper: copy `vendor/` down from a prod host so the gate can boot/test locally |
| `.env.laravel.example` | the env block to add to your `bot/.env` |

## Wire it up

Add to your `bot/.env` (absolute paths; forward slashes are fine on Windows):

```env
GATE_CMD=bash /path/to/agent-plan-review-loop/examples/laravel/laravel-gate.sh
DEPLOY_CMD=bash /path/to/agent-plan-review-loop/examples/laravel/laravel-deploy.sh
SHIP_SCRIPT=/path/to/ship.sh
RULES_FILE=/path/to/agent-plan-review-loop/examples/rules/laravel-no-ddl.md
```

`deploy-run.sh` exports `REPO`, `TICKET`, `SHIP_PROJECT`, `ORIG_HEAD`, `NEW_HEAD` to
both commands. The gate also reads optional adapter vars you can set in `bot/.env`:
`PHP` (binary), `LINT_ONLY=1` (syntax-only), and `RUN_TESTS=1` (opt-in phpunit). See
`.env.laravel.example` for the full block, including generic bot knobs like
`SHIP_PROJECTS` and `NO_DEPLOY`.

## Notes

- The gate is **no-DB by default** (lint + boot). Running `phpunit` is opt-in
  (`RUN_TESTS=1`) because most app tests need a database.
- Local edit-checkouts often lack `vendor/` (composer runs on the server). Use
  `pull-vendor.sh` to copy it down, or the gate degrades to lint-only.
- Prod is never automatic — `DEPLOY_CMD` only runs on an explicit human action.
