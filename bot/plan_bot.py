#!/usr/bin/env python3
"""
plan-bot — dedicated Telegram bot that drives the agent-plan-review-loop plan↔review loop.

Parallel-runs model (v2): each ticket gets its own run dict in RUNS[ticket], so multiple
/plan, /code and /deploy can be in flight at the same time (capped by MAX_PARALLEL).
Free-text steering, callback buttons, and progress lines are all routed by ticket.

Secrets come ONLY from the environment (never hard-coded): TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_CHAT_ID.
The bot must run on a host where the `claude` CLI is authenticated, `bash` exists
(Git Bash / WSL on Windows), and the target repositories are checked out.
"""

from __future__ import annotations

# Avast HTTPS scanner replaces certs with its own MITM root, which Python's bundled `certifi`
# trust store does NOT know about -> [SSL: CERTIFICATE_VERIFY_FAILED] on every Telegram call.
# truststore makes Python use the OS (Windows) cert store, which DOES trust Avast's root.
# Must run BEFORE httpx/telegram are imported (they cache the default SSL context on import).
try:
    import truststore
    truststore.inject_into_ssl()
except ImportError:
    pass  # optional — only needed on machines with HTTPS interception (Avast/Kaspersky/corporate MITM)

import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent / ".env")  # always load bot/.env, regardless of CWD
except Exception:  # python-dotenv optional
    pass

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

import notes  # local module — single source of truth for steering-notes paths + I/O

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s", level=logging.INFO
)
log = logging.getLogger("plan-bot")
# httpx logs every request URL at INFO — and the URL embeds the bot token. Silence it (also cuts poll noise).
logging.getLogger("httpx").setLevel(logging.WARNING)

# --------------------------------------------------------------------------- config
TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
ALLOWED = {
    int(x) for x in re.split(r"[,\s]+", os.environ.get("TELEGRAM_ALLOWED_CHAT_ID", "").strip()) if x
}
REPO_DEFAULT = os.environ.get("PLAN_REPO", "").strip()
try:
    PROJECTS = {k.lower(): v for k, v in json.loads(os.environ.get("PLAN_PROJECTS", "") or "{}").items()}
except Exception:
    PROJECTS = {}
try:
    SHIP_PROJECTS = {k.lower(): v for k, v in json.loads(os.environ.get("SHIP_PROJECTS", "") or "{}").items()}
except Exception:
    SHIP_PROJECTS = {}
NO_DEPLOY = {x.strip().lower() for x in os.environ.get("NO_DEPLOY", "").split(",") if x.strip()}

MAX_ITERS = os.environ.get("MAX_ITERS", "")          # empty -> scripts auto-pick by complexity tier
AUTHOR_MODEL = os.environ.get("AUTHOR_MODEL", "")    # empty -> auto (sonnet for T0/T1, opus for T2)
REVIEWER_MODEL = os.environ.get("REVIEWER_MODEL", "")  # empty -> sonnet
PERM_MODE = os.environ.get("PERM_MODE", "acceptEdits")
AUTO_CODE = os.environ.get("AUTO_CODE", "1").strip().lower() not in ("0", "false", "no", "off")
try:
    MAX_PARALLEL = max(1, int(os.environ.get("MAX_PARALLEL", "5") or "5"))
except ValueError:
    MAX_PARALLEL = 5

SCRIPT = (Path(__file__).resolve().parent.parent / "scripts" / "plan-loop.sh").as_posix()
CODE_SCRIPT = (Path(__file__).resolve().parent.parent / "scripts" / "code-run.sh").as_posix()
DEPLOY_SCRIPT = (Path(__file__).resolve().parent.parent / "scripts" / "deploy-run.sh").as_posix()


def find_bash() -> str:
    """Locate a real bash. On Windows, prefer Git Bash and AVOID the WSL stub in System32
    (it fails with 'execvpe(/bin/bash) failed' when no working WSL distro is installed).
    Override with the PLAN_BASH env var if needed."""
    env_bash = os.environ.get("PLAN_BASH", "").strip()
    if env_bash:
        return env_bash
    candidates = []
    git = shutil.which("git")
    if git:  # <GitRoot>\cmd\git.exe -> <GitRoot>\bin\bash.exe
        root = Path(git).resolve().parent.parent
        candidates += [root / "bin" / "bash.exe", root / "usr" / "bin" / "bash.exe"]
    candidates += [
        Path(r"C:\Program Files\Git\bin\bash.exe"),
        Path(r"C:\Program Files\Git\usr\bin\bash.exe"),
        Path(r"C:\Program Files (x86)\Git\bin\bash.exe"),
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    return found or "bash"


BASH = find_bash()

# --------------------------------------------------------------------------- per-ticket runs (v2: parallel)
# RUNS holds every active ticket. The bot can be working on several at once (cap = MAX_PARALLEL).
# phase:  running | awaiting_answers | reviewing | stalled | stopped
# stage:  plan    | code              | deploy
# A run lives from its first /plan|/code|/deploy until it either errors out, gets /stop, or is
# explicitly closed after a successful deploy / non-deployable code.
RUNS: dict[str, dict] = {}
FOCUS: dict[int, str] = {}    # chat_id -> last "active" ticket (default target for /code, /deploy, free text)
RECENT: dict[str, str] = {}   # ticket -> repo (so buttons / commands still find the repo after a run closes)
CURRENT: dict[int, str] = {}  # chat_id -> selected project key (set via /project or /start buttons)


def new_run(ticket: str, repo: str, desc: str, chat_id: int, *, auto: bool = False, stage: str = "plan") -> dict:
    """Register a fresh run and make it the chat's focus."""
    r = {
        "ticket": ticket, "repo": repo, "desc": desc, "chat_id": chat_id,
        "phase": "running", "stage": stage, "proc": None, "pending": set(),
        "auto": auto, "started_at": datetime.now(), "task": None,
    }
    RUNS[ticket] = r
    FOCUS[chat_id] = ticket
    RECENT[ticket] = repo
    return r


def close_run(ticket: str) -> None:
    RUNS.pop(ticket, None)
    # FOCUS may still point at a closed ticket — leave it; helpers will fall through to other matches.


def active_running_count() -> int:
    """Subprocess-active runs (reviewing/awaiting_answers don't consume CPU/API)."""
    return sum(1 for r in RUNS.values() if r["phase"] == "running")


def at_capacity() -> bool:
    return active_running_count() >= MAX_PARALLEL


def runs_for_chat(chat_id: int) -> list[dict]:
    return [r for r in RUNS.values() if r["chat_id"] == chat_id]


def run_for_chat(ticket: str, chat_id: int):
    """Return an active run only when it belongs to this Telegram chat."""
    run = RUNS.get(ticket)
    return run if run and run["chat_id"] == chat_id else None


# Phases in which a steering message is still useful for the PLAN author:
# - "running" + stage=plan         → folded into the NEXT author pass (the immediate next round)
# - "awaiting_answers" + stage=plan → folded into the author pass that fires once questions are answered
# - "stalled" + stage=plan         → folded into the author pass when the user taps "+N rounds"
# A "reviewing" run is mid-code-review (post-coder); steering there targets the CODER.
_PLAN_STEER_PHASES = ("running", "awaiting_answers", "stalled")


def find_steerable(chat_id: int, want: str):
    """Return the run that a steering message (text or photo) should target.

    `want = 'plan'`   → run is at the plan stage (running or awaiting_answers).
    `want = 'review'` → run is in 'reviewing' state (code is written, awaiting deploy/recode).

    Prefer the chat's focused ticket; else the most recently started matching run.
    """
    def matches(r) -> bool:
        if r["chat_id"] != chat_id:
            return False
        if want == "plan":
            return r["phase"] in _PLAN_STEER_PHASES and r["stage"] == "plan"
        if want == "review":
            return r["phase"] == "reviewing"
        return False

    focused = RUNS.get(FOCUS.get(chat_id, "")) if FOCUS.get(chat_id) else None
    if focused and matches(focused):
        return focused
    candidates = [r for r in RUNS.values() if matches(r)]
    return max(candidates, key=lambda r: r["started_at"]) if candidates else None


def _steer_target(want: str, run: dict) -> Path:
    """The notes file a steering message should be appended to for this run."""
    if want == "plan":
        return notes.notes_path(run["repo"], run["ticket"])
    return notes.code_notes_path(run["repo"], run["ticket"])


def _steer_ack(run: dict, want: str, *, kind: str) -> str:
    """Human-friendly reply that names the ticket + tells the user what happens next.
    `kind` ∈ {'note', 'image'}."""
    ticket = run["ticket"]
    icon = "📎" if kind == "image" else "📝"
    if want == "plan":
        if run["phase"] == "awaiting_answers":
            return (f"{icon} [{ticket}] сохранил — применится в следующем раунде автора, "
                    f"ПОСЛЕ того как ответишь на висящие вопросы выше.")
        return f"{icon} [{ticket}] принял — автор учтёт в следующем раунде плана."
    # review
    return f"{icon} [{ticket}] правка принята. Жми «↻ Переписать код» или «🚀 Деплой»."


def stop_ticket(ticket: str) -> bool:
    r = RUNS.get(ticket)
    if not r:
        return False
    r["phase"] = "stopped"
    proc = r.get("proc")
    if proc and proc.poll() is None:
        try:
            proc.terminate()
        except Exception:  # noqa: BLE001
            pass
    close_run(ticket)
    return True


# --------------------------------------------------------------------------- questions file parsing
RE_STATUS = re.compile(r"^\s*STATUS:\s*(.*)$", re.IGNORECASE)
RE_QHEAD = re.compile(r"^#{1,4}\s+(Q\d+)\b\s*[—:-]?\s*(.*)$")
RE_OPT = re.compile(r"^\s*[-*]\s*([A-Za-z])[\).]\s+(.*)$")
RE_ANS = re.compile(r"^\s*A:\s*(.*)$")


def parse_questions(text: str):
    lines = text.splitlines()
    status = None
    questions: list[dict] = []
    cur: dict | None = None
    for idx, line in enumerate(lines):
        m = RE_STATUS.match(line)
        if m and status is None:
            status = m.group(1).strip()
            continue
        h = RE_QHEAD.match(line)
        if h:
            if cur:
                questions.append(cur)
            cur = {"id": h.group(1), "title": (h.group(2) or "").strip(),
                   "qtext": "", "options": [], "answer": "", "answer_idx": None}
            continue
        if cur is None:
            continue
        o = RE_OPT.match(line)
        if o:
            txt = o.group(2).strip()
            reco = "(recommended)" in txt.lower() or "(reco" in txt.lower()
            txt = re.sub(r"\(recommend\w*\)", "", txt, flags=re.IGNORECASE).strip()
            cur["options"].append({"letter": o.group(1).upper(), "text": txt, "recommended": reco})
            continue
        a = RE_ANS.match(line)
        if a:
            cur["answer"] = a.group(1).strip()
            cur["answer_idx"] = idx
            continue
        if not cur["options"] and line.strip():
            cur["qtext"] = (cur["qtext"] + " " + line.strip()).strip()
    if cur:
        questions.append(cur)
    return status, questions, lines


def write_answer(path: Path, qid: str, letter: str) -> bool:
    status, questions, lines = parse_questions(path.read_text(encoding="utf-8"))
    q = next((x for x in questions if x["id"] == qid), None)
    if not q:
        return False
    if q["answer_idx"] is not None:
        lines[q["answer_idx"]] = f"A: {letter}"
    else:
        lines.append(f"A: {letter}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def set_status(path: Path, value: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    for i, l in enumerate(lines):
        if RE_STATUS.match(l):
            lines[i] = f"STATUS: {value}"
            break
    else:
        lines.insert(0, f"STATUS: {value}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def ticket_paths(repo: str, ticket: str) -> dict:
    """All file paths owned by a ticket. Notes/attachment paths come from `notes` module
    so there's exactly one source of truth (the bot AND the scripts must agree)."""
    base = notes.plans_dir(repo)
    return {
        "plan": base / f"{ticket}-plan.md",
        "review": base / f"{ticket}-review.md",
        "questions": base / f"{ticket}-questions.md",
        "notes": notes.notes_path(repo, ticket),
        "code_notes": notes.code_notes_path(repo, ticket),
        "attachments": notes.attachments_dir(repo, ticket),
        "log": base / f"{ticket}.log",
        "diff": base / f"{ticket}.diff",
    }


def make_ticket_id(tok: str) -> str:
    """Normalize an explicit ticket like 'tp-3646' / 'ABC12' → 'TP-3646' / 'ABC-12'."""
    m = re.match(r"(?i)^([A-Z]{2,10})-?(\d+)$", tok)
    return f"{m.group(1).upper()}-{m.group(2)}" if m else re.sub(r"[^A-Za-z0-9._-]", "-", tok)


def slug_id(desc: str) -> str:
    """Build a readable id from a free-text task (no Jira ticket).
    URLs are stripped. Words must START with an ASCII letter (so a lone digit
    like "2" in a Russian-only sentence doesn't slugify to "task-2" and collide
    with prior tickets). Pure-non-ASCII descriptions fall back to a timestamp."""
    no_url = re.sub(r"https?://\S+", " ", desc)
    # Letter-led tokens only — "TP" matches, but "1234" or "2" do not.
    words = re.findall(r"[A-Za-z][A-Za-z0-9]+", no_url)
    slug = "-".join(words[:6]).lower()[:40].strip("-")
    return "task-" + (slug or datetime.now().strftime("%Y%m%d-%H%M%S"))


# --------------------------------------------------------------------------- helpers
def is_allowed(update: Update) -> bool:
    chat = update.effective_chat
    return bool(chat and chat.id in ALLOWED)


def project_keyboard():
    if not PROJECTS:
        return None
    rows, row = [], []
    for key in PROJECTS:
        row.append(InlineKeyboardButton(key, callback_data=f"proj|{key}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    return InlineKeyboardMarkup(rows)


def project_key_for(repo: str):
    rp = Path(repo).as_posix().rstrip("/").lower()
    for k, v in PROJECTS.items():
        if Path(v).as_posix().rstrip("/").lower() == rp:
            return k
    return None


def deploy_target_for(repo: str) -> str:
    key = project_key_for(repo)
    if key and key in SHIP_PROJECTS:
        return SHIP_PROJECTS[key]
    return key or Path(repo).name


def is_deployable(repo: str) -> bool:
    name = (project_key_for(repo) or Path(repo).name).lower()
    return name not in NO_DEPLOY


def code_review_keyboard(ticket: str, repo: str):
    """Buttons shown after the coder finishes: rewrite-with-corrections (+ deploy if allowed)."""
    rows = [[InlineKeyboardButton("↻ Переписать код с правкой", callback_data=f"recode|{ticket}")]]
    if is_deployable(repo):
        target = deploy_target_for(repo)
        rows.append([InlineKeyboardButton(f"🚀 Деплой в прод ({target})", callback_data=f"deploy|{ticket}")])
    return InlineKeyboardMarkup(rows)


def stalled_plan_keyboard(ticket: str):
    """Buttons shown when plan didn't converge in MAX_ITERS rounds.
    Lets the user extend the loop with N more rounds, manually accept the current plan
    (skips review verdict by appending an APPROVED override to the review file), or drop the run."""
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🔁 +3 раунда",  callback_data=f"extend|{ticket}|3"),
         InlineKeyboardButton("🔁 +6 раундов", callback_data=f"extend|{ticket}|6")],
        [InlineKeyboardButton("✅ Принять и в код", callback_data=f"accept|{ticket}"),
         InlineKeyboardButton("❌ Прервать",         callback_data=f"drop|{ticket}")],
    ])


async def send(context: ContextTypes.DEFAULT_TYPE, chat_id: int, text: str) -> None:
    await context.bot.send_message(chat_id=chat_id, text=text[:4096])


async def send_doc(context: ContextTypes.DEFAULT_TYPE, chat_id: int, path: Path) -> None:
    try:
        if path.exists() and path.stat().st_size > 0:
            with path.open("rb") as fh:
                await context.bot.send_document(chat_id=chat_id, document=fh, filename=path.name)
    except Exception as e:  # noqa: BLE001
        log.warning("send_doc failed for %s: %s", path, e)


async def send_question(context: ContextTypes.DEFAULT_TYPE, chat_id: int, ticket: str, q: dict) -> None:
    rows = []
    for opt in q["options"]:
        label = f"{opt['letter']}) {opt['text']}"
        if opt["recommended"]:
            label = "⭐ " + label
        rows.append([InlineKeyboardButton(label[:64], callback_data=f"ans|{ticket}|{q['id']}|{opt['letter']}")])
    body = f"[{ticket}] {q['id']} — {q['title']}\n{q['qtext']}".strip()
    await context.bot.send_message(chat_id=chat_id, text=body[:4096], reply_markup=InlineKeyboardMarkup(rows))


# --------------------------------------------------------------------------- subprocess wrappers (per-run proc tracking)
async def run_loop_once(run: dict, *, max_iters_override: str = ""):
    """Run plan-loop.sh once for `run`; return (returncode, stderr_text). Non-blocking for the event loop.
    `max_iters_override` (e.g. "3") forces a specific MAX_ITERS just for this invocation — used by
    the "+N rounds" stalled-plan button to extend without changing global config."""
    env = dict(os.environ)
    env.update(REPO=Path(run["repo"]).as_posix(),
               MAX_ITERS=(max_iters_override or MAX_ITERS),
               AUTHOR_MODEL=AUTHOR_MODEL,
               REVIEWER_MODEL=REVIEWER_MODEL, PERM_MODE=PERM_MODE)
    proc = subprocess.Popen(
        [BASH, SCRIPT, run["ticket"], run["desc"]],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )
    run["proc"] = proc
    loop = asyncio.get_running_loop()
    _, stderr = await loop.run_in_executor(None, proc.communicate)
    run["proc"] = None
    return proc.returncode, (stderr or "")


async def run_code_once(run: dict):
    """Run code-run.sh once for `run`; return (returncode, stderr_text)."""
    env = dict(os.environ)
    env.update(REPO=Path(run["repo"]).as_posix(), CODER_MODEL=os.environ.get("CODER_MODEL", ""), PERM_MODE=PERM_MODE)
    proc = subprocess.Popen(
        [BASH, CODE_SCRIPT, run["ticket"]],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )
    run["proc"] = proc
    loop = asyncio.get_running_loop()
    _, stderr = await loop.run_in_executor(None, proc.communicate)
    run["proc"] = None
    return proc.returncode, (stderr or "")


async def run_deploy_once(run: dict, deploy_target: str):
    """Run deploy-run.sh once for `run`; return (returncode, stderr_text)."""
    env = dict(os.environ)
    env.update(REPO=Path(run["repo"]).as_posix(), SHIP_PROJECT=deploy_target)
    proc = subprocess.Popen(
        [BASH, DEPLOY_SCRIPT, run["ticket"]],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )
    run["proc"] = proc
    loop = asyncio.get_running_loop()
    _, stderr = await loop.run_in_executor(None, proc.communicate)
    run["proc"] = None
    return proc.returncode, (stderr or "")


def progress_message(line: str):
    """Map a raw log line to a short Telegram progress message (or None to skip)."""
    m = re.search(r"tier=(\S+) -> author=(\S+) reviewer=(\S+) iters=(\S+)", line)
    if m:
        return f"🎚 Сложность {m.group(1)} → автор {m.group(2)}, ревью {m.group(3)} (до {m.group(4)} раундов)"
    m = re.search(r"author: drafting initial plan(?: \(([^)]+)\))?", line)
    if m:
        extra = f" ({m.group(1)})" if m.group(1) else ""
        return f"✍️ Пишу первый вариант плана{extra}…"
    m = re.search(r"round (\d+): reviewer(?: \(([^)]+)\))?", line)
    if m:
        extra = f" ({m.group(2)})" if m.group(2) else ""
        return f"🔎 Ревью плана, раунд {m.group(1)}{extra}…"
    m = re.search(r"round (\d+): author revising(?: \(([^)]+)\))?", line)
    if m:
        extra = f" ({m.group(2)})" if m.group(2) else ""
        return f"✍️ Правлю план, раунд {m.group(1)}{extra}…"
    if "steering note arrived" in line:
        return "📝 Замечание учтено — ещё один проход автора по плану…"
    if "coder: preparing worktree" in line:
        return "📦 Готовлю изолированный worktree…"
    if "applying user corrections" in line:
        return "↻ Применяю твои правки к коду…"
    m = re.search(r"coder: implementing \(([^)]+)\)", line)
    if m:
        return f"🛠 Пишу код ({m.group(1).replace('model=', '')})…"
    if "coder: implementing" in line:
        return "🛠 Пишу код…"
    if "deploy: merging" in line:
        return "🔀 Вливаю ветку в основной чекаут…"
    if "deploy: running GATE_CMD" in line:
        return "🧪 Запускаю GATE_CMD…"
    if "deploy: gate OK" in line:
        return "✅ Гейт прошёл"
    if "deploy: no GATE_CMD set" in line:
        return "⚠️ GATE_CMD не задан — деплой без гейта"
    if "deploy: SKIP_GATE=1" in line:
        return "⚠️ Гейт пропущен (SKIP_GATE=1)"
    if "deploy: gate green" in line:
        return "🚀 Гейт зелёный → запускаю DEPLOY_CMD…"
    return None


async def run_with_progress(context: ContextTypes.DEFAULT_TYPE, chat_id: int, ticket: str, log_path, awaitable):
    """Run the subprocess coroutine while streaming progress lines from its log file to chat.
    Progress messages are prefixed with [ticket] so parallel runs don't get confused."""
    task = asyncio.ensure_future(awaitable)
    try:
        processed = len(log_path.read_text(encoding="utf-8", errors="replace").splitlines()) if log_path.exists() else 0
    except Exception:  # noqa: BLE001
        processed = 0
    while True:
        done, _ = await asyncio.wait({task}, timeout=4)
        if done:
            break
        try:
            if log_path.exists():
                lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
                for line in lines[processed:]:
                    msg = progress_message(line)
                    if msg:
                        await send(context, chat_id, f"[{ticket}] {msg}")
                processed = len(lines)
        except Exception:  # noqa: BLE001
            pass
    return await task


# --------------------------------------------------------------------------- drivers (operate on a run dict)
async def drive_plan(context: ContextTypes.DEFAULT_TYPE, run: dict, *, max_iters_override: str = "") -> None:
    ticket, repo, chat_id = run["ticket"], run["repo"], run["chat_id"]
    run["stage"] = "plan"
    log_path = ticket_paths(repo, ticket)["log"]
    try:
        rc, err = await run_with_progress(context, chat_id, ticket, log_path,
                                          run_loop_once(run, max_iters_override=max_iters_override))
    except FileNotFoundError:
        await send(context, chat_id, f"❌ [{ticket}] `bash` не найден в PATH. Нужен Git Bash / WSL.")
        close_run(ticket)
        return
    except Exception as e:  # noqa: BLE001
        await send(context, chat_id, f"❌ [{ticket}] ошибка запуска цикла: {e}")
        close_run(ticket)
        return

    if run["phase"] == "stopped":  # /stop fired during the run
        close_run(ticket)
        return

    p = ticket_paths(repo, ticket)

    if rc == 0:
        RECENT[ticket] = repo
        await send(context, chat_id, f"✅ [{ticket}] план одобрен ревьюером.\n{p['plan']}")
        await send_doc(context, chat_id, p["plan"])
        if run.get("auto"):
            await send(context, chat_id, f"→ [{ticket}] AUTO_CODE — пишу код автоматически…")
            await drive_code(context, run)
            return
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("🛠 Написать код по плану", callback_data=f"code|{ticket}")]])
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"[{ticket}] Написать код в изолированном worktree (test-first, без деплоя)?",
            reply_markup=kb,
        )
        close_run(ticket)
        return

    if rc == 4:
        text = p["questions"].read_text(encoding="utf-8") if p["questions"].exists() else ""
        _, questions, _ = parse_questions(text)
        unanswered = [q for q in questions if not q["answer"]]
        if not unanswered:
            await send(context, chat_id, f"⚠️ [{ticket}] код 4, но вопросы не разобрать. См. {p['questions']}")
            close_run(ticket)
            return
        run["phase"] = "awaiting_answers"
        run["pending"] = {q["id"] for q in unanswered}
        await send(context, chat_id, f"❓ [{ticket}] нужны твои решения ({len(unanswered)}). Жми вариант под каждым вопросом.")
        for q in unanswered:
            await send_question(context, chat_id, ticket, q)
        return  # keep the run alive, waiting for ans| callbacks

    if rc == 2:
        await send(context, chat_id, f"⚠️ [{ticket}] застрял — план не меняется, ревью не одобряет. Нужен ты.")
        await send_doc(context, chat_id, p["review"])
        close_run(ticket)
        return

    if rc == 3:
        # Not converged in MAX_ITERS rounds. Keep the run alive in 'stalled' state and offer
        # the user buttons to extend with more rounds, manually accept the current plan, or drop.
        # plan-loop.sh's invariant: the plan file is whatever the last author pass produced;
        # the review file holds the last CHANGES_REQUESTED verdict (or the previous round's).
        # Re-invoking the loop (via "extend") naturally continues from there.
        iters_used = MAX_ITERS or "?"
        try:
            log_text = p["log"].read_text(encoding="utf-8", errors="replace")
            m = re.search(r"iters=(\d+)", log_text)
            if m:
                iters_used = m.group(1)
        except Exception:  # noqa: BLE001
            pass
        run["phase"] = "stalled"
        run["proc"] = None
        FOCUS[chat_id] = ticket
        await send_doc(context, chat_id, p["plan"])
        await context.bot.send_message(
            chat_id=chat_id,
            text=(f"⚠️ [{ticket}] не сошлось за {iters_used} раундов.\n\n"
                  "Можно: продлить ещё на сколько-то раундов / принять план как есть и идти в код / прервать.\n"
                  "💬 Перед «+N раундов» можно отправить замечание текстом — автор учтёт."),
            reply_markup=stalled_plan_keyboard(ticket),
        )
        return  # KEEP the run alive in 'stalled'

    tail = "\n".join(err.strip().splitlines()[-15:]) or "(no stderr)"
    await send(context, chat_id, f"❌ [{ticket}] прогон упал (код {rc}).\n{tail}")
    close_run(ticket)


async def drive_code(context: ContextTypes.DEFAULT_TYPE, run: dict, *, fresh: bool = True) -> None:
    ticket, repo, chat_id = run["ticket"], run["repo"], run["chat_id"]
    run["phase"] = "running"
    run["stage"] = "code"
    paths0 = ticket_paths(repo, ticket)
    if fresh:  # first code run of a cycle — drop stale correction notes (a recode keeps them)
        notes.clear_code_notes(repo, ticket)
    log_path = paths0["log"]
    try:
        rc, err = await run_with_progress(context, chat_id, ticket, log_path, run_code_once(run))
    except FileNotFoundError:
        await send(context, chat_id, f"❌ [{ticket}] `bash` не найден в PATH. Нужен Git Bash / WSL.")
        close_run(ticket)
        return
    except Exception as e:  # noqa: BLE001
        await send(context, chat_id, f"❌ [{ticket}] ошибка запуска coder: {e}")
        close_run(ticket)
        return

    if run["phase"] == "stopped":
        close_run(ticket)
        return

    p = ticket_paths(repo, ticket)
    if rc == 0:
        RECENT[ticket] = repo
        await send(context, chat_id, f"✅ [{ticket}] код готов на ветке auto/{ticket} (изолированный worktree).")
        await send_doc(context, chat_id, p["diff"])
        # stay in 'reviewing' — free text now becomes a code correction; buttons = recode / deploy
        run["phase"] = "reviewing"
        run["stage"] = "code"
        run["proc"] = None
        FOCUS[chat_id] = ticket
        if is_deployable(repo):
            text = (f"[{ticket}] Глянь diff. Деплой = merge → гейт → деплой.\n"
                    "💬 Не то? Впиши правку текстом и жми «↻ Переписать код».")
        else:
            text = (f"[{ticket}] Деплой этого проекта — вручную.\n"
                    "💬 Хочешь поправить? Впиши правку текстом и жми «↻ Переписать код».")
        await context.bot.send_message(chat_id=chat_id, text=text, reply_markup=code_review_keyboard(ticket, repo))
        return  # KEEP the run alive in 'reviewing'

    if rc == 5:
        await send(context, chat_id, f"⚠️ [{ticket}] coder не внёс изменений (возможно, задача уже реализована). См. {p['log']}.")
    else:
        tail = "\n".join(err.strip().splitlines()[-15:]) or "(no stderr)"
        await send(context, chat_id, f"❌ [{ticket}] coder упал (код {rc}).\n{tail}")
    close_run(ticket)


async def drive_deploy(context: ContextTypes.DEFAULT_TYPE, run: dict) -> None:
    ticket, repo, chat_id = run["ticket"], run["repo"], run["chat_id"]
    run["phase"] = "running"
    run["stage"] = "deploy"
    deploy_target = deploy_target_for(repo)
    log_path = ticket_paths(repo, ticket)["log"]
    try:
        rc, err = await run_with_progress(context, chat_id, ticket, log_path, run_deploy_once(run, deploy_target))
    except FileNotFoundError:
        await send(context, chat_id, f"❌ [{ticket}] `bash` не найден в PATH.")
        close_run(ticket)
        return
    except Exception as e:  # noqa: BLE001
        await send(context, chat_id, f"❌ [{ticket}] ошибка запуска деплоя: {e}")
        close_run(ticket)
        return

    if run["phase"] == "stopped":
        close_run(ticket)
        return

    if rc == 0:
        notes.clear_code_notes(repo, ticket)  # corrections deployed — clean slate for the next cycle
        await send(context, chat_id, f"🚀 [{ticket}] задеплоено ({deploy_target}). Гейт зелёный, ветка влита и подчищена.")
    else:
        tail = "\n".join(err.strip().splitlines()[-15:]) or "(no stderr)"
        await send(context, chat_id, f"❌ [{ticket}] деплой не прошёл (код {rc}). Если до деплоя — merge откатан.\n{tail}")
    close_run(ticket)


# --------------------------------------------------------------------------- handlers
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    chat_id = update.effective_chat.id
    current = CURRENT.get(chat_id) or REPO_DEFAULT or "—"
    text = (
        "plan-bot готов.\n"
        f"Текущий проект: {current}\n"
        f"Параллель: до {MAX_PARALLEL} задач одновременно.\n\n"
        "/plan <описание|TP-1234> — запустить (план → код → diff)\n"
        "/project — выбрать проект кнопкой\n"
        "/code [project] <ticket> — код по одобренному плану\n"
        "/deploy [project] <ticket> — гейт (GATE_CMD) → деплой (DEPLOY_CMD)\n"
        "/list — активные задачи · /focus <ticket> — переключить фокус\n"
        "/stop [ticket] — отменить · /whoami — твой chat_id\n"
        "(/plan --manual — только план, код по кнопке)\n"
        "💬 Текстом ИЛИ фото без команды: уйдёт в задачу-«фокус» (план — автору, после кода — кодеру). Фото складываются в <ticket>-attachments/, агент сам их откроет."
    )
    kb = project_keyboard()
    if kb:
        await update.message.reply_text(text + "\n\nВыбери проект:", reply_markup=kb)
    else:
        await update.message.reply_text(text)


async def cmd_project(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    kb = project_keyboard()
    if not kb:
        return await update.message.reply_text(
            "Проекты не заданы. Добавь их в PLAN_PROJECTS (JSON) в .env, например:\n"
            'PLAN_PROJECTS={"app":"/path/to/your-repo","api":"/path/to/another-repo"}'
        )
    cur = CURRENT.get(update.effective_chat.id) or REPO_DEFAULT or "—"
    await update.message.reply_text(f"Текущий проект: {cur}\nВыбери проект:", reply_markup=kb)


async def cmd_whoami(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    await update.message.reply_text(f"chat_id: {update.effective_chat.id}")


async def deny(update: Update) -> None:
    await update.message.reply_text(
        f"⛔ Не авторизовано. Твой chat_id: {update.effective_chat.id} — добавь его в TELEGRAM_ALLOWED_CHAT_ID."
    )


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    chat_id = update.effective_chat.id
    rs = sorted(runs_for_chat(chat_id), key=lambda r: r["started_at"])
    if not rs:
        return await update.message.reply_text("Активных задач нет.")
    f = FOCUS.get(chat_id)
    lines = []
    for r in rs:
        marker = " ← focus" if r["ticket"] == f else ""
        age = int((datetime.now() - r["started_at"]).total_seconds())
        lines.append(f"  • {r['ticket']}  ({r['phase']}/{r['stage'] or '-'}, {age}s){marker}")
    await update.message.reply_text(
        f"Активные ({len(rs)}/{MAX_PARALLEL}):\n" + "\n".join(lines) + "\n\n/focus <ticket> — переключить · /stop <ticket>"
    )


async def cmd_focus(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    chat_id = update.effective_chat.id
    args = list(context.args or [])
    if not args:
        return await cmd_list(update, context)
    ticket = args[0]
    if ticket not in RUNS:
        return await update.message.reply_text(f"Нет активной задачи {ticket}. /list — список.")
    if RUNS[ticket]["chat_id"] != chat_id:
        return await update.message.reply_text("Эта задача из другого чата.")
    FOCUS[chat_id] = ticket
    await update.message.reply_text(f"🎯 Фокус: {ticket}")


async def cmd_plan(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)

    toks = list(context.args or [])
    auto = AUTO_CODE
    if any(t.lower() == "--auto" for t in toks):
        auto = True
    if any(t.lower() in ("--manual", "--noauto") for t in toks):
        auto = False
    toks = [t for t in toks if t.lower() not in ("--auto", "--manual", "--noauto")]
    if not toks:
        return await update.message.reply_text("Использование: /plan [project] [--auto|--manual] [TP-1234] <описание>")

    if toks and toks[0].lower() in PROJECTS:
        repo = PROJECTS[toks[0].lower()]                  # explicit project token
        toks = toks[1:]
    else:
        cur = CURRENT.get(update.effective_chat.id)       # remembered project (from buttons)
        repo = PROJECTS[cur] if cur in PROJECTS else REPO_DEFAULT

    if toks and re.match(r"(?i)^[A-Z]{2,10}-?\d+$", toks[0]):
        ticket = make_ticket_id(toks[0])      # explicit ticket id (e.g. TP-1234 or TASK-12)
        desc = " ".join(toks[1:]).strip()
    else:
        desc = " ".join(toks).strip()         # free-text task — auto-id from the description
        ticket = slug_id(desc)

    if not desc:
        desc = "<no description provided>"
    if not repo:
        return await update.message.reply_text("Не задан репозиторий: установи PLAN_REPO или передай известный project.")
    if not (Path(repo) / ".git").exists():
        return await update.message.reply_text(f"Это не git-репозиторий: {repo}")
    if ticket in RUNS:
        return await update.message.reply_text(f"⏳ {ticket} уже в работе ({RUNS[ticket]['phase']}). /list · /stop {ticket}")
    if at_capacity():
        return await update.message.reply_text(
            f"⏳ Достигнут лимит параллели ({MAX_PARALLEL}). /list — что активно, /stop <ticket> — освободить слот."
        )

    chat_id = update.effective_chat.id
    run = new_run(ticket, repo, desc, chat_id, auto=auto, stage="plan")
    await update.message.reply_text(
        f"▶️ [{ticket}] планирование (repo={repo}). Активно: {active_running_count()}/{MAX_PARALLEL}."
    )
    run["task"] = asyncio.create_task(drive_plan(context, run))


async def cmd_stop(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    chat_id = update.effective_chat.id
    args = list(context.args or [])
    if args:
        ticket = args[0]
        if ticket not in RUNS:
            return await update.message.reply_text(f"Нет активной задачи {ticket}.")
        if RUNS[ticket]["chat_id"] != chat_id:
            return await update.message.reply_text("Эта задача из другого чата.")
        stop_ticket(ticket)
        return await update.message.reply_text(f"⏹ Остановил {ticket}.")
    chat_runs = [r for r in runs_for_chat(chat_id) if r["phase"] in ("running", "awaiting_answers")]
    if not chat_runs:
        return await update.message.reply_text("Нечего останавливать.")
    if len(chat_runs) == 1:
        t = chat_runs[0]["ticket"]
        stop_ticket(t)
        return await update.message.reply_text(f"⏹ Остановил {t}.")
    listing = "\n".join(f"  • {r['ticket']}" for r in chat_runs)
    await update.message.reply_text(f"Несколько активных — укажи какую:\n{listing}\n/stop <ticket>")


async def cmd_code(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    toks = list(context.args or [])
    if not toks:
        return await update.message.reply_text("Использование: /code [project] <ticket>")
    explicit_project = False
    if toks[0].lower() in PROJECTS:
        repo = PROJECTS[toks[0].lower()]
        explicit_project = True
        toks = toks[1:]
    else:
        cur = CURRENT.get(update.effective_chat.id)
        repo = PROJECTS[cur] if cur in PROJECTS else REPO_DEFAULT
    if not toks:
        return await update.message.reply_text("Укажи ticket id (как в имени плана).")
    ticket = toks[0]
    # RECENT remembers per-ticket repo from the prior /plan — fall back to it ONLY when the user
    # did NOT specify a project. An explicit project token must win (covers cross-repo recovery).
    if not explicit_project:
        repo = RECENT.get(ticket, repo)
    if not repo:
        return await update.message.reply_text("Не задан репозиторий: PLAN_REPO или известный project.")
    if not (Path(repo) / ".git").exists():
        return await update.message.reply_text(f"Это не git-репозиторий: {repo}")
    if ticket in RUNS:
        return await update.message.reply_text(
            f"⏳ {ticket} уже в работе ({RUNS[ticket]['phase']}). Используй ↻ Переписать или /stop {ticket}."
        )
    if at_capacity():
        return await update.message.reply_text(f"⏳ Лимит параллели {MAX_PARALLEL}. /list · /stop <ticket>")
    chat_id = update.effective_chat.id
    run = new_run(ticket, repo, "", chat_id, stage="code")
    await update.message.reply_text(f"🛠 [{ticket}] пишу код в worktree (test-first, без деплоя)…")
    run["task"] = asyncio.create_task(drive_code(context, run))


async def cmd_deploy(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update):
        return await deny(update)
    toks = list(context.args or [])
    if not toks:
        return await update.message.reply_text("Использование: /deploy [project] <ticket>")
    explicit_project = False
    if toks[0].lower() in PROJECTS:
        repo = PROJECTS[toks[0].lower()]
        explicit_project = True
        toks = toks[1:]
    else:
        cur = CURRENT.get(update.effective_chat.id)
        repo = PROJECTS[cur] if cur in PROJECTS else REPO_DEFAULT
    if not toks:
        return await update.message.reply_text("Укажи ticket id.")
    ticket = toks[0]
    chat_id = update.effective_chat.id
    existing = RUNS.get(ticket)
    if existing and existing["chat_id"] != chat_id:
        return await update.message.reply_text("Эта задача из другого чата.")
    if not explicit_project:
        repo = RECENT.get(ticket, repo)
    if not repo:
        return await update.message.reply_text("Не задан репозиторий.")
    if not is_deployable(repo):
        return await update.message.reply_text("Деплой этого проекта пока вручную.")
    if existing and existing["phase"] not in ("reviewing",):
        return await update.message.reply_text(
            f"⏳ {ticket} занят ({existing['phase']}). Дождись или /stop {ticket}."
        )
    if at_capacity() and existing is None:
        return await update.message.reply_text(f"⏳ Лимит параллели {MAX_PARALLEL}. /list · /stop <ticket>")
    run = existing  # if a 'reviewing' run is open, reuse it; otherwise create one
    if run is None:
        run = new_run(ticket, repo, "", chat_id, stage="deploy")
    else:
        run["phase"] = "running"; run["stage"] = "deploy"
        FOCUS[chat_id] = ticket
    await update.message.reply_text(f"🚀 [{ticket}] гейт → деплой…")
    run["task"] = asyncio.create_task(drive_deploy(context, run))


async def _route_steering(update: Update, write_to_run, *, no_target_hint: str) -> None:
    """Shared routing for steering inputs (text + photos).

    `write_to_run(run, want)` does the actual append+confirmation work; we just pick the run
    (plan-stage first, else review-stage) and handle the no-target case uniformly.
    """
    chat_id = update.effective_chat.id

    for want in ("plan", "review"):
        run = find_steerable(chat_id, want)
        if run is None:
            continue
        try:
            await write_to_run(run, want)
        except Exception as e:  # noqa: BLE001
            await update.message.reply_text(f"❌ [{run['ticket']}] не смог сохранить: {e}")
            return
        FOCUS[chat_id] = run["ticket"]
        return

    # No suitable run — be informative but brief.
    if runs_for_chat(chat_id):
        await update.message.reply_text(no_target_hint)
    else:
        await update.message.reply_text("Бот свободен. Запусти задачу: /plan <описание>.")


async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Free-text (non-command) message → steering note for the focused run.

    Goes to <ticket>-notes.md while planning (incl. awaiting_answers), to
    <ticket>-code-notes.md while reviewing the diff. Outside of an active run, short hint.
    """
    if not is_allowed(update):
        return  # stay silent for non-authorized chats
    text = (update.message.text or "").strip()
    if not text:
        return

    async def write(run: dict, want: str) -> None:
        notes.append_text(_steer_target(want, run), text)
        kb = code_review_keyboard(run["ticket"], run["repo"]) if want == "review" else None
        await update.message.reply_text(_steer_ack(run, want, kind="note"), reply_markup=kb)

    await _route_steering(update, write,
        no_target_hint="Сейчас нет задачи, готовой к замечанию (нет активного плана и нет diff'а на ревью). /list — что активно.")


async def on_photo(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Photo (incl. forwards) → saved to <ticket>-attachments/, referenced from notes.

    The plan author / coder agent finds the `[image: <abs-path>]` marker in its notes file
    and opens the image with its Read tool (Claude Code supports PNG/JPEG as visual input).
    Caption (if any) is preserved on the same line.
    """
    if not is_allowed(update):
        return
    msg = update.message
    if not msg or not msg.photo:
        return
    caption = (msg.caption or "").strip()

    async def write(run: dict, want: str) -> None:
        # largest available size — last entry in the photos array
        tg_file = await context.bot.get_file(msg.photo[-1].file_id)
        saved = await notes.save_photo(tg_file, run["repo"], run["ticket"])
        notes.append_image_ref(_steer_target(want, run), saved, caption)
        kb = code_review_keyboard(run["ticket"], run["repo"]) if want == "review" else None
        ack = _steer_ack(run, want, kind="image")
        tail = f"\n📁 {saved.name}" + (f" + подпись" if caption else "")
        await update.message.reply_text(ack + tail, reply_markup=kb)

    await _route_steering(update, write,
        no_target_hint="Сейчас нет задачи, готовой принять вложение. /list — что активно.")


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if not is_allowed(update):
        await query.answer("Не авторизовано", show_alert=True)
        return
    data = query.data or ""

    if data.startswith("proj|"):
        key = data.split("|", 1)[1]
        if key not in PROJECTS:
            await query.answer("Неизвестный проект.")
            return
        CURRENT[update.effective_chat.id] = key
        await query.answer(f"Проект: {key}")
        try:
            await query.edit_message_text(f"✅ Проект: {key}\nТеперь пришли задачу: /plan <описание>")
        except Exception:  # noqa: BLE001
            pass
        return

    if data.startswith("code|"):
        ticket = data.split("|", 1)[1]
        chat_id = update.effective_chat.id
        existing = RUNS.get(ticket)
        if existing and existing["chat_id"] != chat_id:
            await query.answer("Эта задача из другого чата.", show_alert=True)
            return
        if existing:
            await query.answer(f"{ticket} уже в работе.")
            return
        if at_capacity():
            await query.answer(f"Лимит параллели {MAX_PARALLEL}.", show_alert=True)
            return
        repo = RECENT.get(ticket) or REPO_DEFAULT
        if not repo:
            await query.answer("Не знаю репо. Используй /code <project> <ticket>.", show_alert=True)
            return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        run = new_run(ticket, repo, "", chat_id, stage="code")
        await send(context, chat_id, f"🛠 [{ticket}] пишу код в worktree (test-first, без деплоя)…")
        run["task"] = asyncio.create_task(drive_code(context, run))
        return

    if data.startswith("deploy|"):
        ticket = data.split("|", 1)[1]
        chat_id = update.effective_chat.id
        existing = RUNS.get(ticket)
        if existing and existing["chat_id"] != chat_id:
            await query.answer("Эта задача из другого чата.", show_alert=True)
            return
        if existing and existing["phase"] not in ("reviewing",):
            await query.answer(f"{ticket} занят ({existing['phase']}).")
            return
        if existing is None and at_capacity():
            await query.answer(f"Лимит параллели {MAX_PARALLEL}.", show_alert=True)
            return
        repo = (existing["repo"] if existing else None) or RECENT.get(ticket) or REPO_DEFAULT
        if not repo:
            await query.answer("Не знаю репо. Используй /deploy <project> <ticket>.", show_alert=True)
            return
        if not is_deployable(repo):
            await query.answer("Этот проект деплоится вручную.", show_alert=True)
            return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        if existing is None:
            run = new_run(ticket, repo, "", chat_id, stage="deploy")
        else:
            run = existing
            run["phase"] = "running"; run["stage"] = "deploy"
            FOCUS[chat_id] = ticket
        await send(context, chat_id, f"🚀 [{ticket}] гейт → деплой…")
        run["task"] = asyncio.create_task(drive_deploy(context, run))
        return

    if data.startswith("recode|"):
        ticket = data.split("|", 1)[1]
        chat_id = update.effective_chat.id
        existing = RUNS.get(ticket)
        if existing and existing["chat_id"] != chat_id:
            await query.answer("Эта задача из другого чата.", show_alert=True)
            return
        if existing and existing["phase"] not in ("reviewing",):
            await query.answer(f"{ticket} занят ({existing['phase']}).")
            return
        if existing is None and at_capacity():
            await query.answer(f"Лимит параллели {MAX_PARALLEL}.", show_alert=True)
            return
        repo = (existing["repo"] if existing else None) or RECENT.get(ticket) or REPO_DEFAULT
        if not repo:
            await query.answer("Не знаю репо. Используй /code <project> <ticket>.", show_alert=True)
            return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        if existing is None:
            run = new_run(ticket, repo, "", chat_id, stage="code")
        else:
            run = existing
            run["phase"] = "running"; run["stage"] = "code"
            FOCUS[chat_id] = ticket
        await send(context, chat_id, f"↻ [{ticket}] переписываю код с твоими правками…")
        run["task"] = asyncio.create_task(drive_code(context, run, fresh=False))
        return

    # ---- stalled-plan recovery buttons (rc=3 in drive_plan) ----
    if data.startswith("extend|"):
        # extend|<ticket>|<N>  — re-run plan-loop.sh with MAX_ITERS=N over the existing plan.
        parts = data.split("|")
        if len(parts) < 3:
            await query.answer("bad payload"); return
        _, ticket, n_more = parts[0], parts[1], parts[2]
        if n_more not in {"3", "6"}:
            await query.answer("bad payload", show_alert=True); return
        run = run_for_chat(ticket, update.effective_chat.id)
        if not run or run["phase"] != "stalled":
            await query.answer("Этот вопрос уже неактуален."); return
        if at_capacity():
            await query.answer(f"Лимит параллели {MAX_PARALLEL} — освободи слот сначала.", show_alert=True); return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        run["phase"] = "running"; run["stage"] = "plan"
        FOCUS[update.effective_chat.id] = ticket
        await send(context, run["chat_id"], f"🔁 [{ticket}] продлеваю ещё на {n_more} раунд(ов)…")
        run["task"] = asyncio.create_task(drive_plan(context, run, max_iters_override=n_more))
        return

    if data.startswith("accept|"):
        # accept|<ticket>  — user overrides the reviewer, marks plan APPROVED, goes to code.
        ticket = data.split("|", 1)[1]
        run = run_for_chat(ticket, update.effective_chat.id)
        if not run or run["phase"] != "stalled":
            await query.answer("Этот вопрос уже неактуален."); return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        # Append a clear manual-override marker so the audit trail shows the user accepted,
        # NOT a real reviewer approval. code-run.sh greps for "VERDICT: APPROVED" anywhere
        # in the file, so this both satisfies the gate AND documents what happened.
        p = ticket_paths(run["repo"], ticket)
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        try:
            with p["review"].open("a", encoding="utf-8") as fh:
                fh.write(f"\n\n## Manual override ({stamp})\n"
                         f"User accepted the plan as-is after the reviewer did not converge.\n\n"
                         f"VERDICT: APPROVED\n")
        except Exception as e:  # noqa: BLE001
            await send(context, run["chat_id"], f"❌ [{ticket}] не смог дописать override в review: {e}")
            return
        await send(context, run["chat_id"], f"✅ [{ticket}] принял план как есть (manual override). Иду к кодеру…")
        run["phase"] = "running"; run["stage"] = "code"
        FOCUS[update.effective_chat.id] = ticket
        run["task"] = asyncio.create_task(drive_code(context, run))
        return

    if data.startswith("drop|"):
        # drop|<ticket>  — close the stalled run cleanly.
        ticket = data.split("|", 1)[1]
        run = run_for_chat(ticket, update.effective_chat.id)
        if not run or run["phase"] != "stalled":
            await query.answer("Этот вопрос уже неактуален."); return
        await query.answer()
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        close_run(ticket)
        await send(context, run["chat_id"], f"❌ [{ticket}] прервал. План и ревью остались в репо.")
        return

    if not data.startswith("ans|"):
        await query.answer()
        return
    _, ticket, qid, letter = (data.split("|") + ["", "", ""])[:4]
    run = run_for_chat(ticket, update.effective_chat.id)
    if not run or run["phase"] != "awaiting_answers":
        await query.answer("Этот вопрос уже неактуален.")
        return
    if qid not in run["pending"]:
        await query.answer("Уже отвечено.")
        return

    p = ticket_paths(run["repo"], ticket)
    if not write_answer(p["questions"], qid, letter):
        await query.answer("Не нашёл вопрос в файле.", show_alert=True)
        return

    run["pending"].discard(qid)
    await query.answer(f"{qid} → {letter}")
    try:
        await query.edit_message_text(f"✅ [{ticket}] {qid}: {letter}")
    except Exception:  # noqa: BLE001
        pass

    if not run["pending"]:
        set_status(p["questions"], "ANSWERED")
        chat_id = run["chat_id"]
        await send(context, chat_id, f"▶️ [{ticket}] ответы получены, продолжаю.")
        run["phase"] = "running"; run["stage"] = "plan"
        run["task"] = asyncio.create_task(drive_plan(context, run))


def main() -> None:
    if not TOKEN:
        raise SystemExit("Set TELEGRAM_BOT_TOKEN (env or .env).")
    if not ALLOWED:
        log.warning("TELEGRAM_ALLOWED_CHAT_ID is empty — /plan and /stop will reject everyone. "
                    "Send /whoami to the bot to learn your chat_id, then set it.")
    app = Application.builder().token(TOKEN).concurrent_updates(True).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("whoami", cmd_whoami))
    app.add_handler(CommandHandler("project", cmd_project))
    app.add_handler(CommandHandler("plan", cmd_plan))
    app.add_handler(CommandHandler("stop", cmd_stop))
    app.add_handler(CommandHandler("code", cmd_code))
    app.add_handler(CommandHandler("deploy", cmd_deploy))
    app.add_handler(CommandHandler("list", cmd_list))
    app.add_handler(CommandHandler("focus", cmd_focus))
    app.add_handler(MessageHandler(filters.PHOTO, on_photo))  # before TEXT (own filter, but explicit order)
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.add_handler(CallbackQueryHandler(on_callback))
    log.info("plan-bot starting (bash=%s, allowed=%s, default repo=%s, parallel=%d)",
             BASH, ALLOWED or "<none>", REPO_DEFAULT or "<none>", MAX_PARALLEL)
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
