/**
 * `reconcile()`: on request, re-delivers results the SIMRS may have missed (HLD D12).
 * It lists COMPLETED orders created in a time window, fetches each result and gives final ones
 * to the same handler as the webhook. It never runs by itself and keeps no record of what the
 * SIMRS already has (HLD D11): the caller's `skip` and an idempotent handler cover that.
 */
package core;

import platform.Platform.Platform;
import core.LisError.LisError;
import core.LisError.LisErrorHelper;
import core.ResultDispatch.ResultHandler;
import core.Results.ResultState;
import haxe.Json;

/**
 * Asks the caller whether an order is already stored. The answer is `(true, null)` to skip it,
 * `(false, null)` to fetch it, or `(false, message)` when the check itself failed: the order is
 * then reported in `failed` and not fetched.
 */
typedef ReconcileSkip = (orderId:String, answer:(skip:Bool, error:Null<String>)->Void) -> Void;

typedef ReconcileFailure = {
  order_id:String,
  error:String
};

/**
 * `checked`: results fetched from the LIS. `delivered`: final results the handler accepted.
 * `pending`: not ready or not final yet. `skipped`: rows the caller's `skip` excluded.
 * `truncated`: stopped early (limit, page cap, LIS down), so the window may hold more rows.
 */
typedef ReconcileReport = {
  checked:Int,
  delivered:Int,
  pending:Int,
  skipped:Int,
  failed:Array<ReconcileFailure>,
  truncated:Bool
};

typedef ReconcileOptions = {
  since:String,
  ?until:String,
  ?limit:Int
};

class Reconciler {
  // Default and upper bound for `limit`; the LIS accepts at most 1000 rows per page.
  public static inline var DEFAULT_LIMIT:Int = 100;
  public static inline var MAX_LIMIT:Int = 1000;
  // Every row costs the LIS a full load of patient, specimens and requests, so pages stay small.

  // Stops a LIS that ignores `page` and keeps returning full pages.
  public static inline var MAX_PAGES:Int = 50;

  private var platform:Platform;
  private var log:Log;
  private var his:HisClient;
  private var results:Results;

  public function new(platform:Platform, log:Log, his:HisClient, results:Results) {
    this.platform = platform;
    this.log = log;
    this.his = his;
    this.results = results;
  }

  /**
   * Starts a run. Throws LisError VALIDATION_FAILED for bad options or a missing handler; the
   * caller's `run` converts that to an outcome.
   */
  public function start(
    done:String->Void,
    optionsJson:String,
    skip:Null<ReconcileSkip>,
    handler:Null<ResultHandler>
  ):Void {
    var options = parseOptions(optionsJson);
    if (handler == null) {
      throw LisErrorHelper.validationFailed(
        "reconcile() needs an onResult handler. Register one first.",
        "handler"
      );
    }
    new ReconcileRun(platform, log, his, results, options, skip, handler, done).pump();
  }

  private static function parseOptions(optionsJson:String):ReconcileOptions {
    var raw:Dynamic = null;
    try {
      raw = Json.parse(optionsJson);
    } catch (e:Dynamic) {
      throw LisErrorHelper.validationFailed("Invalid reconcile options JSON.", "options");
    }
    var since:Dynamic = raw != null ? Reflect.field(raw, "since") : null;
    if (!Std.isOfType(since, String) || StringTools.trim(since).length == 0) {
      throw LisErrorHelper.validationFailed(
        "reconcile() needs `since`, for example '2026-11-04'. It limits how far back to look.",
        "since"
      );
    }
    var until:Dynamic = Reflect.field(raw, "until");
    var limit:Dynamic = Reflect.field(raw, "limit");
    if (limit != null && (!Std.isOfType(limit, Int) || limit < 1 || limit > MAX_LIMIT)) {
      throw LisErrorHelper.validationFailed(
        "`limit` must be a whole number from 1 to " + MAX_LIMIT + ".",
        "limit"
      );
    }
    return {
      since: StringTools.trim(since),
      until: Std.isOfType(until, String) ? until : null,
      limit: limit != null ? limit : DEFAULT_LIMIT
    };
  }
}

/** State of one reconcile call: walks pages and rows without growing the call stack. */
private class ReconcileRun {
  private var platform:Platform;
  private var log:Log;
  private var his:HisClient;
  private var results:Results;
  private var options:ReconcileOptions;
  private var skip:Null<ReconcileSkip>;
  private var handler:ResultHandler;
  private var done:String->Void;

  private var report:ReconcileReport = {
    checked: 0,
    delivered: 0,
    pending: 0,
    skipped: 0,
    failed: [],
    truncated: false
  };
  private var rows:Array<Dynamic> = [];
  private var rowIndex:Int = 0;
  private var page:Int = 0;
  private var lastPageFull:Bool = false;
  private var finished:Bool = false;
  private var pumping:Bool = false;
  private var again:Bool = false;

  public function new(
    platform:Platform,
    log:Log,
    his:HisClient,
    results:Results,
    options:ReconcileOptions,
    skip:Null<ReconcileSkip>,
    handler:ResultHandler,
    done:String->Void
  ) {
    this.platform = platform;
    this.log = log;
    this.his = his;
    this.results = results;
    this.options = options;
    this.skip = skip;
    this.handler = handler;
    this.done = done;
  }

  /**
   * Runs steps until one has to wait. A step that finishes synchronously (PHP, or a cached
   * answer) asks for the next one through `again`, so 1000 rows do not mean 1000 nested calls.
   */
  public function pump():Void {
    if (pumping) {
      again = true;
      return;
    }
    pumping = true;
    do {
      again = false;
      step();
    } while (again);
    pumping = false;
  }

  private function step():Void {
    if (finished) {
      return;
    }
    if (rowIndex < rows.length) {
      processRow(rows[rowIndex++]);
      return;
    }
    if (page > 0 && !lastPageFull) {
      finish(false);
      return;
    }
    if (report.checked >= options.limit || page >= Reconciler.MAX_PAGES) {
      finish(true);
      return;
    }
    loadNextPage();
  }

  private function pageSize():Int {
    return options.limit < Reconciler.DEFAULT_LIMIT ? options.limit : Reconciler.DEFAULT_LIMIT;
  }

  private function loadNextPage():Void {
    var nextPage = page + 1;
    var filter:Dynamic = {
      from: options.since,
      status: "COMPLETED",
      page: nextPage,
      limit: pageSize()
    };
    if (options.until != null) {
      Reflect.setField(filter, "to", options.until);
    }
    var path = "/order" + HisApi.buildOrderQueryString(Json.stringify(filter));
    his.send(done, "GET", path, null, function(err, envelope) {
      if (err != null) {
        finishWithError(err);
        return;
      }
      var data:Dynamic = envelope.data;
      rows = Std.isOfType(data, Array) ? data : [];
      rowIndex = 0;
      page = nextPage;
      lastPageFull = rows.length >= pageSize();
      pump();
    });
  }

  private function processRow(row:Dynamic):Void {
    var orderId:Dynamic = Reflect.field(row, "order_id");
    var simrsBarcode:Dynamic = Reflect.field(row, "barcode_simrs");
    // Orders created directly in the LIS have no SIMRS barcode; they are not ours to deliver.
    var isSimrsOrder = Std.isOfType(simrsBarcode, String) && simrsBarcode.length > 0;
    if (!isSimrsOrder || !Std.isOfType(orderId, String) || orderId.length == 0) {
      pump();
      return;
    }
    if (report.checked >= options.limit) {
      finish(true);
      return;
    }
    if (skip == null) {
      fetchAndDeliver(orderId);
      return;
    }
    skip(orderId, function(shouldSkip:Bool, skipError:Null<String>) {
      if (skipError != null) {
        recordFailure(orderId, "skip check failed: " + skipError);
        pump();
        return;
      }
      if (shouldSkip) {
        report.skipped++;
        pump();
        return;
      }
      fetchAndDeliver(orderId);
    });
  }

  private function fetchAndDeliver(orderId:String):Void {
    report.checked++;
    results.fetch(done, orderId, function(err, result) {
      if (err != null) {
        recordFailure(orderId, err.message);
        if (isFatal(err)) {
          finish(true);
          return;
        }
        pump();
        return;
      }
      if (result.state != "AVAILABLE" || result.is_final != true) {
        report.pending++;
        pump();
        return;
      }
      deliver(orderId, result);
    });
  }

  private function deliver(orderId:String, result:ResultState):Void {
    var event = ResultDispatch.buildEvent(orderId, result, platform.clock.isoString());
    ResultDispatch.run(handler, event, function(handlerErr) {
      if (handlerErr != null) {
        recordFailure(orderId, handlerErr);
      } else {
        report.delivered++;
      }
      pump();
    });
  }

  private function recordFailure(orderId:String, message:String):Void {
    log.warn("reconcile", "Could not deliver result.", {orderId: orderId, error: message});
    report.failed.push({order_id: orderId, error: message});
  }

  /** Every later row would fail the same way, so stop instead of failing N more times. */
  private static function isFatal(err:LisError):Bool {
    var details:Dynamic = err.details;
    var breakerOpen = details != null && Reflect.field(details, "breakerOpen") == true;
    return breakerOpen
      || err.code == LisErrorHelper.AUTH_FAILED
      || err.code == LisErrorHelper.BRIDGING_DISABLED;
  }

  private function finish(truncated:Bool):Void {
    if (finished) {
      return;
    }
    finished = true;
    report.truncated = truncated;
    Outcomes.ok(done, report);
  }

  private function finishWithError(err:LisError):Void {
    if (finished) {
      return;
    }
    finished = true;
    Outcomes.error(done, err);
  }
}
