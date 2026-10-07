#!/bin/sh
# timeline supervisor — keeps the r1 timeline endpoint and its public tunnel up,
# and (optionally) republishes the current tunnel URL to the stable pointer the
# creation reads.
#
# Safe to run repeatedly (cron every 5 min, and @reboot). Idempotent:
#  - starts the endpoint only if it is not already listening
#  - starts a tunnel only if one is not already running
#  - updates the pointer gist only when the URL actually changed
#
# It never reads or writes timeline data itself; it only serves data/timeline.json.
#
# Configuration, in order of precedence:
#   1. environment variables (e.g. set in the crontab line)
#   2. server/config.env next to this script (written by install.sh)
#   3. defaults below
#
#   TIMELINE_BASE   project directory           (default: this script's parent)
#   TIMELINE_PORT   endpoint port               (default: 8791)
#   TIMELINE_HOST   endpoint bind address       (default: 127.0.0.1)
#   TIMELINE_CFD    path to the cloudflared bin (default: cloudflared on PATH)
#   POINTER_GIST    gist id the creation reads  (optional; skip pointer if unset)
#   TIMELINE_TOKEN  pairing token the endpoint requires (optional; open if unset)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${TIMELINE_BASE:-$(cd "$HERE/.." && pwd)}

# config.env (written by install.sh) fills in anything not already in the env.
if [ -f "$HERE/config.env" ]; then
  # shellcheck disable=SC1090
  . "$HERE/config.env"
fi

SERVER="$BASE/server/timeline-server.py"
STATE="$BASE/server/.state"
CFD=${TIMELINE_CFD:-cloudflared}
PORT=${TIMELINE_PORT:-8791}
HOST=${TIMELINE_HOST:-127.0.0.1}
LOG="$BASE/server/supervisor.log"
POINTER_GIST=${POINTER_GIST:-}
TOKEN=${TIMELINE_TOKEN:-}
PY=${TIMELINE_PYTHON:-python3}

mkdir -p "$STATE"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG"; }

# --- endpoint ---------------------------------------------------------------
if ! curl -fsS -m 5 -H "Authorization: Bearer $TOKEN" "http://$HOST:$PORT/health" >/dev/null 2>&1; then
  log "endpoint down; starting"
  TIMELINE_PORT="$PORT" TIMELINE_HOST="$HOST" TIMELINE_TOKEN="$TOKEN" \
    TIMELINE_ACCESS_LOG="$STATE/access.jsonl" \
    nohup "$PY" "$SERVER" </dev/null >>"$BASE/server/endpoint.log" 2>&1 &
  sleep 2
fi

# --- tunnel -----------------------------------------------------------------
if ! pgrep -f "cloudflared tunnel --url http://$HOST:$PORT" >/dev/null 2>&1; then
  log "tunnel down; starting"
  : >"$STATE/tunnel.log"
  nohup "$CFD" tunnel --url "http://$HOST:$PORT" --no-autoupdate \
    </dev/null >>"$STATE/tunnel.log" 2>&1 &
  # wait up to ~40s for the URL to appear
  i=0
  while [ "$i" -lt 40 ]; do
    grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$STATE/tunnel.log" >"$STATE/url.new" 2>/dev/null && break
    sleep 1
    i=$((i + 1))
  done
fi

URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$STATE/tunnel.log" 2>/dev/null | tail -1)
if [ -z "$URL" ]; then
  log "no tunnel URL yet; leaving pointer as is"
  exit 0
fi
echo "$URL" >"$STATE/url.current"

# --- pointer ----------------------------------------------------------------
if [ -z "$POINTER_GIST" ]; then
  exit 0
fi
OLD=$(cat "$STATE/url.published" 2>/dev/null || true)
if [ "$URL" != "$OLD" ]; then
  TMP=$(mktemp)
  printf '{"endpoint":"%s","updated":"%s"}\n' "$URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TMP"
  if gh gist edit "$POINTER_GIST" -f ptr.json "$TMP" >/dev/null 2>&1; then
    echo "$URL" >"$STATE/url.published"
    log "pointer updated -> $URL"
  else
    log "pointer update FAILED for $URL"
  fi
  rm -f "$TMP"
fi

exit 0
