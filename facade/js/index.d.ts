/**
 * TypeScript definitions for bridgelis-tama-connection.
 */

export interface PatientData {
  medical_record_number: string;
  first_name: string;
  last_name?: string;
  date_of_birth: string;
  sex: 'M' | 'F' | string;
  phone_number?: string;
  address?: string;
  id_card_number?: string;
}

export interface TestOrderItem {
  loinc_code?: string;
  code?: string;
  id?: number | string;
  name?: string;
}

export interface PackageOrderItem {
  loinc_code?: string;
  code?: string;
  id?: number | string;
  name?: string;
}

export interface LisOrderData {
  order_id: string;
  tests?: TestOrderItem[];
  packages?: PackageOrderItem[];
  clinical_notes?: string;
  priority?: string;
}

export interface OrderRequest {
  patient: PatientData;
  lis_order: LisOrderData;
}

export interface SanitizerWarning {
  code: string;
  field: string;
  from: string;
  to: string;
}

export interface OrderReceipt {
  status: 'SENT' | 'UNCHANGED';
  order_id: string;
  lab_work_order_id: number | null;
  lab_barcode: string | null;
  warnings: SanitizerWarning[];
}

/** Order as returned by LIS `GET /order/:id` (verified against a real LIS). Results are not here; use getResult(). */
export interface OrderDetail {
  id: number;
  order_id: string;
  barcode: string;
  barcode_simrs: string;
  /** `NEW` until results are approved, then `COMPLETED`. */
  status: string;
  work_order_status?: string;
  received_date_time?: string;
  patient?: PatientData;
  tests?: Array<{ code: string; name: string }>;
  specimens?: any[];
  total_request?: number;
  [key: string]: any;
}

/** One result row, same field names as the LIS HIS V2 API. */
export interface TestResultItem {
  test_code: string;
  test_name: string;
  package_code?: string;
  package_name?: string;
  status: 'Preliminary' | 'Final' | string;
  /** The measured value, as text (for example `"13.5"`). */
  result?: string;
  unit?: string;
  reference_range?: string;
  /** For example `N`, `H`, `HH`, `L`, `LL`; may be empty. */
  abnormal_flag?: string;
  is_critical?: boolean;
  validated_at?: string;
  [key: string]: any;
}

export interface PersonRef {
  id: number;
  name?: string;
}

/** The `order` part of a LIS result (from getResult() and the webhook event). */
export interface ResultOrder {
  order_id: string;
  status: string;
  order_date_time?: string;
  received_date_time?: string;
  validation_date_time?: string;
  ordering_physician?: PersonRef | null;
  attending_physician?: PersonRef | null;
  technologist?: PersonRef | null;
  validator?: PersonRef | null;
  results?: TestResultItem[];
  [key: string]: any;
}

export interface ResultResponse {
  state: 'AVAILABLE' | 'PENDING';
  is_final?: boolean;
  patient?: PatientData;
  order?: ResultOrder;
}

export interface ResultEvent {
  order_id: string;
  is_final: boolean;
  received_at: string;
  patient: PatientData;
  order: ResultOrder;
}

/**
 * HTTP reply for the LIS. Send it with your framework, for example
 * `new Response(r.body, r)` or `res.status(r.status).set(r.headers).send(r.body)`.
 */
export interface WebhookResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/** Header containers from any framework; values may be lists (first value is used). */
export type WebhookHeaders =
  | Record<string, string | string[] | number | undefined | null>
  | Iterable<[string, string]>
  | { forEach(callback: (value: string, name: string) => void): void };

/** Raw webhook body: as received, or already parsed by a body parser. */
export type WebhookBody = string | Uint8Array | Record<string, unknown>;

/** fetch-style request (Next.js route handlers, Hono, Bun, Deno, Remix). */
export interface FetchLikeRequest {
  text(): Promise<string>;
  headers: { forEach(callback: (value: string, name: string) => void): void };
}

/** Node-style request (http, Express, NestJS, Fastify, Koa). */
export interface NodeLikeRequest {
  headers: Record<string, string | string[] | undefined>;
  body?: unknown;
}

export interface HealthStatus {
  version: string;
  baseUrl: string;
  apiKeySet: boolean;
  webhookSecretSet: boolean;
  /** `custom` when the application injected its own storage. */
  storage: 'file' | 'memory' | 'custom';
  breaker: {
    open: boolean;
    fails: number;
  };
  catalogAgeSec: number;
  lisReachable: boolean;
}

/**
 * Storage the application can inject instead of the built-in file storage (for example a shared
 * folder or a database). All calls are synchronous. Experimental until 1.0: the method set may
 * still change. Keys are short strings; values are short strings (hashes and markers, never
 * patient data). `ttlSec` of 0 means "never expires".
 */
export interface LisStorage {
  get(key: string): string | null | undefined;
  set(key: string, value: string, ttlSec: number): void;
  delete(key: string): void;
  /**
   * Stores the value only when the key is absent or expired, atomically.
   * Returns `true` when this call stored it, `false` when a live value already exists.
   */
  setIfAbsent(key: string, value: string, ttlSec: number): boolean;
}

/** Options of {@link LisClient.reconcile}. */
export interface ReconcileOptions {
  /**
   * Required. Start of the window, for example `'2026-11-04'` or `'2026-11-04 08:00:00'`.
   * The LIS filters on the time the order was CREATED, not on when it was approved.
   */
  since: string;
  /** End of the window. Default: now. */
  until?: string;
  /** Most results to fetch in one call, 1 to 1000. Default 100. Skipped orders do not count. */
  limit?: number;
  /**
   * Return `true` when your database already holds this order's result, so it is not fetched.
   * May return a promise. If it throws, that order is listed in `failed` and not fetched.
   */
  skip?: (orderId: string) => boolean | Promise<boolean>;
}

export interface ReconcileReport {
  /** Results fetched from the LIS. */
  checked: number;
  /** Final results your `onResult` handler accepted. */
  delivered: number;
  /** Results not ready or not final yet. */
  pending: number;
  /** Orders excluded by `skip`. */
  skipped: number;
  failed: Array<{ order_id: string; error: string }>;
  /** `true`: stopped early (limit, LIS unavailable, bad key). Call again, with `skip`. */
  truncated: boolean;
}

/** Every field is optional and overrides its environment variable. */
export interface ClientConfig {
  /** LIS server address, for example `http://192.168.1.10:8322`. Env: `LIS_BASE_URL` (required). */
  baseUrl?: string;
  /** Same as SimrsApiKey in the LIS settings. Env: `LIS_API_KEY`. */
  apiKey?: string;
  webhook?: {
    /** Same value as the webhook auth in LIS. Env: `LIS_WEBHOOK_SECRET`. */
    secret?: string;
    /** Header that carries the secret. Default `X-API-Key`, or `Authorization` for bearer. Env: `LIS_WEBHOOK_SECRET_HEADER`. */
    secretHeader?: string;
  };
  catalog?: {
    /** What to do with a test code unknown to LIS: `reject` (default), `warn`, or `off`. Env: `LIS_UNKNOWN_TEST_POLICY`. */
    unknownTestPolicy?: 'reject' | 'warn' | 'off';
    /** How long the test catalog is cached, in seconds. */
    ttlSec?: number;
  };
  /** Folder for the small cache (order hash, connection state, catalog). Keep it outside the public web folder. Env: `LIS_STORAGE_DIR`. */
  storageDir?: string;
  /** Request timeout in ms. Default 8000. Env: `LIS_TIMEOUT_MS`. */
  timeoutMs?: number;
  /** Connect timeout in ms. Default 3000. Env: `LIS_CONNECT_TIMEOUT_MS`. */
  connectTimeoutMs?: number;
  /** Default `info`. Env: `LIS_LOG_LEVEL`. */
  logLevel?: 'debug' | 'info' | 'warn' | 'error';
  /** Extra mapping from your sex values to `M`/`F`, for example `{ LK: 'M' }`. */
  sexMap?: Record<string, string>;
  /** Receives library logs. Patient names and ID numbers are already masked. */
  logger?: (level: string, msg: string, ctx?: any) => void;
  /** Replaces the built-in file storage. Needed when several servers share one LIS client. */
  storage?: LisStorage;
}

/** Error thrown by every {@link LisClient} method. */
export class LisError extends Error {
  /** Stable error code, for example `BRIDGING_DISABLED`. Use it for `switch`, not `message`. */
  code: string;
  /** `true`: LIS is unavailable, trying again later is fine. `false`: fix the data or configuration first. */
  retryable: boolean;
  /** HTTP status from LIS, when the error came from a LIS reply. */
  httpStatus?: number;
  /** Request id from LIS. Give it to the LIS team when reporting a problem. */
  requestId?: string;
  /** Extra detail from LIS or from validation. */
  details?: any;
  /** Name of the invalid input field, for validation errors. */
  field?: string;

  constructor(
    message: string,
    code: string,
    retryable: boolean,
    httpStatus?: number,
    requestId?: string,
    details?: any,
    field?: string
  );
}

/**
 * Client for LIS Tama. Every method rejects with {@link LisError}.
 * Check `error.retryable`: `true` means LIS is unavailable (try again later),
 * `false` means the data or the configuration must be fixed first.
 *
 * @example
 * import { LisClient, LisError } from 'bridgelis-tama-connection';
 * const lis = new LisClient(); // reads LIS_BASE_URL, LIS_API_KEY, ... from process.env
 */
export class LisClient {
  /**
   * @param config Optional. Overrides environment variables (`LIS_BASE_URL`, `LIS_API_KEY`,
   *   `LIS_WEBHOOK_SECRET`, `LIS_STORAGE_DIR`, ...). Omit it to read everything from `process.env`.
   * @param platform Internal. Leave empty.
   */
  constructor(config?: ClientConfig, platform?: any);

  /**
   * Registers the handler that receives lab results sent by LIS through the webhook.
   * Call it once at startup, before the webhook endpoint receives traffic.
   * The same result can arrive more than once (Resend, re-approval after revision),
   * so save it with an upsert per `(order_id, test_code)`, never a plain insert.
   * The webhook only fires after the result is finished and approved in LIS.
   *
   * @param handler Called for each valid webhook. If it throws, LIS gets an error reply
   *   and records the delivery as FAILED, so the lab operator can press "Resend".
   */
  onResult(handler: (event: ResultEvent) => void | Promise<void>): void;

  /**
   * Creates an order in LIS, or replaces it when `lis_order.order_id` already exists.
   * Before sending, the library normalizes sex (`L`/`P` becomes `M`/`F`) and birth date,
   * and checks every test code against the LIS catalog.
   *
   * - Identical resubmission is not sent again and returns `status: 'UNCHANGED'`.
   * - Changing an existing order replaces its tests and patient data. If auto-approve is
   *   off in LIS, result approval is reset to "not approved". `warnings` then contains `ORDER_RESUBMITTED`.
   * - Field names use snake_case, same as the HIS V2 API. `order_id` must not contain `/`.
   *
   * @param order `patient` data plus `lis_order` (`order_id` and `tests` and/or `packages`).
   * @returns Receipt with `status` (`SENT` or `UNCHANGED`), LIS ids, and sanitizer `warnings`.
   * - Only one `createOrder()` per `order_id` runs at a time. A second one that starts while
   *   the first is still sending fails at once with `ORDER_IN_PROGRESS` (`retryable: true`).
   *
   * @throws {LisError} Unknown test code (when policy is `reject`), invalid data (`retryable: false`),
   *   `ORDER_IN_PROGRESS`, or LIS unavailable (`retryable: true`).
   *
   * @example
   * await lis.createOrder({
   *   patient: {
   *     medical_record_number: 'RM-001234',
   *     first_name: 'Budi',
   *     date_of_birth: '1990-01-31',
   *     sex: 'L',
   *   },
   *   lis_order: { order_id: 'ORD-001', tests: [{ code: 'HB' }] },
   * });
   */
  createOrder(order: OrderRequest): Promise<OrderReceipt>;

  /**
   * PERMANENTLY deletes an order from LIS, with its samples and test list, whatever its status,
   * even when the result is already out or approved. This cannot be undone.
   * To cancel only some tests, send the order again with `createOrder()` and the new test list.
   *
   * @param orderId The `order_id` used in `createOrder()`.
   * @throws {LisError} Order not found, or LIS unavailable.
   */
  deleteOrder(orderId: string): Promise<{ status: string }>;

  /**
   * Updates the clinical notes of an existing order.
   *
   * @param orderId The `order_id` used in `createOrder()`.
   * @param notes New notes. They replace the old ones.
   * @throws {LisError} Order not found, or LIS unavailable.
   */
  updateNotes(orderId: string, notes: string): Promise<{ status: string }>;

  /**
   * Gets one order from LIS, including barcode and status.
   *
   * @param orderId The `order_id` used in `createOrder()`.
   * @throws {LisError} Order not found, or LIS unavailable.
   */
  getOrder(orderId: string): Promise<OrderDetail>;

  /**
   * Lists orders in LIS.
   *
   * @param filter Optional query filter, passed to the LIS orders endpoint as is.
   */
  listOrders(filter?: Record<string, any>): Promise<any>;

  /**
   * Gets the result of an order. Does not throw when the result is not ready:
   * it returns `state: 'PENDING'`. When `state` is `'AVAILABLE'`, read `order.results`.
   * Prefer {@link LisClient.onResult} for normal use; there is no polling inside the library.
   *
   * @param orderId The `order_id` used in `createOrder()`.
   * @throws {LisError} Order not found, or LIS unavailable.
   */
  getResult(orderId: string): Promise<ResultResponse>;

  /**
   * Downloads the result as a PDF.
   *
   * @param orderId The `order_id` used in `createOrder()`.
   * @returns PDF file content. At runtime this is a Node `Buffer` (a `Uint8Array`),
   *   so it can be passed to `fs.writeFile` or sent as a response body directly.
   * @throws {LisError} Result not available, or LIS unavailable.
   */
  getResultPdf(orderId: string): Promise<Uint8Array>;

  /** Lists the tests defined in LIS. The library also uses this list to check test codes (cached). */
  getTestTypes(): Promise<any[]>;

  /** Lists the test packages defined in LIS. */
  getPackages(): Promise<any[]>;

  /**
   * Gets one test package, including its tests.
   *
   * @param code Package code in LIS.
   * @throws {LisError} Package not found, or LIS unavailable.
   */
  getPackage(code: string): Promise<any>;

  /** Lists doctors and analysts registered in LIS. */
  getUsers(): Promise<any[]>;

  /**
   * Handles one webhook call from LIS: checks the secret, parses the body, and runs the
   * {@link LisClient.onResult} handler. Always resolves with a reply; it never throws for bad requests.
   * Send the reply with your framework.
   *
   * Pass the framework's request object, or a raw body plus headers.
   * Works with Express, NestJS, Fastify, Koa, Next.js, Hono, Bun, and Deno.
   * Edge runtimes (Cloudflare Workers, Next.js `runtime = 'edge'`) are not supported.
   *
   * @example
   * // Express
   * app.post('/lis/webhook', async (req, res) => {
   *   const r = await lis.handleWebhook(req);
   *   res.status(r.status).set(r.headers).send(r.body);
   * });
   * // Fetch style (Next.js route handler, Hono, Bun, Deno)
   * export const POST = async (request: Request) => {
   *   const r = await lis.handleWebhook(request);
   *   return new Response(r.body, r);
   * };
   */
  handleWebhook(request: FetchLikeRequest | NodeLikeRequest): Promise<WebhookResponse>;
  handleWebhook(body: WebhookBody, headers: WebhookHeaders): Promise<WebhookResponse>;

  /**
   * Recovers results that never arrived (webhook failed and nobody pressed Resend). Call it from
   * your own cron job or an admin button; the library never runs it by itself.
   *
   * It lists the COMPLETED orders created in the window, fetches each result, and gives every
   * final one to the {@link LisClient.onResult} handler, the same handler as the webhook. Orders
   * created directly in LIS (not sent by your SIMRS) are ignored.
   *
   * Limits to know:
   * - The window is the order's creation time. An old order that was approved or revised later is
   *   only found if `since` reaches back to its creation date.
   * - LIS gives no "changed since" filter, so revised results are recovered by fetching every
   *   order in the window again (one request each). Use `skip` for orders you already hold, and a
   *   narrow `since`.
   * - Your handler must upsert: the same result can arrive from the webhook and from here.
   *
   * @throws {LisError} `VALIDATION_FAILED` (no `since`, no `onResult` handler), or the order list
   *   itself could not be read (`AUTH_FAILED`, `LIS_UNAVAILABLE`, ...). A single failing order
   *   never throws; it is listed in `failed`.
   *
   * @example
   * lis.onResult(async (event) => { await db.upsertLabResult(event); });
   * const report = await lis.reconcile({
   *   since: '2026-11-04',
   *   skip: (orderId) => db.hasFinalResult(orderId),
   * });
   */
  reconcile(options: ReconcileOptions): Promise<ReconcileReport>;

  /**
   * Checks the configuration and the connection to LIS. Safe to call at startup or from a
   * monitoring endpoint. Secret values are never returned, only whether they are set
   * (`apiKeySet`, `webhookSecretSet`). `lisReachable` is `false` when LIS cannot be contacted.
   */
  health(): Promise<HealthStatus>;
}

