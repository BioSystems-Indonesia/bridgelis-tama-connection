<?php

declare(strict_types=1);

namespace BridgeLisTamaConnection;

use BridgeLisTamaConnection\platform\IStorage;

/**
 * Lets the core use an application's {@see Storage}. Only converts the call style; the generated
 * core interface has no PHP type declarations.
 */
class StorageAdapter implements IStorage
{
    /** @var Storage */
    private $storage;

    public function __construct(Storage $storage)
    {
        $this->storage = $storage;
    }

    public function get($key)
    {
        return $this->storage->get((string) $key);
    }

    public function set($key, $value, $ttlSec)
    {
        $this->storage->set((string) $key, (string) $value, (int) $ttlSec);
    }

    public function delete($key)
    {
        $this->storage->delete((string) $key);
    }

    public function setIfAbsent($key, $value, $ttlSec)
    {
        return $this->storage->setIfAbsent((string) $key, (string) $value, (int) $ttlSec);
    }
}
