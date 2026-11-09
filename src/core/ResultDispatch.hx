/**
 * Builds the result event and hands it to the SIMRS handler. Shared by the webhook and
 * reconcile(), so both deliver exactly the same event shape (LLD §7.2).
 */
package core;

import core.Results.ResultState;
import haxe.Json;

/** Event given to `onResult`; `patient` and `order` are the LIS payload as received. */
typedef ResultEvent = {
  order_id:String,
  is_final:Bool,
  received_at:String,
  patient:Dynamic,
  order:Dynamic
};

/** Calls `done(null)` on success or `done(message)` on failure. */
typedef ResultHandler = (eventJson:String, done:(err:Null<String>)->Void)->Void;

class ResultDispatch {
  /** Builds the event for an AVAILABLE result; `receivedAt` is the delivery time (ISO). */
  public static function buildEvent(
    orderId:String,
    result:ResultState,
    receivedAt:String
  ):ResultEvent {
    return {
      order_id: orderId,
      is_final: HisApi.isOrderFinal(result.order),
      received_at: receivedAt,
      patient: result.patient,
      order: result.order
    };
  }

  /**
   * Runs the handler and reports its outcome through `next`: null on success, otherwise the
   * failure text. A throwing handler is reported as a failure, never rethrown (user code).
   */
  public static function run(
    handler:ResultHandler,
    event:ResultEvent,
    next:Null<String>->Void
  ):Void {
    try {
      handler(Json.stringify(event), function(handlerErr:Null<String>) {
        var failed = handlerErr != null && handlerErr.length > 0;
        next(failed ? handlerErr : null);
      });
    } catch (e:Dynamic) {
      next("handler threw: " + Std.string(e));
    }
  }
}
