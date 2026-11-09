#!/bin/bash
# Docker sandbox for bridgeLIS-Tama-Connection against a REAL LIS on the host.
#   ./sandbox/run.sh                      -> full matrix
#   ./sandbox/run.sh js:express4:22 php:slim:8.3   -> selected targets (kind:app:runtime-version)
# Env: LIS_HOST_URL (default http://host.docker.internal:8322), LIS_KEY (default qwerty)
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd -W 2>/dev/null || pwd)"
NET=sbx-net
WH_SECRET=whsec-sbx
LIS_URL=${LIS_HOST_URL:-http://host.docker.internal:8322}
LIS_KEY=${LIS_KEY:-qwerty}

DEFAULT="js:http-cjs:18 js:http-esm:22 js:ts-esm:22 js:ts-cjs:22 js:express4:22 js:express5:24 js:fastify:22 js:koa:22 js:hono:22 js:nest:22
php:native:7.4 php:native:8.4 php:slim:8.3 php:symfony:8.3 php:laravel:8.3"
TARGETS=${*:-$DEFAULT}
MODE=${MODE:-real}   # real = LIS on host, mock = repo mock LIS in a container (full lifecycle)

docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
RESULTS=()
if [ "$MODE" = mock ]; then
  docker rm -f sbx-mock >/dev/null 2>&1
  docker run -d --name sbx-mock --network $NET -v "$ROOT:/repo:ro" node:22-slim node /repo/tests/contract/mock/server.mjs >/dev/null
  LIS_URL=http://sbx-mock:8322; POLICY=reject
else POLICY=reject; fi

for t in $TARGETS; do
  IFS=: read -r kind app ver <<<"$t"
  name="sbx-$kind-$app-v${ver//./-}"
  echo "=============== $t"
  docker rm -f "$name" >/dev/null 2>&1
  if [ "$kind" = js ]; then
    image="node:$ver-slim"; cmd="sh /sandbox/js/_shared/start.sh $app"
    cache="-v sbx-npm-cache:/root/.npm"
  elif [ "$kind" = bun ]; then
    image="oven/bun:$ver"; cmd="sh /sandbox/js/_shared/start-alt.sh bun $app"; cache=""
  elif [ "$kind" = deno ]; then
    image="denoland/deno:$ver"; cmd="sh /sandbox/js/_shared/start-alt.sh deno $app"; cache=""
  else
    image="sbx-php:$ver"; cmd="sh /sandbox/php/_shared/start.sh $app"
    cache="-v sbx-composer-cache:/root/.composer/cache"
    docker image inspect "$image" >/dev/null 2>&1 || docker build -q -t "$image" --build-arg PHPV="$ver" -f sandbox/php/Dockerfile sandbox/php >/dev/null || { RESULTS+=("BUILD-FAIL $t"); continue; }
  fi
  docker run -d --name "$name" --network $NET $cache \
    -v "$ROOT:/repo:ro" -v "$ROOT/sandbox:/sandbox:ro" \
    -e LIS_BASE_URL="$LIS_URL" -e LIS_API_KEY="$LIS_KEY" -e LIS_WEBHOOK_SECRET=$WH_SECRET \
    -e LIS_UNKNOWN_TEST_POLICY=$POLICY -e LIS_STORAGE_DIR=/tmp/lis-store -e LIS_LOG_LEVEL=warn \
    "$image" $cmd >/dev/null || { echo "  FAIL  container did not start"; RESULTS+=("FAIL $t"); continue; }
  docker run --rm --network $NET -v "$ROOT/sandbox/driver:/d:ro" -e LIS_WEBHOOK_SECRET=$WH_SECRET -e MODE=$MODE -e TEST_CODE=${TEST_CODE:-HGB} \
    node:22-slim node /d/driver.mjs "http://$name:3000" "$app-$kind$ver"
  rc=$?
  if [ $rc -ne 0 ]; then echo "---- app log ($name)"; docker logs --tail 40 "$name" 2>&1; fi
  [ $rc -eq 0 ] && RESULTS+=("OK   $t") || RESULTS+=("FAIL $t")
  docker rm -f "$name" >/dev/null 2>&1
done

docker rm -f sbx-mock >/dev/null 2>&1
echo; echo "=============== SUMMARY ($MODE)"; printf '%s\n' "${RESULTS[@]}"
