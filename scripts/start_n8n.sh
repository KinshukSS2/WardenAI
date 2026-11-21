#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# WardenAI — Start standalone n8n on Linux (counterpart of start_n8n.ps1)
#
# Runs n8n as a single container on the WardenAI network, imports the five
# workflows from n8n/workflows, and optionally publishes (activates) them.
#
# Usage:
#   bash scripts/start_n8n.sh              # start + import, workflows stay inactive
#   bash scripts/start_n8n.sh --activate   # also publish all five workflows
#
# Activating makes the workflows act on real services (Slack posts, OpenAI
# calls) with the keys in .env, which is why it is opt-in.
#
# Data lives in $N8N_DATA_DIR (default ~/.wardenai-n8n).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${N8N_DATA_DIR:-$HOME/.wardenai-n8n}"
NETWORK="wardenai_wardenai-net"
ACTIVATE=false
[ "${1:-}" = "--activate" ] && ACTIVATE=true

WORKFLOW_IDS=(
  wf01-critical-alert-soar
  wf02-daily-soc-report
  wf03-cve-intel-pipeline
  wf04-sla-watchdog
  wf05-weekly-board-report
)

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "[n8n] Network $NETWORK not found. Start the core stack first: docker compose up -d" >&2
  exit 1
fi

# Pass only the variables n8n needs from .env (not every secret in the file).
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^(OPENAI_API_KEY|SLACK_BOT_TOKEN|SLACK_CHANNEL_ID)=' "$ROOT/.env")
  set +a
fi

if docker ps -a --format '{{.Names}}' | grep -qx N8N; then
  echo "[n8n] Container N8N already exists, starting it"
  docker start N8N >/dev/null
else
  echo "[n8n] Creating container N8N (data: $DATA_DIR)"
  mkdir -p "$DATA_DIR"
  docker run -d --name N8N \
    --restart unless-stopped \
    --network "$NETWORK" \
    --add-host host.docker.internal:host-gateway \
    -p 5678:5678 \
    -v "$DATA_DIR:/home/node/.n8n" \
    -e OPENAI_API_KEY -e SLACK_BOT_TOKEN -e SLACK_CHANNEL_ID \
    -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
    -e TZ="${TZ:-Asia/Kolkata}" -e GENERIC_TIMEZONE="${TZ:-Asia/Kolkata}" \
    n8nio/n8n:latest >/dev/null
fi

echo -n "[n8n] Waiting for n8n to become ready"
for _ in $(seq 1 60); do
  if docker logs N8N 2>&1 | grep -q "Editor is now accessible"; then echo " ok"; break; fi
  echo -n "."; sleep 2
done

# Import any workflow that isn't there yet. Tags are stripped on the way in:
# the JSON tags have no ids, so n8n's CLI tries to create the shared "wardenai"
# tag once per file and the whole import fails on the duplicate name.
existing="$(docker exec -u node N8N n8n list:workflow 2>/dev/null | cut -d'|' -f1)"
missing=()
for id in "${WORKFLOW_IDS[@]}"; do
  grep -qx "$id" <<<"$existing" || missing+=("$id")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "[n8n] Importing ${#missing[@]} workflow(s)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  python3 -I - "$ROOT/n8n/workflows" "$tmp" "${missing[@]}" <<'PY'
import json, glob, os, sys
src, out, wanted = sys.argv[1], sys.argv[2], set(sys.argv[3:])
for path in sorted(glob.glob(os.path.join(src, "*.json"))):
    with open(path, encoding="utf-8") as f:
        wf = json.load(f)
    if wf.get("id") in wanted:
        wf["tags"] = []
        with open(os.path.join(out, os.path.basename(path)), "w", encoding="utf-8") as f:
            json.dump(wf, f)
PY
  docker exec N8N rm -rf /tmp/wf_import
  docker cp "$tmp/." N8N:/tmp/wf_import >/dev/null
  docker exec -u node N8N n8n import:workflow --separate --input=/tmp/wf_import 2>&1 | grep -v "license SDK"
else
  echo "[n8n] All workflows already imported"
fi

if $ACTIVATE; then
  echo "[n8n] Publishing workflows"
  for id in "${WORKFLOW_IDS[@]}"; do
    docker exec -u node N8N n8n publish:workflow --id="$id" 2>&1 | grep -v "license SDK" || true
  done
  docker restart N8N >/dev/null
  echo "[n8n] Restarted to load published workflows"
else
  echo "[n8n] Workflows are imported but inactive. Re-run with --activate to publish them."
fi

echo "[n8n] Ready at http://localhost:5678"
