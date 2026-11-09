<?php

declare(strict_types=1);

require_once __DIR__ . '/../../../targets/php/autoload.php';

use BridgeLisTamaConnection\Client;
use BridgeLisTamaConnection\LisException;

$port = 8398;
$baseUrl = "http://127.0.0.1:{$port}";
$rootDir = dirname(__DIR__, 3);
$storageDir = $rootDir . '/tmp/test-storage-php';

// Remove stale test storage
if (is_dir($storageDir)) {
    $files = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($storageDir, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($files as $fileinfo) {
        $fileinfo->isDir() ? rmdir($fileinfo->getRealPath()) : unlink($fileinfo->getRealPath());
    }
    rmdir($storageDir);
}

// Start mock server in background
// The command is an array (no shell), so proc_terminate stops node itself, not a wrapper shell.
$mockStart = "import('./tests/contract/mock/server.mjs')"
    . ".then(m => m.createMockServer({$port}).start())";
$nodeProcess = proc_open(
    ['node', '-e', $mockStart],
    [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
    $pipes,
    $rootDir
);

// Wait for mock server to be ready
$maxTries = 30;
while ($maxTries > 0) {
    usleep(100000); // 100ms
    $ch = curl_init("{$baseUrl}/api/v1/ping");
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT_MS, 500);
    $res = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code === 200) {
        break;
    }
    $maxTries--;
}

if ($maxTries === 0) {
    fwrite(STDERR, "Failed to start mock server for PHP contract tests\n");
    exit(1);
}

function callMock(string $path, array $body = []): array {
    global $baseUrl;
    $ch = curl_init("{$baseUrl}/__mock/{$path}");
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    $res = curl_exec($ch);
    curl_close($ch);
    return json_decode((string)$res, true) ?? [];
}

function getMockRequests(): array {
    global $baseUrl;
    $ch = curl_init("{$baseUrl}/__mock/requests");
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    $res = curl_exec($ch);
    curl_close($ch);
    return json_decode((string)$res, true) ?? [];
}

echo "=== Starting Contract Tests (PHP Runner) ===\n\n";

$passed = 0;
$failed = 0;

/**
 * Reads a shared scenario file from tests/contract/scenarios (same files as the JS runner).
 */
function loadScenario(string $name): array
{
    $file = dirname(__DIR__) . '/scenarios/' . $name . '.json';
    return json_decode(file_get_contents($file), true);
}

function runTest(string $name, callable $fn) {
    global $passed, $failed;
    callMock('reset');
    try {
        $fn();
        echo "  ✅ PASS: {$name}\n";
        $passed++;
    } catch (\Throwable $t) {
        echo "  ❌ FAIL: {$name}\n";
        echo "     " . $t->getMessage() . " at " . $t->getFile() . ":" . $t->getLine() . "\n";
        $failed++;
    }
}

$client = new Client([
    'baseUrl' => $baseUrl,
    'apiKey' => 'test-api-key',
    'storageDir' => $storageDir
]);

// Scenario 1: Create order then identical returns UNCHANGED
runTest('01: Create order then identical returns UNCHANGED with 1 server request', function () use (
    $client,
    $rootDir
) {
    $sc = loadScenario('01-create-order-success');
    $r1 = $client->createOrder($sc['order']);
    if ($r1['status'] !== 'SENT' || $r1['order_id'] !== 'ORD-CONTRACT-01') {
        throw new \Exception("Expected first status SENT, got " . json_encode($r1));
    }

    $r2 = $client->createOrder($sc['order']);
    if ($r2['status'] !== 'UNCHANGED' || $r2['order_id'] !== 'ORD-CONTRACT-01') {
        throw new \Exception("Expected second status UNCHANGED, got " . json_encode($r2));
    }

    $reqs = getMockRequests();
    $posts = array_filter($reqs, function ($r) {
        return $r['path'] === '/api/v2/his/order' && $r['method'] === 'POST';
    });
    if (count($posts) !== 1) {
        throw new \Exception("Expected 1 POST /order request, found " . count($posts));
    }
});

// Scenario 2: Create order updated payload
runTest('02: Create order with changed payload emits ORDER_RESUBMITTED warning', function () use (
    $client,
    $rootDir
) {
    $sc = loadScenario('02-create-order-resubmitted');
    $r1 = $client->createOrder($sc['order_initial']);
    $r2 = $client->createOrder($sc['order_updated']);

    if ($r2['status'] !== 'SENT') {
        throw new \Exception("Expected status SENT, got " . json_encode($r2));
    }
    $warnings = $r2['warnings'] ?? [];
    $found = false;
    foreach ($warnings as $w) {
        if (($w['code'] ?? '') === 'ORDER_RESUBMITTED') {
            $found = true;
            break;
        }
    }
    if (!$found) {
        throw new \Exception("Expected ORDER_RESUBMITTED warning in " . json_encode($warnings));
    }
});

// Scenario 3: Unknown test code rejected by catalog
runTest('03: Unknown test code rejected by catalog with 0 requests to /order', function () use (
    $client,
    $rootDir
) {
    $sc = loadScenario('03-unknown-test-code');
    $threw = false;
    try {
        $client->createOrder($sc['order']);
    } catch (LisException $e) {
        $threw = true;
        if ($e->getErrorCode() !== 'UNKNOWN_TEST_CODE' || $e->isRetryable() !== false) {
            throw new \Exception("Unexpected error code: " . $e->getErrorCode());
        }
    }
    if (!$threw) {
        throw new \Exception("Expected LisException UNKNOWN_TEST_CODE");
    }

    $reqs = getMockRequests();
    $posts = array_filter($reqs, function ($r) {
        return $r['path'] === '/api/v2/his/order' && $r['method'] === 'POST';
    });
    if (count($posts) !== 0) {
        throw new \Exception("Expected 0 requests to /order");
    }
});

// Scenario 4: Patient sanitization
runTest('04: Normalizes patient sex to F and DOB to YYYY-MM-DD on wire', function () use (
    $client,
    $rootDir
) {
    $sc = loadScenario('04-sanitize-patient');
    $r = $client->createOrder($sc['order']);
    if ($r['status'] !== 'SENT') {
        throw new \Exception("Expected status SENT");
    }

    $reqs = getMockRequests();
    $posts = array_values(array_filter($reqs, function ($r) {
        return $r['path'] === '/api/v2/his/order' && $r['method'] === 'POST';
    }));
    $sent = $posts[0]['body'];
    if ($sent['patient']['sex'] !== 'F' || $sent['patient']['date_of_birth'] !== '1990-05-15') {
        throw new \Exception("Sanitized payload mismatch: " . json_encode($sent));
    }
});

// Scenario 5: 503 retry
runTest('05: 503 error on first attempt retries once and succeeds', function () use (
    $client,
    $rootDir
) {
    callMock('set_behavior', ['orderErrorCount' => 1, 'orderErrorType' => 503]);
    $sc = loadScenario('05-retry-transient');
    $r = $client->createOrder($sc['order']);
    if ($r['status'] !== 'SENT') {
        throw new \Exception("Expected status SENT");
    }

    $reqs = getMockRequests();
    $posts = array_filter($reqs, function ($r) {
        return $r['path'] === '/api/v2/his/order' && $r['method'] === 'POST';
    });
    if (count($posts) !== 2) {
        throw new \Exception("Expected exactly 2 requests after 1 retry, got " . count($posts));
    }
});

// Scenario 6: Circuit breaker
runTest('06: 5 consecutive transient failures trip circuit breaker open', function () use (
    $client,
    $rootDir,
    $storageDir
) {
    callMock('set_behavior', ['orderErrorCount' => 100, 'orderErrorType' => 503]);
    $sc = loadScenario('06-circuit-breaker');

    for ($i = 0; $i < 5; $i++) {
        try {
            $order = $sc['order'];
            $order['lis_order']['order_id'] = "ORD-CB-PHP-{$i}";
            $client->createOrder($order);
        } catch (\Throwable $t) {}
    }

    $tripped = false;
    try {
        $order = $sc['order'];
        $order['lis_order']['order_id'] = "ORD-CB-PHP-FAST-FAIL";
        $client->createOrder($order);
    } catch (LisException $e) {
        if ($e->getErrorCode() === 'LIS_UNAVAILABLE') {
            $tripped = true;
        }
    }
    if (!$tripped) {
        throw new \Exception("Expected circuit breaker to be tripped open");
    }

    // Verify request works again after cooldown expires (LLD §8 & §12)
    $resetBreaker = function ($dir) use (&$resetBreaker) {
        if (!is_dir($dir)) {
            return;
        }
        foreach (scandir($dir) as $item) {
            if ($item === '.' || $item === '..') {
                continue;
            }
            $full = $dir . '/' . $item;
            if (is_dir($full)) {
                $resetBreaker($full);
            }
            elseif (substr($full, -5) === '.json') {
                $raw = @file_get_contents($full);
                if ($raw && strpos($raw, 'openUntil') !== false) {
                    $outer = json_decode($raw, true);
                    $inner = json_decode($outer['v'], true);
                    $inner['openUntil'] = 1.0;
                    $outer['v'] = json_encode($inner);
                    file_put_contents($full, json_encode($outer));
                }
            }
        }
    };
    $resetBreaker($storageDir);

    callMock('set_behavior', ['orderStatus' => 200, 'orderErrorCount' => 0]);
    $order = $sc['order'];
    $order['lis_order']['order_id'] = "ORD-CB-PHP-RECOVERED";
    $recovered = $client->createOrder($order);
    if ($recovered['status'] !== 'SENT') {
        throw new \Exception(
            "Expected SENT after breaker cooldown expires, got " . $recovered['status']
        );
    }
});

// Scenario 7: 400 LIS_REJECTED without negative cache
runTest('07: 400 produces LIS_REJECTED without negative caching', function () use (
    $client,
    $rootDir,
    $storageDir
) {
    // Reset test storage to clear tripped circuit breaker from scenario 06
    if (is_dir($storageDir)) {
        $files = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($storageDir, RecursiveDirectoryIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($files as $fileinfo) {
            $fileinfo->isDir() ? rmdir($fileinfo->getRealPath()) : unlink($fileinfo->getRealPath());
        }
    }
    callMock('set_behavior', ['orderStatus' => 400, 'customOrderMessage' => 'Invalid ward code']);
    $sc = loadScenario('07-lis-rejected-no-negative-cache');

    $threw = false;
    try {
        $client->createOrder($sc['order']);
    } catch (LisException $e) {
        $threw = true;
        if ($e->getErrorCode() !== 'LIS_REJECTED' || $e->getHttpStatus() !== 400) {
            throw new \Exception("Expected LIS_REJECTED with status 400");
        }
    }
    if (!$threw) {
        throw new \Exception("Expected 400 to throw LisException");
    }

    // Resend to verify no negative cache
    try {
        $client->createOrder($sc['order']);
    } catch (\Throwable $t) {}

    $reqs = getMockRequests();
    $posts = array_filter($reqs, function ($r) {
        return $r['path'] === '/api/v2/his/order' && $r['method'] === 'POST';
    });
    if (count($posts) !== 2) {
        throw new \Exception("Expected 2 requests to server without negative cache");
    }
});

// Scenario 8: Status code mappings
runTest('08: Status code mappings (401, 403, 429)', function () use ($client, $baseUrl) {
    // 401
    callMock('set_behavior', ['authRequired' => true, 'authKey' => 'correct-secret']);
    $badAuthClient = new Client(['baseUrl' => $baseUrl, 'apiKey' => 'wrong-secret']);
    $threw401 = false;
    try {
        $badAuthClient->getTestTypes();
    } catch (LisException $e) {
        if ($e->getErrorCode() === 'AUTH_FAILED') {
            $threw401 = true;
        }
    }
    if (!$threw401) {
        throw new \Exception("Expected AUTH_FAILED on 401");
    }

    // 403
    callMock('set_behavior', ['authRequired' => false, 'orderStatus' => 403]);
    $threw403 = false;
    try {
        $client->createOrder([
            'patient' => [
                'medical_record_number' => 'RM-1',
                'first_name' => 'A',
                'sex' => 'M',
                'date_of_birth' => '1990-01-01',
            ],
            'lis_order' => ['order_id' => 'ORD-403', 'tests' => [['loinc_code' => '2345-7']]]
        ]);
    } catch (LisException $e) {
        if ($e->getErrorCode() === 'BRIDGING_DISABLED') {
            $threw403 = true;
        }
    }
    if (!$threw403) {
        throw new \Exception("Expected BRIDGING_DISABLED on 403");
    }

    // 429 (not retried)
    callMock('set_behavior', ['orderStatus' => 200, 'rateLimitCount' => 1]);
    $countTestTypes = function () {
        return count(array_filter(getMockRequests(), function ($r) {
            return ($r['path'] ?? '') === '/api/v2/his/test-types';
        }));
    };
    $reqsBefore429 = $countTestTypes();
    $threw429 = false;
    try {
        $client->getTestTypes();
    } catch (LisException $e) {
        $headersReached = ($e->getDetails()['retryAfterSec'] ?? null) === 7
            && $e->getRequestId() === 'req-429';
        $isRateLimited = $e->getErrorCode() === 'RATE_LIMITED' && $e->isRetryable() === true;
        if ($isRateLimited && $headersReached) {
            $threw429 = true;
        }
    }
    if (!$threw429) {
        throw new \Exception("Expected RATE_LIMITED on 429");
    }
    $reqsAfter429 = $countTestTypes();
    if ($reqsAfter429 - $reqsBefore429 !== 1) {
        throw new \Exception(
            "Expected exactly 1 request on 429 (no retry), got " . ($reqsAfter429 - $reqsBefore429)
        );
    }
});

// Scenario 9: getResult 404 -> PENDING
runTest('09: getResult maps 404 to [state => "PENDING"]', function () use ($client) {
    $res = $client->getResult('ORD-PENDING');
    if (($res['state'] ?? '') !== 'PENDING') {
        throw new \Exception("Expected state PENDING, got " . json_encode($res));
    }
});

// Field names verified against a real LIS: result / abnormal_flag / is_critical.
runTest('09b: getResult AVAILABLE keeps real LIS field names', function () use ($client) {
    $res = $client->getResult('ORD-REAL-SHAPE');
    $row = $res['order']['results'][0] ?? [];
    if (($res['state'] ?? '') !== 'AVAILABLE' || ($row['result'] ?? null) !== '95' || ($row['abnormal_flag'] ?? null) !== 'N' || ($row['is_critical'] ?? null) !== false || isset($row['result_value'])) {
        throw new Exception("Unexpected result shape: " . json_encode($res));
    }
});

// Scenario 10: Webhook dispatching
runTest('10: Webhook secret, order id, result dispatch and 500 on throw', function () use (
    $baseUrl
) {
    $whClient = new Client([
        'baseUrl' => $baseUrl,
        'apiKey' => 'test-api-key',
        'webhook' => ['secret' => 'wh-secret-key', 'secretHeader' => 'X-API-Key']
    ]);

    $received = null;
    $whClient->onResult(function (array $event) use (&$received) {
        $received = $event;
        if ($event['order_id'] === 'ORD-PHP-FAIL') {
            throw new \RuntimeException('DB insert failure');
        }
    });

    $send = function (array $body, string $secret) use ($whClient): array {
        return $whClient->handleWebhook(json_encode($body), ['X-API-Key' => $secret]);
    };

    // 1. Secret mismatch -> 401
    $r1 = $send(['order_no' => 'ORD-1'], 'bad-secret');
    if ($r1['status'] !== 401) {
        throw new \Exception("Expected status 401 on secret mismatch");
    }

    // 2. Missing order id -> 400
    $r2 = $send(['status' => 'SUCCESS'], 'wh-secret-key');
    if ($r2['status'] !== 400) {
        throw new \Exception("Expected status 400 on missing order_id");
    }

    // 2b. Upstream LIS 503 -> 502 Bad Gateway (LLD §7.2 & §12)
    $r502 = $send(['order_no' => 'ORD-LIS-DOWN'], 'wh-secret-key');
    if ($r502['status'] !== 502) {
        throw new \Exception(
            "Expected status 502 on upstream LIS down, got " . $r502['status']
            . " body: " . ($r502['body'] ?? '')
        );
    }

    // 3. Valid webhook -> 200
    $r3 = $send(['order_no' => 'ORD-PHP-OK'], 'wh-secret-key');
    $dispatched = !empty($received) && $received['order_id'] === 'ORD-PHP-OK'
        && $received['is_final'] === true;
    if ($r3['status'] !== 200 || !$dispatched) {
        throw new \Exception("Webhook success dispatch failed: " . json_encode($r3));
    }

    // 4. Handler throw -> 500
    $r4 = $send(['order_no' => 'ORD-PHP-FAIL'], 'wh-secret-key');
    if ($r4['status'] !== 500) {
        throw new \Exception("Expected status 500 on handler exception");
    }
});

// Scenario 11: Webhook Bearer Auth
runTest('11: Webhook with Authorization: Bearer secret', function () use ($baseUrl) {
    $whBearer = new Client([
        'baseUrl' => $baseUrl,
        'webhook' => ['secret' => 'bearer-secret-token', 'secretHeader' => 'Authorization']
    ]);
    $whBearer->onResult(function () {});
    $res = $whBearer->handleWebhook(
        json_encode(['order_no' => 'ORD-BEARER']),
        ['authorization' => 'Bearer bearer-secret-token']
    );
    if ($res['status'] !== 200) {
        throw new \Exception("Bearer auth webhook failed: " . json_encode($res));
    }
});

// Scenario 12: deleteOrder evicts dedup hash
runTest('12: deleteOrder evicts hash allowing identical order recreate', function () use ($client) {
    $order = [
        'patient' => [
            'medical_record_number' => 'RM-D',
            'first_name' => 'B',
            'sex' => 'M',
            'date_of_birth' => '1990-01-01',
        ],
        'lis_order' => ['order_id' => 'ORD-PHP-DEL', 'tests' => [['loinc_code' => '2345-7']]]
    ];

    $r1 = $client->createOrder($order);
    if ($r1['status'] !== 'SENT') {
        throw new \Exception("Expected first SENT");
    }

    $r2 = $client->createOrder($order);
    if ($r2['status'] !== 'UNCHANGED') {
        throw new \Exception("Expected second UNCHANGED");
    }

    $del = $client->deleteOrder('ORD-PHP-DEL');
    if ($del['status'] !== 'SENT') {
        throw new \Exception("Expected delete SENT");
    }

    $r3 = $client->createOrder($order);
    if ($r3['status'] !== 'SENT') {
        throw new \Exception("Expected recreated SENT");
    }
});

// Scenario 13: Config validation
runTest('13: Config env resolution and missing baseUrl error', function () {
    $threw = false;
    try {
        new Client(['baseUrl' => '']);
    } catch (LisException $e) {
        if ($e->getErrorCode() === 'VALIDATION_FAILED') {
            $threw = true;
        }
    }
    if (!$threw) {
        throw new \Exception("Expected VALIDATION_FAILED when baseUrl is empty");
    }

    // Test process environment variables and explicit override (LLD §9 & §12)
    putenv('LIS_BASE_URL=http://env-url:8000');
    putenv('LIS_API_KEY=env-secret-key');
    $envClient = new Client();
    $envHealth = $envClient->health();
    if ($envHealth['baseUrl'] !== 'http://env-url:8000' || $envHealth['apiKeySet'] !== true) {
        throw new \Exception(
            "Expected env vars to be read by default constructor: " . json_encode($envHealth)
        );
    }

    $overrideClient = new Client(['baseUrl' => 'http://custom-url:9999']);
    $overrideHealth = $overrideClient->health();
    if ($overrideHealth['baseUrl'] !== 'http://custom-url:9999') {
        throw new \Exception(
            "Expected explicit baseUrl to override env var: " . json_encode($overrideHealth)
        );
    }

    putenv('LIS_BASE_URL');
    putenv('LIS_API_KEY');
});

// Scenario 14: End-to-end other endpoints
runTest('14: Other endpoints end to end (orders, PDF, catalog, users, health)', function () use (
    $client
) {
    $order = $client->getOrder('ORD-TEST');
    if (empty($order)) {
        throw new \Exception("getOrder failed");
    }

    $list = $client->listOrders(['limit' => 5]);
    if (!is_array($list)) {
        throw new \Exception("listOrders failed");
    }

    $noteRes = $client->updateNotes('ORD-TEST', 'Urgent note from doctor');
    if ($noteRes['status'] !== 'SENT') {
        throw new \Exception("updateNotes failed");
    }

    $pdf = $client->getResultPdf('ORD-TEST');
    if (strlen($pdf) === 0 || strpos($pdf, '%PDF-1.4') === false) {
        throw new \Exception("getResultPdf returned invalid binary data: " . $pdf);
    }

    $pkgs = $client->getPackages();
    if (!is_array($pkgs)) {
        throw new \Exception("getPackages failed");
    }

    $pkg = $client->getPackage('PKG-LIPID');
    if (($pkg['code'] ?? '') !== 'PKG-LIPID') {
        throw new \Exception("getPackage failed");
    }

    $users = $client->getUsers();
    if (!is_array($users)) {
        throw new \Exception("getUsers failed");
    }

    $health = $client->health();
    if (empty($health['lisReachable']) || empty($health['apiKeySet'])) {
        throw new \Exception("health check failed: " . json_encode($health));
    }
});

// Regression: a PSR-3 logger object was ignored because Reflect.hasField misses methods.
runTest('15: PSR-3 logger receives masked, PSR-level log records', function () use (
    $baseUrl,
    $storageDir
) {
    $psr = new class {
        /** @var array<int, array{0: string, 1: string, 2: array}> */
        public $records = [];

        public function log($level, $message, array $context = []): void
        {
            $this->records[] = [$level, $message, $context];
        }
    };

    $psrClient = new Client(['baseUrl' => $baseUrl, 'storageDir' => $storageDir, 'logger' => $psr]);
    if (count($psrClient->health()) === 0) {
        throw new \Exception("health returned nothing");
    }

    $warnings = array_filter($psr->records, function ($r) {
        return $r[0] === 'warning' && strpos($r[1], 'LIS_API_KEY') !== false;
    });
    if (count($warnings) !== 1) {
        throw new \Exception(
            "Expected one PSR-3 'warning' about LIS_API_KEY, got " . json_encode($psr->records)
        );
    }
    if (!is_array(array_values($warnings)[0][2])) {
        throw new \Exception("PSR-3 context must be an array");
    }
});

// Stand-ins for framework request objects (no framework is installed in the test run).
final class FakeHeaderBag
{
    /** @var array<string, string[]> */
    private $headers;

    public function __construct(array $headers)
    {
        $this->headers = $headers;
    }

    public function all(): array
    {
        return $this->headers;
    }
}

/** Laravel / Symfony HttpFoundation Request: getContent() + public $headers bag. */
final class FakeSymfonyRequest
{
    /** @var FakeHeaderBag */
    public $headers;
    /** @var string */
    private $content;

    public function __construct(string $content, array $headers)
    {
        $this->content = $content;
        $this->headers = new FakeHeaderBag($headers);
    }

    public function getContent(): string
    {
        return $this->content;
    }
}

/** PSR-7 ServerRequest (Slim, Laminas, Yii 3); CodeIgniter 4 passes header objects instead. */
final class FakePsr7Request
{
    /** @var string */
    private $body;
    /** @var array<string, mixed> */
    private $headers;

    public function __construct(string $body, array $headers)
    {
        $this->body = $body;
        $this->headers = $headers;
    }

    public function getBody(): string
    {
        return $this->body;
    }

    public function getHeaders(): array
    {
        return $this->headers;
    }
}

/** CodeIgniter 4 Header object. */
final class FakeCi4Header
{
    /** @var string */
    private $value;

    public function __construct(string $value)
    {
        $this->value = $value;
    }

    public function getValue(): string
    {
        return $this->value;
    }
}

runTest('16: Webhook accepts the request shapes of common PHP frameworks', function () use (
    $baseUrl,
    $storageDir
) {
    $sc = loadScenario('16-webhook-request-shapes');
    $shapeClient = new Client([
        'baseUrl' => $baseUrl,
        'apiKey' => 'test-api-key',
        'storageDir' => $storageDir,
        'webhook' => ['secret' => $sc['secret']],
    ]);
    $shapeClient->onResult(function (array $event) {
    });
    $raw = json_encode(['order_no' => $sc['order_no']]);

    $shapes = [
        'raw + plain headers' => function ($secret) use ($raw) {
            return [$raw, ['X-API-Key' => $secret]];
        },
        'raw + headers->all()' => function ($secret) use ($raw) {
            return [$raw, ['x-api-key' => [$secret]]];
        },
        'decoded array body' => function ($secret) use ($sc) {
            return [['order_no' => $sc['order_no']], ['X-API-Key' => $secret]];
        },
        'Laravel/Symfony Request' => function ($secret) use ($raw) {
            return [new FakeSymfonyRequest($raw, ['x-api-key' => [$secret]])];
        },
        'PSR-7 request' => function ($secret) use ($raw) {
            return [new FakePsr7Request($raw, ['X-API-Key' => [$secret]])];
        },
        'CodeIgniter 4 request' => function ($secret) use ($raw) {
            return [new FakePsr7Request($raw, ['X-API-Key' => new FakeCi4Header($secret)])];
        },
    ];

    foreach ($shapes as $label => $build) {
        $ok = $shapeClient->handleWebhook(...$build($sc['secret']));
        if ($ok['status'] !== $sc['expectedStatus']) {
            throw new \Exception(
                "{$label}: expected {$sc['expectedStatus']}, got " . $ok['status']
            );
        }
        if (($ok['headers']['Content-Type'] ?? '') !== $sc['expectedContentType']) {
            throw new \Exception("{$label}: missing JSON Content-Type header");
        }
        $denied = $shapeClient->handleWebhook(...$build('wrong-secret'));
        if ($denied['status'] !== 401) {
            throw new \Exception("{$label}: wrong secret must be 401, got " . $denied['status']);
        }
    }

    // No arguments (plain PHP): headers come from $_SERVER; the CLI has no request body,
    // so a correct secret gets past auth (400: no order id) and a wrong one is 401.
    $_SERVER['HTTP_X_API_KEY'] = $sc['secret'];
    $native = $shapeClient->handleWebhook();
    $_SERVER['HTTP_X_API_KEY'] = 'wrong-secret';
    $nativeDenied = $shapeClient->handleWebhook();
    unset($_SERVER['HTTP_X_API_KEY']);
    if ($native['status'] !== 400 || $nativeDenied['status'] !== 401) {
        throw new \Exception(
            "plain PHP: expected 400 then 401, got {$native['status']}"
            . " then {$nativeDenied['status']}"
        );
    }
});

runTest('17: Concurrent createOrder for one order_id reaches the LIS once', function () use ($baseUrl, $rootDir) {
    $sc = loadScenario('17-create-order-concurrent');
    callMock('set_behavior', ['orderDelayMs' => $sc['orderDelayMs']]);
    $raceDir = $rootDir . '/tmp/test-storage-php-race';
    if (is_dir($raceDir)) {
        foreach (glob($raceDir . '/*/*') ?: [] as $file) {
            @unlink($file);
        }
    }
    $scenarioFile = dirname(__DIR__) . '/scenarios/17-create-order-concurrent.json';

    $children = [];
    for ($i = 0; $i < $sc['parallel']; $i++) {
        $children[] = proc_open(
            [PHP_BINARY, __DIR__ . '/worker-create-order.php', $baseUrl, $raceDir, $scenarioFile],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes
        );
        $children[$i] = [$children[$i], $pipes];
    }

    $outcomes = [];
    foreach ($children as [$process, $pipes]) {
        $outcomes[] = json_decode((string) stream_get_contents($pipes[1]), true);
        fclose($pipes[1]);
        fclose($pipes[2]);
        proc_close($process);
    }

    $sent = array_filter($outcomes, function ($o) {
        return ($o['status'] ?? '') === 'SENT';
    });
    if (count($sent) !== 1) {
        throw new \Exception('exactly one process must send, got ' . json_encode($outcomes));
    }
    foreach ($outcomes as $o) {
        $isBlocked = ($o['error'] ?? '') === 'ORDER_IN_PROGRESS' && !empty($o['retryable']);
        if (!$isBlocked && !in_array($o['status'] ?? '', ['SENT', 'UNCHANGED'], true)) {
            throw new \Exception('unexpected outcome ' . json_encode($o));
        }
    }
    $posts = array_filter(getMockRequests(), function ($r) {
        return $r['method'] === 'POST' && $r['path'] === '/api/v2/his/order';
    });
    if (count($posts) !== 1) {
        throw new \Exception('LIS must receive 1 POST, got ' . count($posts));
    }
});

runTest('18: reconcile delivers missed final results', function () use ($baseUrl, $storageDir) {
    $sc = loadScenario('18-reconcile');
    callMock('set_behavior', ['listRows' => $sc['rows']]);
    $delivered = [];
    $reconcileClient = new Client([
        'baseUrl' => $baseUrl,
        'apiKey' => 'test-api-key',
        'storageDir' => $storageDir,
        'logLevel' => 'error',
    ]);
    $reconcileClient->onResult(function (array $event) use (&$delivered, $sc) {
        if (in_array($event['order_id'], $sc['failIds'], true)) {
            throw new \RuntimeException('db down');
        }
        $delivered[] = $event['order_id'];
    });

    $report = $reconcileClient->reconcile([
        'since' => $sc['since'],
        'skip' => function (string $orderId) use ($sc): bool {
            return in_array($orderId, $sc['skipIds'], true);
        },
    ]);

    foreach ($sc['expectedReport'] as $key => $value) {
        if ($report[$key] !== $value) {
            throw new \Exception("report.{$key}: expected " . json_encode($value) . ', got ' . json_encode($report[$key]));
        }
    }
    if ($delivered !== $sc['expectedDeliveredIds']) {
        throw new \Exception('delivered ' . json_encode($delivered));
    }
    $failedIds = array_map(function ($f) {
        return $f['order_id'];
    }, $report['failed']);
    if ($failedIds !== $sc['expectedFailedIds']) {
        throw new \Exception('failed ' . json_encode($failedIds));
    }

    $requests = getMockRequests();
    $list = null;
    foreach ($requests as $r) {
        if ($r['method'] === 'GET' && $r['path'] === '/api/v2/his/order') {
            $list = $r;
        }
    }
    if ($list === null || strpos($list['search'], 'status=COMPLETED') === false
        || strpos($list['search'], 'from=' . $sc['since']) === false) {
        throw new \Exception('unexpected list query ' . json_encode($list));
    }
    foreach ($requests as $r) {
        foreach ($sc['unexpectedResultRequests'] as $id) {
            if ($r['path'] === '/api/v2/his/result/' . $id) {
                throw new \Exception("{$id} must not be fetched");
            }
        }
    }

    foreach ([[[], 'since'], [['since' => $sc['since']], 'handler']] as [$options, $field]) {
        $target = $field === 'handler' ? new Client(['baseUrl' => $baseUrl]) : $reconcileClient;
        try {
            $target->reconcile($options);
            throw new \Exception("reconcile must reject missing {$field}");
        } catch (LisException $e) {
            if ($e->getErrorCode() !== 'VALIDATION_FAILED' || $e->getField() !== $field) {
                throw new \Exception("wrong error for {$field}: " . $e->getErrorCode());
            }
        }
    }
});

runTest('19: Custom storage replaces the file storage', function () use ($baseUrl) {
    $sc = loadScenario('19-custom-storage');
    $storage = new class implements \BridgeLisTamaConnection\Storage {
        /** @var array<string, string> */
        public $entries = [];
        /** @var array<int, string> */
        public $lockKeys = [];

        public function get(string $key): ?string
        {
            return $this->entries[$key] ?? null;
        }

        public function set(string $key, string $value, int $ttlSec): void
        {
            $this->entries[$key] = $value;
        }

        public function delete(string $key): void
        {
            unset($this->entries[$key]);
        }

        public function setIfAbsent(string $key, string $value, int $ttlSec): bool
        {
            $this->lockKeys[] = $key;
            if (isset($this->entries[$key])) {
                return false;
            }
            $this->entries[$key] = $value;
            return true;
        }
    };
    $custom = new Client(['baseUrl' => $baseUrl, 'apiKey' => 'test-api-key', 'storage' => $storage]);

    if ($custom->createOrder($sc['order'])['status'] !== 'SENT') {
        throw new \Exception('first create must be SENT');
    }
    if ($custom->createOrder($sc['order'])['status'] !== 'UNCHANGED') {
        throw new \Exception('second create must be UNCHANGED');
    }
    if (!in_array('inflight:ORD-CONTRACT-STORE', $storage->lockKeys, true)
        || !isset($storage->entries['sent:ORD-CONTRACT-STORE'])
        || isset($storage->entries['inflight:ORD-CONTRACT-STORE'])) {
        throw new \Exception('storage state is wrong: ' . json_encode($storage->entries));
    }
    if ($custom->health()['storage'] !== 'custom') {
        throw new \Exception('health().storage must be custom');
    }

    $storage->entries['inflight:ORD-CONTRACT-STORE'] = 'held';
    $changed = $sc['order'];
    $changed['lis_order']['clinical_notes'] = 'x';
    try {
        $custom->createOrder($changed);
        throw new \Exception('createOrder must fail while the lock is held');
    } catch (LisException $e) {
        if ($e->getErrorCode() !== 'ORDER_IN_PROGRESS') {
            throw new \Exception('wrong error ' . $e->getErrorCode());
        }
    }

    try {
        new Client(['baseUrl' => $baseUrl, 'storage' => new \stdClass()]);
        throw new \Exception('invalid storage must be rejected');
    } catch (LisException $e) {
        if ($e->getErrorCode() !== 'VALIDATION_FAILED' || $e->getField() !== 'config.storage') {
            throw new \Exception('wrong error ' . $e->getErrorCode() . '/' . $e->getField());
        }
    }
});

// Clean up background node mock process
$status = proc_get_status($nodeProcess);
if ($status && !empty($status['pid'])) {
    if (strtoupper(substr(PHP_OS, 0, 3)) === 'WIN') {
        @exec("taskkill /F /T /PID " . $status['pid'] . " 2>&1");
    }
}
proc_terminate($nodeProcess);
proc_close($nodeProcess);

echo "\n=== Results: {$passed} passed, {$failed} failed ===\n\n";
if ($failed > 0) {
    exit(1);
}

