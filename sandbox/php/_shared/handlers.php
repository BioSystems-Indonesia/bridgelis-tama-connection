<?php
// Shared route logic for all PHP apps (PHP 7.4 compatible). Not framework glue.
use BridgeLisTamaConnection\Client;
use BridgeLisTamaConnection\LisException;

function sbx_events_file(): string { return sys_get_temp_dir() . '/sbx-events.json'; }

function sbx_events(): array {
    $f = sbx_events_file();
    return is_file($f) ? (json_decode(file_get_contents($f), true) ?: []) : [];
}

function sbx_upsert(string $orderId, array $r): void {
    $f = sys_get_temp_dir() . '/sbx-results.json';
    $all = is_file($f) ? (json_decode(file_get_contents($f), true) ?: []) : [];
    $all[$orderId . '|' . $r['test_code']] = ['order_id' => $orderId, 'test_code' => $r['test_code'], 'result' => $r['result'] ?? null, 'flag' => $r['abnormal_flag'] ?? null];
    file_put_contents($f, json_encode($all), LOCK_EX);
}

/** Registers onResult. PHP requests do not share memory, so events go to a temp file. */
function sbx_register(Client $lis): void {
    $lis->onResult(function (array $e) {
        $all = sbx_events();
        $all[] = ['order_id' => $e['order_id'], 'is_final' => $e['is_final']];
        foreach (($e['order']['results'] ?? []) as $r) { // upsert per (order_id, test_code)
            sbx_upsert($e['order_id'], $r);
        }
        file_put_contents(sbx_events_file(), json_encode($all), LOCK_EX);
    });
}

/** @return array{0:int,1:mixed} [httpStatus, json] */
function sbx_call(callable $fn): array {
    try {
        return [200, $fn()];
    } catch (LisException $e) {
        return [$e->isRetryable() ? 503 : 422, [
            'error' => $e->getErrorCode(), 'retryable' => $e->isRetryable(),
            'httpStatus' => $e->getHttpStatus(), 'message' => $e->getMessage(),
        ]];
    } catch (\Throwable $e) {
        return [500, ['error' => 'NOT_LIS_ERROR', 'message' => get_class($e) . ': ' . $e->getMessage()]];
    }
}

/** Dispatch for the non-webhook routes. Returns null when the route is unknown. */
function sbx_route(Client $lis, string $method, string $path, ?array $body): ?array {
    if ($method === 'GET' && $path === '/health') return sbx_call(function () use ($lis) { return $lis->health(); });
    if ($method === 'GET' && $path === '/catalog') return sbx_call(function () use ($lis) { return ['count' => count($lis->getTestTypes())]; });
    if ($method === 'GET' && $path === '/events') return [200, sbx_events()];
    if ($method === 'POST' && $path === '/orders') return sbx_call(function () use ($lis, $body) { return $lis->createOrder($body ?? []); });
    if (preg_match('#^/orders/([^/]+)(/result)?$#', $path, $m)) {
        $id = rawurldecode($m[1]);
        if ($method === 'GET' && !empty($m[2])) return sbx_call(function () use ($lis, $id) { return $lis->getResult($id); });
        if ($method === 'GET') return sbx_call(function () use ($lis, $id) { return $lis->getOrder($id); });
        if ($method === 'DELETE') return sbx_call(function () use ($lis, $id) { return $lis->deleteOrder($id); });
    }
    return null;
}
