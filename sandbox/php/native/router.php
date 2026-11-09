<?php
// Plain PHP (no framework): front controller for `php -S`.
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/_shared/handlers.php';

$lis = new BridgeLisTamaConnection\Client();   // config from env
sbx_register($lis);

$method = $_SERVER['REQUEST_METHOD'];
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($method === 'POST' && $path === '/lis/webhook') {
    $lis->serveWebhook();                       // README: PHP native / CodeIgniter 3
    return;
}
$res = sbx_route($lis, $method, $path, json_decode(file_get_contents('php://input'), true));
http_response_code($res ? $res[0] : 404);
header('Content-Type: application/json');
echo json_encode($res ? $res[1] : ['error' => 'ROUTE']);
