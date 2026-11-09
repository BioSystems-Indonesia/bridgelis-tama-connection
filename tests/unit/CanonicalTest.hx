package;

import utest.Test;
import utest.Assert;
import core.Canonical;

class CanonicalTest extends Test {
  public function testStableKeyOrdering() {
    var objA = {b: 2, a: 1, c: 3};
    var objB = {a: 1, c: 3, b: 2};
    Assert.equals(Canonical.json(objA), Canonical.json(objB));
  }

  public function testTestsArrayOrdering() {
    var orderA = {
      lis_order: {
        order_id: "ORD-1",
        tests: [
          {code: "GLU", loinc_code: "2345-7"},
          {code: "CHOL", loinc_code: "14682-9"}
        ]
      }
    };

    var orderB = {
      lis_order: {
        order_id: "ORD-1",
        tests: [
          {code: "CHOL", loinc_code: "14682-9"},
          {code: "GLU", loinc_code: "2345-7"}
        ]
      }
    };

    Assert.equals(Canonical.json(orderA), Canonical.json(orderB));
  }
}

