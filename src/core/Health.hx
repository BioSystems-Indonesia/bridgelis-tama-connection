/**
 * Reports local state and LIS reachability (LLD §10). Never fails because the LIS is down.
 */
package core;

import platform.Platform.Platform;
import platform.Platform.HttpRequest;
import core.Config.ClientConfig;
import haxe.Json;

typedef HealthReport = {
  version:String,
  baseUrl:String,
  apiKeySet:Bool,
  webhookSecretSet:Bool,
  storage:String,
  breaker:{open:Bool, fails:Int},
  catalogAgeSec:Int,
  lisReachable:Bool
};

class Health {
  // health() ping is a quick reachability probe, so it uses shorter timeouts than real calls.
  static inline var PING_TIMEOUT_MS:Int = 3000;
  static inline var PING_CONNECT_TIMEOUT_MS:Int = 2000;

  private var platform:Platform;
  private var config:ClientConfig;
  private var log:Log;
  private var guard:Guard;
  private var outcomes:Outcomes;

  public function new(
    platform:Platform,
    config:ClientConfig,
    log:Log,
    guard:Guard,
    outcomes:Outcomes
  ) {
    this.platform = platform;
    this.config = config;
    this.log = log;
    this.guard = guard;
    this.outcomes = outcomes;
  }

  public function check(done:String->Void):Void {
    var req:HttpRequest = {
      method: "GET",
      url: config.baseUrl + "/api/v1/ping",
      headers: HisApi.createHeaders(config.apiKey, platform.name),
      timeoutMs: PING_TIMEOUT_MS,
      connectTimeoutMs: PING_CONNECT_TIMEOUT_MS
    };
    platform.http.request(req, function(res) {
      outcomes.protect(done, "health", function() {
        Outcomes.ok(done, buildReport(res.status == 200));
      });
    });
  }

  private function buildReport(lisReachable:Bool):HealthReport {
    var now = platform.clock.nowMs();
    var breaker = guard.getBreakerState();
    return {
      version: HisApi.VERSION,
      baseUrl: config.baseUrl,
      apiKeySet: config.apiKey != null && config.apiKey.length > 0,
      webhookSecretSet: config.webhook.secret != null && config.webhook.secret.length > 0,
      storage: storageKind(),
      breaker: {open: breaker.openUntil > now, fails: breaker.fails},
      catalogAgeSec: readCatalogAgeSec(now),
      lisReachable: lisReachable
    };
  }

  /**
   * `memory` after the file fallback, `file` for the built-in storage, `custom` for storage
   * injected by the SIMRS (it has no `isMemoryOnly` flag).
   */
  private function storageKind():String {
    var storage:Dynamic = platform.storage;
    if (!Reflect.hasField(storage, "isMemoryOnly")) {
      return "custom";
    }
    return Reflect.field(storage, "isMemoryOnly") == true ? "memory" : "file";
  }

  /** Age of the cached test type catalog in seconds, or -1 when there is no usable cache. */
  private function readCatalogAgeSec(now:Float):Int {
    var raw = platform.storage.get(Catalog.KEY_TEST_TYPES);
    if (raw == null) {
      return -1;
    }
    try {
      var parsed:Dynamic = Json.parse(raw);
      return Std.int((now - Reflect.field(parsed, "fetchedAt")) / 1000.0);
    } catch (e:Dynamic) {
      // A corrupt cache entry is reported as "no cache"; Catalog refetches it on next use.
      log.debug("health", "Catalog cache entry is unreadable: " + Std.string(e));
      return -1;
    }
  }
}
