/**
 * LOINC format and Luhn-style Mod-10 check digit verification according to LLD §6.3.
 * Validates clinical LOINC test codes before submission to prevent server-side drops.
 */
package core;

/**
 * LOINC check digit validation logic.
 */
class Loinc {
  private static var LOINC_PATTERN:EReg = ~/^[0-9]{1,7}-[0-9]$/;

  /**
   * Checks whether the given string is a syntactically and mathematically valid LOINC code.
   *
   * @param code LOINC code to test (e.g., '2345-7')
   * @return true if format and Mod-10 check digit match
   */
  public static function isValid(code:Null<String>):Bool {
    if (code == null) {
      return false;
    }
    var trimmed = StringTools.trim(code);
    if (!LOINC_PATTERN.match(trimmed)) {
      return false;
    }

    var parts = trimmed.split("-");
    var baseNumber = parts[0];
    var expectedCheck = Std.parseInt(parts[1]);
    if (expectedCheck == null) {
      return false;
    }

    var calculatedCheck = computeCheckDigit(baseNumber);
    return calculatedCheck == expectedCheck;
  }

  /**
   * Calculates the Mod-10 check digit for the base number portion.
   * Positions are counted starting from the rightmost digit as 1.
   * Odd positions (1, 3, 5, ...) are doubled; if >= 10, their digits are added together.
   * Check digit is (10 - (sum mod 10)) mod 10.
   */
  public static function computeCheckDigit(numStr:String):Int {
    var sum = 0;
    var len = numStr.length;
    var pos = 1;

    for (i in 0...len) {
      var charIndex = len - 1 - i;
      var digit = numStr.charCodeAt(charIndex) - 48; // ASCII '0' is 48
      if (digit < 0 || digit > 9) {
        return -1;
      }

      if (pos % 2 == 1) {
        var doubled = digit * 2;
        if (doubled >= 10) {
          sum += (doubled % 10) + Std.int(doubled / 10);
        } else {
          sum += doubled;
        }
      } else {
        sum += digit;
      }
      pos++;
    }

    return (10 - (sum % 10)) % 10;
  }
}

