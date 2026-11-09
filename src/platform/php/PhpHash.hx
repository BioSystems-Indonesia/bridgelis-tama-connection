/**
 * PHP SHA-256 hash implementation using native hash function.
 */
package platform.php;

import platform.Platform.IHash;
import php.Global;

class PhpHash implements IHash {
  public function new() {}

  public function sha256Hex(s:String):String {
    return Global.hash("sha256", s);
  }
}

