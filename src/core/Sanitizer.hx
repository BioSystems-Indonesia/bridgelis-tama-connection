/**
 * Order payload sanitization and field normalization according to LLD §6.1.
 * Trims strings, strips control characters, normalizes patient sex and birth dates,
 * and deduplicates tests while generating actionable warnings.
 */
package core;

import core.LisError.LisErrorHelper;
import haxe.Json;

typedef SanitizerWarning = {
  code:String,
  field:String,
  from:String,
  to:String
};

typedef SanitizeResult = {
  order:Dynamic,
  warnings:Array<SanitizerWarning>
};

class Sanitizer {
  private static var CONTROL_CHARS_REGEX:EReg = ~/[\x00-\x1F\x7F]/g;

  public static function sanitizeOrder(
    rawInput:Dynamic,
    ?customSexMap:Map<String, String>,
    nowEpochMs:Float
  ):SanitizeResult {
    var warnings = new Array<SanitizerWarning>();
    if (rawInput == null) {
      throw LisErrorHelper.validationFailed("Order payload must not be null.", "order");
    }

    var order:Dynamic = Json.parse(Json.stringify(rawInput));
    order = cleanStrings(order);

    sanitizePatient(order, customSexMap, nowEpochMs, warnings);
    sanitizeLisOrder(order);

    return {order: order, warnings: warnings};
  }

  private static function sanitizePatient(
    order:Dynamic,
    customSexMap:Null<Map<String, String>>,
    nowEpochMs:Float,
    warnings:Array<SanitizerWarning>
  ):Void {
    var patient:Dynamic = Reflect.field(order, "patient");
    if (patient == null || !Reflect.isObject(patient)) {
      return;
    }

    var rawSexVal:Dynamic = Reflect.field(patient, "sex");
    if (rawSexVal != null) {
      var rawSexStr = StringTools.trim(Std.string(rawSexVal));
      var normalizedSex = normalizeSex(rawSexStr, customSexMap);
      if (normalizedSex == null) {
        throw LisErrorHelper.validationFailed(
          "Invalid patient sex: '" + rawSexStr + "'. LIS only accepts 'M' or 'F'.",
          "patient.sex"
        );
      }
      if (rawSexStr != normalizedSex) {
        warnings.push({
          code: "SEX_NORMALIZED",
          field: "patient.sex",
          from: rawSexStr,
          to: normalizedSex
        });
      }
      Reflect.setField(patient, "sex", normalizedSex);
    }

    var rawDobVal:Dynamic = Reflect.field(patient, "date_of_birth");
    if (rawDobVal != null) {
      var rawDobStr = StringTools.trim(Std.string(rawDobVal));
      var normalizedDob = normalizeDateOfBirth(rawDobStr, nowEpochMs);
      if (normalizedDob == null) {
        throw LisErrorHelper.validationFailed(
          "Invalid patient date_of_birth: '" + rawDobStr
            + "'. Expected a valid date >= 1900 and not in the future.",
          "patient.date_of_birth"
        );
      }
      if (rawDobStr != normalizedDob) {
        warnings.push({
          code: "DOB_NORMALIZED",
          field: "patient.date_of_birth",
          from: rawDobStr,
          to: normalizedDob
        });
      }
      Reflect.setField(patient, "date_of_birth", normalizedDob);
    }
  }

  private static function sanitizeLisOrder(order:Dynamic):Void {
    var lisOrder:Dynamic = Reflect.field(order, "lis_order");
    if (lisOrder == null || !Reflect.isObject(lisOrder)) {
      return;
    }

    var rawTests:Dynamic = Reflect.field(lisOrder, "tests");
    if (rawTests != null && Std.isOfType(rawTests, Array)) {
      Reflect.setField(lisOrder, "tests", filterAndDedupItems(cast rawTests));
    }

    var rawPackages:Dynamic = Reflect.field(lisOrder, "packages");
    if (rawPackages != null && Std.isOfType(rawPackages, Array)) {
      Reflect.setField(lisOrder, "packages", filterAndDedupItems(cast rawPackages));
    }
  }

  public static function normalizeSex(val:String, ?customMap:Map<String, String>):Null<String> {
    if (val == null) {
      return null;
    }
    var upper = StringTools.trim(val).toUpperCase();

    if (customMap != null && customMap.exists(upper)) {
      var mapped = customMap.get(upper);
      if (mapped == "M" || mapped == "F") {
        return mapped;
      }
    }

    return switch (upper) {
      case "M", "L", "LAKI-LAKI", "LAKI LAKI", "PRIA", "MALE", "1": "M";
      case "F", "P", "PEREMPUAN", "WANITA", "FEMALE", "2": "F";
      default: null;
    };
  }

  public static function normalizeDateOfBirth(val:String, nowEpochMs:Float):Null<String> {
    if (val == null || val.length == 0) {
      return null;
    }
    var trimmed = StringTools.trim(val);

    var datePart = trimmed;
    if (datePart.indexOf("T") != -1) {
      datePart = datePart.split("T")[0];
    }
    else if (datePart.indexOf(" ") != -1) {
      datePart = datePart.split(" ")[0];
    }
    datePart = StringTools.trim(datePart);

    var ymd = parseDateParts(datePart);
    if (ymd == null) {
      return null;
    }

    var y = ymd.y;
    var m = ymd.m;
    var d = ymd.d;

    if (y < 1900 || m < 1 || m > 12) {
      return null;
    }
    if (d < 1 || d > getDaysInMonth(y, m)) {
      return null;
    }

    var testEpoch = Date.fromString(formatYmd(y, m, d) + " 00:00:00").getTime();
    if (testEpoch > nowEpochMs + 86400000.0) {
      return null;
    }

    return formatYmd(y, m, d);
  }

  private static function parseDateParts(datePart:String):Null<{y:Int, m:Int, d:Int}> {
    var isoRegex = ~/^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})$/;
    var dayFirstRegex = ~/^(\d{1,2})[-\/](\d{1,2})[-\/](\d{4})$/;

    if (isoRegex.match(datePart)) {
      return {
        y: Std.parseInt(isoRegex.matched(1)),
        m: Std.parseInt(isoRegex.matched(2)),
        d: Std.parseInt(isoRegex.matched(3))
      };
    } else if (dayFirstRegex.match(datePart)) {
      return {
        d: Std.parseInt(dayFirstRegex.matched(1)),
        m: Std.parseInt(dayFirstRegex.matched(2)),
        y: Std.parseInt(dayFirstRegex.matched(3))
      };
    }
    return null;
  }

  private static function getDaysInMonth(y:Int, m:Int):Int {
    return switch (m) {
      case 1, 3, 5, 7, 8, 10, 12: 31;
      case 4, 6, 9, 11: 30;
      case 2:
        var isLeap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
        isLeap ? 29 : 28;
      default: 30;
    };
  }

  private static function formatYmd(y:Int, m:Int, d:Int):String {
    var mm = m < 10 ? "0" + m : "" + m;
    var dd = d < 10 ? "0" + d : "" + d;
    return y + "-" + mm + "-" + dd;
  }

  private static function filterAndDedupItems(items:Array<Dynamic>):Array<Dynamic> {
    var out = new Array<Dynamic>();
    var seenKeys = new Map<String, Bool>();

    for (item in items) {
      if (item == null || !Reflect.isObject(item)) {
        continue;
      }
      var identifier = extractItemIdentifier(item);
      if (identifier == null) {
        continue;
      }

      if (!seenKeys.exists(identifier)) {
        seenKeys.set(identifier, true);
        out.push(item);
      }
    }
    return out;
  }

  private static function extractItemIdentifier(item:Dynamic):Null<String> {
    var loinc:Null<String> = Reflect.field(item, "loinc_code");
    if (loinc != null && loinc.length > 0) {
      return "loinc:" + StringTools.trim(loinc).toUpperCase();
    }
    var code:Null<String> = Reflect.field(item, "code");
    if (code != null && code.length > 0) {
      return "code:" + StringTools.trim(code).toUpperCase();
    }
    var id:Dynamic = Reflect.field(item, "id");
    if (id != null) {
      return "id:" + StringTools.trim(Std.string(id));
    }
    return null;
  }

  private static function cleanStrings(val:Dynamic):Dynamic {
    if (val == null) {
      return null;
    }
    if (Std.isOfType(val, String)) {
      return StringTools.trim(CONTROL_CHARS_REGEX.replace(cast val, ""));
    }
    if (Std.isOfType(val, Array)) {
      var arr:Array<Dynamic> = cast val;
      for (i in 0...arr.length) {
        arr[i] = cleanStrings(arr[i]);
      }
      return arr;
    }
    if (Reflect.isObject(val) && !Std.isOfType(val, Bool) &&
        !Std.isOfType(val, Int) && !Std.isOfType(val, Float)) {
      for (f in Reflect.fields(val)) {
        Reflect.setField(val, f, cleanStrings(Reflect.field(val, f)));
      }
      return val;
    }
    return val;
  }
}
