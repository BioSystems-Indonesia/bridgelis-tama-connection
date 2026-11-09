<?php

declare(strict_types=1);

namespace BridgeLisTamaConnection;

/**
 * Storage an application can inject (config key `storage`) instead of the built-in file storage,
 * for example a database table or a shared folder. Experimental until 1.0: the method set
 * may still change.
 *
 * Keys are short strings. Values are short strings (hashes and markers, never patient data).
 * `$ttlSec` of 0 means "never expires".
 */
interface Storage
{
    /** Returns the stored value, or null when the key is missing or expired. */
    public function get(string $key): ?string;

    public function set(string $key, string $value, int $ttlSec): void;

    public function delete(string $key): void;

    /**
     * Stores the value only when the key is absent or expired, in one atomic step.
     * Returns true when this call stored it, false when a live value already exists.
     */
    public function setIfAbsent(string $key, string $value, int $ttlSec): bool;
}
