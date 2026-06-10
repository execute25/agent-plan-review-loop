#!/usr/bin/env bash
set -euo pipefail

# Install the Claude skills for interactive use (/ticket-plan-start, /ticket-plan-review).

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="${TOOLKIT_DIR}/skills"
SKILLS_DST="${HOME}/.claude/skills"

mkdir -p "$SKILLS_DST"
for s in ticket-plan-start ticket-plan-review; do
  mkdir -p "${SKILLS_DST}/${s}"
  cp "${SKILLS_SRC}/${s}/SKILL.md" "${SKILLS_DST}/${s}/SKILL.md"
  echo "✓ installed skill: ${s}"
done

cat <<EOF

Skills installed to ${SKILLS_DST}

Interactive use:
  /ticket-plan-start  docs/tickets/plans/TP-1234-plan.md
  /ticket-plan-review docs/tickets/plans/TP-1234-plan.md

Automated loop (no copy-paste):
  REPO=/path/to/repo bash ${TOOLKIT_DIR}/scripts/plan-loop.sh TASK-1 "add a CSV export button to the reports page"
EOF
