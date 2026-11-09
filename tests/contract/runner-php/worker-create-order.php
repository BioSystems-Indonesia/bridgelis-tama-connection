<?php

declare(strict_types=1);

/**
 * Child process of contract test 17: sends one order and prints a one-line JSON outcome.
 * Usage: php worker-create-order.php <baseUrl> <storageDir> <scenarioFile>
 */

require_once __DIR__ . '/../../../targets/php/autoload.php';

use BridgeLisTamaConnection\Client;
use BridgeLisTamaConnection\LisException;

[, $baseUrl, $storageDir, $scenarioFile] = $argv;
$scenario = json_decode((string) file_get_contents($scenarioFile), true);

try {
    $client = new Client([
        'baseUrl' => $baseUrl,
        'apiKey' => 'test-api-key',
        'storageDir' => $storageDir,
        'logLevel' => 'error',
    ]);
    $receipt = $client->createOrder($scenario['order']);
    echo json_encode(['status' => $receipt['status']]);
} catch (LisException $e) {
    echo json_encode(['error' => $e->getErrorCode(), 'retryable' => $e->isRetryable()]);
}
