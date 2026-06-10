"""Persistent steering notes for a ticket — text + image attachments.

The bot writes the user's live steering messages (free text from Telegram, plus any
forwarded/attached photos) into one of two files under the target repo:

    <repo>/docs/tickets/plans/<ticket>-notes.md       — steering for the PLAN author
    <repo>/docs/tickets/plans/<ticket>-code-notes.md  — corrections for the CODER

Images are saved into a sibling folder and referenced by absolute path inside the notes
file, so the agent (running in a separate plan-loop / code-run subprocess) can open them
with its Read tool — Claude Code natively supports PNG/JPEG as visual input.

    <repo>/docs/tickets/plans/<ticket>-attachments/img-NNN.<ext>

This module is the single source of truth for all of these paths. plan_bot.ticket_paths
re-exports them so call sites don't pick names out of thin air.
"""

from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path
from typing import Protocol

log = logging.getLogger(__name__)

# All ticket artifacts live here, relative to the repo root.
PLANS_SUBDIR = "docs/tickets/plans"


# --------------------------------------------------------------------------- paths
def plans_dir(repo: str) -> Path:
    """Directory holding ALL ticket artifacts for `repo`."""
    return Path(repo) / PLANS_SUBDIR


def notes_path(repo: str, ticket: str) -> Path:
    """Steering notes for the PLAN author. Cleared when a fresh plan is created."""
    return plans_dir(repo) / f"{ticket}-notes.md"


def code_notes_path(repo: str, ticket: str) -> Path:
    """Corrections for the CODER. Cleared on the first coder run of a cycle and on deploy."""
    return plans_dir(repo) / f"{ticket}-code-notes.md"


def attachments_dir(repo: str, ticket: str) -> Path:
    """Folder for images attached via Telegram, referenced by absolute path from the notes files."""
    return plans_dir(repo) / f"{ticket}-attachments"


# --------------------------------------------------------------------------- write helpers
def _now_stamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _append_line(path: Path, line: str) -> None:
    """Append a single line; create the parent directory if missing."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line.rstrip("\n") + "\n")


def append_text(path: Path, text: str) -> str:
    """Append a free-text steering note. Returns the written line (useful for echoing back)."""
    line = f"- [{_now_stamp()}] {text.strip()}"
    _append_line(path, line)
    return line


def append_image_ref(path: Path, image_path: Path, caption: str = "") -> str:
    """Append a note that references a saved image by absolute path.

    The marker format `[image: <abs-path>]` is what the author / coder prompts tell the
    agent to look for — they then Read the path to see the image. The optional `caption`
    (Telegram message caption) is preserved on the same line.
    """
    abs_p = image_path.resolve()
    suffix = f" — {caption.strip()}" if caption.strip() else ""
    line = f"- [{_now_stamp()}] [image: {abs_p}]{suffix}"
    _append_line(path, line)
    return line


# --------------------------------------------------------------------------- attachments
class TelegramFile(Protocol):
    """Minimal protocol matching python-telegram-bot's File object.
    Kept tiny so we don't couple this module to PTB types — easier to test."""

    async def download_to_drive(self, custom_path: str) -> Path: ...


def _next_image_path(repo: str, ticket: str, ext: str) -> Path:
    """Return the next free `img-NNN.<ext>` path; creates the attachments dir if missing.
    Per-ticket counter so order matches upload order in the chat (useful when reading the log)."""
    folder = attachments_dir(repo, ticket)
    folder.mkdir(parents=True, exist_ok=True)
    n = len(list(folder.glob(f"img-*{ext}"))) + 1
    return folder / f"img-{n:03d}{ext}"


async def save_photo(file_obj: TelegramFile, repo: str, ticket: str, *, ext: str = ".jpg") -> Path:
    """Download a Telegram photo file to `<ticket>-attachments/img-NNN.<ext>`. Returns the absolute path.

    Raises whatever `download_to_drive` raises (network, disk full, …); the caller is expected
    to catch and inform the user — we don't swallow errors here.
    """
    dst = _next_image_path(repo, ticket, ext)
    saved = await file_obj.download_to_drive(custom_path=str(dst))
    return Path(saved).resolve()


# --------------------------------------------------------------------------- lifecycle
def clear_plan_notes(repo: str, ticket: str) -> None:
    """Drop the plan steering notes file (used when a brand-new plan is started)."""
    notes_path(repo, ticket).unlink(missing_ok=True)


def clear_code_notes(repo: str, ticket: str) -> None:
    """Drop the code corrections file (used on the first coder run of a cycle and after a successful deploy)."""
    code_notes_path(repo, ticket).unlink(missing_ok=True)
