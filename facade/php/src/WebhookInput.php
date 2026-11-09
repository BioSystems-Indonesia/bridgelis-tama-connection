<?php

declare(strict_types=1);

namespace BridgeLisTamaConnection;

/**
 * Turns a webhook request in whatever shape a PHP app has into a raw body and header map.
 * Only type conversion lives here; webhook rules (secret, order id, statuses) stay in the core.
 * Compatible with PHP >= 7.4; frameworks are recognized by duck typing, without dependencies.
 */
final class WebhookInput
{
    /**
     * Accepted shapes:
     * - nothing: plain PHP, reads php://input and the request headers;
     * - Laravel / Symfony Request (`getContent()` + `headers`);
     * - PSR-7 ServerRequest (`getBody()` + `getHeaders()`): Slim, Laminas, Yii 3, CodeIgniter 4;
     * - a raw body (string, or an already-decoded array/object) plus headers (array, values
     *   string or string[], or a Symfony HeaderBag).
     *
     * @param mixed $request
     * @param mixed $headers
     * @return array{0: string, 1: array<string, mixed>}
     */
    public static function normalize($request, $headers): array
    {
        if ($request === null && $headers === null) {
            return [self::readPhpInput(), self::readServerHeaders()];
        }
        if ($headers === null && self::isSymfonyRequest($request)) {
            return [(string) $request->getContent(), self::toHeaderArray($request->headers)];
        }
        if ($headers === null && self::isPsr7Request($request)) {
            return [(string) $request->getBody(), self::toHeaderArray($request->getHeaders())];
        }

        return [self::toBodyString($request), self::toHeaderArray($headers ?? [])];
    }

    /** @param mixed $request */
    private static function isSymfonyRequest($request): bool
    {
        return is_object($request)
            && method_exists($request, 'getContent')
            && isset($request->headers);
    }

    /** @param mixed $request */
    private static function isPsr7Request($request): bool
    {
        return is_object($request)
            && method_exists($request, 'getBody')
            && method_exists($request, 'getHeaders');
    }

    /** @param mixed $body */
    private static function toBodyString($body): string
    {
        if ($body === null) {
            return '';
        }
        if (is_string($body)) {
            return $body;
        }
        if (is_array($body) || $body instanceof \JsonSerializable || $body instanceof \stdClass) {
            // The app (or its framework) already decoded the JSON; re-encode it for the core.
            return (string) json_encode($body);
        }
        return (string) $body;
    }

    /**
     * @param mixed $headers  array, HeaderBag-like object with all(), or Traversable
     * @return array<string, mixed>
     */
    private static function toHeaderArray($headers): array
    {
        if (is_object($headers) && method_exists($headers, 'all')) {
            $headers = $headers->all();
        } elseif ($headers instanceof \Traversable) {
            $headers = iterator_to_array($headers);
        }
        if (!is_array($headers)) {
            return [];
        }

        $out = [];
        foreach ($headers as $name => $value) {
            $out[(string) $name] = self::toHeaderValue($value);
        }
        return $out;
    }

    /**
     * Strings and string lists pass through (the core takes the first value). Header objects,
     * such as CodeIgniter 4 `Header`, are read through getValue().
     *
     * @param mixed $value
     * @return mixed
     */
    private static function toHeaderValue($value)
    {
        if (is_object($value) && method_exists($value, 'getValue')) {
            return $value->getValue();
        }
        if (is_array($value)) {
            return array_map(function ($item) {
                $isHeaderObject = is_object($item) && method_exists($item, 'getValue');
                return $isHeaderObject ? $item->getValue() : $item;
            }, array_values($value));
        }
        return $value;
    }

    private static function readPhpInput(): string
    {
        $body = @file_get_contents('php://input');
        return $body === false ? '' : $body;
    }

    /** @return array<string, string> */
    private static function readServerHeaders(): array
    {
        if (function_exists('getallheaders')) {
            $headers = getallheaders();
            if (is_array($headers) && count($headers) > 0) {
                return $headers;
            }
        }

        // Fallback for SAPIs without getallheaders(): rebuild headers from $_SERVER.
        $headers = [];
        foreach ($_SERVER as $key => $value) {
            if (strpos((string) $key, 'HTTP_') === 0) {
                $name = str_replace('_', '-', substr((string) $key, 5));
                $headers[$name] = (string) $value;
            }
        }
        // Apache can hide Authorization from PHP unless it is passed on (see README).
        if (!isset($headers['AUTHORIZATION']) && isset($_SERVER['REDIRECT_HTTP_AUTHORIZATION'])) {
            $headers['AUTHORIZATION'] = (string) $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
        }
        return $headers;
    }
}
