# agent-plan-review-loop

An automated, **multi-agent** ticket pipeline: an Author model drafts an implementation
plan, an adversarial Reviewer model tears it apart against your *real* codebase, and the
loop iterates until the plan is **APPROVED** — then (optionally) a Coder implements it in
an isolated git worktree, and a pluggable gate ships it. Built on
[Claude Code](https://claude.com/claude-code); model providers are pluggable — the reviewer
can already run on another model family via Cursor. Drive it from the CLI or a Telegram bot.

> **File = source of truth, not chat.** Every artifact (plan, review, questions, diff) is a
> file in your repo. Each model runs as a fresh `claude -p` process, so the reviewer never
> sees the author's reasoning — it judges the artifact on its own merits.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Try it in 5 minutes (CLI only)

No Telegram, no deploy, no Python — just plan a ticket and (optionally) have it implemented on
a throwaway branch. **Telegram and deploy are optional, advanced features — skip them for now.**

**1. Get the prerequisites** — the [Claude Code](https://claude.com/claude-code) CLI
(authenticated), `git`, and `bash` (Git Bash or WSL on Windows). Then clone, and run the
preflight **from the repo you want to change**:

```bash
git clone https://github.com/execute25/agent-plan-review-loop.git
cd /path/to/your-project                                            # the repo you want to change
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/doctor.sh  # prints OK/ERR for each requirement
```

**2. Plan a ticket** — from inside the repo you want to change (your *target* repo):

```bash
cd /path/to/your-project
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/plan-loop.sh TASK-1 "add a CSV export button to the reports page"
```

An Author drafts a plan, an adversarial Reviewer tears it apart against your real code, and the
loop repeats until it's **APPROVED** (exit `0`) — or pauses to ask you a question (exit `4`).

**3. (Optional) Implement the approved plan** on an isolated branch:

```bash
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/code-run.sh TASK-1
```

**What you get:** in your target repo, under `docs/tickets/plans/` — `TASK-1-plan.md`,
`TASK-1-review.md`, a `.log`, and (after step 3) `TASK-1.diff` on branch `auto/TASK-1`. These
are *local-ignored* (added to `.git/info/exclude`), so they never show in `git status`. The
flow **never pushes, merges, or deploys** — you review the diff and ship it yourself.

→ Full walkthrough, exactly what gets modified, and troubleshooting: **[docs/quickstart.md](docs/quickstart.md)**.
Deploying the coded branch is a separate, opt-in step — see [Deploy](#deploy-optional-pluggable).

---

## What it does

```
            ┌─────────── complexity tier (Haiku) ───────────┐
            ▼                                                 │
  /plan ──► AUTHOR ──► REVIEWER ──► APPROVED? ──no──► AUTHOR (revise) ──┘
  (Opus/    drafts     adversarial    │                  ▲
   Sonnet)  plan.md    review.md       │ yes              │ [BLOCKING] items
                                       ▼
                              CODER (isolated worktree, branch auto/<ticket>)
                                       │  writes code + tests, leaves a diff
                                       ▼
                              DEPLOY (manual tap) ── gate ──► your DEPLOY_CMD
                              merge → GATE_CMD → push → deploy → cleanup
```

- **Adversarial review by a *different* model.** The reviewer is told to find why the plan
  will *fail* and defaults to `CHANGES_REQUESTED`. Author and reviewer are always different
  model tiers (cheap decorrelation; optionally route the reviewer through Cursor for true
  cross-family review).
- **Complexity-aware.** A Haiku classifier tags each task T0/T1/T2 and routes model strength
  and iteration count accordingly.
- **Isolated coding.** The coder works in a throwaway git worktree on an `auto/<ticket>`
  branch — never your working tree, never a push, never your main branch.
- **Pluggable, manual deploy.** Production is never automatic. The deploy step is two env
  vars (`GATE_CMD` + `DEPLOY_CMD`) so it fits any stack; a Laravel example ships in `examples/`.
- **Stop-and-ask.** When the author hits a decision only a human can make, it writes a
  questions file and pauses (CLI) or sends inline buttons (bot).

---

## Requirements

- **[Claude Code](https://claude.com/claude-code) CLI**, authenticated (`claude` on your PATH).
- **git** and **bash** (on Windows: Git Bash or WSL — the scripts are bash).
- **Python 3.10+** — only for the optional Telegram bot.

The whole thing shells out to `claude -p`, so it must run on a machine where Claude Code is
installed and your target repos are checked out. Run `bash scripts/doctor.sh` to verify these
in one shot (Python/Telegram/deploy are **not** required for the CLI flow).

---

## Install

```bash
git clone https://github.com/execute25/agent-plan-review-loop.git
cd agent-plan-review-loop

# (optional) install the interactive skills into ~/.claude/skills
bash scripts/install.sh
```

There is nothing to build. The CLI is just bash scripts; the bot needs `pip install -r bot/requirements.txt`.

---

## Optional: advanced features

Everything below is **optional** — the [5-minute CLI flow](#try-it-in-5-minutes-cli-only) above
is the whole core. Add these only once the basic `plan-loop.sh` → `code-run.sh` flow works for you.

- **Telegram bot** — drive the loop from your phone: inline buttons (answer questions, write
  code, deploy), free-text/photo steering, parallel tickets. Needs Python + its own BotFather
  token, and adds no capability the CLI lacks. See **[bot/README.md](bot/README.md)**.
- **Deploy** — gate-and-ship the coded branch with your own command. See [Deploy](#deploy-optional-pluggable).
- **Project rules** — house policies injected into every prompt (e.g. "no DB migrations"). See
  [Project rules](#project-rules-rules_file).

---

## How it works

| stage | script | what happens |
|-------|--------|--------------|
| classify | `plan-loop.sh` | Haiku tags the task **T0/T1/T2** → picks author/reviewer models + iteration cap |
| plan | `plan-loop.sh` | Author drafts/revises `…-plan.md`; Reviewer writes `…-review.md` ending in a `VERDICT:` line; loop until `APPROVED`, an oscillation guard trips, or the cap is hit |
| code | `code-run.sh` | Coder implements the approved plan in an isolated worktree; emits `…-diff` |
| deploy | `deploy-run.sh` | (manual) merge `auto/<ticket>` → run your `GATE_CMD` → push → run your `DEPLOY_CMD` → clean up; rolls back on gate failure |

### Exit codes (`plan-loop.sh`)

- `0` — plan approved.
- `2` — stuck (plan unchanged after a revision but still not approved) → human needed.
- `3` — not converged within `MAX_ITERS` → human needed.
- `4` — the author needs a decision only you can make → answer the questions file, then re-run.

### Clarifying questions & assumptions

The author separates three kinds of uncertainty:

- **Uncertain fact** (a path, a signature) → it resolves via Grep/Read, or leaves a `VERIFY:` item.
- **Decision with a sensible default** → it picks the default and records it under `## Assumptions`.
- **A fork only you can own** (product / scope / risk) → it does *not* guess: it writes
  `…-questions.md` with `STATUS: NEEDS_ANSWERS` and the loop pauses (exit 4). Fill each `A:`
  line, set `STATUS: ANSWERED`, and re-run. (In the bot this is automatic — inline buttons.)

---

## Configuration

Set via env vars (CLI) or `bot/.env` (bot).

| var | default | meaning |
|-----|---------|---------|
| `REPO` | current git toplevel | target codebase |
| `RULES_FILE` | `<repo>/.agent-workflow-rules.md` | optional project rules injected into every prompt (see below) |
| `MAX_ITERS` | auto by tier (3 or 6) | max author↔reviewer rounds |
| `AUTHOR_MODEL` / `REVIEWER_MODEL` / `CODER_MODEL` | auto by tier | pin a model to override auto-routing |
| `SCORER_MODEL` | `haiku` | the complexity classifier |
| `PERM_MODE` | `acceptEdits` | `claude --permission-mode` |
| `LOG_COST` | off | log per-call `total_cost_usd` |
| `REVIEWER_PROVIDER` | `claude` | set `cursor` to review via the Cursor CLI (cross-family decorrelation) |
| `GATE_CMD` / `DEPLOY_CMD` | — | the pluggable deploy gate + deploy step (see below) |

### Project rules (`RULES_FILE`)

House policies the agents must obey, injected verbatim into the author, reviewer, and coder
prompts (they OVERRIDE the plan). Point `RULES_FILE` at a markdown file, or drop
`.agent-workflow-rules.md` in a repo (auto-detected). Ready-made templates live in
[`examples/rules/`](examples/rules) — e.g. *"the DB schema is managed by hand, never emit
migrations"* or *"no new dependencies without sign-off"*. The default prompts are
stack-agnostic; everything project-specific comes from here (and from your `CLAUDE.md` /
`AGENTS.md`, which the agents also respect).

### Deploy (optional, pluggable)

`deploy-run.sh` does the git plumbing (merge → gate → push → deploy → cleanup) and delegates
the stack-specific steps to two env vars:

- **`DEPLOY_CMD`** (required for deploy) — the command that ships the merged code.
- **`GATE_CMD`** (optional) — lint/build/tests; a non-zero exit rolls the merge back.

Both run with `cwd=REPO` and get `REPO`, `TICKET`, `SHIP_PROJECT`, `ORIG_HEAD`, `NEW_HEAD`
in the environment. A complete **Laravel + `ship`** adapter (gate = `php -l` + boot + phpunit;
deploy = a `ship` script) is in [`examples/laravel/`](examples/laravel).

---

## Layout

```
scripts/
  plan-loop.sh        # the automated author↔reviewer loop (+ tier classifier, steering, retries)
  code-run.sh         # implement an approved plan in an isolated worktree
  deploy-run.sh       # generic, pluggable gate-and-ship (GATE_CMD + DEPLOY_CMD)
  install.sh          # copy the skills into ~/.claude/skills
  lib/                # claude/cursor retry-with-backoff helpers
skills/               # interactive /ticket-plan-start and /ticket-plan-review
templates/            # the plan-file skeleton
bot/                  # the Telegram bot (optional) — see bot/README.md
examples/
  rules/              # RULES_FILE templates
  laravel/            # a complete deploy adapter for Laravel + `ship`
```

Plan artifacts are written into the **target repo** at `docs/tickets/plans/<ticket>-*`, and
the scripts add that path to the repo's local `.git/info/exclude` so they never get committed.

---

## Limitations & notes

- **Windows-first.** Built and run daily on Windows + Git Bash; the bash scripts and the
  macOS/Linux autostart helpers are written to be portable but get less mileage there.
- **The Telegram bot UI is in Russian** (it was built for its author). The CLI, scripts, and
  all docs are English. PRs to internationalize the bot strings are very welcome.
- **No DDL by design philosophy** — schema changes are treated as a human, manual step *when
  you opt into that rule* (see `examples/rules/laravel-no-ddl.md`). It is not forced on you.
- The coder's worktree usually lacks installed dependencies, so it writes tests but often
  can't *run* them there — run them (or let the deploy gate run them) before shipping.

## Roadmap

- Feature tests against a dedicated test DB (seed from a manual schema dump, not migrations).
- A risk scorer separate from the complexity tier (`risk = max(model-judgement, rules)`).
- More deploy adapters in `examples/` (containers, serverless).
- Bot i18n.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
