# sourced by start.sh. Real CodeIgniter 4 app (appstarter), library wired as README shows.
composer create-project codeigniter4/appstarter /work/proj --prefer-dist --no-interaction --no-progress -q
PROJ=/work/proj; DOCROOT=/work/proj/public; SERVE=vendor/codeigniter4/framework/system/rewrite.php
cp -r /work/_shared "$PROJ/_shared"
cp /work/Lis.php "$PROJ/app/Controllers/Lis.php"
cat >> "$PROJ/app/Config/Routes.php" <<'ROUTES'

$routes->post('lis/webhook', 'Lis::webhook');
$routes->match(['get', 'post', 'delete'], '(:any)', 'Lis::rest/$1');
ROUTES
echo "[sandbox] codeigniter scaffold ready"
