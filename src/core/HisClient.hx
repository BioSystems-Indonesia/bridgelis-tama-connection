/**
 * Sends HIS V2 requests through Guard and maps non-2xx statuses to LisError (LLD §4, §5).
 * Every service (orders, results, reconcile) talks to the LIS only through this class.
 */
package core;

import platform.Platform.Platform;
import platform.Platform.HttpRequest;
import platform.Platform.HttpResponse;
import core.Config.ClientConfig;
import core.HisApi.Envelope;
import core.LisError.LisError;
import core.LisError.LisErrorHelper;

typedef HisCallback = (err:Null<LisError>, env:Null<Envelope>) -> Void;

class HisClient {
  public var guard(default, null):Guard;

  private var platform:Platform;
  private var config:ClientConfig;
  private var outcomes:Outcomes;

  public function new(platform:Platform, config:ClientConfig, guard:Guard, outcomes:Outcomes) {
    this.platform = platform;
    this.config = config;
    this.guard = guard;
    this.outcomes = outcomes;
  }

  /**
   * Sends one HIS request. The continuation runs inside `protect`, so an exception in it still
   * produces one outcome.
   */
  public function send(
    done:String->Void,
    method:String,
    path:String,
    body:Null<String>,
    next:HisCallback
  ):Void {
    var req = buildRequest(method, path, body);
    guard.call(req, function(guardErr, res) {
      outcomes.protect(done, method + " " + path, function() {
        if (guardErr != null) {
          next(guardErr, null);
          return;
        }
        if (res.status == 200 || res.status == 204) {
          next(null, HisApi.parseEnvelope(res.body));
          return;
        }
        next(errorFromResponse(res), null);
      });
    });
  }

  /** GET a HIS endpoint and report its `data` field as the outcome. */
  public function fetchData(done:String->Void, path:String):Void {
    send(done, "GET", path, null, function(err, envelope) {
      if (err != null) {
        Outcomes.error(done, err);
        return;
      }
      Outcomes.ok(done, envelope.data);
    });
  }

  /** Builds a request for a HIS V2 path (the path starts after `/api/v2/his`). */
  public function buildRequest(method:String, path:String, body:Null<String>):HttpRequest {
    return {
      method: method,
      url: HisApi.buildUrl(config.baseUrl, path),
      headers: HisApi.createHeaders(config.apiKey, platform.name),
      body: body,
      timeoutMs: config.timeoutMs,
      connectTimeoutMs: config.connectTimeoutMs
    };
  }

  public static function errorFromResponse(res:HttpResponse):LisError {
    var envelope = HisApi.parseEnvelope(res.body);
    return LisErrorHelper.fromHttpStatus(res.status, envelope.message, Guard.getRequestId(res));
  }
}
