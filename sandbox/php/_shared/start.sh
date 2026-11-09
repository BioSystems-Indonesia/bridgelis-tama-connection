#!/bin/sh
# Usage: start.sh <app-dir>. Runs in sbx-php:<ver>; /repo and /sandbox are read-only mounts.
set -e
APP=$1
mkdir -p /work && cp -r /sandbox/php/$APP/. /work/ && cp -r /sandbox/php/_shared /work/_shared
cd /work
PROJ=/work; SERVE="router.php"; DOCROOT=/work
[ -f setup.sh ] && . ./setup.sh          # may change PROJ / SERVE / DOCROOT
cd "$PROJ"
composer config repositories.lib '{"type":"path","url":"/repo/targets/php","options":{"symlink":false}}'
composer require tama-connection/bridgelis-tama-connection:@dev --no-interaction --no-progress -q
php -r 'require "vendor/autoload.php"; echo "[sandbox] php ".PHP_VERSION.", library class: ".(class_exists("BridgeLisTamaConnection\\Client")?"loaded":"MISSING").PHP_EOL;'
export PHP_CLI_SERVER_WORKERS=4
exec php -S 0.0.0.0:3000 -t "$DOCROOT" "$SERVE"
