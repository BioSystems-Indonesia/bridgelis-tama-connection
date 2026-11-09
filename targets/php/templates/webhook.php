<?php

declare(strict_types=1);

// The address of this file is the webhook URL you give to LIS. Plain PHP only; a framework uses
// the route snippet printed by `init` instead. Adjust the path to lis.php if you move this file.
require_once __DIR__ . '/lis.php';
lis()->serveWebhook();
