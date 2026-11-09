/**
 * PHP logger: forwards to a PSR-3 logger when one is given, otherwise writes with error_log.
 * Messages and context arrive already PHI-masked by core.Log.
 */
package platform.php;

import platform.Platform.ILogger;
import haxe.Json;
import php.Global;

class PhpLogger implements ILogger {
  private var psrLogger:Null<Dynamic>;

  /**
   * @param psrLogger  optional object with a PSR-3 `log($level, $message, array $context)` method
   */
  public function new(?psrLogger:Dynamic) {
    this.psrLogger = psrLogger;
  }

  public function log(level:String, msg:String, ctx:Dynamic):Void {
    if (hasPsrLogger()) {
      try {
        var context:Dynamic = php.Syntax.code("is_object({0}) ? get_object_vars({0}) : []", ctx);
        php.Syntax.code("{0}->log({1}, {2}, {3})", psrLogger, toPsrLevel(level), msg, context);
        return;
      } catch (_:Dynamic) {
        // A broken custom logger must never break the SIMRS; fall back to the default output.
      }
    }

    var serializedCtx = ctx != null ? " " + Json.stringify(ctx) : "";
    Global.error_log("[bridgeLIS " + level.toUpperCase() + "] " + msg + serializedCtx);
  }

  /** Reflect.hasField only sees properties on PHP objects, so methods are checked natively. */
  private function hasPsrLogger():Bool {
    if (psrLogger == null) {
      return false;
    }
    return php.Syntax.code("is_object({0}) && method_exists({0}, 'log')", psrLogger);
  }

  /** PSR-3 names the warn level "warning"; the other core levels map one to one. */
  private static function toPsrLevel(level:String):String {
    return level == "warn" ? "warning" : level;
  }
}
