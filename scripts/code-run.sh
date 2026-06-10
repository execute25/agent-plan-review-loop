#!/usr/bin/env bash
set -euo pipefail

# agent-plan-review-loop — implement an APPROVED plan in an isolated git worktree.
# Test-first where possible. Does NOT deploy, push, or touch your main branch.
# Leaves a branch (auto/<ticket>) + a diff for the human to review and ship.
#
# Usage: REPO=/path/to/repo bash code-run.sh <ticket>
# Env:   REPO  CODER_MODEL(=opus)  PERM_MODE(=acceptEdits)
#
# Exit: 0 = code ready on branch | 5 = coder produced no changes | other = error

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERM_MODE="${PERM_MODE:-acceptEdits}"
# CODER_MODEL: if unset, taken from the plan's complexity tier (.tier) below.

die() { echo "ERROR: $*" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || die "claude CLI not found in PATH"
command -v git    >/dev/null 2>&1 || die "git not found in PATH"
[[ $# -ge 1 ]] || die "Usage: code-run.sh <ticket>"

ticket="${1// /}"
[[ "$ticket" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Bad id: ${1}"

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO" && -d "$REPO/.git" ]] || die "Set REPO to a git repo."

# keep toolkit artifacts out of git (local-only ignore)
_gitroot="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || echo "$REPO")"
_excl="${_gitroot}/.git/info/exclude"
mkdir -p "$(dirname "$_excl")"
grep -qsF 'docs/tickets/plans/' "$_excl" || printf 'docs/tickets/plans/\n' >> "$_excl"

plan_rel="docs/tickets/plans/${ticket}-plan.md"
plan_abs="${REPO}/${plan_rel}"
review_abs="${REPO}/docs/tickets/plans/${ticket}-review.md"
log="${REPO}/docs/tickets/plans/${ticket}.log"
diff_out="${REPO}/docs/tickets/plans/${ticket}.diff"
code_notes="${REPO}/docs/tickets/plans/${ticket}-code-notes.md"

[[ -f "$plan_abs" ]] || die "No plan: ${plan_rel} — run plan-loop.sh first."
if [[ -f "$review_abs" ]] && ! grep -qE 'VERDICT:[[:space:]]*APPROVED' "$review_abs"; then
  die "Plan not approved yet (review verdict is not APPROVED)."
fi

logline() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log" >&2; }

# shared claude-with-retry helper (5xx / Overloaded / network -> backoff retry, NOT auth/prompt errors).
# shellcheck disable=SC1091
. "${TOOLKIT_DIR}/scripts/lib/claude-with-retry.sh"

# coder model: env override wins; else from the plan's complexity tier (T0/T1 -> sonnet, else opus)
_tier="$(grep -oE 'T[0-2]' "${REPO}/docs/tickets/plans/${ticket}.tier" 2>/dev/null | head -1 || true)"
if [ -z "${CODER_MODEL:-}" ]; then
  case "$_tier" in T0|T1) CODER_MODEL=sonnet ;; *) CODER_MODEL=opus ;; esac
fi

branch="auto/${ticket}"
wt="${TOOLKIT_DIR}/.worktrees/${ticket}"
base="$(git -C "$REPO" rev-parse HEAD)"

logline "coder: preparing worktree (branch ${branch}, base ${base:0:8})"
git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
rm -rf "$wt"
git -C "$REPO" branch -D "$branch" >/dev/null 2>&1 || true
mkdir -p "${TOOLKIT_DIR}/.worktrees"
git -C "$REPO" worktree add -b "$branch" "$wt" "$base" >/dev/null

plan_content="$(cat "$plan_abs")"

# Optional PROJECT RULES (hard constraints) — same mechanism as plan-loop.sh.
# Point RULES_FILE at a markdown file, or drop ".agent-workflow-rules.md" in the repo root.
RULES_FILE="${RULES_FILE:-${REPO}/.agent-workflow-rules.md}"
rules_block=""
if [[ -f "$RULES_FILE" ]]; then
  rules_block="PROJECT RULES (hard constraints — these OVERRIDE the plan; obey them exactly):
$(cat "$RULES_FILE")
"
fi

# user corrections typed at the diff-review step (the bot's "recode") — applied ON TOP of the plan
corrections_block=""
if [[ -f "$code_notes" ]]; then
  corrections_block="USER CORRECTIONS — the user reviewed your implementation and asked for these changes. They are HIGH PRIORITY and OVERRIDE any conflicting detail in the plan. Apply ALL of them as part of this implementation. If a correction contains a '[image: <absolute-path>]' marker, the user attached a screenshot — Read that path FIRST to see the visual context (PNG/JPEG supported) before applying that correction.
$(cat "$code_notes")
"
fi

coder_prompt() {
  cat <<EOF
You are the CODER. Implement the APPROVED plan below in THIS repository. Your working directory is an isolated git worktree on branch ${branch}.

${rules_block}Rules:
- The plan is the contract. Follow its Implementation checklist exactly. If a step is genuinely impossible, STOP and explain — do not improvise.
- WORKTREE BOUNDARY (HARD RULE — overrides the plan). Your CWD is an isolated git worktree at ${wt}. You MUST edit ONLY files under that directory. NEVER write to absolute paths that point OUTSIDE this worktree, even if the plan's Implementation checklist gives you an absolute path to a different directory (e.g. a sibling repo). If the plan targets a different repo, STOP and emit a one-line message "PLAN_TARGETS_DIFFERENT_REPO: <path>" then exit — do NOT silently edit there. Out-of-worktree edits bypass isolation, diff, review, and rollback (the toolkit's safety net). When the plan uses absolute paths, translate them to paths INSIDE your worktree by stripping the repo prefix.
- Follow the plan's "Testing notes": write the specified tests. NOTE: this worktree may lack installed dependencies (vendor/, node_modules/, .env), so you may be unable to RUN the suite here — if you can run it, prefer test-first (failing test first); otherwise write the tests carefully per the plan, to be run before deploy.
- Do NOT deploy, do NOT 'git push', do NOT commit. Just leave your changes in the working tree.

APPROVED PLAN (${ticket}):
---
${plan_content}
---
${corrections_block}
When done, briefly summarise what you changed and which test you added.
EOF
}

[ -n "$corrections_block" ] && logline "coder: applying user corrections from ${ticket}-code-notes.md" || true
logline "coder: implementing (model=${CODER_MODEL}, tier ${_tier:-?}) — can take several minutes"
# pipe the prompt via stdin (NOT as a CLI arg): a big plan can exceed the OS command-line
# limit (~32KB on Windows) -> "Argument list too long". stdin has no such limit.
# claude_with_retry transparently retries 5xx/Overloaded/network errors with backoff.
coder_prompt | ( cd "$wt" && claude_with_retry "$CODER_MODEL" --permission-mode "$PERM_MODE" ) || die "coder run failed"

# Capture whatever the coder changed (works whether or not it committed).
git -C "$wt" add -A
git -C "$wt" commit -m "auto(${ticket}): implement approved plan" >/dev/null 2>&1 || true
head_now="$(git -C "$wt" rev-parse HEAD)"

if [[ "$head_now" == "$base" ]]; then
  logline "coder: NO changes produced"
  echo "NO_CHANGES"
  exit 5
fi

git -C "$wt" diff "$base" "$head_now" > "$diff_out" || true
stat="$(git -C "$wt" diff --stat "$base" "$head_now" | tail -n 1)"
logline "DONE coder ${ticket}: branch=${branch} (${stat})"

printf '\n✓ %s code ready on branch %s\n  %s\n  worktree: %s\n  diff: %s\n  Run tests, then merge + ship — manual.\n' \
  "$ticket" "$branch" "$stat" "$wt" "$diff_out"
