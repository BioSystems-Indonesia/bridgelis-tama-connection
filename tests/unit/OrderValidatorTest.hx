package;

import utest.Test;
import utest.Assert;
import core.OrderValidator;
import core.LisError.LisError;

class OrderValidatorTest extends Test {
  public function testValidOrderPasses() {
    var validOrder = {
      patient: {
        medical_record_number: "RM-123",
        first_name: "Budi",
        sex: "M",
        date_of_birth: "1990-01-01"
      },
      lis_order: {
        order_id: "ORD-123",
        tests: [{loinc_code: "2345-7"}]
      }
    };

    var threw = false;
    try {
      OrderValidator.check(validOrder);
    } catch (_:Dynamic) {
      threw = true;
    }
    Assert.isFalse(threw);
  }

  public function testOrderIdWithSlashRejected() {
    var orderWithSlash = {
      patient: {
        medical_record_number: "RM-123",
        first_name: "Budi",
        sex: "M",
        date_of_birth: "1990-01-01"
      },
      lis_order: {
        order_id: "ORD/123",
        tests: [{loinc_code: "2345-7"}]
      }
    };

    var threw = false;
    try {
      OrderValidator.check(orderWithSlash);
    } catch (e:Dynamic) {
      threw = true;
      var err:LisError = cast e;
      Assert.equals("VALIDATION_FAILED", err.code);
      Assert.equals("lis_order.order_id", err.field);
    }
    Assert.isTrue(threw);
  }

  public function testValidateOrderIdReportsCallerField() {
    var field:Null<String> = null;
    try {
      OrderValidator.validateOrderId("A/B");
    } catch (e:Dynamic) {
      field = (cast e : LisError).field;
    }
    Assert.equals("orderId", field);
  }

  public function testMissingTestsAndPackagesRejected() {
    var emptyOrder = {
      patient: {
        medical_record_number: "RM-123",
        first_name: "Budi",
        sex: "M",
        date_of_birth: "1990-01-01"
      },
      lis_order: {
        order_id: "ORD-123"
      }
    };

    var threw = false;
    try {
      OrderValidator.check(emptyOrder);
    } catch (e:Dynamic) {
      threw = true;
      var err:LisError = cast e;
      Assert.equals("VALIDATION_FAILED", err.code);
    }
    Assert.isTrue(threw);
  }
}

