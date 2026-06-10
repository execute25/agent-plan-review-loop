#!/usr/bin/env bash
set -euo pipefail
# Laravel deploy step for agent-plan-review-loop (use as DEPLOY_CMD in deploy-run.sh).
# Runs your `ship` script: `bash $SHIP_SCRIPT $SHIP_PROJECT prod`.
#
# deploy-run.sh has ALREADY pushed the merge to origin before calling this, and
# exports REPO, TICKET, SHIP_PROJECT, ORIG_HEAD, NEW_HEAD.
#
# Env:
#   SHIP_SCRIPT   path to your deploy script (required)
#   SHIP_PROJECT  project name passed to it (exported by deploy-run.sh)

SHIP_SCRIPT="${SHIP_SCRIPT:?Set SHIP_SCRIPT to the path of your ship/deploy script}"
SHIP_PROJECT="${SHIP_PROJECT:?SHIP_PROJECT not set (run via deploy-run.sh)}"
[[ -f "$SHIP_SCRIPT" ]] || { echo "ship script not found: $SHIP_SCRIPT"; exit 1; }

exec bash "$SHIP_SCRIPT" "$SHIP_PROJECT" prod
