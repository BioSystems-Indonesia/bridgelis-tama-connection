/**
 * Turns every public core operation into exactly one JSON outcome (LLD §2).
 * Exceptions never cross the core boundary: a thrown LisError keeps its code, anything else is
 * reported as INTERNAL.
 */
package core;

import core.LisError.LisError;
import core.LisError.LisErrorHelper;
import haxe.Json;

class Outcomes {
  private var log:Log;

  public function new(log:Log) {
    this.log = log;
  }

  /**
   * Runs a public method body with a callback that can fire only once.
   * Synchronous exceptions (validation throws, bugs) become a single error outcome.
   */
  public function run(op:String, cb:String->Void, body:(String->Void)->Void):Void {
    var done = once(op, cb);
    protect(done, op, function() {
      body(done);
    });
  }

  /** Executes an (often asynchronous) continuation and turns any exception into an outcome. */
  public function protect(done:String->Void, op:String, fn:Void->Void):Void {
    try {
      fn();
    } catch (e:Dynamic) {
      fail(done, op, e);
    }
  }

  private function once(op:String, cb:String->Void):String->Void {
    var called = false;
    return function(outcomeJson:String) {
      if (called) {
        log.error(op, "Outcome reported twice; the second outcome was dropped.");
        return;
      }
      called = true;
      cb(outcomeJson);
    };
  }

  /** Thrown LisError keeps its code; anything else is a library bug reported as INTERNAL. */
  private function fail(done:String->Void, op:String, e:Dynamic):Void {
    if (e != null && Reflect.isObject(e) && Reflect.hasField(e, "code")) {
      error(done, cast e);
      return;
    }
    log.error(op, "Unexpected internal error: " + Std.string(e));
    error(done, LisErrorHelper.internalError("Unexpected internal error in " + op + "."));
  }

  /** Reports success; `value` is any JSON-serializable value. */
  public static function ok(cb:String->Void, value:Dynamic):Void {
    cb(Json.stringify({ok: true, value: value}));
  }

  public static function error(cb:String->Void, failure:LisError):Void {
    cb(Json.stringify({ok: false, error: failure}));
  }
}
