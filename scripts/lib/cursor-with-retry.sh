# cursor-with-retry — wrap the Cursor Agent CLI ('agent') with backoff retry on
# transient API failures. Mirrors claude-with-retry.sh.
#
# Sourced by plan-loop.sh. Requires `logline` defined by the caller (optional —
# falls back to stderr if absent).
#
# Why: Cursor's OpenAI/Anthropic/Gemini upstreams occasionally return 5xx /
# Overloaded / network blips. A naive call would die on the first one; this
# helper retries ONLY transient signatures.
#
# Headless model: we call node.exe + index.js directly (skipping the .cmd shim
# that confuses Git Bash's exec). The latest version under
# %LOCALAPPDATA%\cursor-agent\versions is discovered each call so cursor-agent
# auto-updates don't break us.
#
# Usage (prompt is passed as a positional arg, NOT stdin — cursor's CLI takes
# the prompt as a positional argument, and review prompts are small ~1KB):
#
#   cursor_with_retry MODEL WORKSPACE PROMPT [extra_args...]
#
# Notes:
# - Always forced to --mode ask (read-only) — reviewers must NOT edit files.
# - Always --trust to skip workspace-trust prompt (we control the path).
# - Output: agent's stdout. Stderr passes through on failure (auth errors etc.).
# - Tuning via env: CURSOR_RETRY_DELAYS (default: "10 30 60"), CURSOR_AGENT_DIR.

_CURSOR_AGENT_DIR_DEFAULT="${LOCALAPPDATA:-$HOME/AppData/Local}/cursor-agent"
# Normalize Windows path to MSYS / Git Bash form ("C:\..." -> "/c/...")
case "$_CURSOR_AGENT_DIR_DEFAULT" in
  [A-Za-z]:*) _CURSOR_AGENT_DIR_DEFAULT="/$(echo "$_CURSOR_AGENT_DIR_DEFAULT" | sed -E 's|^([A-Za-z]):|\L\1|;s|\\|/|g')" ;;
esac

# Resolve (node.exe, index.js) of the latest installed cursor-agent version.
# Returns 0 on success, prints two lines: <node_exe>\n<index_js>. Returns 1 if not found.
_cursor_resolve_runtime() {
  local agent_dir="${CURSOR_AGENT_DIR:-$_CURSOR_AGENT_DIR_DEFAULT}"
  local latest
  latest="$(ls -1d "$agent_dir"/versions/*/ 2>/dev/null | sed 's:/$::' | sort -r | head -1)"
  [ -n "$latest" ] && [ -f "$latest/node.exe" ] && [ -f "$latest/index.js" ] || return 1
  printf '%s\n%s\n' "$latest/node.exe" "$latest/index.js"
}

# Transient-error signature: matched (case-insensitive) against agent's stderr
# to decide if a non-zero exit should be retried.
_CURSOR_RETRY_TRANSIENT_RX='API Error: 5[0-9][0-9]|Overloaded|temporarily unavailable|network error|connection reset|connection timeout|EAI_AGAIN|ECONNRESET|ETIMEDOUT|rate limit|503 Service|502 Bad Gateway|504 Gateway'

cursor_with_retry() {
  local model="$1"; shift
  local workspace="$1"; shift
  local prompt="$1"; shift

  local rt node_exe index_js
  rt="$(_cursor_resolve_runtime)" || {
    echo "cursor-agent: no installed version under ${CURSOR_AGENT_DIR:-$_CURSOR_AGENT_DIR_DEFAULT}/versions/" >&2
    return 127
  }
  node_exe="$(printf '%s' "$rt" | sed -n '1p')"
  index_js="$(printf '%s' "$rt" | sed -n '2p')"

  local -a delays
  read -r -a delays <<<"${CURSOR_RETRY_DELAYS:-10 30 60}"
  local max_attempts=$(( ${#delays[@]} + 1 ))

  local stderr_file
  stderr_file="$(mktemp 2>/dev/null || echo "/tmp/cwr-$$-err")"

  local attempt rc delay why
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    : > "$stderr_file"
    "$node_exe" "$index_js" -p "$prompt" \
      --model "$model" \
      --workspace "$workspace" \
      --mode ask \
      --trust \
      --output-format text \
      "$@" \
      2> "$stderr_file"
    rc=$?

    if [ "$rc" -eq 0 ]; then
      cat "$stderr_file" >&2 || true   # forward benign warnings
      rm -f "$stderr_file" 2>/dev/null
      return 0
    fi

    if grep -qiE "$_CURSOR_RETRY_TRANSIENT_RX" "$stderr_file" && [ "$attempt" -lt "$max_attempts" ]; then
      delay=${delays[$((attempt-1))]}
      why="$(head -1 "$stderr_file" | tr -d '\r' | cut -c1-180)"
      if declare -f logline >/dev/null 2>&1; then
        logline "cursor(${model}) transient: ${why} — retry ${attempt}/${max_attempts} in ${delay}s"
      else
        printf '[cursor-retry] %s — retry %d/%d in %ds\n' "$why" "$attempt" "$max_attempts" "$delay" >&2
      fi
      sleep "$delay"
      continue
    fi

    # non-transient OR exhausted retries — surface the real error
    cat "$stderr_file" >&2
    rm -f "$stderr_file" 2>/dev/null
    return "$rc"
  done
}
