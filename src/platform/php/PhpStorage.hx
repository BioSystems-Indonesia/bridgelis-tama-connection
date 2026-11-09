/**
 * PHP filesystem key-value storage with TTL according to LLD §3.1.
 * Atomic writes, expiration eviction, and memory fallback when unwritable.
 */
package platform.php;

import platform.Platform.IStorage;
import platform.Platform.IHash;
import platform.Platform.IClock;
import platform.MemoryStorage;
import haxe.Json;
import php.Global;

class PhpStorage implements IStorage {
  private static inline var MAX_ATTEMPTS:Int = 5;

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
      baseDir = Global.sys_get_temp_dir() + "/bridgelis-tama-connection";
    }

    var baseHash = hash.sha256Hex(baseUrl).substr(0, 12);
    this.targetDir = baseDir + "/" + baseHash;

    if (!ensureDir()) {
      triggerMemoryFallback();
    }
  }

  /**
   * Creates the storage folder. On PHP 7.4 a recursive mkdir fails when another process creates
   * the same parent at that moment, which is not a sign of an unwritable disk, so it is retried.
   */
  private function ensureDir():Bool {
    for (attempt in 0...MAX_ATTEMPTS) {
      if (php.Syntax.code("is_dir({0})", this.targetDir)) {
        return true;
      }
      php.Syntax.code("@mkdir({0}, 0777, true)", this.targetDir);
      if (php.Syntax.code("is_dir({0})", this.targetDir)) {
        return true;
      }
      Global.usleep(2000);
    }
    return false;
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
    var fileExists:Bool = php.Syntax.code("file_exists({0})", filePath);
    if (!fileExists) {
      return null;
    }

    var raw = php.Syntax.code("@file_get_contents({0})", filePath);
    if (raw == null || raw == false) {
      return null;
    }

    try {
      var parsed:Dynamic = Json.parse(Std.string(raw));
      var exp:Float = Reflect.field(parsed, "exp");
      var now = clock.nowMs();
      if (exp > 0 && exp < now) {
        php.Syntax.code("@unlink({0})", filePath);
        return null;
      }
      return Reflect.field(parsed, "v");
    } catch (_:Dynamic) {
      // Corrupted file unlinked and ignored
      php.Syntax.code("@unlink({0})", filePath);
      return null;
    }
  }

  public function set(key:String, value:String, ttlSec:Int):Void {
    if (isMemoryOnly) {
      memoryFallback.set(key, value, ttlSec);
      return;
    }

    ensureDir();

    var filePath = getFilePath(key);
    var now = clock.nowMs();
    var exp:Float = ttlSec > 0 ? (now + (ttlSec * 1000.0)) : 0.0;
    var data = Json.stringify({v: value, exp: exp});

    var rand = Std.string(Global.mt_rand(100000, 999999));
    var tmpPath = filePath + ".tmp-" + rand;

    var written:Dynamic = php.Syntax.code("@file_put_contents({0}, {1})", tmpPath, data);
    if (written == false) {
      triggerMemoryFallback();
      memoryFallback.set(key, value, ttlSec);
      return;
    }

    var renamed = false;
    for (i in 0...3) {
      if (php.Syntax.code("@rename({0}, {1})", tmpPath, filePath)) {
        renamed = true;
        break;
      }
      Global.usleep(10000); // 10ms
    }

    if (!renamed) {
      if (php.Syntax.code("@copy({0}, {1})", tmpPath, filePath)) {
        php.Syntax.code("@unlink({0})", tmpPath);
      } else {
        triggerMemoryFallback();
        memoryFallback.set(key, value, ttlSec);
      }
    }
  }

  /**
   * Creates the entry file exclusively (mode "x"), so of several callers only one succeeds.
   * An existing file blocks the caller unless it has expired; an expired one is removed and
   * the creation is tried once more. Atomic on a local disk; not reliable on network shares.
   */
  public function setIfAbsent(key:String, value:String, ttlSec:Int):Bool {
    if (isMemoryOnly) {
      return memoryFallback.setIfAbsent(key, value, ttlSec);
    }

    ensureDir();

    var filePath = getFilePath(key);
    var exp:Float = ttlSec > 0 ? (clock.nowMs() + (ttlSec * 1000.0)) : 0.0;
    var data = Json.stringify({v: value, exp: exp});

    for (attempt in 0...MAX_ATTEMPTS) {
      var handle:Dynamic = php.Syntax.code("@fopen({0}, 'x')", filePath);
      if (handle != false) {
        php.Syntax.code("fwrite({0}, {1})", handle, data);
        php.Syntax.code("fclose({0})", handle);
        return true;
      }
      var fileExists:Bool = php.Syntax.code("file_exists({0})", filePath);
      if (fileExists) {
        if (!removeIfExpired(filePath)) {
          return false;
        }
      } else {
        // Missing after a failed create: the owner released it just now, or the folder is gone.
        ensureDir();
      }
    }

    // Only a file that can never be created means the disk is unusable: a per-process lock
    // would otherwise let every process send.
    if (php.Syntax.code("file_exists({0})", filePath)) {
      return false;
    }
    triggerMemoryFallback();
    return memoryFallback.setIfAbsent(key, value, ttlSec);
  }

  /**
   * Removes an entry file that has expired. A file that cannot be parsed is treated as live:
   * it may be mid-write by the caller that just won the creation race.
   */
  private function removeIfExpired(filePath:String):Bool {
    var raw = php.Syntax.code("@file_get_contents({0})", filePath);
    if (raw == null || raw == false) {
      return false;
    }
    try {
      var parsed:Dynamic = Json.parse(Std.string(raw));
      var exp:Float = Reflect.field(parsed, "exp");
      if (exp > 0 && exp < clock.nowMs()) {
        php.Syntax.code("@unlink({0})", filePath);
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
    var exists:Bool = php.Syntax.code("file_exists({0})", filePath);
    if (exists) {
      php.Syntax.code("@unlink({0})", filePath);
    }
  }

  private function getFilePath(key:String):String {
    var keyHash = hash.sha256Hex(key).substr(0, 24);
    return targetDir + "/" + keyHash + ".json";
  }
}
