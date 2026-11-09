<?php

declare(strict_types=1);

namespace BridgeLisTamaConnection;

/**
 * Standard exception thrown by the PHP facade for all LIS and validation failures.
 * Compatible with PHP >= 7.4.
 */
class LisException extends \RuntimeException
{
    /** @var string */
    private $errorCode;

    /** @var bool */
    private $retryable;

    /** @var int|null */
    private $httpStatus;

    /** @var string|null */
    private $requestId;

    /** @var mixed */
    private $details;

    /** @var string|null */
    private $field;

    public function __construct(
        string $message,
        string $errorCode,
        bool $retryable,
        ?int $httpStatus = null,
        ?string $requestId = null,
        $details = null,
        ?\Throwable $previous = null,
        ?string $field = null
    ) {
        parent::__construct($message, $httpStatus ?? 0, $previous);
        $this->errorCode = $errorCode;
        $this->retryable = $retryable;
        $this->httpStatus = $httpStatus;
        $this->requestId = $requestId;
        $this->details = $details;
        $this->field = $field;
    }

    /**
     * Stable error code, for example BRIDGING_DISABLED. Use it for `switch`, not the message.
     */
    public function getErrorCode(): string
    {
        return $this->errorCode;
    }

    /**
     * True: LIS is unavailable, trying again later is fine. False: fix the data or configuration first.
     */
    public function isRetryable(): bool
    {
        return $this->retryable;
    }

    /**
     * HTTP status from LIS, when the error came from a LIS reply.
     */
    public function getHttpStatus(): ?int
    {
        return $this->httpStatus;
    }

    /**
     * Request id from LIS. Give it to the LIS team when reporting a problem.
     */
    public function getRequestId(): ?string
    {
        return $this->requestId;
    }

    /**
     * Extra detail from LIS or from validation.
     *
     * @return mixed
     */
    public function getDetails()
    {
        return $this->details;
    }

    /**
     * Name of the invalid input field, for validation errors.
     */
    public function getField(): ?string
    {
        return $this->field;
    }
}
