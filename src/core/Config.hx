/**
 * Configuration parsing, environment precedence resolution, and validation according to LLD §9.
 * Resolves configuration in order: explicit constructor config -> process environment -> defaults.
 */
package core;

import platform.Platform.IEnv;
import core.LisError.LisErrorHelper;
import haxe.Json;

typedef WebhookConfig = {
  secret:String,
  secretHeader:String
};

typedef CatalogConfig = {
  unknownTestPolicy:String,
  ttlSec:Int
};

typedef ClientConfig = {
  baseUrl:String,
  apiKey:String,
  webhook:WebhookConfig,
  catalog:CatalogConfig,
  storageDir:String,
  timeoutMs:Int,
  connectTimeoutMs:Int,
  logLevel:String,
  ?sexMap:Map<String, String>
};

class Config {
  public static inline var DEFAULT_TIMEOUT_MS:Int = 8000;
  public static inline var DEFAULT_CONNECT_TIMEOUT_MS:Int = 3000;
  public static inline var DEFAULT_CATALOG_TTL_SEC:Int = 3600;
  public static inline var DEFAULT_WEBHOOK_HEADER:String = "X-API-Key";
  public static inline var DEFAULT_UNKNOWN_TEST_POLICY:String = "reject";
  public static inline var DEFAULT_LOG_LEVEL:String = "info";

  public static function resolve(rawJson:Null<String>, env:IEnv):ClientConfig {
    var raw:Dynamic = parseConfigJson(rawJson);

    var getEnv = function(name:String):Null<String> {
      if (env == null) {
        return null;
      }
      var val = env.get(name);
      return (val != null && val.length > 0) ? StringTools.trim(val) : null;
    };

    var baseUrl = resolveBaseUrl(raw, getEnv);
    var apiKey = resolveApiKey(raw, getEnv);
    var webhook = resolveWebhook(raw, getEnv);
    var catalog = resolveCatalog(raw, getEnv);
    var storageDir = resolveStorageDir(raw, getEnv);
    var timeoutMs = parseTimeout(
      raw,
      getEnv("LIS_TIMEOUT_MS"),
      "LIS_TIMEOUT_MS",
      DEFAULT_TIMEOUT_MS
    );
    var connTimeoutMs = parseTimeout(
      raw,
      getEnv("LIS_CONNECT_TIMEOUT_MS"),
      "LIS_CONNECT_TIMEOUT_MS",
      DEFAULT_CONNECT_TIMEOUT_MS
    );
    var logLevel = resolveLogLevel(raw, getEnv);
    var sexMap = parseSexMap(raw);

    return {
      baseUrl: baseUrl,
      apiKey: apiKey,
      webhook: webhook,
      catalog: catalog,
      storageDir: storageDir,
      timeoutMs: timeoutMs,
      connectTimeoutMs: connTimeoutMs,
      logLevel: logLevel,
      sexMap: sexMap
    };
  }

  private static function parseConfigJson(rawJson:Null<String>):Dynamic {
    if (rawJson == null || rawJson.length == 0) {
      return null;
    }
    try {
      return Json.parse(rawJson);
    } catch (e:Dynamic) {
      throw LisErrorHelper.validationFailed(
        "Invalid JSON passed in configuration: " + Std.string(e),
        "config"
      );
    }
  }

  private static function resolveBaseUrl(raw:Dynamic, getEnv:String->Null<String>):String {
    var explicit:Null<String> = raw != null ? Reflect.field(raw, "baseUrl") : null;
    var fromEnv = getEnv("LIS_BASE_URL");
    var url = explicit != null ? StringTools.trim(explicit) : fromEnv;

    if (url == null || url.length == 0) {
      throw LisErrorHelper.validationFailed(
        "LIS_BASE_URL is not set. Set it in the environment.",
        "config.baseUrl"
      );
    }

    while (url.length > 0 && url.charAt(url.length - 1) == "/") {
      url = url.substr(0, url.length - 1);
    }
    return url;
  }

  private static function resolveApiKey(raw:Dynamic, getEnv:String->Null<String>):String {
    var explicit:Null<String> = raw != null ? Reflect.field(raw, "apiKey") : null;
    var fromEnv = getEnv("LIS_API_KEY");
    return explicit != null ? explicit : (fromEnv != null ? fromEnv : "");
  }

  private static function resolveWebhook(raw:Dynamic, getEnv:String->Null<String>):WebhookConfig {
    var rawWh:Dynamic = raw != null ? Reflect.field(raw, "webhook") : null;
    var expSec:Null<String> = rawWh != null ? Reflect.field(rawWh, "secret") : null;
    var envSec = getEnv("LIS_WEBHOOK_SECRET");
    var secret = expSec != null ? expSec : (envSec != null ? envSec : "");

    var expHdr:Null<String> = rawWh != null ? Reflect.field(rawWh, "secretHeader") : null;
    var envHdr = getEnv("LIS_WEBHOOK_SECRET_HEADER");
    var header = expHdr != null ? expHdr : (envHdr != null ? envHdr : DEFAULT_WEBHOOK_HEADER);

    return {secret: secret, secretHeader: header};
  }

  private static function resolveCatalog(raw:Dynamic, getEnv:String->Null<String>):CatalogConfig {
    var rawCat:Dynamic = raw != null ? Reflect.field(raw, "catalog") : null;
    var expPol:Null<String> = rawCat != null ? Reflect.field(rawCat, "unknownTestPolicy") : null;
    var envPol = getEnv("LIS_UNKNOWN_TEST_POLICY");

    var policy = expPol != null ? expPol : (envPol != null ? envPol : DEFAULT_UNKNOWN_TEST_POLICY);
    var lowerPol = policy.toLowerCase();
    if (lowerPol != "reject" && lowerPol != "warn" && lowerPol != "off") {
      throw LisErrorHelper.validationFailed(
        "Invalid LIS_UNKNOWN_TEST_POLICY: '" + policy + "'. Allowed: reject, warn, off.",
        "config.catalog.unknownTestPolicy"
      );
    }

    var expTtl:Dynamic = rawCat != null ? Reflect.field(rawCat, "ttlSec") : null;
    var hasTtl = expTtl != null && Std.isOfType(expTtl, Int);
    var ttl = hasTtl ? cast(expTtl, Int) : DEFAULT_CATALOG_TTL_SEC;

    return {unknownTestPolicy: lowerPol, ttlSec: ttl};
  }

  private static function resolveStorageDir(raw:Dynamic, getEnv:String->Null<String>):String {
    var exp:Null<String> = raw != null ? Reflect.field(raw, "storageDir") : null;
    var fromEnv = getEnv("LIS_STORAGE_DIR");
    return exp != null ? exp : (fromEnv != null ? fromEnv : "");
  }

  private static function resolveLogLevel(raw:Dynamic, getEnv:String->Null<String>):String {
    var exp:Null<String> = raw != null ? Reflect.field(raw, "logLevel") : null;
    var fromEnv = getEnv("LIS_LOG_LEVEL");
    return exp != null ? exp : (fromEnv != null ? fromEnv : DEFAULT_LOG_LEVEL);
  }

  private static function parseSexMap(raw:Dynamic):Null<Map<String, String>> {
    var rawMap:Dynamic = raw != null ? Reflect.field(raw, "sexMap") : null;
    if (rawMap == null) {
      return null;
    }
    var map = new Map<String, String>();
    for (k in Reflect.fields(rawMap)) {
      map.set(k.toUpperCase(), Std.string(Reflect.field(rawMap, k)).toUpperCase());
    }
    return map;
  }

  private static function parseTimeout(
    raw:Dynamic,
    envVal:Null<String>,
    envName:String,
    defaultVal:Int
  ):Int {
    var fieldKey = envName == "LIS_TIMEOUT_MS" ? "timeoutMs" : "connectTimeoutMs";
    var explicitVal:Dynamic = raw != null ? Reflect.field(raw, fieldKey) : null;

    if (explicitVal != null) {
      if (Std.isOfType(explicitVal, Int) && cast(explicitVal, Int) > 0) {
        return cast explicitVal;
      }
      if (Std.isOfType(explicitVal, String)) {
        var p = Std.parseInt(cast explicitVal);
        if (p != null && p > 0) {
          return p;
        }
      }
      throw LisErrorHelper.validationFailed(
        "Invalid integer for " + fieldKey,
        "config." + fieldKey
      );
    }

    if (envVal != null && envVal.length > 0) {
      var p = Std.parseInt(envVal);
      if (p != null && p > 0) {
        return p;
      }
      throw LisErrorHelper.validationFailed(
        "Invalid integer for environment variable " + envName + ": '" + envVal + "'",
        "config." + fieldKey
      );
    }

    return defaultVal;
  }
}
