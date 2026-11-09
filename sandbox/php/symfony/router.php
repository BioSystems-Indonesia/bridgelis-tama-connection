<?php
// Symfony HttpKernel + Routing + HttpFoundation: handleWebhook($symfonyRequest).
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/_shared/handlers.php';

use Symfony\Component\EventDispatcher\EventDispatcher;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Controller\ArgumentResolver;
use Symfony\Component\HttpKernel\Controller\ControllerResolver;
use Symfony\Component\HttpKernel\EventListener\RouterListener;
use Symfony\Component\HttpKernel\HttpKernel;
use Symfony\Component\Routing\Matcher\UrlMatcher;
use Symfony\Component\Routing\RequestContext;
use Symfony\Component\Routing\Route;
use Symfony\Component\Routing\RouteCollection;

$lis = new BridgeLisTamaConnection\Client();
sbx_register($lis);

$webhook = function (Request $request) use ($lis): Response {
    $r = $lis->handleWebhook($request);         // Symfony Request
    return new Response($r['body'], $r['status'], $r['headers']);
};
$rest = function (Request $request) use ($lis): Response {
    $res = sbx_route($lis, $request->getMethod(), $request->getPathInfo(), json_decode($request->getContent(), true))
        ?? [404, ['error' => 'ROUTE']];
    return new JsonResponse($res[1], $res[0]);
};

$routes = new RouteCollection();
$routes->add('webhook', new Route('/lis/webhook', ['_controller' => $webhook], [], [], '', [], ['POST']));
$routes->add('rest', new Route('/{path}', ['_controller' => $rest], ['path' => '.*']));

$request = Request::createFromGlobals();
$dispatcher = new EventDispatcher();
$stack = new RequestStack();
$dispatcher->addSubscriber(new RouterListener(new UrlMatcher($routes, new RequestContext()), $stack));
$kernel = new HttpKernel($dispatcher, new ControllerResolver(), $stack, new ArgumentResolver());
$response = $kernel->handle($request);
$response->send();
