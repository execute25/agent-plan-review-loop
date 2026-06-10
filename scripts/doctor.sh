#!/usr/bin/env bash
# doctor.sh — preflight check for the agent-plan-review-loop CLI flow.
#
# Verifies the MINIMAL requirements only: git, bash, the `claude` CLI, a target
# git repo, and the plan template. It does NOT require Python, Telegram, GATE_CMD,
# or DEPLOY_CMD — those are optional/advanced and not needed to try the project.
#
# Usage:
#   bash scripts/doctor.sh                      # checks the current directory as the target repo
#   REPO=/path/to/your-repo bash scripts/doctor.sh
#
# Exit: 0 = all REQUIRED checks passed | 1 = a required tool / file / repo is missing.

set -u

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Colour only when writing to a terminal (portable; degrades to plain text in pipes/CI).
if [ -t 1 ]; then
  G="$(printf '\033[32m')"; R="$(printf '\033[31m')"; Y="$(printf '\033[33m')"; N="$(printf '\033[0m')"
else
  G=""; R=""; Y=""; N=""
fi

fail=0
ok()   { printf '  %s OK %s  %s\n'  "$G" "$N" "$1"; }
err()  { printf '  %sERR %s  %s\n'  "$R" "$N" "$1"; fail=1; }
warn() { printf '  %sWARN%s  %s\n'  "$Y" "$N" "$1"; }

printf '\nagent-plan-review-loop — preflight (CLI flow)\n'
printf 'toolkit: %s\n\n' "$TOOLKIT_DIR"

printf 'Required:\n'

# --- required CLI dependencies ---
if command -v git >/dev/null 2>&1; then
  ok "git found — $(git --version 2>/dev/null | head -1)"
else
  err "git not found in PATH — install git."
fi

if command -v bash >/dev/null 2>&1; then
  ok "bash found — ${BASH_VERSION:-version unknown}"
else
  err "bash not found in PATH."
fi

if command -v claude >/dev/null 2>&1; then
  ok "claude CLI found — $(command -v claude)"
else
  err "claude CLI not found in PATH — install Claude Code, then run 'claude' once to authenticate."
fi

# --- plan template (proves this is a complete toolkit checkout) ---
if [ -f "${TOOLKIT_DIR}/templates/_TEMPLATE.md" ]; then
  ok "plan template present — templates/_TEMPLATE.md"
else
  err "missing ${TOOLKIT_DIR}/templates/_TEMPLATE.md — incomplete clone of the toolkit?"
fi

# --- target git repo (current dir, or $REPO) — context for plan-loop, NOT a hard dependency ---
# Use `git rev-parse` (not `-d "$REPO/.git"`) so git worktrees, where .git is a FILE, also pass.
# An absent target repo is a WARN (you just haven't picked a project yet), not a failure — so
# running this straight after `git clone` from any directory doesn't error.
REPO_SET="${REPO:-}"
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -n "${REPO}" ] && git -C "${REPO}" rev-parse --show-toplevel >/dev/null 2>&1; then
  ok "target git repo — $(git -C "${REPO}" rev-parse --show-toplevel 2>/dev/null)"
elif [ -n "${REPO_SET}" ]; then
  err "REPO is set but is not a git repo: ${REPO_SET} (run 'git init' there, or fix REPO)."
else
  warn "no target repo here — cd into the repo you want to change, or set REPO=/path/to/it (plan-loop.sh needs one)."
fi

# --- optional, never fatal: just informational ---
printf '\nOptional (not needed for the CLI flow):\n'
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  ok "python found — only needed for the Telegram bot"
else
  warn "python not found — fine; only the optional Telegram bot needs it."
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf '%sSome required checks failed.%s Fix the ERR line(s) above, then re-run.\n\n' "$R" "$N"
  exit 1
fi
printf '%sAll required checks passed.%s Next:\n' "$G" "$N"
printf '  cd /path/to/your-project\n'
printf '  REPO="$PWD" bash %s/scripts/plan-loop.sh TASK-1 "describe the change"\n\n' "$TOOLKIT_DIR"
exit 0
