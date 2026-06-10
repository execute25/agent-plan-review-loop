# plan-bot

A dedicated Telegram bot that drives the `plan-loop.sh` → `code-run.sh` → `deploy-run.sh`
pipeline with inline buttons. Standalone — give it **its own** BotFather token (it must be
the only poller for that token).

> **Optional — do this last.** The bot is just a frontend over the CLI scripts; it adds no
> capability they lack. Get the [5-minute CLI flow](../README.md#try-it-in-5-minutes-cli-only)
> working first, *then* come back and add the bot. It needs Python and its own Telegram token.

> **Heads up:** the bot's user-facing strings are currently in Russian. The functionality is
> language-agnostic; PRs to internationalize are welcome. The rest of this doc is in English.

## Prerequisites

- A host where the **`claude` CLI is authenticated**, **`bash`** exists (Git Bash or WSL on
  Windows), and your **target repos are checked out**. The bot shells out to `claude -p`.
- **Python 3.10+**.

## Setup

1. Create a **new** bot: message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. Install deps:
   ```bash
   pip install -r requirements.txt
   ```
3. Configure:
   ```bash
   cp .env.example .env
   # edit .env: paste TELEGRAM_BOT_TOKEN and set PLAN_REPO (and PLAN_PROJECTS if you have several)
   ```
4. Run it:
   ```bash
   python plan_bot.py
   ```
5. In Telegram, send `/whoami` → it replies your `chat_id`. Put that in
   `TELEGRAM_ALLOWED_CHAT_ID` in `.env` and restart. (Until you do, the bot rejects everyone.)

To start it automatically at login: Windows uses `start-bot.ps1` (+ a Startup `.vbs`);
macOS/Linux use `install-autostart.sh`. The `AUTOSTART` key in `.env` toggles it.

## Commands

- `/plan TASK-1 add a CSV export button` — plan against `PLAN_REPO`.
- `/plan app TASK-1 …` — pick a repo from `PLAN_PROJECTS`.
- `/project` — choose the current project (remembered per chat).
- `/list`, `/focus <ticket>` — see / target active runs (multiple tickets run in parallel).
- `/code <ticket>`, `/deploy <ticket>` — run those stages explicitly.
- `/stop [<ticket>]` — cancel a run.
- `/whoami` — print your chat id.

The bot auto-chains plan → code by default (`AUTO_CODE=1`). On a clarifying question it sends
inline option buttons; your tap writes the answer and resumes. After the code is written it
shows **↻ rewrite** / **🚀 deploy** buttons. Free text (and photos) sent mid-run are folded
in as steering notes / corrections. Deploy is always an explicit human tap — prod is never automatic.

## Configuration

All knobs live in `.env`. The core ones are documented in `.env.example`; the optional deploy
wiring (`GATE_CMD` / `DEPLOY_CMD`) and project rules (`RULES_FILE`) are covered in the
top-level [README](../README.md). Worked deploy adapters live in [`examples/`](../examples).

## Notes / limits

- In-memory run state — restarting the bot mid-run drops pending-question tracking (the files
  on disk survive; just re-run `/plan`).
- One run at a time **per ticket**; up to `MAX_PARALLEL` (default 5) different tickets concurrently.
- Secrets come only from the environment / `.env` (gitignored). Never commit your token.
