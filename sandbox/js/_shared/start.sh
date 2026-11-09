#!/bin/sh
# Usage: start.sh <app-dir>. Runs in a node container; /repo and /sandbox are read-only mounts.
set -e
APP=$1
mkdir -p /work && cp -r /sandbox/js/$APP/. /work/ && cp -r /sandbox/js/_shared /work/_shared
cd /work
npm pack /repo/targets/js --pack-destination /tmp --silent >/dev/null
TGZ=$(ls /tmp/bridgelis-tama-connection-*.tgz)
npm install --no-audit --no-fund --loglevel=error
npm install --no-audit --no-fund --loglevel=error --no-save "$TGZ"
if [ -f tsconfig.json ]; then npx tsc -p . && echo "[sandbox] tsc OK"; fi
ENTRY=$(cat entry 2>/dev/null || echo app.cjs)
echo "[sandbox] node $(node -v), starting $APP ($ENTRY)"
exec node "$ENTRY"
