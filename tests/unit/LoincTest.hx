package;

import utest.Test;
import utest.Assert;
import core.Loinc;

class LoincTest extends Test {
  public function testValidLoincVectors() {
    Assert.isTrue(Loinc.isValid("2345-7"));
    Assert.isTrue(Loinc.isValid("14682-9"));
    Assert.isTrue(Loinc.isValid("24326-1"));
    Assert.isTrue(Loinc.isValid("58410-2"));
  }

  public function testInvalidLoincVectors() {
    Assert.isFalse(Loinc.isValid("2345-8"));
    Assert.isFalse(Loinc.isValid("14682-0"));
    Assert.isFalse(Loinc.isValid(""));
    Assert.isFalse(Loinc.isValid(null));
    Assert.isFalse(Loinc.isValid("not-a-loinc"));
    Assert.isFalse(Loinc.isValid("12345"));
  }
}

