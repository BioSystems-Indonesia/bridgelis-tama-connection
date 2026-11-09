/**
 * Node.js console logger implementation.
 */
package platform.js;

import platform.Platform.ILogger;
import haxe.Json;

class NodeLogger implements ILogger {
  private var customLogger:Null<Dynamic>;

  public function new(?customLogger:Dynamic) {
    this.customLogger = customLogger;
  }

  public function log(level:String, msg:String, ctx:Dynamic):Void {
    if (customLogger != null && Reflect.isFunction(customLogger)) {
      try {
        Reflect.callMethod(null, customLogger, [level, msg, ctx]);
        return;
      } catch (_:Dynamic) {
        // A broken custom logger must never break the SIMRS; fall back to the default output.
      }
    }

    var serializedCtx = ctx != null ? " " + Json.stringify(ctx) : "";
    var line = "[" + level.toUpperCase() + "] " + msg + serializedCtx;
    switch (level) {
      case "error":
        js.Node.console.error(line);
      case "warn":
        js.Node.console.warn(line);
      default:
        js.Node.console.log(line);
    }
  }
}

