/**
 * PHP clock implementation using microtime, usleep, and gmdate according to LLD §3.
 */
package platform.php;

import platform.Platform.IClock;
import php.Global;

class PhpClock implements IClock {
  public function new() {}

  public function nowMs():Float {
    var mt:Float = cast Global.microtime(true);
    return mt * 1000.0;
  }

  public function sleep(ms:Int, cb:Void->Void):Void {
    Global.usleep(ms * 1000);
    cb();
  }

  public function isoString(?epochMs:Float):String {
    var sec:Int = epochMs != null ? Std.int(epochMs / 1000.0) : Global.time();
    return Global.gmdate("Y-m-d\\TH:i:s\\Z", sec);
  }
}
