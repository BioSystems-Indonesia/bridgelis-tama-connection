#!/bin/bash
# Full matrix. MODES="real mock" (default) or e.g. MODES=mock (CI: no real LIS available).
cd "$(dirname "$0")/.." || exit 1
ALL="js:http-cjs:18 js:http-cjs:20 js:http-esm:22 js:ts-esm:22 js:ts-cjs:22 js:express4:22 js:express5:24 js:fastify:22 js:koa:22 js:hono:22 js:nest:22 js:next:22 bun:fetch:1 deno:fetch:latest php:native:7.4 php:native:8.0 php:native:8.1 php:native:8.2 php:native:8.4 php:native:8.5 php:slim:8.3 php:symfony:8.3 php:laravel:8.3 php:ci4:8.3"
mkdir -p sandbox/out
rc=0
for m in ${MODES:-real mock}; do
  MODE=$m bash sandbox/run.sh $ALL > sandbox/out/all-$m.log 2>&1
  sed -n '/SUMMARY/,$p' sandbox/out/all-$m.log
  grep -aq "^FAIL\|BUILD-FAIL" sandbox/out/all-$m.log && rc=1
done
echo ALLDONE > sandbox/out/done
exit $rc
