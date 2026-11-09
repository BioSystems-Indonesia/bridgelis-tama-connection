# Changelog

All notable changes to `bridgeLIS-Tama-Connection` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-09

First public release.

### Added
- Core client logic written in Haxe 4.3.7 (`src/core/`) compiling to both Node.js (ESM & CJS) and PHP (>= 7.4).
- Deterministic canonical JSON serialization (`core.Canonical`) with lexicographical key ordering and strict test sorting.
- LOINC validation with Luhn mod-10 check digit verification (`core.Loinc`).
- Patient demographic sanitization (`core.Sanitizer`) normalizing gender to `M`/`F` and DOB to `YYYY-MM-DD`.
- Path traversal and routing safety validator (`core.OrderValidator`) prohibiting empty IDs and `/` across all operations.
- Dynamic test types and packages catalog caching (`core.Catalog`) with configurable TTL and unknown test policies (`reject`, `warn`, `off`).
- Circuit breaker and retry resilience guard (`core.Guard`) tripping open after 5 consecutive transient failures for 30s cooldown with single 500ms retry.
- Real-time webhook verification (`core.Webhook`) with constant-time shared-secret comparison (not HMAC) and automatic result resolution.
- `handleWebhook()` accepts the request in any framework shape: PHP without arguments, Laravel/Symfony, PSR-7 and CodeIgniter 4 requests; JS fetch `Request` and Node/Express/NestJS/Fastify requests; or a raw body (string, Buffer, parsed object) plus headers (object, `Headers`, `Map`, pairs, list values). The reply is `{status, headers, body}`, so it can be sent as-is by any framework.
- PHP `Client::serveWebhook()`: one call that reads the request, handles it and sends the reply (plain PHP, CodeIgniter 3).
- `reconcile({ since, until?, limit?, skip? })`: on-request recovery of results that never arrived. Lists COMPLETED orders created in a window, drops orders without `barcode_simrs`, fetches each result and gives final ones to the same `onResult` handler as the webhook. Returns `{checked, delivered, pending, skipped, failed, truncated}`. Never runs by itself.
- `ORDER_IN_PROGRESS` error (`retryable: true`) and a per-`order_id` lock (`IStorage.setIfAbsent`, key `inflight:<order_id>`, 30 s): a second concurrent `createOrder` for the same order is rejected at once instead of racing.
- Injectable storage: `storage` config option (JS: synchronous object with `get/set/delete/setIfAbsent`; PHP: `BridgeLisTamaConnection\Storage`). `health().storage` can be `custom`. Experimental until 1.0.
- `init` command: `npx bridgelis-tama-connection init` and `vendor/bin/bridgelis-tama-connection init` create an integration folder (template + README) once, never overwrite without `--force`, and print a webhook route for `--framework`.
- PHI-masking structured logger (`core.Log`) redacting credentials and obfuscating patient names, MRN, and birth dates.
- Isolated PHP namespace distribution using `-D php-prefix=BridgeLisTamaConnection` to guarantee zero collisions with SIMRS globals.
- Node.js SDK target in `targets/js/` with TypeScript typings (`index.d.ts`).
- PHP SDK target in `targets/php/` with Composer PSR-4 autoloading (`composer.json`).
- Unit tests (`tests/unit/`), contract tests against a mock LIS (`tests/contract/`), facade method sync and `init` end to end, on both Node.js and PHP.
- README: per-framework recipes (PHP native, Laravel, Symfony/Slim/CodeIgniter 4, Express, NestJS, Fastify, Next.js, Hono/Bun/Deno) and environment notes (edge, serverless, Apache `Authorization`).
- `LICENSE` (MIT).
