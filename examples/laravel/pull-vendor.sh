#!/usr/bin/env bash
# Pull vendor/ from a prod host into local Laravel checkouts (READ-ONLY on prod).
#
# Local edit-checkouts often lack vendor/ (composer runs on the server). Copying it
# down lets the deploy gate boot the app / run tests locally. Nothing on prod is changed.
#
# Configure via env (NO hard-coded hosts — bring your own):
#   PROD_HOST    user@host of the prod box                  (required, e.g. root@1.2.3.4)
#   PROD_ROOT    remote dir holding <project>/vendor         (required, e.g. /var/www/html)
#   LOCAL_ROOT   local dir holding your project checkouts    (default: current dir)
#
# Usage:
#   PROD_HOST=root@1.2.3.4 PROD_ROOT=/var/www/html LOCAL_ROOT=/path/to/projects \
#     bash pull-vendor.sh                # every checkout without vendor/
#   PROD_HOST=... PROD_ROOT=... bash pull-vendor.sh app api   # only the named local dirs
#   FORCE=1 PROD_HOST=... PROD_ROOT=... bash pull-vendor.sh app   # re-pull even if vendor/ present
set -uo pipefail   # NOT -e: keep going past a per-project failure

PROD_HOST="${PROD_HOST:?Set PROD_HOST=user@host}"
PROD_ROOT="${PROD_ROOT:?Set PROD_ROOT=/remote/webroot}"
LOCAL_ROOT="${LOCAL_ROOT:-$PWD}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=15"

want=("$@")
selected() {
  [ ${#want[@]} -eq 0 ] && return 0
  local w
  for w in "${want[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

pull() {
  local name="$1" remote="$2" local="$3"
  printf '>>> %s  (%s:%s/vendor)\n' "$name" "$PROD_HOST" "$remote"
  if [ "${FORCE:-0}" != "1" ] && [ -d "${local}/vendor" ]; then
    printf '    skip: vendor/ already present locally (FORCE=1 to overwrite)\n'; return
  fi
  if ! $SSH "$PROD_HOST" "test -d '$remote/vendor'" 2>/dev/null; then
    printf '    SKIP: no %s/vendor on prod (or SSH failed)\n' "$remote"; return
  fi
  mkdir -p "$local"
  if $SSH "$PROD_HOST" "tar -C '$remote' -czf - vendor" | tar -xzf - -C "$local"; then
    printf '    OK\n'
  else
    printf '    FAIL extracting %s\n' "$name"
  fi
}

for d in "$LOCAL_ROOT"/*/; do
  name="$(basename "$d")"
  [ -d "${d}.git" ] || continue
  selected "$name" || continue
  pull "$name" "$PROD_ROOT/$name" "${d%/}"
done

echo "done."
