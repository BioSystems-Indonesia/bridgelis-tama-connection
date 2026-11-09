package;

import utest.Test;
import utest.Assert;
import core.Catalog;
import core.Config;
import core.Guard;
import core.Log;
import haxe.Json;

class CatalogTest extends Test {
  private function makeConfig(policy:String = "reject", ttlSec:Int = 3600):ClientConfig {
    return {
      baseUrl: "http://localhost",
      apiKey: "test-key",
      storageDir: "./storage",
      timeoutMs: 1000,
      connectTimeoutMs: 1000,
      logLevel: "debug",
      webhook: {
        secret: "secret",
        secretHeader: "X-API-Key"
      },
      catalog: {
        ttlSec: ttlSec,
        unknownTestPolicy: policy
      }
    };
  }

  public function testPolicyOffBypassesCatalog() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);
    var catalog = new Catalog(mock.platform, makeConfig("off"), guard, log);

    var order = {tests: [{code: "UNKNOWN_XYZ"}]};
    var cbCalled = false;
    catalog.check(order, function(err, warnings) {
      cbCalled = true;
      Assert.isNull(err);
      Assert.equals(0, warnings.length);
    });

    Assert.isTrue(cbCalled);
    Assert.equals(0, mock.http.requests.length); // Never called LIS
  }

  public function testPolicyRejectFailsOnUnknownTest() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);
    var catalog = new Catalog(mock.platform, makeConfig("reject"), guard, log);

    // Queue test-types and packages responses
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: [{code: "CBC"}]})
    });
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: [{code: "PKG_LIVER"}]})
    });

    var order = {tests: [{code: "NON_EXISTENT_CODE"}]};
    var cbCalled = false;
    catalog.check(order, function(err, warnings) {
      cbCalled = true;
      Assert.notNull(err);
      Assert.equals("UNKNOWN_TEST_CODE", err.code);
    });

    Assert.isTrue(cbCalled);
  }

  public function testPolicyWarnPassesWithWarnings() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);
    var catalog = new Catalog(mock.platform, makeConfig("warn"), guard, log);

    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: [{code: "CBC"}]})
    });
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: [{code: "PKG_LIVER"}]})
    });

    var order = {tests: [{code: "NON_EXISTENT_CODE"}]};
    var cbCalled = false;
    catalog.check(order, function(err, warnings) {
      cbCalled = true;
      Assert.isNull(err);
      Assert.equals(1, warnings.length);
      Assert.equals("UNKNOWN_TEST_CODE_WARN", warnings[0].code);
    });

    Assert.isTrue(cbCalled);
  }

  public function testIndexIgnoresMissingPackageId() {
    // A package without id must not register the token "NULL" (so code "null" stays unknown).
    var index = Catalog.buildIndex([], [{code: "PKG-A"}]);
    Assert.isTrue(index.exists("PKG-A"));
    Assert.isFalse(index.exists("NULL"));
  }

  public function testTtlCacheFreshnessAndStaleFallback() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);
    var catalog = new Catalog(mock.platform, makeConfig("reject", 3600), guard, log);

    // Initial fetch
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: [{code: "CBC"}]})
    });
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: Json.stringify({status: 200, data: []})
    });

    var order = {tests: [{code: "CBC"}]};
    catalog.check(order, function(err, warnings) {
      Assert.isNull(err);
    });
    Assert.equals(2, mock.http.requests.length);

    // Call again within TTL (10 minutes later) -> Uses cache, 0 new HTTP requests
    mock.clock.advance(600000.0);
    catalog.check(order, function(err, warnings) {
      Assert.isNull(err);
    });
    Assert.equals(2, mock.http.requests.length);

    // Advance beyond TTL (2 hours later) -> Triggers refresh
    mock.clock.advance(7200000.0);
    // Refresh fails (server 503)
    mock.http.defaultResponse = {
      status: 503,
      headers: new Map<String, String>(),
      body: "Server down"
    };

    // Should fall back to stale cache up to 7 days
    catalog.check(order, function(err, warnings) {
      Assert.isNull(err); // CBC still accepted via stale cache
    });
  }
}
