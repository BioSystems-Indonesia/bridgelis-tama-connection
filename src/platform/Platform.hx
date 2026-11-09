/**
 * Platform abstraction layer for I/O operations (HTTP, storage, clock, hash, env, logging).
 * Decouples core logic from runtime specifics so core remains testable across PHP, Node.js,
 * and test doubles.
 */
package platform;

/**
 * HTTP client abstraction.
 * Never throws exceptions; network errors and timeouts are returned inside HttpResponse.
 */
interface IHttp {
  function request(req:HttpRequest, cb:HttpResponse->Void):Void;
}

/**
 * HTTP request payload definition.
 */
typedef HttpRequest = {
  method:String,
  url:String,
  headers:Map<String, String>,
  ?body:String,
  timeoutMs:Int,
  connectTimeoutMs:Int
};

/**
 * HTTP response envelope.
 */
typedef HttpResponse = {
  status:Int,
  headers:Map<String, String>,
  body:String,
  ?bodyBase64:String,
  ?networkError:String,
  ?timedOut:Bool
};

/**
 * Key-value storage abstraction with optional TTL expiration. SIMRS code may inject its own
 * implementation (for example a database table or a shared folder); the calls are synchronous. Experimental
 * until 1.0: the method set may still change.
 */
interface IStorage {
  function get(key:String):Null<String>;
  function set(key:String, value:String, ttlSec:Int):Void;
  function delete(key:String):Void;

  /**
   * Stores the value only when the key is absent or expired, in one atomic step.
   *
   * @return true when this call stored the value, false when a live value already exists
   */
  function setIfAbsent(key:String, value:String, ttlSec:Int):Bool;
}

/**
 * Environment variable provider abstraction.
 */
interface IEnv {
  function get(name:String):Null<String>;
}

/**
 * Clock abstraction for current time and sleep delays.
 */
interface IClock {
  function nowMs():Float;
  function sleep(ms:Int, cb:Void->Void):Void;
  function isoString(?epochMs:Float):String;
}

/**
 * Cryptographic hashing abstraction.
 */
interface IHash {
  function sha256Hex(s:String):String;
}

/**
 * Structured logger abstraction.
 */
interface ILogger {
  function log(level:String, msg:String, ctx:Dynamic):Void;
}

/**
 * Container bundling all platform implementations together.
 */
class Platform {
  public var http:IHttp;
  public var storage:IStorage;
  public var env:IEnv;
  public var clock:IClock;
  public var hash:IHash;
  public var logger:ILogger;
  public var name:String;

  public function new(
    http:IHttp,
    storage:IStorage,
    env:IEnv,
    clock:IClock,
    hash:IHash,
    logger:ILogger,
    ?name:String = "core"
  ) {
    this.http = http;
    this.storage = storage;
    this.env = env;
    this.clock = clock;
    this.hash = hash;
    this.logger = logger;
    this.name = name;
  }
}
