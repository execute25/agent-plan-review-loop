#!/usr/bin/env bash
set -euo pipefail

# agent-plan-review-loop — gate-and-deploy a coder branch (generic & pluggable).
#
# Merges auto/<ticket> into the main checkout, runs an OPTIONAL project gate
# (GATE_CMD), pushes to origin, then runs your deploy command (DEPLOY_CMD).
# Rolls the merge back if the gate fails. Triggered only by an explicit human
# action (the bot's deploy button, or a manual call) — prod is never automatic.
#
# This script is deliberately stack-agnostic: plug your own gate/deploy in via
# two env vars. Worked adapters live in examples/.
#
# Usage: REPO=/path DEPLOY_CMD='...' [GATE_CMD='...'] bash deploy-run.sh <ticket>
#
# Env:
#   REPO          target repo (default: current git toplevel)
#   DEPLOY_CMD    REQUIRED. Shell command that deploys the merged code (a deploy
#                 script, `git push` + webhook, kubectl, fly deploy, …). Run with
#                 cwd=REPO. Exported to it: REPO TICKET SHIP_PROJECT ORIG_HEAD NEW_HEAD.
#   GATE_CMD      Optional. Shell command run AFTER the merge, BEFORE the push/deploy.
#                 A non-zero exit rolls the merge back and deploys nothing. Same cwd +
#                 exported env as DEPLOY_CMD. Use it for lint/build/tests. If unset,
#                 there is no gate (the merge is deployed as-is).
#   SHIP_PROJECT  optional label exported to the gate/deploy commands (default: basename REPO)
#   SKIP_GATE     1 = skip GATE_CMD (deliberate, risky)
#   DRY_RUN       1 = merge + gate, then roll back WITHOUT pushing/deploying (safe test)
#
# Exit: 0 = gate green + deployed | non-zero = gate failed (merge rolled back) or deploy failed

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v git >/dev/null 2>&1 || die "git not found in PATH"
[[ $# -ge 1 ]] || die "Usage: deploy-run.sh <ticket>"

ticket="${1// /}"
[[ "$ticket" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Bad id: ${1}"

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
# `git rev-parse` (not `-d "$REPO/.git"`) so git worktrees, where .git is a FILE, also pass.
[[ -n "$REPO" ]] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "Set REPO to a git repo (or worktree)."
SHIP_PROJECT="${SHIP_PROJECT:-$(basename "$REPO")}"
[[ -n "${DEPLOY_CMD:-}" ]] || die "DEPLOY_CMD is required — the command that deploys your merged code (see examples/)."

branch="auto/${ticket}"
wt="${TOOLKIT_DIR}/.worktrees/${ticket}"
log="${REPO}/docs/tickets/plans/${ticket}.log"
logline() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log" >&2; }

git -C "$REPO" rev-parse --verify "$branch" >/dev/null 2>&1 || die "No branch ${branch} — run the coder first."

# keep toolkit artifacts out of git (local-only ignore) so the tree is clean and the deploy won't commit them
_gitroot="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || echo "$REPO")"
_excl="${_gitroot}/.git/info/exclude"
mkdir -p "$(dirname "$_excl")"
grep -qsF 'docs/tickets/plans/' "$_excl" || printf 'docs/tickets/plans/\n' >> "$_excl"

# only TRACKED uncommitted changes block the deploy (untracked scratch files are fine)
[[ -z "$(git -C "$REPO" status --porcelain -uno)" ]] || die "Working tree of ${REPO} has uncommitted TRACKED changes — commit/stash first."

orig_head="$(git -C "$REPO" rev-parse HEAD)"
rollback() { git -C "$REPO" reset --hard "$orig_head" >/dev/null 2>&1 || true; }

logline "deploy: merging ${branch} into $(git -C "$REPO" rev-parse --abbrev-ref HEAD) (base ${orig_head:0:8})"
if ! git -C "$REPO" merge --no-ff -m "merge ${branch}" "$branch" >/dev/null 2>&1; then
  git -C "$REPO" merge --abort >/dev/null 2>&1 || true
  die "merge conflict for ${branch} — resolve manually."
fi
new_head="$(git -C "$REPO" rev-parse HEAD)"

# ---------- optional project gate (lint / build / tests — whatever GATE_CMD does) ----------
if [[ -n "${GATE_CMD:-}" && "${SKIP_GATE:-0}" != "1" ]]; then
  logline "deploy: running GATE_CMD"
  if ! ( cd "$REPO" && REPO="$REPO" TICKET="$ticket" SHIP_PROJECT="$SHIP_PROJECT" \
         ORIG_HEAD="$orig_head" NEW_HEAD="$new_head" bash -c "$GATE_CMD" ); then
    rollback
    die "gate failed (GATE_CMD) — merge rolled back, nothing deployed."
  fi
  logline "deploy: gate OK"
elif [[ "${SKIP_GATE:-0}" == "1" ]]; then
  logline "deploy: SKIP_GATE=1 — gate skipped (risky)"
else
  logline "deploy: no GATE_CMD set — deploying the merge ungated"
fi

# ---------- deploy ----------
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  logline "deploy: DRY_RUN — would push + run DEPLOY_CMD; rolling merge back, keeping branch"
  rollback
  printf '\n✓ %s DRY RUN ok — gate passed, NOT deployed (branch auto/%s kept)\n' "$ticket" "$ticket"
  exit 0
fi

# push the merge to origin first — many deploy flows pull from origin on the server,
# so without this the server would pull nothing and nothing would actually deploy.
push_branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
logline "deploy: pushing ${push_branch} -> origin"
git -C "$REPO" push origin "$push_branch" || die "git push failed — merge is local only, nothing deployed."

logline "deploy: gate green -> running DEPLOY_CMD (${SHIP_PROJECT})"
if ! ( cd "$REPO" && REPO="$REPO" TICKET="$ticket" SHIP_PROJECT="$SHIP_PROJECT" \
       ORIG_HEAD="$orig_head" NEW_HEAD="$new_head" bash -c "$DEPLOY_CMD" ); then
  die "DEPLOY_CMD failed (pushed to origin, but the deploy step failed — check your target)."
fi

# cleanup the isolated worktree + the now-merged branch
git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
git -C "$REPO" branch -d "$branch" >/dev/null 2>&1 || true

logline "DONE deploy ${ticket}: deployed ${SHIP_PROJECT}"
printf '\n✓ %s deployed (%s)\n' "$ticket" "$SHIP_PROJECT"
