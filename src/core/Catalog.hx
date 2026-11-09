/**
 * Test type and package catalog: cache, index and unknown code check (LLD §6.4).
 * Prevents orders from losing unrecognized tests silently on the LIS server (HLD F2).
 */
package core;

import platform.Platform.Platform;
import platform.Platform.HttpRequest;
import core.LisError.LisError;
import core.LisError.LisErrorHelper;
import core.Config.ClientConfig;
import haxe.Json;

typedef CatalogWarning = {code:String, field:String, from:String, to:String};
typedef CheckCallback = (err:Null<LisError>, warnings:Array<CatalogWarning>) -> Void;

typedef CatalogEntry = {
  fetchedAt:Float,
  data:Dynamic
};

class Catalog {
  public static inline var KEY_TEST_TYPES:String = "cat:test-types";
  public static inline var KEY_PACKAGES:String = "cat:packages";
  public static inline var MAX_STALE_MS:Float = 604800000.0; // 7 days in ms
  public static inline var MIN_REFRESH_INTERVAL_MS:Float = 300000.0; // 5 minutes in ms
  // Storage TTL equals the 7-day stale limit; older entries are useless (LLD §6.4).
  public static inline var CACHE_TTL_SEC:Int = 604800;

  private var platform:Platform;
  private var config:ClientConfig;
  private var guard:Guard;
  private var log:Log;

  public function new(platform:Platform, config:ClientConfig, guard:Guard, log:Log) {
    this.platform = platform;
    this.config = config;
    this.guard = guard;
    this.log = log;
  }

  public function check(
    lisOrder:Dynamic,
    cb:CheckCallback
  ):Void {
    var policy = config.catalog.unknownTestPolicy;
    if (policy == "off") {
      cb(null, []);
      return;
    }

    getIndex(function(err, index, isUnavailable) {
      if (isUnavailable) {
        cb(null, [{
          code: "CATALOG_UNAVAILABLE",
          field: "catalog",
          from: "catalog",
          to: "bypassed"
        }]);
        return;
      }

      var missingCodes = findMissingCodes(lisOrder, index);
      if (missingCodes.length == 0) {
        cb(null, []);
        return;
      }

      checkWithRefreshFallback(lisOrder, missingCodes, policy, cb);
    });
  }

  private function checkWithRefreshFallback(
    lisOrder:Dynamic,
    missingCodes:Array<String>,
    policy:String,
    cb:CheckCallback
  ):Void {
    if (canRefresh()) {
      log.info("catalog", "Unknown test code found. Refreshing catalog...", {
        missing: missingCodes
      });
      refresh(function(refreshErr, newIndex) {
        if (newIndex != null) {
          var recheck = findMissingCodes(lisOrder, newIndex);
          if (recheck.length == 0) {
            cb(null, []);
            return;
          }
          handleMissing(recheck, policy, cb);
        } else {
          handleMissing(missingCodes, policy, cb);
        }
      });
    } else {
      handleMissing(missingCodes, policy, cb);
    }
  }

  private function handleMissing(
    missingCodes:Array<String>,
    policy:String,
    cb:CheckCallback
  ):Void {
    if (policy == "reject") {
      cb(LisErrorHelper.unknownTestCode(
        "One or more test codes are not recognized by LIS catalog: " + missingCodes.join(", "),
        missingCodes
      ), []);
    } else {
      var warnings = new Array<CatalogWarning>();
      for (c in missingCodes) {
        warnings.push({
          code: "UNKNOWN_TEST_CODE_WARN",
          field: "lis_order.tests",
          from: c,
          to: "unrecognized"
        });
      }
      cb(null, warnings);
    }
  }

  private function findMissingCodes(lisOrder:Dynamic, index:Map<String, Bool>):Array<String> {
    var missing = new Array<String>();
    scanItems(Reflect.field(lisOrder, "tests"), index, missing);
    scanItems(Reflect.field(lisOrder, "packages"), index, missing);
    return missing;
  }

  private function scanItems(items:Dynamic, index:Map<String, Bool>, missing:Array<String>):Void {
    if (items == null || !Std.isOfType(items, Array)) {
      return;
    }
    var arr:Array<Dynamic> = cast items;
    for (item in arr) {
      if (item == null || !Reflect.isObject(item)) {
        continue;
      }
      var found = false;

      var loinc:Null<String> = Reflect.field(item, "loinc_code");
      if (loinc != null && index.exists(StringTools.trim(loinc).toUpperCase())) {
        found = true;
      }

      var code:Null<String> = Reflect.field(item, "code");
      if (code != null && index.exists(StringTools.trim(code).toUpperCase())) {
        found = true;
      }

      var id:Dynamic = Reflect.field(item, "id");
      if (id != null && index.exists(StringTools.trim(Std.string(id)).toUpperCase())) {
        found = true;
      }

      if (!found) {
        var rep = loinc != null ? loinc : (code != null ? code : Std.string(id));
        missing.push(rep);
      }
    }
  }

  private function canRefresh():Bool {
    var raw = platform.storage.get(KEY_TEST_TYPES);
    if (raw == null) {
      return true;
    }
    try {
      var parsed:Dynamic = Json.parse(raw);
      var fetchedAt:Float = Reflect.field(parsed, "fetchedAt");
      var now = platform.clock.nowMs();
      return (now - fetchedAt) > MIN_REFRESH_INTERVAL_MS;
    } catch (_:Dynamic) {
      // JSON parse failure treated as expired cache
      return true;
    }
  }

  public function getIndex(
    cb:(err:Null<LisError>, index:Null<Map<String, Bool>>, isUnavailable:Bool)->Void
  ):Void {
    var cachedTestTypes = readCache(KEY_TEST_TYPES);
    var cachedPackages = readCache(KEY_PACKAGES);
    var now = platform.clock.nowMs();
    var ttlMs = config.catalog.ttlSec * 1000.0;

    // Both present and fresh according to catalog.ttlSec (LLD §6.4)
    var isFresh = cachedTestTypes != null && cachedPackages != null &&
      (now - cachedTestTypes.fetchedAt) <= ttlMs &&
      (now - cachedPackages.fetchedAt) <= ttlMs;

    if (isFresh) {
      var idx = buildIndex(cachedTestTypes.data, cachedPackages.data);
      cb(null, idx, false);
      return;
    }

    refresh(function(err, idx) {
      if (idx != null) {
        cb(null, idx, false);
      } else {
        // Fall back to stale cache up to 7 days
        if (cachedTestTypes != null || cachedPackages != null) {
          var ttData = cachedTestTypes != null ? cachedTestTypes.data : [];
          var pkgData = cachedPackages != null ? cachedPackages.data : [];
          cb(null, buildIndex(ttData, pkgData), false);
        } else {
          cb(null, null, true);
        }
      }
    });
  }

  public function refresh(cb:(err:Null<LisError>, index:Null<Map<String, Bool>>)->Void):Void {
    var headers = HisApi.createHeaders(config.apiKey, platform.name);
    var reqTT:HttpRequest = {
      method: "GET",
      url: HisApi.buildUrl(config.baseUrl, "/test-types"),
      headers: headers,
      timeoutMs: config.timeoutMs,
      connectTimeoutMs: config.connectTimeoutMs
    };

    guard.call(reqTT, function(errTT, resTT) {
      if (errTT != null || resTT == null || resTT.status != 200) {
        var ttErr = errTT != null
          ? errTT
          : LisErrorHelper.fromHttpStatus(resTT.status, "Fetch test types failed");
        cb(ttErr, null);
        return;
      }

      fetchPackagesAndCache(headers, resTT.body, cb);
    });
  }

  private function fetchPackagesAndCache(
    headers:Map<String, String>,
    ttBody:String,
    cb:(err:Null<LisError>, index:Null<Map<String, Bool>>)->Void
  ):Void {
    var reqPkg:HttpRequest = {
      method: "GET",
      url: HisApi.buildUrl(config.baseUrl, "/packages"),
      headers: headers,
      timeoutMs: config.timeoutMs,
      connectTimeoutMs: config.connectTimeoutMs
    };

    guard.call(reqPkg, function(errPkg, resPkg) {
      if (errPkg != null || resPkg == null || resPkg.status != 200) {
        var pkgErr = errPkg != null
          ? errPkg
          : LisErrorHelper.fromHttpStatus(resPkg.status, "Fetch packages failed");
        cb(pkgErr, null);
        return;
      }

      var ttEnv = HisApi.parseEnvelope(ttBody);
      var pkgEnv = HisApi.parseEnvelope(resPkg.body);
      var now = platform.clock.nowMs();

      try {
        var ttEntry = Json.stringify({fetchedAt: now, data: ttEnv.data});
        var pkgEntry = Json.stringify({fetchedAt: now, data: pkgEnv.data});
        platform.storage.set(KEY_TEST_TYPES, ttEntry, CACHE_TTL_SEC);
        platform.storage.set(KEY_PACKAGES, pkgEntry, CACHE_TTL_SEC);
      } catch (e:Dynamic) {
        // The fresh index is still usable for this call; only the cache write is lost.
        log.warn("catalog", "Failed to cache catalog in storage: " + Std.string(e));
      }

      cb(null, buildIndex(ttEnv.data, pkgEnv.data));
    });
  }

  private function readCache(key:String):Null<CatalogEntry> {
    var raw = platform.storage.get(key);
    if (raw == null || raw.length == 0) {
      return null;
    }
    try {
      var parsed:Dynamic = Json.parse(raw);
      var fetchedAt:Float = Reflect.field(parsed, "fetchedAt");
      var now = platform.clock.nowMs();
      if ((now - fetchedAt) > MAX_STALE_MS) {
        return null;
      }
      return {fetchedAt: fetchedAt, data: Reflect.field(parsed, "data")};
    } catch (_:Dynamic) {
      // Corrupt cache file ignored and discarded
      return null;
    }
  }

  public static function buildIndex(testTypesData:Dynamic, packagesData:Dynamic):Map<String, Bool> {
    var map = new Map<String, Bool>();

    if (testTypesData != null && Std.isOfType(testTypesData, Array)) {
      var arr:Array<Dynamic> = cast testTypesData;
      for (item in arr) {
        if (item == null || !Reflect.isObject(item)) {
          continue;
        }
        addToken(map, Reflect.field(item, "code"));
        addToken(map, Reflect.field(item, "alias_code"));
        addToken(map, Reflect.field(item, "loinc_code"));
        var alts:Dynamic = Reflect.field(item, "alternative_codes");
        if (alts != null && Std.isOfType(alts, Array)) {
          var altArr:Array<Dynamic> = cast alts;
          for (alt in altArr) {
            if (alt != null) {
              addToken(map, Std.string(alt));
            }
          }
        }
      }
    }

    if (packagesData != null && Std.isOfType(packagesData, Array)) {
      var arr:Array<Dynamic> = cast packagesData;
      for (item in arr) {
        if (item == null || !Reflect.isObject(item)) {
          continue;
        }
        addToken(map, Reflect.field(item, "code"));
        var packageId:Dynamic = Reflect.field(item, "id");
        if (packageId != null) {
          addToken(map, Std.string(packageId));
        }
        addToken(map, Reflect.field(item, "loinc_code"));
      }
    }

    return map;
  }

  private static function addToken(map:Map<String, Bool>, token:Null<String>):Void {
    if (token == null || token.length == 0) {
      return;
    }
    var cleaned = StringTools.trim(token).toUpperCase();
    if (cleaned.length > 0) {
      map.set(cleaned, true);
    }
  }
}
