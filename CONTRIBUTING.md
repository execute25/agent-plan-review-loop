# Contributing

Thanks for your interest! This is a small, focused toolkit — contributions that keep it
simple and stack-agnostic are very welcome.

## Ground rules

- **Keep the core stack-agnostic.** Anything specific to a framework/host belongs in
  `examples/`, not in `scripts/` or `bot/`. The default agent prompts must not assume a
  language or framework.
- **No secrets, ever.** Config comes from the environment / `.env` (gitignored). Don't commit
  tokens, hostnames, IPs, DB dumps, or machine-specific paths. `.gitignore` already covers
  `.env`, `.dumps/`, logs, worktrees — keep it that way.
- **Shell scripts:** target bash (Git Bash / WSL / Linux / macOS). Run `bash -n` on anything
  you touch. Prompts are piped via stdin (not CLI args) to avoid command-line length limits.
- **Python (bot):** keep it dependency-light; `python -m py_compile bot/*.py` should pass.

## Good first contributions

- Internationalize the Telegram bot's user-facing strings (currently Russian).
- New `examples/` deploy adapters (containers, serverless, other frameworks).
- New `examples/rules/` templates.

## Before opening a PR

- `bash -n scripts/*.sh scripts/lib/*.sh bot/*.sh examples/**/*.sh`
- `python -m py_compile bot/plan_bot.py bot/notes.py`
- Describe what you changed and how you tested it.
