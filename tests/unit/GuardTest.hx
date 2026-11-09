package;

import utest.Test;
import utest.Assert;
import core.Guard;
import core.Log;
import platform.Platform.HttpRequest;
import platform.Platform.HttpResponse;

class GuardTest extends Test {
  private function makeRequest():HttpRequest {
    return {
      method: "GET",
      url: "http://localhost/test",
      headers: new Map<String, String>(),
      body: null,
      timeoutMs: 1000,
      connectTimeoutMs: 1000
    };
  }

  public function testRetryOnTransient503ThenSuccess() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);

    // Queue 503 first, then 200
    mock.http.responseQueue.push({
      status: 503,
      headers: new Map<String, String>(),
      body: "Service Unavailable"
    });
    mock.http.responseQueue.push({
      status: 200,
      headers: new Map<String, String>(),
      body: "{\"ok\":true}"
    });

    var cbCalled = false;
    guard.call(makeRequest(), function(err, res) {
      cbCalled = true;
      Assert.isNull(err);
      Assert.notNull(res);
      Assert.equals(200, res.status);
    });

    Assert.isTrue(cbCalled);
    Assert.equals(2, mock.http.requests.length); // Retried once
  }

  public function testNoRetryOn400() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);

    mock.http.responseQueue.push({
      status: 400,
      headers: new Map<String, String>(),
      body: "Bad Request"
    });

    var cbCalled = false;
    guard.call(makeRequest(), function(err, res) {
      cbCalled = true;
      Assert.isNull(err);
      Assert.notNull(res);
      Assert.equals(400, res.status);
    });

    Assert.isTrue(cbCalled);
    Assert.equals(1, mock.http.requests.length); // No retry
  }

  public function testRateLimit429ParsesRetryAfter() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);

    var headers = new Map<String, String>();
    headers.set("retry-after", "12");
    mock.http.responseQueue.push({
      status: 429,
      headers: headers,
      body: "Rate limited"
    });

    var cbCalled = false;
    guard.call(makeRequest(), function(err, res) {
      cbCalled = true;
      Assert.notNull(err);
      Assert.equals("RATE_LIMITED", err.code);
      Assert.equals(12, Reflect.field(err.details, "retryAfterSec"));
    });

    Assert.isTrue(cbCalled);
    Assert.equals(1, mock.http.requests.length);
  }

  public function testCircuitBreakerTripsAfter5FailuresAndResetsAfterCooldown() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var guard = new Guard(mock.platform, log);

    // Each transient attempt fails twice (initial + 1 retry) = 1 transient call failure
    mock.http.defaultResponse = {
      status: 503,
      headers: new Map<String, String>(),
      body: "Down"
    };

    // 4 transient failures
    for (i in 0...4) {
      guard.call(makeRequest(), function(err, res) {
        Assert.notNull(err);
        Assert.equals("LIS_UNAVAILABLE", err.code);
      });
    }

    // State should have fails = 4
    var state = guard.getBreakerState();
    Assert.equals(4, state.fails);
    Assert.equals(0.0, state.openUntil);

    // 5th failure trips breaker
    guard.call(makeRequest(), function(err, res) {
      Assert.notNull(err);
      Assert.equals("LIS_UNAVAILABLE", err.code);
    });

    state = guard.getBreakerState();
    Assert.equals(5, state.fails);
    Assert.isTrue(state.openUntil > mock.clock.nowMs());

    // Next call fast-fails immediately without hitting HTTP
    var reqCountBefore = mock.http.requests.length;
    guard.call(makeRequest(), function(err, res) {
      Assert.notNull(err);
      Assert.equals("LIS_UNAVAILABLE", err.code);
      Assert.isTrue(Reflect.field(err.details, "breakerOpen"));
    });
    Assert.equals(reqCountBefore, mock.http.requests.length);

    // Advance clock past 30s cooldown
    mock.clock.advance(31000.0);

    // Now request should hit HTTP again
    mock.http.defaultResponse = {
      status: 200,
      headers: new Map<String, String>(),
      body: "{\"ok\":true}"
    };

    guard.call(makeRequest(), function(err, res) {
      Assert.isNull(err);
      Assert.notNull(res);
      Assert.equals(200, res.status);
    });
    Assert.equals(reqCountBefore + 1, mock.http.requests.length);

    // State reset
    state = guard.getBreakerState();
    Assert.equals(0, state.fails);
    Assert.equals(0.0, state.openUntil);
  }
}
