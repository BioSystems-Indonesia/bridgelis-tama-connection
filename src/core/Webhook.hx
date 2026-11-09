/**
 * Webhook signature verification, payload parsing, and event dispatching according to LLD §7.
 * Dispatches verified LIS completion webhooks to the SIMRS handler with constant-time security.
 */
package core;

import platform.Platform.Platform;
import core.Config.ClientConfig;
import core.LisError.LisError;
import core.ResultDispatch.ResultHandler;
import core.Results.ResultState;
import haxe.Json;

private typedef FetchResult = (
  orderId:String,
  cb:(err:Null<LisError>, res:Null<ResultState>)->Void
)->Void;

typedef WebhookResponse = {
  status:Int,
  body:String
};

class Webhook {
  private var platform:Platform;
  private var config:ClientConfig;
  private var log:Log;

  public function new(platform:Platform, config:ClientConfig, log:Log) {
    this.platform = platform;
    this.config = config;
    this.log = log;
  }

  public function handle(
    rawBody:String,
    headersJson:String,
    getResultFn:FetchResult,
    handler:ResultHandler,
    cb:WebhookResponse->Void
  ):Void {
    var headersMap = parseHeadersJson(headersJson);

    if (!verifySecret(headersMap)) {
      cb({status: 401, body: Json.stringify({error: "Unauthorized: secret mismatch or missing"})});
      return;
    }

    var orderId = extractOrderId(rawBody);
    if (orderId == null) {
      log.warn("webhook", "Webhook parsing failed: missing order identifier", {rawBody: rawBody});
      cb({status: 400, body: Json.stringify({error: "Bad Request: missing order identifier"})});
      return;
    }

    // Same local rule as every other method: the LIS cannot route ids containing '/' (LLD §4).
    if (orderId.indexOf("/") != -1) {
      log.warn("webhook", "Webhook order identifier contains '/'", {orderId: orderId});
      var body = Json.stringify({error: "Bad Request: order identifier contains '/'"});
      cb({status: 400, body: body});
      return;
    }

    fetchAndDispatch(orderId, getResultFn, handler, cb);
  }

  private function verifySecret(headersMap:Map<String, String>):Bool {
    var configuredSecret = config.webhook.secret;
    if (configuredSecret == null || configuredSecret.length == 0) {
      return true;
    }

    var headerName = config.webhook.secretHeader != null
      ? config.webhook.secretHeader
      : Config.DEFAULT_WEBHOOK_HEADER;
    var providedVal = getHeaderCaseInsensitive(headersMap, headerName);
    if (providedVal == null) {
      return false;
    }

    var token = providedVal;
    if (headerName.toLowerCase() == "authorization" && StringTools.startsWith(token, "Bearer ")) {
      token = token.substr(7);
    }
    return constantTimeEquals(token, configuredSecret);
  }

  private function extractOrderId(rawBody:String):Null<String> {
    try {
      var bodyObj:Dynamic = Json.parse(rawBody);
      if (!Reflect.isObject(bodyObj)) {
        return null;
      }

      var candidates = ["order_no", "OrderNo", "order_id", "barcode_simrs"];
      for (cand in candidates) {
        if (Reflect.hasField(bodyObj, cand)) {
          var val = Reflect.field(bodyObj, cand);
          if (val != null) {
            var trimmed = StringTools.trim(Std.string(val));
            if (trimmed.length > 0) {
              return trimmed;
            }
          }
        }
      }
    } catch (_:Dynamic) {
      // Body is not valid JSON
    }
    return null;
  }

  private function fetchAndDispatch(
    orderId:String,
    getResultFn:FetchResult,
    handler:ResultHandler,
    cb:WebhookResponse->Void
  ):Void {
    getResultFn(orderId, function(err, resultObj) {
      if (err != null) {
        log.error("webhook", "Failed to retrieve result for webhook", {
          orderId: orderId,
          error: err.message,
          requestId: err.requestId
        });
        cb({status: 502, body: Json.stringify({error: "Bad Gateway: unable to retrieve result"})});
        return;
      }

      if (resultObj.state == "PENDING") {
        log.warn("webhook", "Result still pending for order in webhook", {orderId: orderId});
        cb({status: 404, body: Json.stringify({error: "Not Found: result pending"})});
        return;
      }

      dispatchToHandler(orderId, resultObj, handler, cb);
    });
  }

  private function dispatchToHandler(
    orderId:String,
    resultObj:ResultState,
    handler:ResultHandler,
    cb:WebhookResponse->Void
  ):Void {
    var event = ResultDispatch.buildEvent(orderId, resultObj, platform.clock.isoString());
    ResultDispatch.run(handler, event, function(handlerErr:Null<String>) {
      if (handlerErr == null) {
        cb({status: 200, body: Json.stringify({ok: true})});
        return;
      }
      log.error("webhook", "Handler failed to process result event", {
        orderId: orderId,
        error: handlerErr
      });
      cb({status: 500, body: Json.stringify({error: "Internal Server Error: " + handlerErr})});
    });
  }

  public static function constantTimeEquals(a:String, b:String):Bool {
    if (a == null || b == null) {
      return false;
    }
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (i in 0...a.length) {
      diff |= (a.charCodeAt(i) ^ b.charCodeAt(i));
    }
    return diff == 0;
  }

  /**
   * Frameworks give a header either as a string or as a list of values (Laravel/Symfony,
   * PSR-7, Node `string[]`). The first value is used: auth headers carry a single value.
   */
  private static function headerValue(raw:Dynamic):Null<String> {
    if (raw == null) {
      return null;
    }
    if (Std.isOfType(raw, Array)) {
      var values:Array<Dynamic> = cast raw;
      return values.length > 0 && values[0] != null ? Std.string(values[0]) : null;
    }
    return Std.string(raw);
  }

  private static function parseHeadersJson(headersJson:Null<String>):Map<String, String> {
    var map = new Map<String, String>();
    if (headersJson == null || headersJson.length == 0) {
      return map;
    }
    try {
      var obj:Dynamic = Json.parse(headersJson);
      if (Reflect.isObject(obj)) {
        for (f in Reflect.fields(obj)) {
          var v = headerValue(Reflect.field(obj, f));
          if (v != null) {
            map.set(f.toLowerCase(), v);
          }
        }
      }
    } catch (_:Dynamic) {
      // Header JSON parse error returns empty map
    }
    return map;
  }

  private static function getHeaderCaseInsensitive(
    headersMap:Map<String, String>,
    name:String
  ):Null<String> {
    var key = name.toLowerCase();
    return headersMap.exists(key) ? headersMap.get(key) : null;
  }
}
