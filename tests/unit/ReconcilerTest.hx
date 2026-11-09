package;

import utest.Test;
import utest.Assert;
import core.LisCore;
import haxe.Json;
import platform.Platform.HttpResponse;

/** reconcile(): window listing, non-SIMRS filter, skip, limit, failures (HLD D12). */
class ReconcilerTest extends Test {
  static inline var CONFIG:String =
    '{"baseUrl":"http://lis.local","apiKey":"k","logLevel":"error"}';

  private function respond(status:Int, body:String):HttpResponse {
    return {status: status, headers: new Map<String, String>(), body: body};
  }

  private function row(orderId:String, simrs:Bool = true):Dynamic {
    return {
      id: 1,
      order_id: orderId,
      barcode_simrs: simrs ? orderId : "",
      work_order_status: "SUCCESS"
    };
  }

  private function listBody(rows:Array<Dynamic>):String {
    return Json.stringify({code: 200, status: "SUCCESS", data: rows});
  }

  private function resultBody(status:String, resultStatus:String):String {
    return Json.stringify({
      code: 200,
      status: "SUCCESS",
      data: {
        patient: {medical_record_number: "RM-1"},
        order: {status: status, results: [{test_code: "GLU", status: resultStatus}]}
      }
    });
  }

  private function reconcile(
    mock:Dynamic,
    options:String,
    ?skip:core.Reconciler.ReconcileSkip,
    ?events:Array<Dynamic>,
    ?handlerError:String
  ):Dynamic {
    var core = new LisCore(CONFIG, mock.platform);
    var handler:core.ResultDispatch.ResultHandler = function(eventJson, done) {
      if (events != null) {
        events.push(Json.parse(eventJson));
      }
      done(handlerError);
    };
    var outcome:Dynamic = null;
    core.reconcile(options, skip, handler, function(json) {
      outcome = Json.parse(json);
    });
    return outcome;
  }

  public function testDeliversFinalResultsOfSimrsOrders() {
    var mock = MockPlatform.create();
    var rows = [row("A"), row("LIS-ONLY", false), row("B")];
    mock.http.responseQueue.push(respond(200, listBody(rows)));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    var events:Array<Dynamic> = [];

    var outcome = reconcile(mock, '{"since":"2026-11-04"}', null, events);

    Assert.isTrue(outcome.ok);
    Assert.equals(2, outcome.value.checked);
    Assert.equals(2, outcome.value.delivered);
    Assert.isFalse(outcome.value.truncated);
    Assert.equals("A", events[0].order_id);
    Assert.isTrue(events[0].is_final);
    Assert.equals(3, mock.http.requests.length);
    Assert.isTrue(mock.http.requests[0].url.indexOf("from=2026-11-04") != -1);
    Assert.isTrue(mock.http.requests[0].url.indexOf("status=COMPLETED") != -1);
  }

  public function testNonFinalAndPendingResultsAreNotDelivered() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Preliminary")));
    mock.http.responseQueue.push(respond(404, '{"code":404,"message":"not ready"}'));
    var events:Array<Dynamic> = [];

    var outcome = reconcile(mock, '{"since":"2026-11-04"}', null, events);

    Assert.equals(2, outcome.value.pending);
    Assert.equals(0, outcome.value.delivered);
    Assert.equals(0, events.length);
  }

  public function testSkippedOrdersAreNotFetched() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    var asked:Array<String> = [];
    var skip:core.Reconciler.ReconcileSkip = function(orderId, answer) {
      asked.push(orderId);
      answer(orderId == "A", null);
    };

    var outcome = reconcile(mock, '{"since":"2026-11-04"}', skip);

    Assert.equals(1, outcome.value.skipped);
    Assert.equals(1, outcome.value.delivered);
    Assert.equals(2, mock.http.requests.length);
    Assert.equals(2, asked.length);
  }

  public function testHandlerFailureIsReportedAndOthersContinue() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));

    var outcome = reconcile(mock, '{"since":"2026-11-04"}', null, null, "db down");

    Assert.equals(2, outcome.value.checked);
    Assert.equals(0, outcome.value.delivered);
    Assert.equals(2, outcome.value.failed.length);
    Assert.equals("A", outcome.value.failed[0].order_id);
    Assert.equals("db down", outcome.value.failed[0].error);
  }

  public function testLimitStopsAndMarksTruncated() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B"), row("C")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));

    var outcome = reconcile(mock, '{"since":"2026-11-04","limit":1}');

    Assert.equals(1, outcome.value.checked);
    Assert.isTrue(outcome.value.truncated);
    Assert.equals(2, mock.http.requests.length);
  }

  public function testFollowsPagesUntilAShortPage() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B")])));
    mock.http.responseQueue.push(respond(200, listBody([row("C")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    var skip:core.Reconciler.ReconcileSkip = function(orderId, answer) {
      answer(orderId != "C", null);
    };

    var outcome = reconcile(mock, '{"since":"2026-11-04","limit":2}', skip);

    Assert.equals(2, outcome.value.skipped);
    Assert.equals(1, outcome.value.delivered);
    Assert.isFalse(outcome.value.truncated);
    Assert.isTrue(mock.http.requests[1].url.indexOf("page=2") != -1);
  }

  public function testSkipCheckFailureIsReportedAndNotFetched() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B")])));
    mock.http.responseQueue.push(respond(200, resultBody("COMPLETED", "Final")));
    var skip:core.Reconciler.ReconcileSkip = function(orderId, answer) {
      answer(false, orderId == "A" ? "db down" : null);
    };

    var outcome = reconcile(mock, '{"since":"2026-11-04"}', skip);

    Assert.equals(1, outcome.value.failed.length);
    Assert.equals("A", outcome.value.failed[0].order_id);
    Assert.equals(1, outcome.value.delivered);
    Assert.equals(2, mock.http.requests.length);
  }

  public function testAuthFailureStopsTheRun() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(200, listBody([row("A"), row("B"), row("C")])));
    mock.http.responseQueue.push(respond(401, '{"code":401,"message":"no"}'));

    var outcome = reconcile(mock, '{"since":"2026-11-04"}');

    Assert.equals(1, outcome.value.checked);
    Assert.equals(1, outcome.value.failed.length);
    Assert.isTrue(outcome.value.truncated);
    Assert.equals(2, mock.http.requests.length);
  }

  public function testListFailureIsReturnedAsError() {
    var mock = MockPlatform.create();
    mock.http.responseQueue.push(respond(403, '{"code":403}'));

    var outcome = reconcile(mock, '{"since":"2026-11-04"}');

    Assert.isFalse(outcome.ok);
    Assert.equals("BRIDGING_DISABLED", outcome.error.code);
  }

  public function testSinceIsRequired() {
    var mock = MockPlatform.create();

    var outcome = reconcile(mock, '{}');

    Assert.equals("VALIDATION_FAILED", outcome.error.code);
    Assert.equals("since", outcome.error.field);
    Assert.equals(0, mock.http.requests.length);
  }

  public function testInvalidLimitIsRejected() {
    var mock = MockPlatform.create();

    Assert.equals("limit", reconcile(mock, '{"since":"2026-11-04","limit":0}').error.field);
    Assert.equals("limit", reconcile(mock, '{"since":"2026-11-04","limit":1001}').error.field);
  }

  public function testMissingHandlerIsRejected() {
    var mock = MockPlatform.create();
    var core = new LisCore(CONFIG, mock.platform);
    var outcome:Dynamic = null;

    core.reconcile('{"since":"2026-11-04"}', null, null, function(json) {
      outcome = Json.parse(json);
    });

    Assert.equals("handler", outcome.error.field);
    Assert.equals(0, mock.http.requests.length);
  }

  public function testManySynchronousRowsDoNotOverflowTheStack() {
    var mock = MockPlatform.create();
    var rows:Array<Dynamic> = [];
    for (i in 0...100) {
      rows.push(row("ORD-" + i));
      mock.http.responseQueue.push(respond(404, '{"code":404,"message":"not ready"}'));
    }
    mock.http.responseQueue.insert(0, respond(200, listBody(rows)));

    var outcome = reconcile(mock, '{"since":"2026-11-04","limit":1000}');

    Assert.equals(100, outcome.value.pending);
  }
}
