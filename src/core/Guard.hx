/**
 * Guard: circuit breaker, one retry for transient errors, and 429 handling (LLD §8).
 * Protects both client and LIS server from cascade failures and request floods.
 */
package core;

import platform.Platform.Platform;
import platform.Platform.HttpRequest;
import platform.Platform.HttpResponse;
import core.LisError.LisErrorHelper;
import core.LisError.LisError;
import haxe.Json;

typedef GuardCallback = (err:Null<LisError>, res:Null<HttpResponse>) -> Void;

typedef CircuitBreakerState = {
  fails:Int,
  openUntil:Float
};

class Guard {
  public static inline var BREAKER_KEY:String = "cb";
  public static inline var BREAKER_FAILURE_LIMIT:Int = 5;
  public static inline var BREAKER_COOLDOWN_MS:Float = 30000.0;
  public static inline var RETRY_DELAY_MS:Int = 500;

  private var platform:Platform;
  private var log:Log;

  public function new(platform:Platform, log:Log) {
    this.platform = platform;
    this.log = log;
  }

  public function call(req:HttpRequest, cb:GuardCallback):Void {
    var now = platform.clock.nowMs();
    var cbState = getBreakerState();

    if (cbState.openUntil > now) {
      log.warn("guard", "Circuit breaker OPEN. Failing fast without a request.", {
        openUntil: cbState.openUntil
      });
      cb(LisErrorHelper.unavailable("LIS server unavailable (circuit breaker open).", true), null);
      return;
    }

    platform.http.request(req, function(res1) {
      if (isTransient(res1)) {
        retryTransient(req, cbState, cb);
      } else {
        handleNormalResponse(cbState, res1, cb);
      }
    });
  }

  private function retryTransient(
    req:HttpRequest,
    cbState:CircuitBreakerState,
    cb:GuardCallback
  ):Void {
    log.warn("guard", "Transient failure on first attempt. Retrying in 500ms...");
    platform.clock.sleep(RETRY_DELAY_MS, function() {
      platform.http.request(req, function(res2) {
        if (isTransient(res2)) {
          handleTransientFailure(cbState, res2, cb);
        } else {
          handleNormalResponse(cbState, res2, cb);
        }
      });
    });
  }

  private function isTransient(res:HttpResponse):Bool {
    if (res.networkError != null && res.networkError.length > 0) {
      return true;
    }
    if (res.timedOut == true) {
      return true;
    }
    if (res.status == 502 || res.status == 503 || res.status == 504) {
      return true;
    }
    return false;
  }

  private function handleTransientFailure(
    cbState:CircuitBreakerState,
    res:HttpResponse,
    cb:GuardCallback
  ):Void {
    var now = platform.clock.nowMs();
    cbState.fails++;
    var reqId = getRequestId(res);

    if (cbState.fails >= BREAKER_FAILURE_LIMIT) {
      cbState.openUntil = now + BREAKER_COOLDOWN_MS;
      saveBreakerState(cbState);
      log.error("guard", "Circuit breaker tripped OPEN for 30s.", {
        fails: cbState.fails,
        openUntil: cbState.openUntil,
        requestId: reqId
      });
      var message = "LIS unavailable. Circuit breaker tripped open.";
      var tripped = LisErrorHelper.unavailable(message, true);
      cb(tripped, null);
    } else {
      saveBreakerState(cbState);
      var errMsg = res.networkError != null ? res.networkError : "HTTP " + res.status;
      cb(LisErrorHelper.unavailable("LIS server unavailable: " + errMsg, false), null);
    }
  }

  private function handleNormalResponse(
    cbState:CircuitBreakerState,
    res:HttpResponse,
    cb:GuardCallback
  ):Void {
    if (cbState.fails > 0 || cbState.openUntil > 0) {
      saveBreakerState({fails: 0, openUntil: 0.0});
    }

    if (res.status == 429) {
      var retryAfter = 1;
      if (res.headers != null && res.headers.exists("retry-after")) {
        var parsed = Std.parseInt(res.headers.get("retry-after"));
        if (parsed != null && parsed > 0) {
          retryAfter = parsed;
        }
      }
      var reqId = getRequestId(res);
      var details = {retryAfterSec: retryAfter};
      cb(LisErrorHelper.fromHttpStatus(429, "Rate limit exceeded.", reqId, details), null);
      return;
    }

    cb(null, res);
  }

  public function getBreakerState():CircuitBreakerState {
    var raw = platform.storage.get(BREAKER_KEY);
    if (raw == null || raw.length == 0) {
      return {fails: 0, openUntil: 0.0};
    }
    try {
      var parsed:Dynamic = Json.parse(raw);
      var fails:Int = Reflect.field(parsed, "fails");
      var openUntil:Float = Reflect.field(parsed, "openUntil");
      return {
        fails: fails != null ? fails : 0,
        openUntil: openUntil != null ? openUntil : 0.0
      };
    } catch (_:Dynamic) {
      // Corrupt state treated as initial reset state
      return {fails: 0, openUntil: 0.0};
    }
  }

  public static function getRequestId(res:HttpResponse):Null<String> {
    if (res == null || res.headers == null) {
      return null;
    }
    if (res.headers.exists("x-request-id")) {
      return res.headers.get("x-request-id");
    }
    return null;
  }

  private function saveBreakerState(state:CircuitBreakerState):Void {
    try {
      platform.storage.set(BREAKER_KEY, Json.stringify(state), 0);
    } catch (e:Dynamic) {
      log.warn("guard", "Failed to persist circuit breaker state to storage: " + Std.string(e));
    }
  }
}
