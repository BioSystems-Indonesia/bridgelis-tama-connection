package;

import utest.Test;
import utest.Assert;
import core.LisError;

class ErrorMappingTest extends Test {
  public function testHttpStatusMappings() {
    var err400 = LisErrorHelper.fromHttpStatus(400, "Bad input", "req-1");
    Assert.equals("LIS_REJECTED", err400.code);
    Assert.isFalse(err400.retryable);
    Assert.equals(400, err400.httpStatus);
    Assert.equals("req-1", err400.requestId);

    var err401 = LisErrorHelper.fromHttpStatus(401, "Unauthorized", "req-2");
    Assert.equals("AUTH_FAILED", err401.code);
    Assert.isFalse(err401.retryable);

    var err403 = LisErrorHelper.fromHttpStatus(403, "Forbidden", "req-3");
    Assert.equals("BRIDGING_DISABLED", err403.code);
    Assert.isFalse(err403.retryable);

    var err404 = LisErrorHelper.fromHttpStatus(404, "Not Found", "req-4");
    Assert.equals("NOT_FOUND", err404.code);
    Assert.isFalse(err404.retryable);

    var details = {retryAfterSec: 5};
    var err429 = LisErrorHelper.fromHttpStatus(429, "Too Many Requests", "req-5", details);
    Assert.equals("RATE_LIMITED", err429.code);
    Assert.isTrue(err429.retryable);
    Assert.equals(5, Reflect.field(err429.details, "retryAfterSec"));

    var err500 = LisErrorHelper.fromHttpStatus(500, "Internal Server Error", "req-6");
    Assert.equals("LIS_SERVER_ERROR", err500.code);
    Assert.isTrue(err500.retryable);

    var err502 = LisErrorHelper.fromHttpStatus(502, "Bad Gateway", "req-7");
    Assert.equals("LIS_UNAVAILABLE", err502.code);
    Assert.isTrue(err502.retryable);

    var err503 = LisErrorHelper.fromHttpStatus(503, "Service Unavailable", "req-8");
    Assert.equals("LIS_UNAVAILABLE", err503.code);
    Assert.isTrue(err503.retryable);

    var err504 = LisErrorHelper.fromHttpStatus(504, "Gateway Timeout", "req-9");
    Assert.equals("LIS_UNAVAILABLE", err504.code);
    Assert.isTrue(err504.retryable);
  }

  public function testSpecificErrorConstructors() {
    var valErr = LisErrorHelper.validationFailed("Invalid MRN", "patient.medical_record_number");
    Assert.equals("VALIDATION_FAILED", valErr.code);
    Assert.equals("patient.medical_record_number", valErr.field);
    Assert.isFalse(valErr.retryable);

    var unkErr = LisErrorHelper.unknownTestCode("Unknown code", ["CBC99"]);
    Assert.equals("UNKNOWN_TEST_CODE", unkErr.code);
    Assert.isFalse(unkErr.retryable);

    var unavailErr = LisErrorHelper.unavailable("Network down", true);
    Assert.equals("LIS_UNAVAILABLE", unavailErr.code);
    Assert.isTrue(unavailErr.retryable);
    Assert.isTrue(Reflect.field(unavailErr.details, "breakerOpen"));

    var intErr = LisErrorHelper.internalError("Unexpected null pointer");
    Assert.equals("INTERNAL", intErr.code);
    Assert.isFalse(intErr.retryable);
  }
}

