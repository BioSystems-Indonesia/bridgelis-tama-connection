<?php
// config/lis.php — explicit config, as README recommends for `php artisan config:cache`.
return [
    'baseUrl'    => env('LIS_BASE_URL'),
    'apiKey'     => env('LIS_API_KEY'),
    'webhook'    => ['secret' => env('LIS_WEBHOOK_SECRET')],
    'storageDir' => env('LIS_STORAGE_DIR'),
    'catalog'    => ['unknownTestPolicy' => env('LIS_UNKNOWN_TEST_POLICY', 'reject')],
];
