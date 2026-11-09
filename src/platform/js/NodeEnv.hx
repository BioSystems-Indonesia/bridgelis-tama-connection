/**
 * Node.js process.env reader.
 */
package platform.js;

import platform.Platform.IEnv;

class NodeEnv implements IEnv {
  public function new() {}

  public function get(name:String):Null<String> {
    var val = Reflect.field(js.Node.process.env, name);
    return val != null ? Std.string(val) : null;
  }
}

