package;

import utest.Test;
import utest.Assert;
import core.Webhook;
import core.Config;
import core.Log;
import core.LisError;
import haxe.Json;

class WebhookTest extends Test {
  private function makeConfig(?secret:String = "my-secret-token"):ClientConfig {
    return {
      baseUrl: "http://localhost",
      apiKey: "test-key",
      storageDir: "./storage",
      timeoutMs: 1000,
      connectTimeoutMs: 1000,
      logLevel: "debug",
      webhook: {
        secret: secret != null ? secret : "my-secret-token",
        secretHeader: "X-API-Key"
      },
      catalog: {
        unknownTestPolicy: "reject",
        ttlSec: 3600
      }
    };
  }

  public function testSecretMismatchReturns401() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("secret123"), log);

    var rawBody = Json.stringify({order_no: "ORD-123"});
    var headers = Json.stringify({"x-api-key": "wrong-secret"});

    var cbCalled = false;
    webhook.handle(rawBody, headers, function(id, cb) {}, function(evt, done) {}, function(res) {
      cbCalled = true;
      Assert.equals(401, res.status);
    });

    Assert.isTrue(cbCalled);
  }

  public function testBearerTokenVerification() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var cfg = makeConfig("token456");
    cfg.webhook.secretHeader = "Authorization";
    var webhook = new Webhook(mock.platform, cfg, log);

    var rawBody = Json.stringify({order_id: "ORD-999"});
    var headers = Json.stringify({"authorization": "Bearer token456"});

    var cbCalled = false;
    var getResultCalled = false;
    webhook.handle(rawBody, headers, function(id, cb) {
      getResultCalled = true;
      Assert.equals("ORD-999", id);
      cb(null, {state: "FINAL", is_final: true, order: {}});
    }, function(evt, done) {
      done(null);
    }, function(res) {
      cbCalled = true;
      Assert.equals(200, res.status);
    });

    Assert.isTrue(cbCalled);
    Assert.isTrue(getResultCalled);
  }

  public function testMissingOrderIdReturns400() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("sec"), log);

    var rawBody = Json.stringify({other_field: "foo"});
    var headers = Json.stringify({"x-api-key": "sec"});

    var cbCalled = false;
    webhook.handle(rawBody, headers, function(id, cb) {}, function(evt, done) {}, function(res) {
      cbCalled = true;
      Assert.equals(400, res.status);
    });

    Assert.isTrue(cbCalled);
  }

  public function testHeaderGivenAsValueListIsAccepted() {
    // Laravel/Symfony, PSR-7 and Node may give a header as a list of values.
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("sec"), log);

    var status = 0;
    var headers = Json.stringify({"X-Api-Key": ["sec"]});
    webhook.handle(Json.stringify({}), headers, function(id, cb) {}, function(evt, done) {},
      function(res) {
        status = res.status;
      });

    Assert.equals(400, status); // secret accepted; fails later on the missing order id
  }

  public function testOrderIdWithSlashReturns400WithoutCallingLis() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("sec"), log);

    var rawBody = Json.stringify({order_no: "ORD/1"});
    var headers = Json.stringify({"x-api-key": "sec"});

    var fetched = false;
    var status = 0;
    var getResultFn = function(id, cb) {
      fetched = true;
    };
    webhook.handle(rawBody, headers, getResultFn, function(evt, done) {}, function(res) {
      status = res.status;
    });

    Assert.equals(400, status);
    Assert.isFalse(fetched);
  }

  public function testUpstreamResultFailureReturns502() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("sec"), log);

    var rawBody = Json.stringify({order_no: "ORD-502"});
    var headers = Json.stringify({"x-api-key": "sec"});

    var cbCalled = false;
    webhook.handle(rawBody, headers, function(id, cb) {
      cb(LisErrorHelper.unavailable("LIS upstream down"), null);
    }, function(evt, done) {}, function(res) {
      cbCalled = true;
      Assert.equals(502, res.status);
    });

    Assert.isTrue(cbCalled);
  }

  public function testPendingResultReturns404() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "debug");
    var webhook = new Webhook(mock.platform, makeConfig("sec"), log);

    var rawBody = Json.stringify({barcode_simrs: "BAR-404"});
    var headers = Json.stringify({"x-api-key": "sec"});

    var cbCalled = false;
    webhook.handle(rawBody, headers, function(id, cb) {
      cb(null, {state: "PENDING", is_final: false});
    }, function(evt, done) {}, function(res) {
      cbCalled = true;
      Assert.equals(404, res.status);
    });

    Assert.isTrue(cbCalled);
  }
}
