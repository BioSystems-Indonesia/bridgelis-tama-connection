#!/bin/sh
# Usage: start-alt.sh <bun|deno> <app-dir>. No npm in these images: the library is copied into node_modules.
set -e
RT=$1; APP=$2
mkdir -p /work && cp -r /sandbox/js/$APP/. /work/ && cp -r /sandbox/js/_shared /work/_shared
cd /work
mkdir -p node_modules && cp -r /repo/targets/js node_modules/bridgelis-tama-connection
if [ "$RT" = bun ]; then
  echo "[sandbox] bun $(bun --version)"; exec bun app.mjs
else
  echo "[sandbox] $(deno --version | head -1)"; exec deno run -A --node-modules-dir=manual app.mjs
fi
