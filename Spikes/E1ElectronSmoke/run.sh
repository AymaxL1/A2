#!/usr/bin/env bash
# E1 Electron smoke spike — repro script.
#
# Prereqs (see README.md for the from-scratch walkthrough):
#   - User-mode Node.js unpacked somewhere (no sudo, no Homebrew).
#     e.g. https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.gz
#   - Proxy reachable at http://127.0.0.1:33888 (or set HTTPS_PROXY yourself).
#
# Usage:
#   NODE_HOME=/path/to/node-vX-darwin-arm64 ./run.sh
# If NODE_HOME is unset, falls back to `node`/`npm` already on PATH.
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "${NODE_HOME:-}" ]; then
  export PATH="$NODE_HOME/bin:$PATH"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: no node on PATH and NODE_HOME not set. See README.md step 1." >&2
  exit 1
fi

echo "== node: $(node -v) =="
echo "== npm:  $(npm -v) =="
export NODE_BIN="$(command -v node)"

# Proxy defaults (harmless if already exported by the shell).
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:33888}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:33888}"

if [ ! -d node_modules/electron ]; then
  echo "== npm install electron (this also downloads the Electron binary) =="
  T0=$(date +%s)
  npm install electron --no-audit --no-fund
  T1=$(date +%s)
  echo "npm install elapsed: $((T1-T0))s"
fi

ELECTRON_BIN="./node_modules/.bin/electron"
if [ ! -x "$ELECTRON_BIN" ]; then
  echo "ERROR: $ELECTRON_BIN missing after npm install." >&2
  exit 1
fi

echo "== electron version: $("$ELECTRON_BIN" --version 2>/dev/null || echo unknown) =="

echo "== launching app (auto-quits within 8s) =="
"$ELECTRON_BIN" . > run.log 2>&1 &
APP_PID=$!

# Give it a couple seconds to spin up windows + UDS server before sampling RSS.
sleep 2.5
echo "== RSS sample (pid,rss_kb,comm) =="
ps -axo pid,rss,comm | grep -i electron | grep -v grep | tee rss-sample.txt || echo "(no electron processes found — see run.log)"

# Wait for the app to exit on its own (hard cap inside main.js is 8s from
# app-ready; give it a bit of slack here).
WAIT_S=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAIT_S" -lt 15 ]; do
  sleep 1
  WAIT_S=$((WAIT_S+1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
  echo "WARNING: app still alive after ${WAIT_S}s wait, killing pid $APP_PID" >&2
  kill "$APP_PID" 2>/dev/null || true
fi

wait "$APP_PID" 2>/dev/null || true
echo "== app exited =="
echo "== run.log =="
cat run.log
