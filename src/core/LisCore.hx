/**
 * Public core entry point exposed to every language facade (LLD §2).
 * All methods take JSON strings and report one JSON outcome through a callback; exceptions
 * never cross this boundary, they are converted to LisError outcomes. The work itself lives in
 * Orders, Results, Reconciler, Health and Webhook; this class only wires them together.
 */
package core;

import platform.Platform.Platform;
import platform.Platform.IEnv;
import core.Config.ClientConfig;
import core.LisError.LisErrorHelper;
import core.Reconciler.ReconcileSkip;
import core.ResultDispatch.ResultHandler;
import core.Results.ResultCallback;
import core.Webhook.WebhookResponse;
import haxe.Json;

@:expose("LisCore")
class LisCore {
  private var outcomes:Outcomes;
  private var his:HisClient;
  private var orders:Orders;
  private var results:Results;
  private var reconciler:Reconciler;
  private var healthCheck:Health;
  private var webhook:Webhook;

  /**
   * Builds the core from config JSON (explicit values override env, LLD §9).
   *
   * @throws LisError VALIDATION_FAILED when config is invalid; the facade converts it to its
   *         native exception because a constructor cannot report through a callback.
   */
  public function new(configJson:String, platform:Platform) {
    var config = Config.resolve(configJson, platform.env);
    var log = new Log(platform.logger, config.logLevel);

    if (config.apiKey == null || config.apiKey.length == 0) {
      log.warn("config", "LIS_API_KEY is not set. Requests are unauthenticated.");
    }

    var guard = new Guard(platform, log);
    this.outcomes = new Outcomes(log);
    this.his = new HisClient(platform, config, guard, outcomes);
    var catalog = new Catalog(platform, config, guard, log);
    this.orders = new Orders(platform, config, log, his, catalog, outcomes);
    this.results = new Results(his, outcomes);
    this.reconciler = new Reconciler(platform, log, his, results);
    this.healthCheck = new Health(platform, config, log, guard, outcomes);
    this.webhook = new Webhook(platform, config, log);
  }

  /**
   * Resolves the storage location before the platform exists, with the same rules as the
   * constructor, so the storage namespace always uses the normalized baseUrl.
   *
   * @return JSON `{"baseUrl":..., "storageDir":...}`
   * @throws LisError VALIDATION_FAILED (for example when LIS_BASE_URL is missing)
   */
  public static function resolveStorageSettings(configJson:String, env:IEnv):String {
    var resolved = Config.resolve(configJson, env);
    return Json.stringify({baseUrl: resolved.baseUrl, storageDir: resolved.storageDir});
  }

  /**
   * Sends a new order or replaces an existing one (server upsert by `order_id`, HLD F1).
   * Identical resubmissions are skipped because every edit resets result approval. Only one
   * submission per order id runs at a time (HLD D13).
   *
   * @param orderJson  order in HIS V2 shape (snake_case fields)
   * @param cb         receipt `{status: SENT|UNCHANGED, order_id, lab_work_order_id,
   *                   lab_barcode, warnings}` or LisError VALIDATION_FAILED | UNKNOWN_TEST_CODE |
   *                   ORDER_IN_PROGRESS | LIS_REJECTED | AUTH_FAILED | BRIDGING_DISABLED |
   *                   RATE_LIMITED | LIS_UNAVAILABLE | LIS_SERVER_ERROR | INTERNAL
   */
  public function createOrder(orderJson:String, cb:String->Void):Void {
    outcomes.run("createOrder", cb, function(done) {
      orders.create(done, orderJson);
    });
  }

  /**
   * Permanently deletes an order in the LIS, whatever its status (hard delete, LLD §6.6).
   * Afterwards the dedup hash is removed so the same order can be sent again.
   *
   * @param cb  `{status: "SENT"}` or LisError VALIDATION_FAILED | NOT_FOUND | LIS_REJECTED |
   *            AUTH_FAILED | BRIDGING_DISABLED | RATE_LIMITED | LIS_UNAVAILABLE | ...
   */
  public function deleteOrder(orderId:String, cb:String->Void):Void {
    outcomes.run("deleteOrder", cb, function(done) {
      orders.delete(done, orderId);
    });
  }

  /**
   * Replaces the clinical notes of an existing order.
   *
   * @param cb  `{status: "SENT"}` or LisError VALIDATION_FAILED | NOT_FOUND | LIS_UNAVAILABLE
   */
  public function updateNotes(orderId:String, notes:String, cb:String->Void):Void {
    outcomes.run("updateNotes", cb, function(done) {
      orders.updateNotes(done, orderId, notes);
    });
  }

  /**
   * Reads one order (HISV2OrderDetailResponse).
   *
   * @param cb  order detail or LisError VALIDATION_FAILED | NOT_FOUND | LIS_UNAVAILABLE | ...
   */
  public function getOrder(orderId:String, cb:String->Void):Void {
    outcomes.run("getOrder", cb, function(done) {
      orders.get(done, orderId);
    });
  }

  /**
   * Lists orders; only the filters supported by the LIS are forwarded (LLD §4).
   *
   * @param filterJson  `{date, from, to, status, order_id, barcode, patient_mrn, search,
   *                    page, limit}`
   * @param cb          array of orders or LisError VALIDATION_FAILED | LIS_REJECTED | ...
   */
  public function listOrders(filterJson:String, cb:String->Void):Void {
    outcomes.run("listOrders", cb, function(done) {
      orders.list(done, filterJson);
    });
  }

  /**
   * Reads the latest result. A 404 means "not ready yet" on this endpoint (HLD F5).
   *
   * @param cb  `{state: "AVAILABLE", is_final, patient, order}` | `{state: "PENDING"}`
   *            or LisError VALIDATION_FAILED | AUTH_FAILED | LIS_UNAVAILABLE | ...
   */
  public function getResult(orderId:String, cb:String->Void):Void {
    outcomes.run("getResult", cb, function(done) {
      OrderValidator.validateOrderId(orderId);
      results.get(done, orderId);
    });
  }

  /**
   * Downloads the result PDF.
   *
   * @param cb  base64 PDF content or LisError VALIDATION_FAILED | NOT_FOUND |
   *            LIS_SERVER_ERROR | ...
   */
  public function getResultPdf(orderId:String, cb:String->Void):Void {
    outcomes.run("getResultPdf", cb, function(done) {
      OrderValidator.validateOrderId(orderId);
      results.getPdf(done, orderId);
    });
  }

  /**
   * Re-delivers results the SIMRS may have missed, on request only (HLD D12, LLD §7.4).
   * Lists COMPLETED orders created since `since`, drops non-SIMRS orders and the ones `skip`
   * excludes, and gives each final result to the same handler as the webhook.
   *
   * @param optionsJson  `{since, until?, limit?}`; `since` is required
   * @param skip         asks the SIMRS whether an order is already stored; may be null
   * @param handler      same as in handleWebhook; null makes the call fail
   * @param cb           report `{checked, delivered, pending, skipped, failed, truncated}` or
   *                     LisError VALIDATION_FAILED | AUTH_FAILED | BRIDGING_DISABLED |
   *                     LIS_UNAVAILABLE | ... (when the order list itself cannot be read)
   */
  public function reconcile(
    optionsJson:String,
    skip:Null<ReconcileSkip>,
    handler:Null<ResultHandler>,
    cb:String->Void
  ):Void {
    outcomes.run("reconcile", cb, function(done) {
      reconciler.start(done, optionsJson, skip, handler);
    });
  }

  /**
   * Reads the LIS test type catalog.
   *
   * @param cb  array of test types or LisError AUTH_FAILED | LIS_UNAVAILABLE | ...
   */
  public function getTestTypes(cb:String->Void):Void {
    outcomes.run("getTestTypes", cb, function(done) {
      his.fetchData(done, "/test-types");
    });
  }

  /**
   * Reads the LIS package catalog.
   *
   * @param cb  array of packages or LisError AUTH_FAILED | LIS_UNAVAILABLE | ...
   */
  public function getPackages(cb:String->Void):Void {
    outcomes.run("getPackages", cb, function(done) {
      his.fetchData(done, "/packages");
    });
  }

  /**
   * Reads one package by code.
   *
   * @param cb  package or LisError VALIDATION_FAILED | NOT_FOUND | LIS_UNAVAILABLE | ...
   */
  public function getPackage(code:String, cb:String->Void):Void {
    outcomes.run("getPackage", cb, function(done) {
      if (code == null || StringTools.trim(code).length == 0) {
        throw LisErrorHelper.validationFailed("Package code is required.", "code");
      }
      his.fetchData(done, "/packages/" + HisApi.encodePathParam(code));
    });
  }

  /**
   * Reads the LIS users (doctors and analysts).
   *
   * @param cb  array of users or LisError AUTH_FAILED | LIS_UNAVAILABLE | ...
   */
  public function getUsers(cb:String->Void):Void {
    outcomes.run("getUsers", cb, function(done) {
      his.fetchData(done, "/users");
    });
  }

  /**
   * Handles a result webhook from the LIS: verify secret, fetch the result, call the handler.
   * Any failure answers non-2xx so the LIS marks the delivery FAILED and allows Resend (HLD F10).
   *
   * @param handler  receives the event JSON and must call `done(null)` or `done(errorMessage)`
   * @param headersJson  JSON object of request headers; values may be strings or string lists
   * @param cb       always ok: `{status, headers, body}` to send back as the HTTP response
   */
  public function handleWebhook(
    body:String,
    headersJson:String,
    handler:ResultHandler,
    cb:String->Void
  ):Void {
    outcomes.run("handleWebhook", cb, function(done) {
      var fetchResultFn = function(orderId:String, next:ResultCallback) {
        results.fetch(done, orderId, next);
      };
      webhook.handle(body, headersJson, fetchResultFn, handler, function(res:WebhookResponse) {
        // Headers travel with the reply so any framework can send it as-is
        // (for example `new Response(r.body, r)` or `response($r['body'], $r['status'], ...)`).
        Outcomes.ok(done, {
          status: res.status,
          headers: {"Content-Type": "application/json"},
          body: res.body
        });
      });
    });
  }

  /**
   * Reports local state and LIS reachability (LLD §10). Never fails because the LIS is down.
   *
   * @param cb  `{version, baseUrl, apiKeySet, webhookSecretSet, storage, breaker, catalogAgeSec,
   *            lisReachable}`
   */
  public function health(cb:String->Void):Void {
    outcomes.run("health", cb, function(done) {
      healthCheck.check(done);
    });
  }
}
