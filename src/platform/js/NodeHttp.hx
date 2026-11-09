/**
 * Node.js HTTP client using global fetch with AbortSignal.timeout according to LLD §3.
 * Never throws exceptions; network errors and timeouts are returned as response data.
 */
package platform.js;

import platform.Platform.IHttp;
import platform.Platform.HttpRequest;
import platform.Platform.HttpResponse;

class NodeHttp implements IHttp {
  public function new() {}

  public function request(req:HttpRequest, cb:HttpResponse->Void):Void {
    var headersObj:Dynamic = {};
    if (req.headers != null) {
      for (k in req.headers.keys()) {
        Reflect.setField(headersObj, k, req.headers.get(k));
      }
    }

    var options:Dynamic = {method: req.method, headers: headersObj};
    if (req.body != null && req.method != "GET" && req.method != "HEAD") {
      Reflect.setField(options, "body", req.body);
    }

    try {
      var globalAny:Dynamic = js.Lib.global;
      if (Reflect.hasField(globalAny, "AbortSignal") &&
          Reflect.hasField(globalAny.AbortSignal, "timeout")) {
        Reflect.setField(options, "signal", globalAny.AbortSignal.timeout(req.timeoutMs));
      }
    } catch (_:Dynamic) {
      // AbortSignal.timeout not supported in older runtimes; proceed without signal
    }

    var globalAny:Dynamic = js.Lib.global;
    var fetchFn:Dynamic = Reflect.field(globalAny, "fetch");

    var handleFetchCatch = function(err:Dynamic) {
      // Node fetch hides the real reason in `err.cause` (ECONNREFUSED, ENOTFOUND, ...); surface it.
      var errStr:String = js.Syntax.code("(function(e) { var s = String(e); var c = e && e.cause; if (c && (c.code || c.message)) { s += ' (' + (c.code ? c.code : '') + (c.code && c.message ? ': ' : '') + (c.message ? c.message : '') + ')'; } return s; })({0})", err);
      var timedOut = errStr.indexOf("TimeoutError") != -1 ||
                     errStr.indexOf("aborted") != -1 ||
                     errStr.indexOf("timeout") != -1;
      cb({
        status: 0,
        headers: new Map<String, String>(),
        body: "",
        networkError: errStr,
        timedOut: timedOut
      });
    };

    var handleResponse = function(res:Dynamic) {
      var status:Int = Reflect.field(res, "status");
      var resHeaders = readHeaders(res);

      var contentType:String = resHeaders.exists("content-type")
        ? resHeaders.get("content-type")
        : "";
      var isPdf = contentType.indexOf("application/pdf") != -1;

      if (isPdf) {
        handlePdfResponse(res, status, resHeaders, cb);
      } else {
        handleTextResponse(res, status, resHeaders, cb);
      }
    };

    try {
      var promise:Dynamic = Reflect.callMethod(null, fetchFn, [req.url, options]);
      js.Syntax.code("{0}.then({1}).catch({2})", promise, handleResponse, handleFetchCatch);
    } catch (e:Dynamic) {
      handleFetchCatch(e);
    }
  }

  /**
   * Copies fetch response headers into a Haxe map with lowercase names.
   * Pairs are collected as a plain JS array first: haxe.ds.StringMap has no runtime `set`
   * method (it is inlined by the compiler), so it cannot be filled from raw JS code.
   */
  private static function readHeaders(res:Dynamic):Map<String, String> {
    var headers = new Map<String, String>();
    var pairs:Array<Array<String>> = js.Syntax.code("(function(h) {
      var out = [];
      if (h && h.forEach) {
        h.forEach(function(v, k) { out.push([String(k).toLowerCase(), String(v)]); });
      }
      return out;
    })({0}.headers)", res);
    for (pair in pairs) {
      headers.set(pair[0], pair[1]);
    }
    return headers;
  }

  private function handlePdfResponse(
    res:Dynamic,
    status:Int,
    resHeaders:Map<String, String>,
    cb:HttpResponse->Void
  ):Void {
    var arrayBufPromise:Dynamic = res.arrayBuffer();
    js.Syntax.code("{0}.then(function(buf) {
      var b64 = Buffer.from(buf).toString('base64');
      {1}({
        status: {2},
        headers: {3},
        body: '',
        bodyBase64: b64,
        networkError: null,
        timedOut: false
      });
    }).catch(function(err) {
      {1}({
        status: {2},
        headers: {3},
        body: '',
        networkError: String(err),
        timedOut: false
      });
    })", arrayBufPromise, cb, status, resHeaders);
  }

  private function handleTextResponse(
    res:Dynamic,
    status:Int,
    resHeaders:Map<String, String>,
    cb:HttpResponse->Void
  ):Void {
    var textPromise:Dynamic = res.text();
    js.Syntax.code("{0}.then(function(text) {
      {1}({
        status: {2},
        headers: {3},
        body: text,
        networkError: null,
        timedOut: false
      });
    }).catch(function(err) {
      {1}({
        status: {2},
        headers: {3},
        body: '',
        networkError: String(err),
        timedOut: false
      });
    })", textPromise, cb, status, resHeaders);
  }
}
