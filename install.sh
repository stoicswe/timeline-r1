#!/bin/sh
# =============================================================================
# timeline-r1 — one-command installer for the OS3-side setup (Linux / macOS)
#
# What it does, in order:
#   1. checks prerequisites (Python 3, cloudflared) and offers to fetch
#      cloudflared into a private folder — no sudo needed;
#   2. copies the endpoint, supervisor and generator spec into an install dir;
#   3. starts the read-only timeline endpoint with a fresh pairing token;
#   4. starts a Cloudflare quick tunnel to it;
#   5. waits out the tunnel-routability delay the pilot found (~60 s) and
#      verifies the endpoint is actually reachable through the tunnel;
#   6. installs the supervisor on cron (every 5 min + @reboot);
#   7. prints the endpoint URL and token to paste into the r1 creation, and the
#      one thing only you can do on the OS3 side (create the daily generator).
#
# It is reviewable and non-destructive: it prints its plan and asks before
# changing anything, and it will not touch an existing install without --force.
#
# Usage: ./install.sh [options]      (see --help)
# =============================================================================
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_SERVER="$SCRIPT_DIR/server"

INSTALL_DIR=${TIMELINE_INSTALL_DIR:-"$HOME/.timeline-r1"}
PORT=${TIMELINE_PORT:-8791}
HOST=${TIMELINE_HOST:-127.0.0.1}
TOKEN=${TIMELINE_TOKEN:-}
POINTER=0
DO_SUPERVISOR=1
DO_TUNNEL=1
ASSUME_YES=0
DRY_RUN=0
FORCE=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
timeline-r1 installer (Linux / macOS)

Stands up the read-only timeline endpoint and a Cloudflare quick tunnel to it,
waits out the tunnel-routability delay, verifies the endpoint is reachable,
generates a pairing token, installs the supervisor, and prints the endpoint URL
and token to paste into the Timeline creation on your r1.

Usage: ./install.sh [options]

Options:
  --dir DIR        install directory             (default: ~/.timeline-r1)
  --port N         endpoint port                 (default: 8791)
  --host IP        endpoint bind address         (default: 127.0.0.1)
  --token TOKEN    use this pairing token        (default: generated)
  --pointer        also publish a pointer gist   (needs gh; default: off)
  --no-supervisor  do not install the cron supervisor
  --no-tunnel      do not start a tunnel (endpoint only; not reachable from r1)
  --force          overwrite an existing install
  --yes, -y        do not ask for confirmation
  --dry-run        print the plan and exit without changing anything
  -h, --help       show this help
EOF
}

# --- arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)           INSTALL_DIR=$2; shift 2 ;;
    --port)          PORT=$2; shift 2 ;;
    --host)          HOST=$2; shift 2 ;;
    --token)         TOKEN=$2; shift 2 ;;
    --pointer)       POINTER=1; shift ;;
    --no-supervisor) DO_SUPERVISOR=0; shift ;;
    --no-tunnel)     DO_TUNNEL=0; shift ;;
    --force)         FORCE=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "unknown option: $1" ;;
  esac
done

# --- platform ----------------------------------------------------------------
OS=$(uname -s)
case "$OS" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=darwin ;;
  *)      die "unsupported OS '$OS' — on Windows run install.ps1 instead" ;;
esac
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   ARCH=x86_64 ;;
  arm64|aarch64)  ARCH=arm64 ;;
  *)              die "unsupported CPU '$ARCH'" ;;
esac

[ -f "$SRC_SERVER/timeline-server.py" ] || \
  die "server/ not found next to this script — run it from a clone of the repo"

# --- prerequisites -----------------------------------------------------------
PYTHON=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && \
     "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    PYTHON=$(command -v "$c"); break
  fi
done

CFD_BIN=""
if command -v cloudflared >/dev/null 2>&1; then
  CFD_BIN=$(command -v cloudflared)
elif [ -x "$INSTALL_DIR/bin/cloudflared" ]; then
  CFD_BIN="$INSTALL_DIR/bin/cloudflared"
fi

NEED_CFD=0
[ -z "$CFD_BIN" ] && NEED_CFD=1

EXISTING=0
[ -f "$INSTALL_DIR/server/config.env" ] && EXISTING=1

# --- plan --------------------------------------------------------------------
step "Plan"
say "  platform        : $PLATFORM / $ARCH"
say "  install dir     : $INSTALL_DIR"
say "  endpoint        : http://$HOST:$PORT  (loopback; not directly reachable from the r1)"
say "  tunnel          : $([ "$DO_TUNNEL" -eq 1 ] && echo 'Cloudflare quick tunnel (no account needed)' || echo 'skipped (--no-tunnel)')"
say "  pairing token   : $([ -n "$TOKEN" ] && echo 'provided' || echo 'will be generated (32 random bytes)')"
say "  supervisor      : $([ "$DO_SUPERVISOR" -eq 1 ] && echo 'cron: every 5 min + @reboot (no sudo)' || echo 'skipped (--no-supervisor)')"
say "  pointer gist    : $([ "$POINTER" -eq 1 ] && echo 'will be published (needs gh)' || echo 'not published (pairing UI does not need one)')"
if [ -n "$PYTHON" ]; then
  say "  python          : $PYTHON"
else
  say "  python          : NOT FOUND — install Python 3.8+ first (below)"
fi
if [ "$NEED_CFD" -eq 1 ]; then
  say "  cloudflared     : not found — will download to $INSTALL_DIR/bin/cloudflared"
else
  say "  cloudflared     : $CFD_BIN"
fi
if [ "$EXISTING" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
  warn "an install already exists at $INSTALL_DIR (config.env present)."
  warn "re-run with --force to overwrite it, or --dir to install elsewhere."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  step "Dry run — nothing was changed."
  exit 0
fi

if [ -z "$PYTHON" ]; then
  step "Python is required"
  say "  Install Python 3.8 or newer, then re-run this installer:"
  case "$PLATFORM" in
    linux)  say "    Debian/Ubuntu : sudo apt install python3   (needs sudo)" ;;
    darwin) say "    macOS         : brew install python3   (or https://www.python.org/downloads/)" ;;
  esac
  exit 1
fi

if [ "$EXISTING" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
  die "refusing to overwrite the existing install at $INSTALL_DIR (use --force)"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nProceed with the setup above? [y/N] '
  read -r ans || ans=
  case "$ans" in
    y|Y|yes|YES) ;;
    *) say "aborted — nothing was changed."; exit 0 ;;
  esac
fi

# --- install files -----------------------------------------------------------
step "Installing files into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/server" "$INSTALL_DIR/data" "$INSTALL_DIR/bin" "$INSTALL_DIR/server/.state"
cp "$SRC_SERVER/timeline-server.py" "$INSTALL_DIR/server/timeline-server.py"
cp "$SRC_SERVER/supervise.sh"       "$INSTALL_DIR/server/supervise.sh"
cp "$SRC_SERVER/generate-timeline.md" "$INSTALL_DIR/server/generate-timeline.md"
[ -f "$SRC_SERVER/supervise.ps1" ] && cp "$SRC_SERVER/supervise.ps1" "$INSTALL_DIR/server/supervise.ps1"
chmod +x "$INSTALL_DIR/server/supervise.sh"

# --- token -------------------------------------------------------------------
if [ -z "$TOKEN" ]; then
  TOKEN=$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')
fi

# --- empty feed (so the endpoint answers instead of 503 until the generator runs)
if [ ! -f "$INSTALL_DIR/data/timeline.json" ]; then
  "$PYTHON" - "$INSTALL_DIR/data/timeline.json" <<'PY'
import json, sys, datetime
p = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(p, "w", encoding="utf-8") as fh:
    json.dump({"version": 1, "timezone": "UTC", "generatedAt": now, "cards": []}, fh, indent=2)
PY
fi

# --- cloudflared -------------------------------------------------------------
if [ "$NEED_CFD" -eq 1 ]; then
  step "Downloading cloudflared (no sudo; into $INSTALL_DIR/bin)"
  REL=https://github.com/cloudflare/cloudflared/releases/latest/download
  case "$PLATFORM-$ARCH" in
    linux-x86_64)  curl -fL "$REL/cloudflared-linux-amd64"  -o "$INSTALL_DIR/bin/cloudflared" ;;
    linux-arm64)   curl -fL "$REL/cloudflared-linux-arm64"  -o "$INSTALL_DIR/bin/cloudflared" ;;
    darwin-x86_64) curl -fL "$REL/cloudflared-darwin-amd64.tgz" -o "$INSTALL_DIR/bin/cfd.tgz" ;;
    darwin-arm64)  curl -fL "$REL/cloudflared-darwin-arm64.tgz" -o "$INSTALL_DIR/bin/cfd.tgz" ;;
  esac
  if [ "$PLATFORM" = darwin ]; then
    tar -xzf "$INSTALL_DIR/bin/cfd.tgz" -C "$INSTALL_DIR/bin"
    rm -f "$INSTALL_DIR/bin/cfd.tgz"
  fi
  chmod +x "$INSTALL_DIR/bin/cloudflared"
  CFD_BIN="$INSTALL_DIR/bin/cloudflared"
  "$CFD_BIN" --version >/dev/null 2>&1 || die "cloudflared did not run after download"
fi

# --- start endpoint ----------------------------------------------------------
step "Starting the endpoint on http://$HOST:$PORT"
TIMELINE_PORT="$PORT" TIMELINE_HOST="$HOST" TIMELINE_TOKEN="$TOKEN" \
TIMELINE_ACCESS_LOG="$INSTALL_DIR/server/.state/access.jsonl" \
  nohup "$PYTHON" "$INSTALL_DIR/server/timeline-server.py" \
  >"$INSTALL_DIR/server/endpoint.log" 2>&1 &
echo $! >"$INSTALL_DIR/server/.state/endpoint.pid"

i=0
while [ "$i" -lt 15 ]; do
  curl -fsS -m 3 -H "Authorization: Bearer $TOKEN" "http://$HOST:$PORT/health" >/dev/null 2>&1 && break
  sleep 1; i=$((i+1))
done
curl -fsS -m 3 -H "Authorization: Bearer $TOKEN" "http://$HOST:$PORT/health" >/dev/null 2>&1 || \
  die "endpoint did not come up — see $INSTALL_DIR/server/endpoint.log"
say "  endpoint is up locally."

# --- start tunnel + verify ---------------------------------------------------
URL=""
if [ "$DO_TUNNEL" -eq 1 ]; then
  step "Starting the Cloudflare quick tunnel"
  : >"$INSTALL_DIR/server/.state/tunnel.log"
  nohup "$CFD_BIN" tunnel --url "http://$HOST:$PORT" --no-autoupdate \
    >"$INSTALL_DIR/server/.state/tunnel.log" 2>&1 &
  echo $! >"$INSTALL_DIR/server/.state/tunnel.pid"

  i=0
  while [ "$i" -lt 60 ]; do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
      "$INSTALL_DIR/server/.state/tunnel.log" 2>/dev/null | tail -1 || true)
    [ -n "$URL" ] && break
    sleep 1; i=$((i+1))
  done
  [ -n "$URL" ] || die "no tunnel hostname appeared — see $INSTALL_DIR/server/.state/tunnel.log"
  say "  tunnel hostname: $URL"
  say "  waiting for it to become routable (the pilot found ~60 s)…"

  i=0; OK=0
  while [ "$i" -lt 60 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
      -H "Authorization: Bearer $TOKEN" "$URL/health" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then OK=1; break; fi
    sleep 2; i=$((i+1))
  done
  [ "$OK" -eq 1 ] || die "the endpoint was not reachable through the tunnel within ~2 min"
  say "  verified: $URL/health returned 200 with the token."

  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$URL/health" 2>/dev/null || echo 000)
  if [ "$code" = "401" ]; then
    say "  verified: without the token the endpoint returns 401 (token is required)."
  else
    warn "without the token the endpoint returned $code, not 401 — check the token config."
  fi
fi

# --- pointer (optional) ------------------------------------------------------
POINTER_GIST=""
if [ "$POINTER" -eq 1 ] && [ -n "$URL" ]; then
  step "Publishing a pointer gist"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    tmp=$(mktemp)
    printf '{"endpoint":"%s","updated":"%s"}\n' "$URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp"
    gist_url=$(gh gist create --public -f ptr.json "$tmp" 2>/dev/null || true)
    rm -f "$tmp"
    if [ -n "$gist_url" ]; then
      POINTER_GIST=$(printf '%s' "$gist_url" | sed 's#.*/##')
      say "  pointer gist: $gist_url"
      say "  raw pointer : https://gist.githubusercontent.com/<you>/$POINTER_GIST/raw/ptr.json"
      say "  (only needed if you build a pre-configured creation; the pairing UI does not use it)"
    else
      warn "gh gist create failed — skipping the pointer."
    fi
  else
    warn "gh is not installed or not signed in — skipping the pointer."
  fi
fi

# --- config for the supervisor ----------------------------------------------
cat >"$INSTALL_DIR/server/config.env" <<EOF
# Written by install.sh — read by supervise.sh. Contains the pairing token.
TIMELINE_BASE=$INSTALL_DIR
TIMELINE_PORT=$PORT
TIMELINE_HOST=$HOST
TIMELINE_CFD=$CFD_BIN
TIMELINE_PYTHON=$PYTHON
TIMELINE_TOKEN=$TOKEN
POINTER_GIST=$POINTER_GIST
EOF
chmod 600 "$INSTALL_DIR/server/config.env"

# --- supervisor --------------------------------------------------------------
if [ "$DO_SUPERVISOR" -eq 1 ]; then
  step "Installing the supervisor on cron (every 5 min + @reboot)"
  tmp=$(mktemp)
  crontab -l 2>/dev/null >"$tmp" || true
  if grep -Fq "$INSTALL_DIR/server/supervise.sh" "$tmp"; then
    say "  cron entries already present — left as they are."
  else
    printf '%s\n%s\n' \
      "*/5 * * * * $INSTALL_DIR/server/supervise.sh >/dev/null 2>&1" \
      "@reboot $INSTALL_DIR/server/supervise.sh >/dev/null 2>&1" >>"$tmp"
    crontab "$tmp"
    say "  cron entries added."
  fi
  rm -f "$tmp"
fi

# --- next steps --------------------------------------------------------------
step "Setup complete"
say ""
if [ -n "$URL" ]; then
  say "  Endpoint URL : $URL"
else
  say "  Endpoint URL : (no tunnel — local only: http://$HOST:$PORT)"
fi
say "  Pairing token: $TOKEN"
say ""
say "On your r1: open Timeline, bring up the pairing screen (first run, or the"
say "'...' in the header / hold the side button), and paste:"
say "    endpoint : ${URL:-http://$HOST:$PORT}"
say "    token    : $TOKEN"
say "Tap 'test' (it should report success and a card count), then 'save'."
say ""
say "Verify from this machine:"
say "    curl -H \"Authorization: Bearer $TOKEN\" ${URL:-http://$HOST:$PORT}/health"
say ""
say "Still to do on the OS3 side — only OS3 can read your journal, recordings and"
say "memory, so the day-cards must be produced by an OS3 scheduled task:"
say "    In OS3, create a daily scheduled task whose prompt is the contents of"
say "      $INSTALL_DIR/server/generate-timeline.md"
say "    It writes $INSTALL_DIR/data/timeline.json, which this endpoint serves."
say "    Until it runs once, the timeline is empty (health shows cardCount 0)."
say ""
say "Supervisor : $([ "$DO_SUPERVISOR" -eq 1 ] && echo "cron -> $INSTALL_DIR/server/supervise.sh" || echo 'not installed (--no-supervisor)')"
say "Logs       : $INSTALL_DIR/server/endpoint.log , $INSTALL_DIR/server/.state/tunnel.log"
say "Config     : $INSTALL_DIR/server/config.env  (contains the token; chmod 600)"
say ""
say "To remove everything later: stop the two processes, remove the two cron"
say "entries ('crontab -e'), and delete $INSTALL_DIR."