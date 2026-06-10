# Quickstart (CLI only)

The fastest way to try **agent-plan-review-loop** — no Telegram, no deploy, no Python.
You'll plan a ticket and (optionally) have it implemented on a throwaway branch, all from the
shell. Telegram and deploy are separate, opt-in features; ignore them until this flow works.

## Prerequisites

- The [Claude Code](https://claude.com/claude-code) CLI, **authenticated** (run `claude` once).
- `git` and `bash` (on Windows: Git Bash or WSL — these are bash scripts, not PowerShell).

You'll verify all of this with `scripts/doctor.sh` in **step 2** (after cloning). It prints
`OK`/`ERR` for each requirement and exits non-zero only if a required CLI tool is missing — it
does **not** require Python, Telegram, or any deploy configuration.

## 1. Clone the toolkit

```bash
git clone https://github.com/execute25/agent-plan-review-loop.git
```

Nothing to build — the CLI is plain bash.

## 2. Check your setup

Run the preflight **from the repo you want to change** (your *target* repo, not the toolkit):

```bash
cd /path/to/your-project
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/doctor.sh
```

It exits non-zero only if a required CLI tool (`git` / `bash` / `claude`) or the plan template
is missing. No target repo yet? It only warns — `cd` into one before the next step.

## 3. Plan a ticket

From your target repo (stay in the directory from step 2):

```bash
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/plan-loop.sh TASK-1 "add a CSV export button to the reports page"
```

An Author model drafts a plan; an adversarial Reviewer cross-checks it against your real code
and writes a verdict; the loop repeats until the plan is **APPROVED**. The id (`TASK-1`) is
yours to choose — any `letters/digits/.-_` (e.g. `TASK-1`, `TP-1234`).

Exit codes: `0` approved · `4` it needs a decision from you (see troubleshooting) · `2`/`3`
it couldn't converge.

## 4. (Optional) Implement the approved plan

```bash
REPO="$PWD" bash /path/to/agent-plan-review-loop/scripts/code-run.sh TASK-1
```

The coder implements the approved plan on an isolated branch and leaves a diff. It does **not**
push, merge, or deploy — you review the diff and ship it yourself.

## What this modifies

In your **target repo**:

- **Creates `docs/tickets/plans/`** and writes the ticket artifacts there:
  `TASK-1-plan.md`, `TASK-1-review.md`, an optional `TASK-1-questions.md`, a `TASK-1.log`,
  and — after the implement step — `TASK-1.diff`.
- **Adds `docs/tickets/plans/` to `.git/info/exclude`** — a *local* ignore. Your committed
  `.gitignore` is untouched and these files are never staged, so they won't appear in
  `git status`.
- **During `code-run.sh`, creates a git worktree** on branch `auto/TASK-1`. The worktree
  lives under the **toolkit's** `.worktrees/` directory — not inside your repo.

It never:

- pushes to any remote,
- merges into your main branch,
- deploys anything.

> Deploy is a separate, opt-in step (`deploy-run.sh` driven by your own `DEPLOY_CMD`) and is
> **not** part of this quickstart. See the top-level README → *Deploy*.

## Clean up

The plan files are local-ignored, so they never pollute `git status`. To remove them:

```bash
# in your target repo:
rm -rf docs/tickets/plans
git branch -D auto/TASK-1            # only if you ran the implement step
# in the toolkit:
git -C /path/to/agent-plan-review-loop worktree prune
```

## Troubleshooting (first run)

| Symptom | Cause / fix |
|---|---|
| `claude CLI not found` | Install Claude Code and run `claude` once to authenticate. Verify with `command -v claude`. |
| `Set REPO=/path/to/target-repo …` | You're not inside a git repo and `REPO` is unset. `cd` into your project, or pass `REPO=`. |
| `Bad id …` | The ticket id must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` — e.g. `TASK-1`, `TP-1234`. |
| Loop exits **4** (needs answers) | The author wrote `docs/tickets/plans/<id>-questions.md`. Fill each `A:` line, set the first line to `STATUS: ANSWERED`, then re-run the same command. |
| Loop exits **3** (not converged) | The reviewer never approved within the round cap. Read `<id>-review.md`, sharpen the description, re-run. Raise the cap with `MAX_ITERS=8 …`. |
| Loop exits **2** (stuck) | The plan stopped changing but isn't approved. Inspect `<id>-plan.md` / `<id>-review.md`; give a clearer description. |
| `code-run.sh` prints `NO_CHANGES` (exit 5) | The coder made no edits — usually the plan targets a different repo, or the change already exists. Check the plan's file paths. |
| The loop stalls on a tool-permission prompt | Run `claude` interactively once to grant tools, or set `PERM_MODE=bypassPermissions` (less safe). |
| `API Error: 5xx` / `Overloaded` | Transient; the scripts auto-retry with backoff. If it persists, check your Claude auth/quota. |
| Windows: "command not found" / scripts won't run | Use **Git Bash** or **WSL**. The scripts are bash; they don't run in PowerShell/cmd. |

## Next steps (optional, advanced)

- **Project rules** — house policies injected into every prompt (e.g. "no DB migrations"):
  [`examples/rules/`](../examples/rules).
- **Telegram bot** — drive the loop from your phone: [`bot/README.md`](../bot/README.md).
- **Deploy** — gate-and-ship the coded branch with your own command:
  [README → Deploy](../README.md#deploy-optional-pluggable).
