<?php
// Autoloader for bridgeLIS Tama Connection (PHP >= 7.4)
require_once __DIR__ . '/lib/BridgeLisTamaConnection/php/Boot.php';

spl_autoload_register(function ($class) {
    $prefix = 'BridgeLisTamaConnection\\';
    $len = strlen($prefix);
    if (strncmp($prefix, $class, $len) !== 0) {
        return;
    }

    $relative = substr($class, $len);
    $relPath = str_replace('\\', '/', $relative) . '.php';

    $facadeFile = __DIR__ . '/src/' . $relPath;
    if (file_exists($facadeFile)) {
        require_once $facadeFile;
        return;
    }

    $libFile = __DIR__ . '/lib/BridgeLisTamaConnection/' . $relPath;
    if (file_exists($libFile)) {
        require_once $libFile;
        return;
    }
});
