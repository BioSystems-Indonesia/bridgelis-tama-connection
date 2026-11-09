/**
 * Node.js filesystem-based key-value storage with TTL according to LLD §3.1.
 * Atomic writes, automatic expiration eviction, and memory fallback when unwritable.
 */
package platform.js;

import platform.Platform.IStorage;
import platform.Platform.IHash;
import platform.Platform.IClock;
import platform.MemoryStorage;
import haxe.Json;

class NodeStorage implements IStorage {
  public var isMemoryOnly:Bool = false;
  private var targetDir:String;
  private var hash:IHash;
  private var clock:IClock;
  private var memoryFallback:MemoryStorage;
  private var onMemoryFallback:Null<Void->Void>;

  public function new(
    baseUrl:String,
    explicitDir:String,
    hash:IHash,
    clock:IClock,
    ?onMemoryFallback:Void->Void
  ) {
    this.hash = hash;
    this.clock = clock;
    this.onMemoryFallback = onMemoryFallback;
    this.memoryFallback = new MemoryStorage(function() return clock.nowMs());

    var baseDir = explicitDir;
    if (baseDir == null || baseDir.length == 0) {
      var os = js.node.Os;
      var path = js.node.Path;
      baseDir = path.join(os.tmpdir(), "bridgelis-tama-connection");
    }

    var baseHash = hash.sha256Hex(baseUrl).substr(0, 12);
    var path = js.node.Path;
    this.targetDir = path.join(baseDir, baseHash);

    try {
      var fs = js.node.Fs;
      if (!fs.existsSync(this.targetDir)) {
        js.Syntax.code("fs.mkdirSync({0}, { recursive: true })", this.targetDir);
      }
    } catch (e:Dynamic) {
      triggerMemoryFallback();
    }
  }

  private function triggerMemoryFallback():Void {
    if (!isMemoryOnly) {
      isMemoryOnly = true;
      if (onMemoryFallback != null) {
        onMemoryFallback();
      }
    }
  }

  public function get(key:String):Null<String> {
    if (isMemoryOnly) {
      return memoryFallback.get(key);
    }

    var filePath = getFilePath(key);
    var fs = js.node.Fs;
    if (!fs.existsSync(filePath)) {
      return null;
    }

    try {
      var raw = fs.readFileSync(filePath, "utf8");
      var parsed:Dynamic = Json.parse(raw);
      var exp:Float = Reflect.field(parsed, "exp");
      var now = clock.nowMs();
      if (exp > 0 && exp < now) {
        removeFile(filePath);
        return null;
      }
      return Reflect.field(parsed, "v");
    } catch (_:Dynamic) {
      removeFile(filePath);
      return null;
    }
  }

  public function set(key:String, value:String, ttlSec:Int):Void {
    if (isMemoryOnly) {
      memoryFallback.set(key, value, ttlSec);
      return;
    }

    var filePath = getFilePath(key);
    var now = clock.nowMs();
    var exp:Float = ttlSec > 0 ? (now + (ttlSec * 1000.0)) : 0.0;
    var data = Json.stringify({v: value, exp: exp});

    var fs = js.node.Fs;
    var rand = Std.string(Std.random(1000000));
    var tmpPath = filePath + ".tmp-" + rand;

    try {
      fs.writeFileSync(tmpPath, data, "utf8");
      renameWithRetry(tmpPath, filePath, 3);
    } catch (e:Dynamic) {
      triggerMemoryFallback();
      memoryFallback.set(key, value, ttlSec);
    }
  }

  /**
   * Creates the entry file exclusively (flag "wx"), so of several callers only one succeeds.
   * An existing file blocks the caller unless it has expired; an expired one is removed and
   * the creation is tried once more. Atomic on a local disk; not reliable on network shares.
   */
  public function setIfAbsent(key:String, value:String, ttlSec:Int):Bool {
    if (isMemoryOnly) {
      return memoryFallback.setIfAbsent(key, value, ttlSec);
    }

    var filePath = getFilePath(key);
    var exp:Float = ttlSec > 0 ? (clock.nowMs() + (ttlSec * 1000.0)) : 0.0;
    var data = Json.stringify({v: value, exp: exp});

    for (attempt in 0...2) {
      try {
        js.node.Fs.writeFileSync(filePath, data, {encoding: "utf8", flag: "wx"});
        return true;
      } catch (e:Dynamic) {
        if (Reflect.field(e, "code") != "EEXIST") {
          triggerMemoryFallback();
          return memoryFallback.setIfAbsent(key, value, ttlSec);
        }
        if (!removeIfExpired(filePath)) {
          return false;
        }
      }
    }
    return false;
  }

  /**
   * Removes an entry file that has expired. A file that cannot be parsed is treated as live:
   * it may be mid-write by the caller that just won the creation race.
   */
  private function removeIfExpired(filePath:String):Bool {
    try {
      var parsed:Dynamic = Json.parse(js.node.Fs.readFileSync(filePath, "utf8"));
      var exp:Float = Reflect.field(parsed, "exp");
      if (exp > 0 && exp < clock.nowMs()) {
        removeFile(filePath);
        return true;
      }
    } catch (_:Dynamic) {
      // Unreadable or half-written: keep it, the owner is still working.
    }
    return false;
  }

  public function delete(key:String):Void {
    if (isMemoryOnly) {
      memoryFallback.delete(key);
      return;
    }
    var filePath = getFilePath(key);
    var fs = js.node.Fs;
    if (fs.existsSync(filePath)) {
      removeFile(filePath);
    }
  }

  /**
   * Deletes a cache file. A failure (file already gone, locked on Windows) is ignored on
   * purpose: storage holds only rebuildable hashes and the stale entry expires by TTL.
   */
  private static function removeFile(filePath:String):Void {
    try {
      js.node.Fs.unlinkSync(filePath);
    } catch (_:Dynamic) {
      // See doc above: losing a cache delete is harmless.
    }
  }

  private function getFilePath(key:String):String {
    var keyHash = hash.sha256Hex(key).substr(0, 24);
    var path = js.node.Path;
    return path.join(targetDir, keyHash + ".json");
  }

  private function renameWithRetry(src:String, dest:String, retries:Int):Void {
    var fs = js.node.Fs;
    for (i in 0...retries) {
      try {
        fs.renameSync(src, dest);
        return;
      } catch (e:Dynamic) {
        if (i == retries - 1) {
          try {
            js.Syntax.code("fs.copyFileSync({0}, {1})", src, dest);
            fs.unlinkSync(src);
            return;
          } catch (_:Dynamic) {
            throw e;
          }
        }
      }
    }
  }
}
