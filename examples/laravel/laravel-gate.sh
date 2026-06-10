#!/usr/bin/env bash
set -uo pipefail
# Laravel deploy gate for agent-plan-review-loop (use as GATE_CMD in deploy-run.sh).
#
# Cheap, no-DB-by-default gate on the merged code:
#   1. php -l on every changed *.php file
#   2. the app boots (php artisan --version)   [skipped if vendor/ is missing or LINT_ONLY=1]
#   3. phpunit on changed tests/*Test.php       [only when RUN_TESTS=1]
# Non-zero exit => deploy-run.sh rolls the merge back and ships nothing.
#
# deploy-run.sh exports: REPO TICKET SHIP_PROJECT ORIG_HEAD NEW_HEAD.
# Extra optional env (the bot sets these per project):
#   PHP         php binary (default: php) — e.g. a php 7.x build for Laravel 5.x
#   LINT_ONLY   1 = syntax check only (no boot/tests) — for projects with no compatible local PHP
#   RUN_TESTS   1 = run phpunit on changed test files (needs a test DB + dev deps installed)

REPO="${REPO:?REPO not set (run this via deploy-run.sh)}"
base="${ORIG_HEAD:?ORIG_HEAD not set}"
head="${NEW_HEAD:?NEW_HEAD not set}"
PHP_BIN="${PHP:-php}"

command -v "$PHP_BIN" >/dev/null 2>&1 || { echo "PHP not found ('$PHP_BIN') — set PHP or LINT differently"; exit 1; }

# 1. syntax of changed PHP files
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  "$PHP_BIN" -l "$REPO/$f" >/dev/null 2>&1 || { echo "php -l failed: $f"; exit 1; }
done < <(git -C "$REPO" diff --name-only "$base" "$head" | grep -E '\.php$' || true)
echo "php -l OK"

if [[ "${LINT_ONLY:-0}" == "1" ]]; then
  echo "LINT_ONLY=1 — boot + tests skipped"; exit 0
fi
if [[ ! -f "$REPO/vendor/autoload.php" ]]; then
  echo "vendor/ not installed locally — boot + tests skipped (lint-only)"; exit 0
fi

# 2. app boots (catches provider/config fatals). APP_ENV=local dodges prod-only guards.
( cd "$REPO" && APP_ENV=local "$PHP_BIN" artisan --version >/dev/null 2>&1 ) || { echo "app boot failed (php artisan --version)"; exit 1; }
echo "boot OK"

# 3. run touched test files — opt-in (most app tests need a DB)
if [[ "${RUN_TESTS:-0}" != "1" ]]; then
  echo "tests opt-in only (RUN_TESTS!=1) — lint+boot gate"; exit 0
fi
phpunit=""
if [[ -f "$REPO/vendor/phpunit/phpunit/phpunit" ]]; then phpunit="vendor/phpunit/phpunit/phpunit"
elif [[ -f "$REPO/vendor/bin/phpunit" ]]; then phpunit="vendor/bin/phpunit"; fi
tests="$(git -C "$REPO" diff --name-only "$base" "$head" | grep -E 'tests/.*Test\.php$' || true)"
if [[ -n "$phpunit" && -n "$tests" ]]; then
  # shellcheck disable=SC2086
  ( cd "$REPO" && "$PHP_BIN" $phpunit $tests ) || { echo "tests failed"; exit 1; }
  echo "tests OK"
elif [[ -z "$phpunit" ]]; then
  echo "RUN_TESTS=1 but phpunit not installed (composer install --dev) — skipping tests"
else
  echo "no changed test files to run"
fi
exit 0
