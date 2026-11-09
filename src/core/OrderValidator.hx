/**
 * Order validation mirroring server constraints and local safety rules according to LLD §6.2.
 * Validates required patient fields, order identifiers, test arrays, and LOINC check digits.
 */
package core;

import core.LisError.LisErrorHelper;

class OrderValidator {
  private static var LOINC_LIKE_REGEX:EReg = ~/^[0-9]{1,7}-[0-9]$/;

  /**
   * Validates order_id across all operations (LLD §4 & §14).
   * Rejects empty IDs and forward slashes which break LIS HTTP path routing.
   *
   * @param orderId  order id given by the caller
   * @param field    error field name; `lis_order.order_id` when validating a full order
   * @throws LisError VALIDATION_FAILED
   */
  public static function validateOrderId(orderId:Null<String>, ?field:String = "orderId"):Void {
    if (orderId == null || StringTools.trim(orderId).length == 0) {
      throw LisErrorHelper.validationFailed("Order 'order_id' is required.", field);
    }
    if (orderId.indexOf("/") != -1) {
      throw LisErrorHelper.validationFailed(
        "Order 'order_id' must not contain '/' because the LIS cannot route it.",
        field
      );
    }
  }

  /**
   * Validates a sanitized order object.
   * Throws LisError (VALIDATION_FAILED) upon the first violation.
   */
  public static function check(order:Dynamic):Void {
    if (order == null || !Reflect.isObject(order)) {
      throw LisErrorHelper.validationFailed("Order object is required.", "order");
    }

    validatePatient(Reflect.field(order, "patient"));
    validateLisOrder(Reflect.field(order, "lis_order"));
  }

  private static function validatePatient(patient:Dynamic):Void {
    if (patient == null || !Reflect.isObject(patient)) {
      throw LisErrorHelper.validationFailed("Field 'patient' is required.", "patient");
    }

    var mrn:Null<String> = Reflect.field(patient, "medical_record_number");
    if (mrn == null || StringTools.trim(mrn).length == 0) {
      throw LisErrorHelper.validationFailed(
        "Patient 'medical_record_number' is required.",
        "patient.medical_record_number"
      );
    }

    var firstName:Null<String> = Reflect.field(patient, "first_name");
    if (firstName == null || StringTools.trim(firstName).length == 0) {
      throw LisErrorHelper.validationFailed(
        "Patient 'first_name' is required.",
        "patient.first_name"
      );
    }

    var sex:Null<String> = Reflect.field(patient, "sex");
    if (sex == null || (sex != "M" && sex != "F")) {
      throw LisErrorHelper.validationFailed("Patient 'sex' must be 'M' or 'F'.", "patient.sex");
    }

    var dob:Null<String> = Reflect.field(patient, "date_of_birth");
    if (dob == null || StringTools.trim(dob).length == 0) {
      throw LisErrorHelper.validationFailed(
        "Patient 'date_of_birth' is required (YYYY-MM-DD).",
        "patient.date_of_birth"
      );
    }
  }

  private static function validateLisOrder(lisOrder:Dynamic):Void {
    if (lisOrder == null || !Reflect.isObject(lisOrder)) {
      throw LisErrorHelper.validationFailed("Field 'lis_order' is required.", "lis_order");
    }

    var orderId:Null<String> = Reflect.field(lisOrder, "order_id");
    validateOrderId(orderId, "lis_order.order_id");

    var tests:Array<Dynamic> = getArrayField(lisOrder, "tests");
    var packages:Array<Dynamic> = getArrayField(lisOrder, "packages");

    var hasTests = tests != null && tests.length > 0;
    var hasPackages = packages != null && packages.length > 0;

    if (!hasTests && !hasPackages) {
      throw LisErrorHelper.validationFailed(
        "Order must contain at least one item in 'tests' or 'packages'.",
        "lis_order.tests"
      );
    }

    if (hasTests) {
      validateTestsLoinc(tests);
    }
    if (hasPackages) {
      validatePackagesLoinc(packages);
    }
  }

  private static function getArrayField(obj:Dynamic, field:String):Null<Array<Dynamic>> {
    var raw:Dynamic = Reflect.field(obj, field);
    return (raw != null && Std.isOfType(raw, Array)) ? cast raw : null;
  }

  private static function validateTestsLoinc(tests:Array<Dynamic>):Void {
    for (i in 0...tests.length) {
      var t = tests[i];
      if (t == null || !Reflect.isObject(t)) {
        continue;
      }

      var loincCode:Null<String> = Reflect.field(t, "loinc_code");
      if (loincCode != null && loincCode.length > 0 && !Loinc.isValid(loincCode)) {
        throw LisErrorHelper.validationFailed(
          "Invalid LOINC code or check digit in tests[" + i + "]: '" + loincCode + "'.",
          "lis_order.tests[" + i + "].loinc_code"
        );
      }

      var code:Null<String> = Reflect.field(t, "code");
      if (code != null && LOINC_LIKE_REGEX.match(code) && !Loinc.isValid(code)) {
        throw LisErrorHelper.validationFailed(
          "Invalid LOINC check digit in tests[" + i + "].code: '" + code + "'.",
          "lis_order.tests[" + i + "].code"
        );
      }
    }
  }

  private static function validatePackagesLoinc(packages:Array<Dynamic>):Void {
    for (i in 0...packages.length) {
      var p = packages[i];
      if (p == null || !Reflect.isObject(p)) {
        continue;
      }

      var loincCode:Null<String> = Reflect.field(p, "loinc_code");
      if (loincCode != null && loincCode.length > 0 && !Loinc.isValid(loincCode)) {
        throw LisErrorHelper.validationFailed(
          "Invalid LOINC code or check digit in packages[" + i + "]: '" + loincCode + "'.",
          "lis_order.packages[" + i + "].loinc_code"
        );
      }
    }
  }
}
