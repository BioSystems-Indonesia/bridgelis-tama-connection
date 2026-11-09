# sourced by start.sh. Builds a real Laravel app, then wires the library the way README shows.
composer create-project laravel/laravel /work/proj --prefer-dist --no-interaction --no-progress -q
PROJ=/work/proj; SERVE=public/index.php; DOCROOT=/work/proj/public
cp -r /work/_shared "$PROJ/_shared"
cp /work/lis.php "$PROJ/config/lis.php"
cp /work/api.php "$PROJ/routes/api.php"
# enable routes/api.php (no CSRF, no session) without the /api prefix
sed -i "s#web: __DIR__.'/../routes/web.php',#web: __DIR__.'/../routes/web.php', api: __DIR__.'/../routes/api.php', apiPrefix: '',#" "$PROJ/bootstrap/app.php"
grep -q "apiPrefix" "$PROJ/bootstrap/app.php" || { echo "[sandbox] bootstrap/app.php patch FAILED"; cat "$PROJ/bootstrap/app.php"; exit 1; }
php -r 'echo "[sandbox] laravel scaffold ready".PHP_EOL;'
