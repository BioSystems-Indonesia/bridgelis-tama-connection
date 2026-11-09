<?php
// routes/api.php — Laravel: handleWebhook(Illuminate\Http\Request), service-container singleton.
use BridgeLisTamaConnection\Client;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

require_once base_path('_shared/handlers.php');

app()->singleton(Client::class, function () {
    $lis = new Client(config('lis'));
    sbx_register($lis);
    return $lis;
});

Route::post('/lis/webhook', function (Request $request, Client $lis) {
    $r = $lis->handleWebhook($request);
    return response($r['body'], $r['status'], $r['headers']);
});

Route::any('/{path}', function (Request $request, Client $lis, string $path) {
    $res = sbx_route($lis, $request->method(), '/' . $path, json_decode($request->getContent(), true))
        ?? [404, ['error' => 'ROUTE']];
    return response()->json($res[1], $res[0]);
})->where('path', '.*');
