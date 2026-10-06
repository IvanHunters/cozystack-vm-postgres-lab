#!/usr/bin/env bash
# End-to-end check: Postgres Ready, VM Running, and the in-VM app can write to
# and read from the managed Postgres. Run from your machine (needs virtctl).
#
# Usage:
#   NS=tenant-yourname SSH_KEY=~/.ssh/id_ed25519 ./check.sh
set -euo pipefail

: "${NS:?set NS to your tenant namespace, e.g. NS=tenant-yourname}"
PG="${PG:-demo}"
VMI="${VMI:-vm-instance-app}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

pgready="$(kubectl get postgres.apps.cozystack.io "$PG" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
echo "Postgres/$PG Ready: ${pgready:-unknown}"

vphase="$(kubectl get vmi "$VMI" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
echo "VMI/$VMI phase:   ${vphase:-unknown}"

echo "--- app health, write, read (inside the VM) ---"
virtctl ssh "ubuntu@vmi/$VMI" -n "$NS" --identity-file="$SSH_KEY" \
  -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" \
  -c 'set -e
      echo -n "health: "; curl -s localhost:8080/health; echo
      echo -n "insert: "; curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"name\":\"check-$(date +%s)\"}" localhost:8080/items; echo
      echo    "items :"; curl -s localhost:8080/items; echo'
