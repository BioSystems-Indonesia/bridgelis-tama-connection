package;

import utest.Test;
import utest.Assert;
import core.Log;

class LogTest extends Test {
  public function testMaskName() {
    Assert.equals("B*** S***", Log.maskName("Budi Santoso"));
    Assert.equals("S***", Log.maskName("Siti"));
    Assert.equals("", Log.maskName(""));
  }

  public function testMaskIdentifier() {
    Assert.equals("****5678", Log.maskIdentifier("12345678"));
    Assert.equals("****", Log.maskIdentifier("1234"));
    Assert.equals("****", Log.maskIdentifier("12"));
    Assert.equals("", Log.maskIdentifier(""));
  }

  public function testMaskDateOfBirth() {
    Assert.equals("1990-**-**", Log.maskDateOfBirth("1990-05-15"));
    Assert.equals("****", Log.maskDateOfBirth("90"));
  }

  public function testSanitizeContext() {
    var rawCtx = {
      apiKey: "super-secret-token-123",
      patient_name: "John Doe",
      mrn: "RM-998877",
      dob: "1985-12-01",
      results: [{test: "GLU", value: 120}],
      order_id: "ORD-001"
    };

    var cleaned:Dynamic = Log.sanitizeContext(rawCtx);
    Assert.equals("[REDACTED]", Reflect.field(cleaned, "apiKey"));
    Assert.equals("J*** D***", Reflect.field(cleaned, "patient_name"));
    Assert.equals("*****8877", Reflect.field(cleaned, "mrn"));
    Assert.equals("1985-**-**", Reflect.field(cleaned, "dob"));
    Assert.equals("[REDACTED]", Reflect.field(cleaned, "results"));
    Assert.equals("ORD-001", Reflect.field(cleaned, "order_id"));
  }

  public function testLogLevelFiltering() {
    var mock = MockPlatform.create();
    var log = new Log(mock.logger, "warn");

    log.debug("test", "debug message");
    log.info("test", "info message");
    Assert.equals(0, mock.logger.logs.length);

    log.warn("test", "warn message");
    Assert.equals(1, mock.logger.logs.length);
    Assert.equals("warn", mock.logger.logs[0].level);

    log.error("test", "error message");
    Assert.equals(2, mock.logger.logs.length);
    Assert.equals("error", mock.logger.logs[1].level);
  }
}
