package;

import utest.Test;
import utest.Assert;
import core.Sanitizer;

class SanitizerTest extends Test {
  // Fixed "now" (2026-11-04T00:00:00Z) so date checks never depend on the real clock.
  static inline var NOW_MS:Float = 1793750400000.0;

  public function testNormalizeSex() {
    Assert.equals("M", Sanitizer.normalizeSex("M"));
    Assert.equals("M", Sanitizer.normalizeSex("L"));
    Assert.equals("M", Sanitizer.normalizeSex("pria"));
    Assert.equals("M", Sanitizer.normalizeSex("Laki-Laki"));
    Assert.equals("M", Sanitizer.normalizeSex("1"));

    Assert.equals("F", Sanitizer.normalizeSex("F"));
    Assert.equals("F", Sanitizer.normalizeSex("P"));
    Assert.equals("F", Sanitizer.normalizeSex("wanita"));
    Assert.equals("F", Sanitizer.normalizeSex("Perempuan"));
    Assert.equals("F", Sanitizer.normalizeSex("2"));

    Assert.isNull(Sanitizer.normalizeSex("unknown"));
    Assert.isNull(Sanitizer.normalizeSex("X"));
  }

  public function testNormalizeDateOfBirth() {
    Assert.equals("1990-05-15", Sanitizer.normalizeDateOfBirth("1990-05-15", NOW_MS));
    Assert.equals("1990-05-15", Sanitizer.normalizeDateOfBirth("15/05/1990", NOW_MS));
    Assert.equals("1990-05-15", Sanitizer.normalizeDateOfBirth("15-05-1990", NOW_MS));
    Assert.equals("1990-05-15", Sanitizer.normalizeDateOfBirth("1990/05/15", NOW_MS));
    Assert.equals("1990-05-15", Sanitizer.normalizeDateOfBirth("1990-05-15 10:30:00", NOW_MS));

    // Invalid format or bounds
    Assert.isNull(Sanitizer.normalizeDateOfBirth("invalid-date", NOW_MS));
    Assert.isNull(Sanitizer.normalizeDateOfBirth("1899-12-31", NOW_MS)); // < 1900
    Assert.isNull(Sanitizer.normalizeDateOfBirth("1990-02-31", NOW_MS)); // 31 Feb
    Assert.isNull(Sanitizer.normalizeDateOfBirth("2030-01-01", NOW_MS)); // future
  }

  public function testStripControlCharacters() {
    var raw = {
      patient: {
        first_name: "Budi\x00\x1F",
        last_name: "Santoso\x7F",
        sex: "L",
        date_of_birth: "1990-01-01"
      }
    };
    var res = Sanitizer.sanitizeOrder(raw, null, NOW_MS);
    Assert.equals("Budi", res.order.patient.first_name);
    Assert.equals("Santoso", res.order.patient.last_name);
  }
}

