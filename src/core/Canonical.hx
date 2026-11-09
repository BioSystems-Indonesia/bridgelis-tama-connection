/**
 * Deterministic JSON serialization for order payload deduplication according to LLD §6.5.
 * Sorts object keys and test/package arrays so identical clinical requests yield identical hashes.
 */
package core;

import haxe.Json;

/**
 * Produces canonical string representations of data structures.
 */
class Canonical {
  /**
   * Serializes an arbitrary dynamic structure into deterministic canonical JSON.
   */
  public static function json(val:Dynamic):String {
    return stringify(sortStructure(val));
  }

  /**
   * Recursively normalizes objects by sorting keys, and sorts tests/packages arrays by identifier.
   */
  public static function sortStructure(val:Dynamic):Dynamic {
    if (val == null) {
      return null;
    }

    if (Std.isOfType(val, Array)) {
      var arr:Array<Dynamic> = cast val;
      var outArr = new Array<Dynamic>();
      for (item in arr) {
        outArr.push(sortStructure(item));
      }
      return outArr;
    }

    var isPlainObject = Reflect.isObject(val) && !Std.isOfType(val, String)
      && !Std.isOfType(val, Bool) && !Std.isOfType(val, Int) && !Std.isOfType(val, Float);
    if (isPlainObject) {
      var fields = Reflect.fields(val);
      fields.sort(function(a, b) return Reflect.compare(a, b));

      var outObj:Dynamic = {};
      for (field in fields) {
        var fieldValue:Dynamic = Reflect.field(val, field);
        if (field == "tests" || field == "packages") {
          if (Std.isOfType(fieldValue, Array)) {
            var items:Array<Dynamic> = cast fieldValue;
            var sortedItems = new Array<Dynamic>();
            for (it in items) {
              sortedItems.push(sortStructure(it));
            }
            sortedItems.sort(function(itemA, itemB) {
              var keyA = getItemSortKey(itemA);
              var keyB = getItemSortKey(itemB);
              return Reflect.compare(keyA, keyB);
            });
            Reflect.setField(outObj, field, sortedItems);
            continue;
          }
        }
        Reflect.setField(outObj, field, sortStructure(fieldValue));
      }
      return outObj;
    }

    return val;
  }

  private static function getItemSortKey(item:Dynamic):String {
    if (item == null) {
      return "";
    }
    var loinc:Null<String> = Reflect.field(item, "loinc_code");
    if (loinc != null && loinc.length > 0) {
      return "1:" + loinc;
    }
    var code:Null<String> = Reflect.field(item, "code");
    if (code != null && code.length > 0) {
      return "2:" + code;
    }
    var id:Dynamic = Reflect.field(item, "id");
    if (id != null) {
      return "3:" + Std.string(id);
    }
    return "9:" + Std.string(item);
  }

  private static function stringify(val:Dynamic):String {
    if (val == null) {
      return "null";
    }

    if (Std.isOfType(val, String)) {
      return Json.stringify(val);
    }
    if (Std.isOfType(val, Bool)) {
      return val ? "true" : "false";
    }
    if (Std.isOfType(val, Int) || Std.isOfType(val, Float)) {
      return Std.string(val);
    }
    if (Std.isOfType(val, Array)) {
      var arr:Array<Dynamic> = cast val;
      var parts = new Array<String>();
      for (elem in arr) {
        parts.push(stringify(elem));
      }
      return "[" + parts.join(",") + "]";
    }
    if (Reflect.isObject(val)) {
      var fields = Reflect.fields(val);
      fields.sort(function(a, b) return Reflect.compare(a, b));
      var parts = new Array<String>();
      for (f in fields) {
        var v = Reflect.field(val, f);
        parts.push(Json.stringify(f) + ":" + stringify(v));
      }
      return "{" + parts.join(",") + "}";
    }

    return Std.string(val);
  }
}

