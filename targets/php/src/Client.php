<?php

declare(strict_types=1);

namespace BridgeLisTamaConnection;

use BridgeLisTamaConnection\core\LisCore;
use BridgeLisTamaConnection\platform\Platform;
use BridgeLisTamaConnection\platform\php\PhpHttp;
use BridgeLisTamaConnection\platform\php\PhpStorage;
use BridgeLisTamaConnection\platform\php\PhpEnv;
use BridgeLisTamaConnection\platform\php\PhpClock;
use BridgeLisTamaConnection\platform\php\PhpHash;
use BridgeLisTamaConnection\platform\php\PhpLogger;

/**
 * Idiomatic PHP client for bridgeLIS Tama Connection.
 * Fully compatible with PHP >= 7.4.
 *
 * Every method throws {@see LisException}. Check `isRetryable()`: true means LIS is
 * unavailable (try again later), false means the data or the configuration must be fixed first.
 *
 * Example:
 *
 *     use BridgeLisTamaConnection\Client;
 *     use BridgeLisTamaConnection\LisException;
 *
 *     $lis = new Client();   // reads LIS_BASE_URL, LIS_API_KEY, ... from the environment
 */
class Client
{
    /** @var LisCore */
    private $core;

    /** @var callable|null */
    private $onResultCallback = null;

    /**
     * Constructs client with optional configuration overrides or custom platform.
     *
     * With no arguments, all settings come from environment variables (`LIS_BASE_URL`,
     * `LIS_API_KEY`, `LIS_WEBHOOK_SECRET`, `LIS_STORAGE_DIR`, ...). Keys in `$config` override them.
     *
     * @param array{
     *     baseUrl?: string,
     *     apiKey?: string,
     *     webhook?: array{secret?: string, secretHeader?: string},
     *     catalog?: array{unknownTestPolicy?: 'reject'|'warn'|'off', ttlSec?: int},
     *     storageDir?: string,
     *     timeoutMs?: int,
     *     connectTimeoutMs?: int,
     *     logLevel?: 'debug'|'info'|'warn'|'error',
     *     sexMap?: array<string, string>,
     *     logger?: mixed,
     *     storage?: Storage
     * }|null $config baseUrl is the LIS address (required, here or in env). apiKey equals SimrsApiKey in
     *     LIS. storageDir is the small cache folder and must be outside the public web folder.
     *     unknownTestPolicy decides what happens with a test code unknown to LIS (default 'reject').
     *     sexMap adds your own sex values, for example ['LK' => 'M']. logger is a PSR-3 logger;
     *     patient names and ID numbers are already masked. storage replaces the built-in file
     *     storage (an object implementing {@see Storage}); use it when several servers share one LIS.
     * @param Platform|null $platform Internal. Leave null.
     * @throws LisException When the configuration is invalid, for example baseUrl is missing.
     */
    public function __construct(?array $config = null, ?Platform $platform = null)
    {
        $logger = $config['logger'] ?? null;
        $storage = $config['storage'] ?? null;
        if ($config !== null) {
            // The logger and the storage are objects, not configuration data; they never go to
            // the core as JSON.
            unset($config['logger'], $config['storage']);
        }
        $configJson = $config !== null ? json_encode($config) : null;

        try {
            if ($platform === null) {
                $platform = $this->createDefaultPlatform($configJson, $logger, $storage);
            }
            $this->core = new LisCore($configJson, $platform);
        } catch (\Throwable $t) {
            throw $this->toLisException($t);
        }
    }

    /**
     * Wires the PHP platform. The storage location is resolved by the core so it follows
     * exactly the same config rules (explicit config, then env, then default).
     *
     * @param string|null $configJson
     * @param mixed $psrLogger
     * @param mixed $customStorage null | Storage given by the application
     */
    private function createDefaultPlatform(
        ?string $configJson,
        $psrLogger,
        $customStorage = null
    ): Platform {
        if ($customStorage !== null && !$customStorage instanceof Storage) {
            throw new LisException(
                'config.storage must implement ' . Storage::class . '.',
                'VALIDATION_FAILED',
                false,
                null,
                null,
                null,
                null,
                'config.storage'
            );
        }

        $env = new PhpEnv();
        $clock = new PhpClock();
        $hash = new PhpHash();
        $logger = new PhpLogger($psrLogger);

        $settings = json_decode(LisCore::resolveStorageSettings($configJson, $env), true);
        $onFallback = function () use ($logger) {
            $message = 'Storage directory is not writable. Using in-memory storage.';
            $logger->log('warn', $message, null);
        };
        $storage = $customStorage !== null
            ? new StorageAdapter($customStorage)
            : new PhpStorage(
                $settings['baseUrl'],
                $settings['storageDir'],
                $hash,
                $clock,
                $onFallback
            );

        return new Platform(new PhpHttp(), $storage, $env, $clock, $hash, $logger, 'php');
    }

    /**
     * Converts an exception thrown while building the core (a thrown LisError) to LisException.
     */
    private function toLisException(\Throwable $t): LisException
    {
        if ($t instanceof LisException) {
            return $t;
        }
        $val = $t instanceof \BridgeLisTamaConnection\haxe\ValueException ? $t->value : null;
        if (!is_object($val) || !isset($val->code)) {
            return new LisException($t->getMessage(), 'INTERNAL', false, null, null, null, $t);
        }

        return new LisException(
            $val->message ?? $t->getMessage(),
            $val->code,
            !empty($val->retryable),
            null,
            null,
            $val->details ?? null,
            $t,
            $val->field ?? null
        );
    }

    /**
     * Registers the handler that receives lab results sent by LIS through the webhook.
     * Register it before the webhook endpoint runs; only one handler is kept (a new call replaces it).
     *
     * The same result can arrive more than once (Resend, re-approval after revision), so save it
     * with an upsert per (order_id, test_code), never a plain insert. The webhook only fires after
     * the result is finished and approved in LIS.
     *
     * If the handler throws, LIS gets an error reply and records the delivery as FAILED, so the
     * lab operator can press "Resend".
     *
     * @param callable $handler function(array $event): void. `$event` has order_id, is_final,
     *     received_at, patient and order.
     */
    public function onResult(callable $handler): void
    {
        $this->onResultCallback = $handler;
    }

    /**
     * Creates an order in LIS, or replaces it when `lis_order.order_id` already exists.
     * Before sending, the library normalizes sex (L/P becomes M/F) and birth date, and checks
     * every test code against the LIS catalog.
     *
     * - Identical resubmission is not sent again and returns status 'UNCHANGED'.
     * - Changing an existing order replaces its tests and patient data. If auto-approve is off in
     *   LIS, result approval is reset to "not approved". `warnings` then contains ORDER_RESUBMITTED.
     * - Field names use snake_case, same as the HIS V2 API. `order_id` must not contain `/`.
     *
     * Example:
     *
     *     $receipt = $lis->createOrder([
     *         'patient' => [
     *             'medical_record_number' => 'RM-001234',
     *             'first_name'            => 'Budi',
     *             'date_of_birth'         => '1990-01-31',
     *             'sex'                   => 'L',
     *         ],
     *         'lis_order' => ['order_id' => 'ORD-001', 'tests' => [['code' => 'HB']]],
     *     ]);
     *
     * @param array{
     *     patient: array{
     *         medical_record_number: string,
     *         first_name: string,
     *         last_name?: string,
     *         date_of_birth: string,
     *         sex: string,
     *         phone_number?: string,
     *         address?: string,
     *         id_card_number?: string
     *     },
     *     lis_order: array{
     *         order_id: string,
     *         tests?: array<int, array<string, mixed>>,
     *         packages?: array<int, array<string, mixed>>,
     *         clinical_notes?: string,
     *         priority?: string
     *     }
     * } $order Each test or package item uses `code`, `loinc_code`, `id` or `name`.
     * @return array{status: string, order_id: string, lab_work_order_id: int|null, lab_barcode: string|null, warnings: array<int, array<string, mixed>>}
     *     Receipt. `status` is 'SENT' or 'UNCHANGED'; `warnings` are sanitizer notes.
     * @throws LisException Unknown test code (when policy is 'reject'), invalid data (not retryable),
     *     or LIS unavailable (retryable).
     */
    public function createOrder(array $order): array
    {
        return $this->invokeCore(function ($cb) use ($order) {
            $this->core->createOrder(json_encode($order), $cb);
        });
    }

    /**
     * PERMANENTLY deletes an order from LIS, with its samples and test list, whatever its status,
     * even when the result is already out or approved. This cannot be undone.
     * To cancel only some tests, send the order again with createOrder() and the new test list.
     *
     * @param string $orderId The `order_id` used in createOrder().
     * @return array{status: string}
     * @throws LisException Order not found, or LIS unavailable.
     */
    public function deleteOrder(string $orderId): array
    {
        return $this->invokeCore(function ($cb) use ($orderId) {
            $this->core->deleteOrder($orderId, $cb);
        });
    }

    /**
     * Updates the clinical notes of an existing order.
     *
     * @param string $orderId The `order_id` used in createOrder().
     * @param string $notes New notes. They replace the old ones.
     * @return array{status: string}
     * @throws LisException Order not found, or LIS unavailable.
     */
    public function updateNotes(string $orderId, string $notes): array
    {
        return $this->invokeCore(function ($cb) use ($orderId, $notes) {
            $this->core->updateNotes($orderId, $notes, $cb);
        });
    }

    /**
     * Gets one order from LIS, including barcode and status.
     *
     * @param string $orderId The `order_id` used in createOrder().
     * @return array<string, mixed> Order detail (id, order_id, barcode, barcode_simrs, status, work_order_status, patient, tests, ...).
     * @throws LisException Order not found, or LIS unavailable.
     */
    public function getOrder(string $orderId): array
    {
        return $this->invokeCore(function ($cb) use ($orderId) {
            $this->core->getOrder($orderId, $cb);
        });
    }

    /**
     * Lists orders in LIS.
     *
     * @param array<string, mixed>|null $filter Optional query filter, passed to the LIS orders endpoint as is.
     * @return array<string, mixed>
     * @throws LisException LIS unavailable, or the filter is rejected by LIS.
     */
    public function listOrders(?array $filter = null): array
    {
        $filterJson = $filter !== null ? json_encode($filter) : '';
        return $this->invokeCore(function ($cb) use ($filterJson) {
            $this->core->listOrders($filterJson, $cb);
        });
    }

    /**
     * Gets the result of an order. Does not throw when the result is not ready: it returns
     * ['state' => 'PENDING']. When `state` is 'AVAILABLE', read `order.results`.
     * Prefer onResult() for normal use; there is no polling inside the library.
     *
     * @param string $orderId The `order_id` used in createOrder().
     * @return array<string, mixed> `state` ('AVAILABLE' or 'PENDING'), and when available: patient, order, is_final.
     * @throws LisException Order not found, or LIS unavailable.
     */
    public function getResult(string $orderId): array
    {
        return $this->invokeCore(function ($cb) use ($orderId) {
            $this->core->getResult($orderId, $cb);
        });
    }

    /**
     * Downloads the result as a PDF.
     *
     * @param string $orderId The `order_id` used in createOrder().
     * @return string Binary PDF content (not text). Save it with file_put_contents() or send it with
     *     the header `Content-Type: application/pdf`.
     * @throws LisException Result not available, or LIS unavailable.
     */
    public function getResultPdf(string $orderId): string
    {
        $b64 = $this->invokeCore(function ($cb) use ($orderId) {
            $this->core->getResultPdf($orderId, $cb);
        });
        return base64_decode($b64);
    }

    /**
     * Lists the tests defined in LIS. The library also uses this list to check test codes (cached).
     *
     * @return array<int, mixed>
     * @throws LisException LIS unavailable.
     */
    public function getTestTypes(): array
    {
        return $this->invokeCore(function ($cb) {
            $this->core->getTestTypes($cb);
        });
    }

    /**
     * Lists the test packages defined in LIS.
     *
     * @return array<int, mixed>
     * @throws LisException LIS unavailable.
     */
    public function getPackages(): array
    {
        return $this->invokeCore(function ($cb) {
            $this->core->getPackages($cb);
        });
    }

    /**
     * Gets one test package, including its tests.
     *
     * @param string $code Package code in LIS.
     * @return array<string, mixed>
     * @throws LisException Package not found, or LIS unavailable.
     */
    public function getPackage(string $code): array
    {
        return $this->invokeCore(function ($cb) use ($code) {
            $this->core->getPackage($code, $cb);
        });
    }

    /**
     * Lists doctors and analysts registered in LIS.
     *
     * @return array<int, mixed>
     * @throws LisException LIS unavailable.
     */
    public function getUsers(): array
    {
        return $this->invokeCore(function ($cb) {
            $this->core->getUsers($cb);
        });
    }

    /**
     * Handles a result webhook from the LIS and returns the HTTP reply to send back.
     * Works in any framework: pass nothing (plain PHP), the framework's request object
     * (Laravel, Symfony, PSR-7, CodeIgniter 4), or a raw body plus headers. See WebhookInput.
     * A non-2xx reply makes the LIS mark the delivery FAILED so it can be resent (HLD F10).
     *
     * Checks the webhook secret, parses the body and runs the onResult() handler. Bad requests
     * produce an error reply instead of an exception. Send the reply with your framework:
     *
     *     // Laravel
     *     $r = $lis->handleWebhook($request);
     *     return response($r['body'], $r['status'], $r['headers']);
     *
     * @param mixed $request  null | request object | raw body (string or decoded array)
     * @param mixed $headers  null | array (values string or string[]) | HeaderBag
     * @return array{status: int, headers: array<string, string>, body: string}
     */
    public function handleWebhook($request = null, $headers = null): array
    {
        [$rawBody, $headerMap] = WebhookInput::normalize($request, $headers);
        $handlerWrapper = $this->resultHandler();

        return $this->invokeCore(function ($cb) use ($rawBody, $headerMap, $handlerWrapper) {
            $headersJson = (string) json_encode((object) $headerMap);
            $this->core->handleWebhook($rawBody, $headersJson, $handlerWrapper, $cb);
        });
    }

    /**
     * Recovers results that never arrived (webhook failed and nobody pressed Resend). Call it from
     * your own cron job or an admin page; the library never runs it by itself.
     *
     * It lists the COMPLETED orders created in the window, fetches each result and gives every
     * final one to the onResult() handler, the same handler as the webhook. Orders created
     * directly in LIS (not sent by your SIMRS) are ignored.
     *
     * Limits to know:
     * - The window is the time the order was CREATED. An old order that was approved or revised
     *   later is only found if "since" reaches back to its creation date.
     * - LIS gives no "changed since" filter, so revised results are recovered by fetching every
     *   order in the window again (one request each). Use "skip" for orders you already hold,
     *   and a narrow "since".
     * - Your handler must upsert: the same result can arrive from the webhook and from here.
     * - A long run can hit PHP's max_execution_time. Lower "limit" and call again with "skip".
     *
     * Example:
     *
     *     $lis->onResult(function (array $event) use ($db) { // upsert here });
     *     $report = $lis->reconcile([
     *         'since' => '2026-11-04',
     *         'skip'  => function (string $orderId): bool { return $db->hasFinalResult($orderId); },
     *     ]);
     *
     * @param array{since: string, until?: string, limit?: int, skip?: callable} $options
     *     "since" is required, for example '2026-11-04' or '2026-11-04 08:00:00'. "until" defaults
     *     to now. "limit" (1 to 1000, default 100) is the most results fetched in one call; skipped
     *     orders do not count. "skip" is function (string $orderId): bool and returns true when your
     *     database already holds the result; if it throws, that order is listed in "failed" and not fetched.
     * @return array{checked: int, delivered: int, pending: int, skipped: int, failed: array<int, array{order_id: string, error: string}>, truncated: bool}
     *     "truncated" is true when the run stopped early (limit, LIS unavailable, bad key): call
     *     again, with "skip".
     * @throws LisException VALIDATION_FAILED (no "since", no onResult() handler), or the order list
     *     itself could not be read (AUTH_FAILED, LIS_UNAVAILABLE, ...). One failing order never
     *     throws; it is listed in "failed".
     */
    public function reconcile(array $options): array
    {
        $skip = $options['skip'] ?? null;
        unset($options['skip']);

        $skipWrapper = null;
        if ($skip !== null) {
            $skipWrapper = function (string $orderId, $answer) use ($skip) {
                try {
                    $answer((bool) call_user_func($skip, $orderId), null);
                } catch (\Throwable $t) {
                    // The order is reported in "failed" and not fetched.
                    $answer(false, $t->getMessage());
                }
            };
        }
        $handler = $this->onResultCallback !== null ? $this->resultHandler() : null;
        $optionsJson = (string) json_encode((object) $options);

        return $this->invokeCore(function ($cb) use ($optionsJson, $skipWrapper, $handler) {
            $this->core->reconcile($optionsJson, $skipWrapper, $handler, $cb);
        });
    }

    /**
     * Adapts the registered onResult() callable to the core callback style. A thrown exception
     * becomes an error message, so LIS gets an error reply (webhook) or the order is listed in
     * "failed" (reconcile).
     */
    private function resultHandler(): callable
    {
        return function (string $eventJson, $done) {
            if ($this->onResultCallback === null) {
                $done('No onResult handler registered on Client.');
                return;
            }
            try {
                $eventData = json_decode($eventJson, true) ?? [];
                call_user_func($this->onResultCallback, $eventData);
                $done(null);
            } catch (\Throwable $t) {
                $done($t->getMessage());
            }
        };
    }

    /**
     * One-call webhook endpoint for plain PHP (or any app without a response object):
     * reads the current request, runs handleWebhook() and sends the HTTP response.
     * Use it in plain PHP or CodeIgniter 3. Call it only after onResult() is registered, and print
     * nothing else before it.
     *
     *     $lis->onResult(function (array $event) { // upsert here });
     *     $lis->serveWebhook();
     *
     * @return array{status: int, headers: array<string, string>, body: string} what was sent
     */
    public function serveWebhook(): array
    {
        $res = $this->handleWebhook();
        if (!headers_sent()) {
            http_response_code($res['status']);
            foreach ($res['headers'] as $name => $value) {
                header($name . ': ' . $value);
            }
        }
        echo $res['body'];
        return $res;
    }

    /**
     * Checks the configuration and the connection to LIS. Safe to call at startup or from a
     * monitoring endpoint. Secret values are never returned, only whether they are set.
     * `lisReachable` is false when LIS cannot be contacted.
     *
     * @return array{version: string, baseUrl: string, apiKeySet: bool, webhookSecretSet: bool, storage: string, breaker: array{open: bool, fails: int}, catalogAgeSec: int, lisReachable: bool}
     */
    public function health(): array
    {
        return $this->invokeCore(function ($cb) {
            $this->core->health($cb);
        });
    }

    /**
     * Synchronous bridge executing CPS callback and translating JSON outcome to return/throw.
     *
     * @param callable $fn
     * @return mixed
     * @throws LisException
     */
    private function invokeCore(callable $fn)
    {
        $outcome = null;
        $fn(function (string $outcomeJson) use (&$outcome) {
            $outcome = json_decode($outcomeJson, true);
        });

        if ($outcome === null) {
            throw new LisException(
                'Core callback was not invoked synchronously.',
                'INTERNAL',
                false
            );
        }

        if (!empty($outcome['ok'])) {
            return $outcome['value'];
        }

        $err = $outcome['error'] ?? [];
        $msg = $err['message'] ?? 'Unknown error';
        $code = $err['code'] ?? 'INTERNAL';
        $retryable = !empty($err['retryable']);
        $httpStatus = isset($err['httpStatus']) ? (int) $err['httpStatus'] : null;
        $requestId = $err['requestId'] ?? null;
        $details = $err['details'] ?? null;
        $field = $err['field'] ?? null;

        throw new LisException(
            $msg,
            $code,
            $retryable,
            $httpStatus,
            $requestId,
            $details,
            null,
            $field
        );
    }
}
