<?php
// Slim 4 (PSR-7): handleWebhook($request) with a PSR-7 ServerRequest.
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/_shared/handlers.php';

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;

$lis = new BridgeLisTamaConnection\Client();
sbx_register($lis);

$json = function (Response $response, array $res): Response {
    $response->getBody()->write(json_encode($res[1]));
    return $response->withStatus($res[0])->withHeader('Content-Type', 'application/json');
};

$app = AppFactory::create();

$app->post('/lis/webhook', function (Request $request, Response $response) use ($lis) {
    $r = $lis->handleWebhook($request);         // PSR-7 request object
    $response->getBody()->write($r['body']);
    $response = $response->withStatus($r['status']);
    foreach ($r['headers'] as $k => $v) { $response = $response->withHeader($k, $v); }
    return $response;
});
$app->map(['GET', 'POST', 'DELETE'], '/{path:.*}', function (Request $request, Response $response) use ($lis, $json) {
    $res = sbx_route($lis, $request->getMethod(), $request->getUri()->getPath(), json_decode((string) $request->getBody(), true))
        ?? [404, ['error' => 'ROUTE']];
    return $json($response, $res);
});
$app->run();
