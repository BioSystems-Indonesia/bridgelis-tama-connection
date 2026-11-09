package;

import platform.Platform;

class MockPlatform {
  public static function create():{
    platform:Platform,
    http:MockHttp,
    storage:MockStorage,
    env:MockPlatformEnv,
    clock:MockClock,
    logger:MockLogger
  } {
    var http = new MockHttp();
    var storage = new MockStorage();
    var env = new MockPlatformEnv();
    var clock = new MockClock();
    var hash = new MockHash();
    var logger = new MockLogger();
    var platform = new Platform(http, storage, env, clock, hash, logger, "test");
    return {
      platform: platform,
      http: http,
      storage: storage,
      env: env,
      clock: clock,
      logger: logger
    };
  }
}

class MockHttp implements IHttp {
  public var requests:Array<HttpRequest> = [];
  public var responseQueue:Array<HttpResponse> = [];
  public var defaultResponse:HttpResponse = {
    status: 200,
    headers: new Map<String, String>(),
    body: "{\"status\":200,\"data\":[]}"
  };

  public function new() {}

  public function request(req:HttpRequest, cb:HttpResponse->Void):Void {
    requests.push(req);
    if (responseQueue.length > 0) {
      cb(responseQueue.shift());
    } else {
      cb(defaultResponse);
    }
  }
}

class MockStorage implements IStorage {
  public var map:Map<String, String> = new Map<String, String>();

  public function new() {}

  public function get(key:String):Null<String> {
    return map.get(key);
  }

  public function set(key:String, value:String, ttlSec:Int):Void {
    map.set(key, value);
  }

  public function setIfAbsent(key:String, value:String, ttlSec:Int):Bool {
    if (map.exists(key)) {
      return false;
    }
    map.set(key, value);
    return true;
  }

  public function delete(key:String):Void {
    map.remove(key);
  }
}

class MockPlatformEnv implements IEnv {
  public var env:Map<String, String> = new Map<String, String>();

  public function new() {}

  public function get(name:String):Null<String> {
    return env.get(name);
  }
}

class MockClock implements IClock {
  public var currentMs:Float = 1700000000000.0;

  public function new(?startMs:Float) {
    if (startMs != null) {
      currentMs = startMs;
    }
  }

  public function nowMs():Float {
    return currentMs;
  }

  public function sleep(ms:Int, cb:Void->Void):Void {
    currentMs += ms;
    cb();
  }

  public function isoString(?epochMs:Float):String {
    var t = epochMs != null ? epochMs : currentMs;
    var d = Date.fromTime(t);
    return d.toString();
  }

  public function advance(ms:Float):Void {
    currentMs += ms;
  }
}

class MockHash implements IHash {
  public function new() {}

  public function sha256Hex(s:String):String {
    return haxe.crypto.Sha256.encode(s);
  }
}

class MockLogger implements ILogger {
  public var logs:Array<{level:String, msg:String, ctx:Dynamic}> = [];

  public function new() {}

  public function log(level:String, msg:String, ctx:Dynamic):Void {
    logs.push({level: level, msg: msg, ctx: ctx});
  }
}
