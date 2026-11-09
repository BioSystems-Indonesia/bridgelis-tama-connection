/**
 * PHP HTTP client using cURL with stream context fallback according to LLD §3.
 * Synchronous and exception-safe: network errors and timeouts are returned as response data.
 */
package platform.php;

import platform.Platform.IHttp;
import platform.Platform.HttpRequest;
import platform.Platform.HttpResponse;
import php.Global;

class PhpHttp implements IHttp {
  public function new() {}

  public function request(req:HttpRequest, cb:HttpResponse->Void):Void {
    var hasCurl:Bool = php.Syntax.code("function_exists('curl_init')");
    if (hasCurl) {
      requestViaCurl(req, cb);
    } else {
      requestViaStream(req, cb);
    }
  }

  private function requestViaCurl(req:HttpRequest, cb:HttpResponse->Void):Void {
    var ch:Dynamic = php.Syntax.code("@curl_init()");
    php.Syntax.code("@curl_setopt({0}, CURLOPT_URL, {1})", ch, req.url);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_RETURNTRANSFER, true)", ch);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_HEADER, true)", ch);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_TIMEOUT_MS, {1})", ch, req.timeoutMs);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_CONNECTTIMEOUT_MS, {1})", ch, req.connectTimeoutMs);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_CUSTOMREQUEST, {1})", ch, req.method);

    var rawHeaders = new Array<String>();
    if (req.headers != null) {
      for (k in req.headers.keys()) {
        rawHeaders.push(k + ": " + req.headers.get(k));
      }
    }
    var phpHeaders:Dynamic = php.Lib.toPhpArray(rawHeaders);
    php.Syntax.code("@curl_setopt({0}, CURLOPT_HTTPHEADER, {1})", ch, phpHeaders);

    if (req.body != null && req.method != "GET" && req.method != "HEAD") {
      php.Syntax.code("@curl_setopt({0}, CURLOPT_POSTFIELDS, {1})", ch, req.body);
    }

    var response:Dynamic = php.Syntax.code("@curl_exec({0})", ch);

    if (response == false) {
      var errNo:Int = php.Syntax.code("@curl_errno({0})", ch);
      var errMsg:String = Std.string(php.Syntax.code("@curl_error({0})", ch));
      php.Syntax.code("@curl_close({0})", ch);
      cb({
        status: 0,
        headers: new Map<String, String>(),
        body: "",
        networkError: errMsg.length > 0 ? errMsg : "cURL error #" + errNo,
        timedOut: (errNo == 28)
      });
      return;
    }

    var headerSize:Int = php.Syntax.code("@curl_getinfo({0}, CURLINFO_HEADER_SIZE)", ch);
    var httpCode:Int = php.Syntax.code("@curl_getinfo({0}, CURLINFO_HTTP_CODE)", ch);
    php.Syntax.code("@curl_close({0})", ch);

    var respStr:String = Std.string(response);
    var rawHeaderPart = respStr.substr(0, headerSize);
    var bodyPart = respStr.substr(headerSize);

    var parsedHeaders = parseHttpHeaders(rawHeaderPart);
    var contentType = parsedHeaders.exists("content-type") ? parsedHeaders.get("content-type") : "";
    var isPdf = contentType.indexOf("application/pdf") != -1;
    var b64:Null<String> = isPdf ? Std.string(Global.base64_encode(bodyPart)) : null;

    cb({
      status: httpCode,
      headers: parsedHeaders,
      body: isPdf ? "" : bodyPart,
      bodyBase64: b64,
      networkError: null,
      timedOut: false
    });
  }

  private function requestViaStream(req:HttpRequest, cb:HttpResponse->Void):Void {
    var rawHeaders = "";
    if (req.headers != null) {
      for (k in req.headers.keys()) {
        rawHeaders += k + ": " + req.headers.get(k) + "\r\n";
      }
    }

    var httpOpts:Dynamic = {
      method: req.method,
      header: rawHeaders,
      timeout: req.timeoutMs / 1000.0,
      ignore_errors: true
    };

    if (req.body != null && req.method != "GET" && req.method != "HEAD") {
      Reflect.setField(httpOpts, "content", req.body);
    }

    var context:Dynamic = php.Syntax.code(
      "@stream_context_create(['http' => (array){0}])",
      httpOpts
    );
    var bodyResult = php.Syntax.code("@file_get_contents({0}, false, {1})", req.url, context);

    if (bodyResult == false) {
      cb({
        status: 0,
        headers: new Map<String, String>(),
        body: "",
        networkError: "stream_context connection failure",
        timedOut: false
      });
      return;
    }

    var bodyStr = Std.string(bodyResult);
    var status = 200;
    var parsedHeaders = new Map<String, String>();

    var rawHeadersArr:Dynamic = php.Syntax.code(
      "isset($http_response_header) ? $http_response_header : []"
    );
    if (rawHeadersArr != null && Std.isOfType(rawHeadersArr, Array)) {
      var arr:Array<String> = cast rawHeadersArr;
      for (line in arr) {
        if (StringTools.startsWith(line, "HTTP/")) {
          var parts = line.split(" ");
          if (parts.length > 1) {
            var st = Std.parseInt(parts[1]);
            if (st != null) {
              status = st;
            }
          }
        } else {
          var colonIdx = line.indexOf(":");
          if (colonIdx != -1) {
            var k = StringTools.trim(line.substr(0, colonIdx)).toLowerCase();
            var v = StringTools.trim(line.substr(colonIdx + 1));
            parsedHeaders.set(k, v);
          }
        }
      }
    }

    var contentType = parsedHeaders.exists("content-type") ? parsedHeaders.get("content-type") : "";
    var isPdf = contentType.indexOf("application/pdf") != -1;
    var b64:Null<String> = isPdf ? Std.string(Global.base64_encode(bodyStr)) : null;

    cb({
      status: status,
      headers: parsedHeaders,
      body: isPdf ? "" : bodyStr,
      bodyBase64: b64,
      networkError: null,
      timedOut: false
    });
  }

  private function parseHttpHeaders(headerText:String):Map<String, String> {
    var map = new Map<String, String>();
    var lines = headerText.split("\r\n");
    for (line in lines) {
      var colon = line.indexOf(":");
      if (colon != -1) {
        var k = StringTools.trim(line.substr(0, colon)).toLowerCase();
        var v = StringTools.trim(line.substr(colon + 1));
        map.set(k, v);
      }
    }
    return map;
  }
}
