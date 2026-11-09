package;

import utest.Test;
import utest.Assert;
import core.LisCore;
import haxe.Json;
import platform.MemoryStorage;

/** In-progress lock of createOrder (HLD D13) and the atomic setIfAbsent it relies on. */
class OrdersLockTest extends Test {
  static inline var CONFIG:String =
    '{"baseUrl":"http://lis.local","apiKey":"k","logLevel":"error",'
    + '"catalog":{"unknownTestPolicy":"off"}}';
  static inline var ORDER_OK_BODY:String =
    '{"code":200,"status":"SUCCESS","data":{"id":7,"barcode":"B-7"}}';

  private function orderJson():String {
    return Json.stringify({
      patient: {
        medical_record_number: "RM-1",
        first_name: "Budi",
        sex: "M",
        date_of_birth: "1990-01-01"
      },
      lis_order: {order_id: "ORD-1", tests: [{loinc_code: "2345-7"}]}
    });
  }

  private function respond(status:Int, body:String):platform.Platform.HttpResponse {
    return {status: status, headers: new Map<String, String>(), body: body};
  }

  private function send(core:LisCore):Dynamic {
    var outcome:Dynamic = null;
    core.createOrder(orderJson(), function(json) {
      outcome = Json.parse(json);
    });
    return outcome;
  }

  public function testSetIfAbsentStoresOnlyOnce() {
    var storage = new MemoryStorage();
    Assert.isTrue(storage.setIfAbsent("k", "a", 0));
    Assert.isFalse(storage.setIfAbsent("k", "b", 0));
    Assert.equals("a", storage.get("k"));
  }

  public function testSetIfAbsentSucceedsAgainAfterExpiry() {
    var nowMs = 1000.0;
    var storage = new MemoryStorage(function() return nowMs);
    Assert.isTrue(storage.setIfAbsent("k", "a", 30));
    nowMs += 29000.0;
    Assert.isFalse(storage.setIfAbsent("k", "b", 30));
    nowMs += 2000.0;
    Assert.isTrue(storage.setIfAbsent("k", "b", 30));
    Assert.equals("b", storage.get("k"));
  }

  public function testCreateOrderIsRejectedWhileAnotherSubmissionRuns() {
    var mock = MockPlatform.create();
    mock.storage.map.set("inflight:ORD-1", "1");
    var core = new LisCore(CONFIG, mock.platform);

    var outcome = send(core);

    Assert.isFalse(outcome.ok);
    Assert.equals("ORDER_IN_PROGRESS", outcome.error.code);
    Assert.isTrue(outcome.error.retryable);
    Assert.equals(0, mock.http.requests.length);
    Assert.equals("1", mock.storage.map.get("inflight:ORD-1"));
  }

  public function testLockIsReleasedAfterSuccessfulSend() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, ORDER_OK_BODY));
    var core = new LisCore(CONFIG, mock.platform);

    var outcome = send(core);

    Assert.isTrue(outcome.ok);
    Assert.equals("SENT", outcome.value.status);
    Assert.isFalse(mock.storage.map.exists("inflight:ORD-1"));
  }

  public function testLockIsReleasedAfterLisRejection() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(400, '{"code":400,"message":"bad"}'));
    mock.http.responseQueue.push(respond(200, ORDER_OK_BODY));
    var core = new LisCore(CONFIG, mock.platform);

    var first = send(core);
    var second = send(core);

    Assert.equals("LIS_REJECTED", first.error.code);
    Assert.isFalse(mock.storage.map.exists("inflight:ORD-1"));
    Assert.isTrue(second.ok);
  }

  public function testIdenticalOrderAfterSuccessIsUnchangedNotInProgress() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, ORDER_OK_BODY));
    var core = new LisCore(CONFIG, mock.platform);

    send(core);
    var second = send(core);

    Assert.equals("UNCHANGED", second.value.status);
    Assert.equals(1, mock.http.requests.length);
  }
}
