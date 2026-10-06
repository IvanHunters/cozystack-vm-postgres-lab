#!/usr/bin/env bash
# Render the VMInstance from the template and apply the VM resources.
# Requires the managed Postgres to be Ready already (the DB password is read
# from its credentials secret and injected, base64, into the VM cloud-init,
# so it never lives in git).
#
# Usage:
#   NS=tenant-yourname SSH_KEY_FILE=~/.ssh/id_ed25519.pub ./deploy.sh
set -euo pipefail

: "${NS:?set NS to your tenant namespace, e.g. NS=tenant-yourname}"
PG="${PG:-demo}"
DB_USER="${DB_USER:-appuser}"
DB_NAME="${DB_NAME:-appdb}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

cd "$(dirname "$0")"

# --validate=false skips the client-side OpenAPI schema download, which can be
# slow on large aggregated-API clusters. The server still validates on admission.
KAPPLY=(kubectl apply --validate=false -n "$NS" --filename)

DB_HOST="postgres-${PG}-rw.${NS}.svc"
PW="$(kubectl get secret -n "$NS" "postgres-${PG}-credentials" -o jsonpath="{.data.${DB_USER}}" | base64 -d)"

APP_ENV="$(printf 'PGHOST=%s\nPGPORT=5432\nPGUSER=%s\nPGPASSWORD=%s\nPGDATABASE=%s\n' \
  "$DB_HOST" "$DB_USER" "$PW" "$DB_NAME")"

APP_PY_B64="$(base64 < app/app.py | tr -d '\n')"
APP_ENV_B64="$(printf '%s' "$APP_ENV" | base64 | tr -d '\n')"
SSH_KEY="$(cat "$SSH_KEY_FILE")"

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed \
  -e "s|__APP_PY_B64__|${APP_PY_B64}|" \
  -e "s|__APP_ENV_B64__|${APP_ENV_B64}|" \
  -e "s|__SSH_KEY__|${SSH_KEY}|" \
  manifests/03-vm-instance.tpl.yaml > "$RENDERED"

"${KAPPLY[@]}" manifests/02-vm-disk.yaml
"${KAPPLY[@]}" "$RENDERED"
echo "applied: vm-disk app-disk + vm-instance app in namespace $NS"
