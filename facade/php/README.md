# tama-connection/bridgelis-tama-connection

Client library connecting SIMRS to LIS Tama through the HIS V2 API. PHP >= 7.4, with `ext-json`.

## Install

```bash
composer require tama-connection/bridgelis-tama-connection
```

Without Composer: `require '/path/to/tama-connection/autoload.php';`

## Configuration

Read from environment variables (`getenv`, `$_ENV`, `$_SERVER`). The library does not read `.env` files by itself; use your framework's `.env` or the system environment.

| Env | Required | Meaning |
|---|---|---|
| `LIS_BASE_URL` | yes | LIS address, e.g. `http://192.168.1.10:8322` |
| `LIS_API_KEY` | recommended | Same as **SimrsApiKey** in LIS settings |
| `LIS_WEBHOOK_SECRET` | recommended | Same as the webhook auth value in LIS |
| `LIS_WEBHOOK_SECRET_HEADER` | no | Default `X-API-Key` (or `Authorization` for bearer) |
| `LIS_STORAGE_DIR` | no | Cache folder. Keep it outside the public web folder |
| `LIS_TIMEOUT_MS` / `LIS_CONNECT_TIMEOUT_MS` | no | Default 8000 / 3000 |
| `LIS_UNKNOWN_TEST_POLICY` | no | `reject` (default), `warn`, `off` |
| `LIS_LOG_LEVEL` | no | Default `info` |

Or pass them directly: `new Client(['baseUrl' => ..., 'apiKey' => ...])`. Use this when your framework caches config (for example Laravel `config:cache`).

## Quick start

```php
use BridgeLisTamaConnection\Client;
use BridgeLisTamaConnection\LisException;

$lis = new Client();

var_dump($lis->health()); // check config and connection

try {
    $receipt = $lis->createOrder([
        'patient' => [
            'medical_record_number' => 'RM-001234',
            'first_name'            => 'Budi',
            'date_of_birth'         => '1990-01-31',
            'sex'                   => 'L',
        ],
        'lis_order' => ['order_id' => 'ORD-001', 'tests' => [['code' => 'HB']]],
    ]);
    echo $receipt['status']; // 'SENT' or 'UNCHANGED'
} catch (LisException $e) {
    echo $e->getErrorCode(), ' ', $e->isRetryable() ? 'retry later' : 'fix data', ': ', $e->getMessage();
}
```

Field names are `snake_case`, same as the HIS V2 API.

## Receive results (webhook)

Results arrive only through the webhook, and only after they are approved in LIS.

```php
// Plain PHP / CodeIgniter 3
$lis->onResult(function (array $event) { /* upsert per (order_id, test_code) */ });
$lis->serveWebhook();

// Laravel, Symfony, PSR-7, CodeIgniter 4: pass the request object, send the reply yourself
$lis->onResult(fn (array $event) => LabResult::upsertFromLis($event));
$r = $lis->handleWebhook($request);
return response($r['body'], $r['status'], $r['headers']);
```

`handleWebhook()` also accepts a raw body plus headers: `handleWebhook($body, $headers)`.

## Methods

| Method | Purpose |
|---|---|
| `createOrder($order)` | Send or replace an order |
| `deleteOrder($orderId)` | **Permanently** delete an order |
| `updateNotes($orderId, $notes)` | Change order notes |
| `getOrder($orderId)` / `listOrders($filter)` | Read orders |
| `getResult($orderId)` | Get result, `state => 'PENDING'` if not ready |
| `getResultPdf($orderId)` | Result as PDF (binary string) |
| `getTestTypes()` / `getPackages()` / `getPackage($code)` | LIS catalog |
| `getUsers()` | Doctors and analysts |
| `onResult($handler)` / `handleWebhook($request)` / `serveWebhook()` | Receive results |
| `reconcile(options)` | Recover missed results on request (see below) |
| `health()` | Check config and connection |

Hover any method in your IDE for details and examples.

## Read before integrating

1. `deleteOrder()` deletes permanently, whatever the status, even when the result is approved.
2. `createOrder()` with an existing `order_id` replaces the order. If auto-approve is off in LIS, approval is reset. Identical resubmission is skipped (`UNCHANGED`); a changed one returns warning `ORDER_RESUBMITTED`.
3. Results come by webhook, and only after approval. If your app is down, LIS marks delivery FAILED and the lab operator can press "Resend". If that is missed, call `$lis->reconcile(['since' => '2026-11-04'])` from your own cron job or admin page: it re-delivers final results of orders created since that date to your `onResult` handler. It never runs by itself, and it looks at the order *creation* date, not the approval date (LIS has no "changed since" filter), so recovering a revision means fetching every order in the window again; use `skip` and a narrow `since`. A long run can hit `max_execution_time`: lower `limit` and call again.
4. The result handler must be idempotent (upsert), because the same result can arrive more than once (webhook, Resend, `reconcile`).
5. A second `createOrder()` for the same `order_id` while the first is still sending throws `ORDER_IN_PROGRESS` (`isRetryable() === true`).
6. Several servers sharing one LIS? Pass `new Client(['storage' => $store])` where `$store` implements `BridgeLisTamaConnection\Storage` (for example a database table). The default file storage is per server. Experimental until 1.0.

## Quick start

```
vendor/bin/bridgelis-tama-connection init --framework laravel
```

Creates `client/bridgelis-tama-connection/` with `lis.php`, `webhook.php` and a README (never overwrites existing files). Keep `lis.php` outside the public web folder, fill the parts marked with a star with your database calls and paste the printed webhook route.
7. Apache may not pass the `Authorization` header to PHP. If the webhook uses bearer auth, add `CGIPassAuth On` (Apache 2.4.13+) or `SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1`.

## Errors

Every method throws `LisException` with `getErrorCode()`, `isRetryable()`, and optional `getHttpStatus()`, `getRequestId()`, `getField()`.
`isRetryable() === true` means LIS is unavailable, try later. `false` means fix the data or configuration.
After 5 consecutive failures the library stops calling LIS for 30 seconds, so your app does not hang.

## Notes

- Test codes are checked against the LIS catalog (LIS code, alias, or LOINC) before sending.
- Sex is normalized (`L`/`P` becomes `M`/`F`). Other values are rejected.
- `order_id` must not contain `/`.
- No patient data is stored on disk. Logs mask patient names and ID numbers.

