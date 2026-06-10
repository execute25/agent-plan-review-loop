#!/usr/bin/env bash
set -euo pipefail

# agent-plan-review-loop — automated, multi-agent ticket plan<->review loop.
#
# Author (Opus) drafts the plan into a file; an adversarial Reviewer (Sonnet)
# cross-checks it against the real repo and writes a verdict; loop until the
# plan is APPROVED or MAX_ITERS is hit, then stop for a human.
# The author pauses the loop (exit 4) when it hits a decision only the user
# can make. No copy-paste; the reviewer can optionally run on another model family (Cursor).
#
# Usage:
#   bash plan-loop.sh TASK-12 "add a CSV export button to the reports page"
#   REPO=/path/to/repo bash plan-loop.sh PROJ-123 "https://your-org.atlassian.net/browse/PROJ-123"
#
# Env: REPO MAX_ITERS AUTHOR_MODEL REVIEWER_MODEL PERM_MODE RULES_FILE  (see README.md)

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERM_MODE="${PERM_MODE:-acceptEdits}"
SCORER_MODEL="${SCORER_MODEL:-haiku}"
# AUTHOR_MODEL / REVIEWER_MODEL / MAX_ITERS: if unset, auto-picked from the complexity tier (below).
# Author and reviewer are kept DIFFERENT models for decorrelation:
#   T0/T1 -> sonnet author + opus reviewer;  T2 -> opus author + sonnet reviewer.
# LOG_COST=1 -> log per-call cost via --output-format json.

die() { echo "ERROR: $*" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || die "claude CLI not found in PATH"
command -v git    >/dev/null 2>&1 || die "git not found in PATH"
[[ $# -ge 1 ]] || die "Usage: plan-loop.sh TP-3646 [description or jira url]"

ticket="${1// /}"
[[ "$ticket" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Bad id (letters/digits/._- , e.g. TP-3646 or task-foo): ${1}"
shift || true

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO" && -d "$REPO" ]] || die "Set REPO=/path/to/target-repo (not inside a git repo and REPO unset)."

template="${TOOLKIT_DIR}/templates/_TEMPLATE.md"
[[ -f "$template" ]] || die "Missing template: $template"

cd "$REPO"
plans_dir="docs/tickets/plans"
plan="${plans_dir}/${ticket}-plan.md"
review="${plans_dir}/${ticket}-review.md"
questions="${plans_dir}/${ticket}-questions.md"
notes="${plans_dir}/${ticket}-notes.md"
log="${plans_dir}/${ticket}.log"
mkdir -p "$plans_dir"

# keep toolkit artifacts out of git (local-only ignore; no tracked change, ship won't commit them)
_gitroot="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || echo "$REPO")"
_excl="${_gitroot}/.git/info/exclude"
mkdir -p "$(dirname "$_excl")"
grep -qsF 'docs/tickets/plans/' "$_excl" || printf 'docs/tickets/plans/\n' >> "$_excl"

today="$(date '+%Y-%m-%d')"
desc="${*:-<no description provided>}"

jira_hint=""
if printf '%s' "$desc" | grep -q "atlassian.net/browse/"; then
  jira_hint="The description contains a Jira URL — fetch the ticket via the Jira MCP tool first if it is available."
fi

page_hint=""
if printf '%s' "$desc" | grep -qiE 'https?://' && ! printf '%s' "$desc" | grep -q "atlassian.net"; then
  page_hint="The description references a URL of a page in this app. Map it to the concrete route / controller / view / model / DB table (or your stack's equivalents) before planning — find their real names in the repo, do not guess."
fi

# Optional PROJECT RULES (hard constraints) injected into every agent prompt.
# Point RULES_FILE at a markdown file, or drop ".agent-workflow-rules.md" in the repo root.
# Use it for house policies the agent must obey — e.g. "no DB migrations", "no new deps",
# "match the existing test style". See examples/rules/ for ready-made templates.
RULES_FILE="${RULES_FILE:-${REPO}/.agent-workflow-rules.md}"
rules_block=""
if [[ -f "$RULES_FILE" ]]; then
  rules_block="PROJECT RULES (hard constraints — these OVERRIDE the plan and any default guidance below; obey them exactly):
$(cat "$RULES_FILE")
"
fi

if [[ ! -f "$plan" ]]; then
  sed "s/{{TICKET_ID}}/${ticket}/g" "$template" > "$plan"
  rm -f "$notes"   # fresh plan -> drop any stale steering notes from a previous run of this ticket
  echo "Created $plan"
fi

logline() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log" >&2; }

# shared claude-with-retry helper (5xx / Overloaded / network -> backoff retry, NOT auth/prompt errors).
# shellcheck disable=SC1091
. "${TOOLKIT_DIR}/scripts/lib/claude-with-retry.sh"
# cursor-with-retry — used when REVIEWER_PROVIDER=cursor (Cursor CLI `agent` for cross-family decorrelation)
# shellcheck disable=SC1091
. "${TOOLKIT_DIR}/scripts/lib/cursor-with-retry.sh"

# v1 escalation = print + log. Replace these bodies with a Telegram push later.
notify() { logline "ESCALATION: $*"; }

# Pause the loop if the author raised a decision only the user can make.
check_questions_gate() {
  if [[ -f "$questions" ]] && grep -qE 'STATUS:[[:space:]]*NEEDS_ANSWERS' "$questions"; then
    notify "${ticket}: author needs decisions only you can make. Fill each 'A:' line in ${questions}, set the first line to 'STATUS: ANSWERED', then re-run the same command."
    exit 4
  fi
}

plan_hash() { git hash-object "$plan" 2>/dev/null || cksum "$plan" | awk '{print $1}'; }
# hash of the live steering-notes file (empty when none) — used to detect notes that arrived mid-run
notes_hash() { if [[ -f "$notes" ]]; then git hash-object "$notes" 2>/dev/null || cksum "$notes" | awk '{print $1}'; else echo ""; fi; }

author_prompt() {
  local review_note=""
  if [[ -f "$review" ]]; then
    review_note="Reviewer feedback from the previous round is in ${review} — every [BLOCKING] item is mandatory: address it, do not argue in the plan."
  fi
  local questions_note=""
  if [[ -f "$questions" ]]; then
    questions_note="An open-questions file exists at ${questions}. If its STATUS is ANSWERED, read the answers (the 'A:' lines) and incorporate them — do NOT re-ask those. Only raise genuinely new blockers."
  fi
  local notes_note=""
  if [[ -f "$notes" ]]; then
    notes_note="STEERING NOTES from the user (sent live during this run) are in ${notes}. Treat EVERY line there as a high-priority additional user instruction / clarification. Make sure the plan reflects ALL of them (they are cumulative — some may already be handled, that is fine). If a note contains a '[image: <absolute-path>]' marker, the user attached a screenshot — use your Read tool on that path FIRST to see the visual context (PNG/JPEG are supported as visual input) before incorporating that note. Add one changelog line noting which steering notes you folded in."
  fi
  cat <<EOF
You are the PLAN AUTHOR for ticket ${ticket}. You write the plan only — no production code.

Plan file: ${plan}
${review_note}
${questions_note}
${notes_note}
${jira_hint}
${page_hint}
${rules_block}
1. Read the plan file ${plan} (it already has the section skeleton).
   When exploring the repo, IGNORE dependency and build directories (e.g. vendor/, node_modules/, target/, dist/, build/) and lock files (read a framework file only to confirm a specific signature) — keeps the plan focused and token-cheap.
2. Fill these sections concretely (exact paths, exact changes): Goal, Non-goals, Decisions (final choices only), Assumptions, Implementation checklist, API / behaviour notes, Testing notes. Stay aligned with CLAUDE.md / AGENTS.md and any PROJECT RULES above if present.
3. Handling uncertainty — THREE cases, do not conflate:
   - Uncertain FACT (class path, signature, existing behaviour): resolve it yourself via Grep/Read; if truly unresolvable, add a "VERIFY: ..." checklist item.
   - Decision with a reasonable default (minor trade-off, not business-critical): pick the default yourself and record it under "## Assumptions" (one line: assumption + why). Do NOT stop for these.
   - A fork only the USER can own (product / scope / risk — e.g. "support X or not", "all users or premium only"): do NOT guess. Append it to ${questions} in the format below, set that file's first line to "STATUS: NEEDS_ANSWERS", fill everything in the plan that is NOT blocked, and reference the open question where the plan depends on it.
   Prefer "decide + record assumption" over asking. Reserve ${questions} for genuine user-owned forks ONLY.
4. Edit only the existing plan file (and ${questions} when you must raise a blocker) — no rewrite from scratch, no other new files.
5. Prepend ONE line to "## Plan changelog" (newest first): "${today} — what changed and why" (delta only; never paste old plan text).
6. End your reply with exactly "✓ Plan ready" only when the plan is solid, every prior [BLOCKING] item is resolved, AND there are no unanswered user-owned questions.

${questions} format (first line is the status; one block per question):
STATUS: NEEDS_ANSWERS
## Q1 — <short title>
<the question, one or two lines>
- A) <option + its trade-off>   (recommended)
- B) <option>
A:

Ticket description:
${desc}
EOF
}

reviewer_prompt() {
  cat <<EOF
You are a SKEPTICAL senior REVIEWER for ticket ${ticket}. Find why this plan will FAIL — do not praise it. Default to CHANGES_REQUESTED; approve only if it is genuinely sound. You have NOT seen the author's reasoning — judge the artifact on its own merits, reading ONLY the plan file and the real repository.

${rules_block}

CALIBRATE STRICTNESS TO SCOPE. Read the plan's actual scope before judging. If it is a trivial change (one renamed string, one JSON key, one CSS tweak, a single config-value flip), [BLOCKING] is reserved for ACTUAL defects ONLY: wrong path/file/key, breaks the build, wrong target, violates a HARD RULE (a PROJECT RULE above, or the no-out-of-worktree-edits boundary), real security/data risk. Process-completeness concerns — "missing stakeholder sign-off", "QA checklist not exhaustive for a one-line copy change", "should also rename adjacent strings", "Testing notes don't enumerate every viewport / locale / role" — are [nit]s at most, NEVER [BLOCKING] on trivial plans. Approve a trivial plan when it is technically correct. The strict standard above applies in full to multi-file refactors, new subsystems, and security/data-sensitive work.

1. Read the full plan file: ${plan} (when cross-checking, IGNORE dependency and build directories (e.g. vendor/, node_modules/, target/, dist/, build/) and lock files — check the application source).
2. Cross-check Decisions, Assumptions and Implementation checklist against the ACTUAL codebase (Grep/Read): flag wrong paths, wrong method signatures, project- or framework-specific behaviour, missing edge cases, test-strategy gaps, and any Assumption that is actually wrong or risky. If any PROJECT RULE above is violated, flag it [BLOCKING]. Stay aligned with CLAUDE.md / AGENTS.md and any PROJECT RULES above if present.
3. Write your review to ${review} (overwrite it), in this shape:
     ## Findings
     - [BLOCKING] <file/section> — <exact required fix>
     - [nit] <...>
   and a FINAL line that is EXACTLY one of:
     VERDICT: APPROVED
     VERDICT: CHANGES_REQUESTED
   Suggest fixes; do not rewrite the plan. When uncertain, choose CHANGES_REQUESTED.
4. Do NOT edit the plan file — only write ${review}.
EOF
}

# Cursor variant of the reviewer prompt — cursor agent runs in --mode ask (read-only),
# so it CANNOT use Write to save ${review}. Instead it prints the review on stdout
# and run_reviewer() captures it into ${review}. Otherwise the contract (findings +
# VERDICT line) is identical.
cursor_reviewer_prompt() {
  cat <<EOF
You are a SKEPTICAL senior REVIEWER for ticket ${ticket}. Find why this plan will FAIL — do not praise it. Default to CHANGES_REQUESTED; approve only if it is genuinely sound. You have NOT seen the author's reasoning — judge the artifact on its own merits, reading ONLY the plan file and the real repository.

${rules_block}

CALIBRATE STRICTNESS TO SCOPE. Read the plan's actual scope before judging. If it is a trivial change (one renamed string, one JSON key, one CSS tweak, a single config-value flip), [BLOCKING] is reserved for ACTUAL defects ONLY: wrong path/file/key, breaks the build, wrong target, violates a HARD RULE (a PROJECT RULE above, or the no-out-of-worktree-edits boundary), real security/data risk. Process-completeness concerns — "missing stakeholder sign-off", "QA checklist not exhaustive for a one-line copy change", "should also rename adjacent strings", "Testing notes don't enumerate every viewport / locale / role" — are [nit]s at most, NEVER [BLOCKING] on trivial plans. Approve a trivial plan when it is technically correct. The strict standard above applies in full to multi-file refactors, new subsystems, and security/data-sensitive work.

You are running in --mode ask (read-only); you CANNOT edit any files in this workspace, and you should not try to. Your stdout IS the review — print it directly, no preamble, no markdown code fences, no chatty intro/outro. The wrapper captures stdout and saves it to ${review} for downstream tooling.

1. Read the full plan file: ${plan} (when cross-checking, IGNORE dependency and build directories (e.g. vendor/, node_modules/, target/, dist/, build/) and lock files — check the application source).
2. Cross-check Decisions, Assumptions and Implementation checklist against the ACTUAL codebase (Grep/Read): flag wrong paths, wrong method signatures, project- or framework-specific behaviour, missing edge cases, test-strategy gaps, and any Assumption that is actually wrong or risky. If any PROJECT RULE above is violated, flag it [BLOCKING]. Stay aligned with CLAUDE.md / AGENTS.md and any PROJECT RULES above if present.
3. Print your review on stdout in this exact shape:
     ## Findings
     - [BLOCKING] <file/section> — <exact required fix>
     - [nit] <...>
   and a FINAL line that is EXACTLY one of:
     VERDICT: APPROVED
     VERDICT: CHANGES_REQUESTED
   Suggest fixes; do not rewrite the plan. When uncertain, choose CHANGES_REQUESTED.
EOF
}

run_claude() {
  # prompt goes via stdin (NOT a CLI arg): a large prompt can exceed the OS command-line
  # limit (~32KB on Windows) -> "Argument list too long". stdin is unbounded.
  # claude_with_retry transparently retries 5xx/Overloaded/network errors with backoff.
  if [ "${LOG_COST:-0}" = "1" ]; then
    local out
    out="$(printf '%s' "$2" | claude_with_retry "$1" --permission-mode "$PERM_MODE" --output-format json 2>/dev/null)" || return 1
    local c; c="$(printf '%s' "$out" | grep -oE '"total_cost_usd":[0-9.]+' | head -1)"
    [ -n "$c" ] && logline "cost ${1}: \$${c##*:}"
    return 0
  fi
  printf '%s' "$2" | claude_with_retry "$1" --permission-mode "$PERM_MODE"
}

# Dispatch the reviewer to whichever provider REVIEWER_PROVIDER selects.
# - claude: existing behaviour — claude writes \${review} itself via Write tool.
# - cursor: agent in --mode ask is read-only; it prints the review on stdout and we
#   capture it into \${review} (functionally identical for the verdict-grep downstream).
run_reviewer() {
  if [ "${REVIEWER_PROVIDER:-claude}" = "cursor" ]; then
    cursor_with_retry "$CURSOR_REVIEWER_MODEL" "$REPO" "$(cursor_reviewer_prompt)" > "$review"
  else
    run_claude "$REVIEWER_MODEL" "$(reviewer_prompt)"
  fi
}

# --- complexity tier -> author model + iterations (auto unless AUTHOR_MODEL/MAX_ITERS pinned) ---
classify_tier() {
  printf '%s' "Classify this software task by complexity. T0 = trivial (copy/text, config value, content, CSS). T1 = clear small change (a simple bugfix or small feature, ~1-3 files). T2 = complex/ambiguous/multi-file/refactor/new subsystem, or security- or data-sensitive. Reply with ONLY the tag: T0, T1, or T2. Task: ${desc}" | claude_with_retry "$SCORER_MODEL" 2>/dev/null | grep -oE 'T[0-2]' | head -1 || true
}
tier="${TIER:-$(classify_tier)}"
[ -n "$tier" ] || tier="T2"   # unknown -> strong model (no quality loss when unsure)
printf '%s\n' "$tier" > "${plans_dir}/${ticket}.tier"
case "$tier" in
  T0|T1) AUTHOR_MODEL="${AUTHOR_MODEL:-sonnet}"; REVIEWER_MODEL="${REVIEWER_MODEL:-opus}";   MAX_ITERS="${MAX_ITERS:-3}" ;;
  *)     AUTHOR_MODEL="${AUTHOR_MODEL:-opus}";   REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet}"; MAX_ITERS="${MAX_ITERS:-6}" ;;
esac

# REVIEWER_PROVIDER routes the review step. Default 'claude' keeps the existing pipeline
# untouched (claude reviewer writes ${review} via its Write tool). 'cursor' sends review
# through the Cursor CLI (`agent`) for cross-family decorrelation + spends the Cursor
# subscription budget instead of the Anthropic quota. Cursor models are picked per tier.
REVIEWER_PROVIDER="${REVIEWER_PROVIDER:-claude}"
if [ "$REVIEWER_PROVIDER" = "cursor" ]; then
  case "$tier" in
    T0|T1) CURSOR_REVIEWER_MODEL="${REVIEWER_MODEL_CURSOR_T1:-composer-2.5-fast}" ;;
    *)     CURSOR_REVIEWER_MODEL="${REVIEWER_MODEL_CURSOR_T2:-gpt-5.3-codex}" ;;
  esac
  REVIEWER_LABEL="cursor:${CURSOR_REVIEWER_MODEL}"
else
  REVIEWER_LABEL="${REVIEWER_MODEL}"
fi

logline "tier=${tier} -> author=${AUTHOR_MODEL} reviewer=${REVIEWER_LABEL} iters=${MAX_ITERS}"
logline "START ${ticket} (author=${AUTHOR_MODEL} reviewer=${REVIEWER_LABEL} max_iters=${MAX_ITERS} repo=${REPO})"

logline "author: drafting initial plan (${AUTHOR_MODEL}, tier ${tier})"
run_claude "$AUTHOR_MODEL" "$(author_prompt)" || die "author run failed"
notes_seen="$(notes_hash)"   # remember which steering notes the author has already folded in
check_questions_gate

approved=0
round=0
note_passes=0
MAX_NOTE_PASSES="${MAX_NOTE_PASSES:-3}"   # cap on extra author passes driven by live steering notes
while (( round < MAX_ITERS )); do
  round=$((round + 1))
  logline "round ${round}: reviewer (${REVIEWER_LABEL})"
  run_reviewer || die "reviewer run failed"

  if [[ ! -f "$review" ]]; then
    logline "round ${round}: WARNING reviewer wrote no ${review}"
  fi

  if [[ -f "$review" ]] && grep -qE 'VERDICT:[[:space:]]*APPROVED' "$review"; then
    # A steering note that arrived AFTER the author's last pass isn't reflected yet:
    # fold it in with one more author pass instead of finalizing. Bounded by MAX_NOTE_PASSES.
    if [[ "$(notes_hash)" != "$notes_seen" && "$note_passes" -lt "$MAX_NOTE_PASSES" ]]; then
      note_passes=$((note_passes + 1))
      logline "round ${round}: APPROVED, but a new steering note arrived -> folding it in (note pass ${note_passes}/${MAX_NOTE_PASSES})"
      run_claude "$AUTHOR_MODEL" "$(author_prompt)" || die "author run failed"
      notes_seen="$(notes_hash)"
      check_questions_gate
      round=$((round - 1))   # a note-driven pass is not a review round — don't burn the iteration budget
      continue
    fi
    approved=1
    logline "round ${round}: APPROVED"
    break
  fi
  logline "round ${round}: CHANGES_REQUESTED"

  before="$(plan_hash)"
  logline "round ${round}: author revising (${AUTHOR_MODEL})"
  run_claude "$AUTHOR_MODEL" "$(author_prompt)" || die "author run failed"
  notes_seen="$(notes_hash)"
  check_questions_gate
  after="$(plan_hash)"

  if [[ "$before" == "$after" ]]; then
    notify "${ticket}: plan unchanged after revision but still not approved — stuck. See ${plan} / ${review}"
    exit 2
  fi
done

if [[ "$approved" -ne 1 ]]; then
  notify "${ticket}: not converged in ${MAX_ITERS} rounds. See ${plan} / ${review}"
  exit 3
fi

logline "DONE ${ticket}: plan approved -> ${plan}"
printf '\n✓ %s plan APPROVED -> %s\n  review: %s\n  questions: %s\n  log:    %s\n' "$ticket" "$plan" "$review" "$questions" "$log"
