/**
 * In-memory fallback implementation of IStorage.
 * Used when file storage directory is unwritable or during isolated unit testing.
 */
package platform;

import platform.Platform.IStorage;

typedef MemoryStorageEntry = {
  v:String,
  exp:Float
};

class MemoryStorage implements IStorage {
  private var entries:Map<String, MemoryStorageEntry>;
  private var nowFn:Void->Float;

  public function new(?nowFn:Void->Float) {
    this.entries = new Map<String, MemoryStorageEntry>();
    this.nowFn = nowFn != null ? nowFn : function() return Date.now().getTime();
  }

  public function get(key:String):Null<String> {
    if (!entries.exists(key)) {
      return null;
    }
    var entry = entries.get(key);
    var now = nowFn();
    if (entry.exp > 0 && entry.exp < now) {
      entries.remove(key);
      return null;
    }
    return entry.v;
  }

  public function set(key:String, value:String, ttlSec:Int):Void {
    var now = nowFn();
    var exp:Float = ttlSec > 0 ? (now + (ttlSec * 1000.0)) : 0.0;
    entries.set(key, {v: value, exp: exp});
  }

  public function setIfAbsent(key:String, value:String, ttlSec:Int):Bool {
    if (get(key) != null) {
      return false;
    }
    set(key, value, ttlSec);
    return true;
  }

  public function delete(key:String):Void {
    entries.remove(key);
  }

  public function clear():Void {
    entries = new Map<String, MemoryStorageEntry>();
  }
}

