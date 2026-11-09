/**
 * PHP environment variable reader checking getenv(), $_ENV, and $_SERVER.
 */
package platform.php;

import platform.Platform.IEnv;
import php.Global;

class PhpEnv implements IEnv {
  public function new() {}

  public function get(name:String):Null<String> {
    var fromGetenv = Global.getenv(name);
    if (fromGetenv != null && fromGetenv != false && Std.string(fromGetenv).length > 0) {
      return Std.string(fromGetenv);
    }

    var fromEnv:Dynamic = php.Syntax.code("isset($_ENV[{0}]) ? $_ENV[{0}] : null", name);
    if (fromEnv != null && Std.string(fromEnv).length > 0) {
      return Std.string(fromEnv);
    }

    var fromServer:Dynamic = php.Syntax.code("isset($_SERVER[{0}]) ? $_SERVER[{0}] : null", name);
    if (fromServer != null && Std.string(fromServer).length > 0) {
      return Std.string(fromServer);
    }

    return null;
  }
}
