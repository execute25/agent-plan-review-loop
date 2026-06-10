#!/usr/bin/env bash
# plan-bot launcher for macOS / Linux  (POSIX mirror of start-bot.ps1).
#   ./start-bot.sh          -> start the bot if not already running (manual; IGNORES AUTOSTART)
#   ./start-bot.sh --auto   -> same, but FIRST obey AUTOSTART in .env (0/false/no/off => do nothing)
# Idempotent: never starts a 2nd poller (Telegram allows one getUpdates per token).
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ENV_FILE="$DIR/.env"
ERR="$DIR/bot.err.log"
OUT="$DIR/bot.out.log"

# login path: honour AUTOSTART (missing key => default ON). Manual run skips this block.
if [ "${1:-}" = "--auto" ] && [ -f "$ENV_FILE" ]; then
  val="$(sed -nE 's/^[[:space:]]*AUTOSTART[[:space:]]*=[[:space:]]*"?([^"#]*).*/\1/p' "$ENV_FILE" \
          | tail -1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$val" in
    0|false|no|off) exit 0 ;;   # disabled from config -> do nothing
  esac
fi

# already running? leave it.
if pgrep -f 'plan_bot\.py' >/dev/null 2>&1; then
  exit 0
fi

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "$(date '+%F %T') ERROR: python3 not found in PATH" >> "$ERR"
  exit 1
fi
if [ ! -f "$DIR/plan_bot.py" ]; then
  echo "$(date '+%F %T') ERROR: plan_bot.py not found in $DIR" >> "$ERR"
  exit 1
fi

cd "$DIR" || exit 1
nohup "$PY" plan_bot.py >> "$OUT" 2>> "$ERR" &
disown 2>/dev/null || true
