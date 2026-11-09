package;

import utest.Test;
import utest.Assert;
import core.LisCore;
import haxe.Json;
import platform.Platform.IStorage;

/** Storage that fails on every call, to simulate an unexpected bug or broken disk. */
private class ThrowingStorage implements IStorage {
  public function new() {}

  public function get(key:String):Null<String> {
    throw "disk exploded";
  }

  public function set(key:String, value:String, ttlSec:Int):Void {
    throw "disk exploded";
  }

  public function setIfAbsent(key:String, value:String, ttlSec:Int):Bool {
    throw "disk exploded";
  }

  public function delete(key:String):Void {
    throw "disk exploded";
  }
}

class LisCoreTest extends Test {
  static inline var CONFIG:String =
    '{"baseUrl":"http://lis.local/","apiKey":"k","logLevel":"error"}';

  private function validOrderJson():String {
    return Json.stringify({
      patient: {
        medical_record_number: "RM-1",
        first_name: "Budi",
        sex: "M",
        date_of_birth: "1990-01-01"
      },
      lis_order: {order_id: "ORD-1", tests: [{loinc_code: "2345-7"}]}
    });
  }

  public function testUnexpectedExceptionBecomesSingleInternalOutcome() {
    var mock = MockPlatform.create();
    mock.platform.storage = new ThrowingStorage();
    var core = new LisCore(CONFIG, mock.platform);

    var outcomes:Array<Dynamic> = [];
    core.createOrder(validOrderJson(), function(json) {
      outcomes.push(Json.parse(json));
    });

    Assert.equals(1, outcomes.length);
    Assert.isFalse(outcomes[0].ok);
    Assert.equals("INTERNAL", outcomes[0].error.code);
  }

  public function testThrownLisErrorKeepsItsCode() {
    var mock = MockPlatform.create();
    var core = new LisCore(CONFIG, mock.platform);

    var outcome:Dynamic = null;
    core.getOrder("A/B", function(json) {
      outcome = Json.parse(json);
    });

    Assert.equals("VALIDATION_FAILED", outcome.error.code);
    Assert.equals("orderId", outcome.error.field);
    Assert.equals(0, mock.http.requests.length);
  }

  public function testCallbackThatThrowsIsNotCalledTwice() {
    var mock = MockPlatform.create();
    var core = new LisCore(CONFIG, mock.platform);

    var calls = 0;
    core.getTestTypes(function(json) {
      calls++;
      throw "facade bug";
    });

    Assert.equals(1, calls);
  }

  public function testStorageSettingsUseNormalizedBaseUrl() {
    var mock = MockPlatform.create();
    var settings:Dynamic = Json.parse(LisCore.resolveStorageSettings(CONFIG, mock.platform.env));
    Assert.equals("http://lis.local", settings.baseUrl);
  }
}
