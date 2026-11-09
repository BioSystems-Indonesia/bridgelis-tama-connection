/**
 * Reads results from the LIS: the latest result and the PDF (LLD §7.3).
 * A 404 on the result endpoint means "not ready yet", not an error (HLD F5).
 */
package core;

import core.LisError.LisError;

/** Result state; `patient` and `order` are present only when `state` is AVAILABLE. */
typedef ResultState = {
  state:String,
  ?is_final:Bool,
  ?patient:Dynamic,
  ?order:Dynamic
};

typedef ResultCallback = (err:Null<LisError>, res:Null<ResultState>) -> Void;

class Results {
  private var his:HisClient;
  private var outcomes:Outcomes;

  public function new(his:HisClient, outcomes:Outcomes) {
    this.his = his;
    this.outcomes = outcomes;
  }

  /**
   * Fetches the latest result. The continuation runs inside `protect`, so an exception in it
   * still produces one outcome on `done`.
   */
  public function fetch(done:String->Void, orderId:String, next:ResultCallback):Void {
    var req = his.buildRequest("GET", resultPath(orderId), null);
    his.guard.call(req, function(err, res) {
      outcomes.protect(done, "getResult", function() {
        if (err != null) {
          next(err, null);
          return;
        }
        if (res.status == 404) {
          next(null, {state: "PENDING"});
          return;
        }
        if (res.status != 200) {
          next(HisClient.errorFromResponse(res), null);
          return;
        }
        next(null, toResultState(HisApi.parseEnvelope(res.body).data));
      });
    });
  }

  /** Reports the latest result as the outcome of `getResult`. */
  public function get(done:String->Void, orderId:String):Void {
    fetch(done, orderId, function(err, result) {
      if (err != null) {
        Outcomes.error(done, err);
        return;
      }
      Outcomes.ok(done, result);
    });
  }

  /** Reports the result PDF (base64) as the outcome of `getResultPdf`. */
  public function getPdf(done:String->Void, orderId:String):Void {
    var req = his.buildRequest("GET", resultPath(orderId) + "/pdf", null);
    req.headers.set("Accept", "application/pdf");
    his.guard.call(req, function(err, res) {
      outcomes.protect(done, "getResultPdf", function() {
        if (err != null) {
          Outcomes.error(done, err);
          return;
        }
        if (res.status != 200) {
          Outcomes.error(done, HisClient.errorFromResponse(res));
          return;
        }
        Outcomes.ok(done, res.bodyBase64 != null ? res.bodyBase64 : "");
      });
    });
  }

  private static function resultPath(orderId:String):String {
    return "/result/" + HisApi.encodePathParam(orderId);
  }

  private static function toResultState(data:Dynamic):ResultState {
    var orderData:Dynamic = data != null ? Reflect.field(data, "order") : null;
    return {
      state: "AVAILABLE",
      is_final: HisApi.isOrderFinal(orderData),
      patient: data != null ? Reflect.field(data, "patient") : null,
      order: orderData
    };
  }
}
