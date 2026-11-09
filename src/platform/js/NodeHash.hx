/**
 * Node.js crypto SHA-256 implementation.
 */
package platform.js;

import platform.Platform.IHash;

class NodeHash implements IHash {
  public function new() {}

  public function sha256Hex(s:String):String {
    var crypto = js.node.Crypto;
    return crypto.createHash("sha256").update(s, "utf8").digest("hex");
  }
}

