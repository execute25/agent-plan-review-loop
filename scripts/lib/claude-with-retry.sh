# claude-with-retry — wrap `claude -p` so transient API failures auto-retry.
# Sourced by plan-loop.sh and code-run.sh. Requires `logline` to be defined by the caller.
#
# Why: Anthropic occasionally returns 529 Overloaded (and 503/504/network blips) on Opus,
# especially at peak. Naively calling `claude -p` makes the script die on the first such error.
# This helper retries ONLY on transient signals (5xx / Overloaded / network / timeout). It does
# NOT retry on auth errors, malformed prompts, or any other genuine failure.
#
# Usage:
#   <prompt-on-stdin> | claude_with_retry <model> [extra claude args...]
#
# Tuning via env (optional):
#   CLAUDE_RETRY_DELAYS  space-separated backoff seconds (default: "10 30 60")
#
# Exit code: claude's last exit. Stdout: claude's stdout (last attempt). Stderr: claude's
# stderr (only on final non-retry path) + retry-attempt notices via logline.

# Transient-error signature: matched (case-insensitive) against claude's stderr to decide
# if a non-zero exit is worth retrying. Anything NOT matching is propagated immediately.
_CLAUDE_RETRY_TRANSIENT_RX='API Error: 5[0-9][0-9]|Overloaded|temporarily unavailable|network error|connection reset|connection timeout|request timeout|EAI_AGAIN|ECONNRESET|ETIMEDOUT'

claude_with_retry() {
  local model="$1"; shift
  local delays=(${CLAUDE_RETRY_DELAYS:-10 30 60})
  local max_attempts=$(( ${#delays[@]} + 1 ))   # initial try + N retries
  local stdin_file stderr_file
  stdin_file="$(mktemp 2>/dev/null || echo "/tmp/cwr-$$-in")"
  stderr_file="$(mktemp 2>/dev/null || echo "/tmp/cwr-$$-err")"
  # buffer stdin so we can replay it across retries (pipes can't seek)
  cat > "$stdin_file"

  local attempt rc delay
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    : > "$stderr_file"
    claude -p --model "$model" "$@" < "$stdin_file" 2> "$stderr_file"
    rc=$?

    if [ "$rc" -eq 0 ]; then
      cat "$stderr_file" >&2 || true   # forward any benign warnings
      rm -f "$stdin_file" "$stderr_file" 2>/dev/null
      return 0
    fi

    if grep -qiE "$_CLAUDE_RETRY_TRANSIENT_RX" "$stderr_file" && [ "$attempt" -lt "$max_attempts" ]; then
      delay=${delays[$((attempt-1))]}
      # log + show the first stderr line so the human knows WHY we're sleeping
      local why
      why="$(head -1 "$stderr_file" | tr -d '\r' | cut -c1-180)"
      if declare -f logline >/dev/null 2>&1; then
        logline "claude(${model}) transient: ${why} — retry ${attempt}/${max_attempts} in ${delay}s"
      else
        printf '[claude-retry] %s — retry %d/%d in %ds\n' "$why" "$attempt" "$max_attempts" "$delay" >&2
      fi
      sleep "$delay"
      continue
    fi

    # non-transient OR exhausted retries — surface claude's real error
    cat "$stderr_file" >&2
    rm -f "$stdin_file" "$stderr_file" 2>/dev/null
    return "$rc"
  done
}
