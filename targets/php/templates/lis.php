<?php

declare(strict_types=1);

/**
 * Your integration with LIS Tama. This file belongs to your project: edit it freely.
 * Created by `vendor/bin/bridgelis-tama-connection init`; the library itself stays in vendor/.
 *
 * Keep this file OUTSIDE the public web folder. Only webhook.php (3 lines) needs a URL.
 *
 * Set these environment variables (see README.md next to this file):
 *   LIS_BASE_URL        address of the LIS server, for example http://192.168.1.10:8322
 *   LIS_API_KEY         same as SimrsApiKey in the LIS settings
 *   LIS_WEBHOOK_SECRET  same as the webhook auth in LIS (leave empty to accept any caller)
 *
 * Parts marked with a star need your database.
 */

use BridgeLisTamaConnection\Client;

if (!class_exists(Client::class)) {
    require_once __DIR__ . '/{{AUTOLOAD}}';
}

/** The shared client. It also registers the result handler once per request. */
function lis(): Client
{
    static $client = null;
    if ($client === null) {
        $client = new Client();
        $client->onResult('lisSaveResult');
    }
    return $client;
}

/**
 * ★ 1. DATABASE. This demo keeps results in a JSON file in the system temp folder so the
 * template works out of the box. Replace lisSaveResult() and lisHasFinalResult() with real
 * database calls.
 */
function lisDemoStorePath(): string
{
    return sys_get_temp_dir() . '/bridgelis-demo-results.json';
}

/** @return array<string, array<string, mixed>> */
function lisDemoResults(): array
{
    $path = lisDemoStorePath();
    $rows = is_file($path) ? json_decode((string) file_get_contents($path), true) : [];
    return is_array($rows) ? $rows : [];
}

/**
 * Saves one lab result event. LIS can send the same result more than once (Resend, a revised
 * and approved-again result, reconcile), so ALWAYS upsert, never plain insert.
 * If this function throws, LIS records the delivery as FAILED and the lab can press Resend.
 *
 * $event = ['order_id', 'is_final', 'received_at', 'patient', 'order' => ['results' => [...]]]
 *
 * @param array<string, mixed> $event
 */
function lisSaveResult(array $event): void
{
    $rows = lisDemoResults();
    foreach ($event['order']['results'] ?? [] as $row) {
        // ★ Example SQL: INSERT ... ON DUPLICATE KEY UPDATE (order_id, test_code are the key).
        $rows[$event['order_id'] . ':' . $row['test_code']] = [
            'order_id' => $event['order_id'],
            'test_code' => $row['test_code'],
            'result' => $row['result'] ?? null,
            'unit' => $row['unit'] ?? null,
            'status' => $row['status'] ?? null,
        ];
    }
    file_put_contents(lisDemoStorePath(), json_encode($rows), LOCK_EX);
}

/** ★ True when your database already holds the final result of this order (used by reconcile). */
function lisHasFinalResult(string $orderId): bool
{
    foreach (lisDemoResults() as $row) {
        if ($row['order_id'] === $orderId && $row['status'] === 'Final') {
            return true;
        }
    }
    return false;
}

/**
 * 2. SEND AN ORDER. Call it when the doctor orders lab tests. $order has 'patient' and
 * 'lis_order' (see README.md). Sending the same order twice is safe: identical orders are
 * skipped ('UNCHANGED'). It throws LisException; isRetryable() tells if trying again later can
 * help (LIS down) or the data must be fixed first.
 *
 * @param array<string, mixed> $order
 * @return array<string, mixed>
 */
function lisSendOrder(array $order): array
{
    return lis()->createOrder($order);
}

/**
 * 3. WEBHOOK. In a framework, pass its request object and send back the returned array:
 * see the route snippet printed by `init`. In plain PHP, webhook.php does it for you.
 *
 * @param mixed $request
 * @return array{status: int, headers: array<string, string>, body: string}
 */
function lisHandleWebhook($request = null): array
{
    return lis()->handleWebhook($request);
}

/**
 * 4. RECOVERY. Fetches results LIS finished but your system never received (webhook failed and
 * nobody pressed Resend). Run it from a cron job or an admin page, for example
 * lisRecoverMissedResults('2026-11-04'). $since is the date the ORDERS were created.
 *
 * @return array<string, mixed>
 */
function lisRecoverMissedResults(string $since): array
{
    return lis()->reconcile(['since' => $since, 'skip' => 'lisHasFinalResult']);
}
