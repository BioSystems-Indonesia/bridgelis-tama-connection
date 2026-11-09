/**
 * Node.js clock implementation using standard timers and Date.
 */
package platform.js;

import platform.Platform.IClock;

class NodeClock implements IClock {
  public function new() {}

  public function nowMs():Float {
    return Date.now().getTime();
  }

  public function sleep(ms:Int, cb:Void->Void):Void {
    js.Node.setTimeout(cb, ms);
  }

  public function isoString(?epochMs:Float):String {
    var ms = epochMs != null ? epochMs : nowMs();
    var d:Dynamic = js.Syntax.code("new Date({0})", ms);
    return js.Syntax.code("{0}.toISOString()", d);
  }
}
