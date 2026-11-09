/**
 * HIS V2 endpoint paths, request headers, query strings and envelope decoding (LLD §4).
 * Maps endpoints to HTTP requests and decodes {code, status, data|message} envelopes.
 */
package core;

import haxe.Json;

/** Decoded HIS V2 envelope: `{code,status,data}` on success, `{code,status,message}` on error. */
typedef Envelope = {
  success:Bool,
  data:Dynamic,
  message:String
};

class HisApi {
  public static inline var VERSION:String = "0.1.0";

  public static function createHeaders(
    apiKey:String,
    ?platformName:String = "core"
  ):Map<String, String> {
    var headers = new Map<String, String>();
    headers.set("Content-Type", "application/json");
    headers.set("Accept", "application/json");
    headers.set("User-Agent", "bridgelis-tama-connection/" + VERSION + " (" + platformName + ")");
    if (apiKey != null && apiKey.length > 0) {
      headers.set("X-API-Key", apiKey);
    }
    return headers;
  }

  public static function buildUrl(baseUrl:String, path:String):String {
    return baseUrl + "/api/v2/his" + path;
  }

  public static function encodePathParam(param:String):String {
    return StringTools.urlEncode(param);
  }

  /**
   * Evaluates whether an order structure is fully final (LLD §7.2).
   * Shared between getResult and Webhook to prevent logic duplication.
   */
  public static function isOrderFinal(orderData:Dynamic):Bool {
    if (orderData == null || !Reflect.isObject(orderData)) {
      return false;
    }
    var status:Null<String> = Reflect.field(orderData, "status");
    if (status != "COMPLETED") {
      return false;
    }

    var rawResults:Dynamic = Reflect.field(orderData, "results");
    if (rawResults == null || !Std.isOfType(rawResults, Array)) {
      return false;
    }

    var results:Array<Dynamic> = cast rawResults;
    if (results.length == 0) {
      return false;
    }

    for (item in results) {
      if (item == null || Reflect.field(item, "status") != "Final") {
        return false;
      }
    }
    return true;
  }

  /**
   * Serializes filter options into query string for GET /order.
   */
  public static function buildOrderQueryString(filterJson:Null<String>):String {
    if (filterJson == null || filterJson.length == 0) {
      return "";
    }
    try {
      var filter:Dynamic = Json.parse(filterJson);
      if (!Reflect.isObject(filter)) {
        return "";
      }

      var parts = new Array<String>();
      var allowedFields = [
        "date", "from", "to", "status", "order_id",
        "barcode", "patient_mrn", "search", "page", "limit"
      ];
      for (f in allowedFields) {
        if (Reflect.hasField(filter, f)) {
          var val = Reflect.field(filter, f);
          if (val != null) {
            parts.push(f + "=" + StringTools.urlEncode(Std.string(val)));
          }
        }
      }
      return parts.length > 0 ? "?" + parts.join("&") : "";
    } catch (_:Dynamic) {
      // Malformed filter JSON yields empty query string
      return "";
    }
  }

  /**
   * Decodes HIS V2 response envelope. Returns parsed data or error message.
   */
  public static function parseEnvelope(body:String):Envelope {
    if (body == null || StringTools.trim(body).length == 0) {
      return {success: true, data: null, message: ""};
    }
    try {
      var parsed:Dynamic = Json.parse(body);
      if (Reflect.isObject(parsed)) {
        var dataVal:Dynamic = Reflect.field(parsed, "data");
        var msgVal:Dynamic = Reflect.field(parsed, "message");
        var msgStr = msgVal != null ? Std.string(msgVal) : "";
        return {success: true, data: dataVal, message: msgStr};
      }
      return {success: true, data: parsed, message: ""};
    } catch (e:Dynamic) {
      return {success: false, data: null, message: body};
    }
  }
}
