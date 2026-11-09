/**
 * Structured logger with PHI (Protected Health Information) masking according to LLD §11.
 * Prevents sensitive clinical data and credentials from leaking into system logs.
 */
package core;

import platform.Platform.ILogger;

/**
 * PHI-safe logger that filters by level and scrubs patient identifiers.
 */
class Log {
  public static inline var LEVEL_DEBUG:String = "debug";
  public static inline var LEVEL_INFO:String = "info";
  public static inline var LEVEL_WARN:String = "warn";
  public static inline var LEVEL_ERROR:String = "error";

  private var logger:ILogger;
  private var currentLevelValue:Int;

  public function new(logger:ILogger, logLevel:String) {
    this.logger = logger;
    this.currentLevelValue = levelToInt(logLevel);
  }

  /**
   * Translates log level string to numeric priority.
   */
  public static function levelToInt(lvl:String):Int {
    if (lvl == null) return 1; // default info
    return switch (lvl.toLowerCase()) {
      case "debug": 0;
      case "info": 1;
      case "warn": 2;
      case "error": 3;
      default: 1;
    };
  }

  /**
   * Logs a message at debug level if allowed by configuration.
   */
  public function debug(op:String, msg:String, ?ctx:Dynamic):Void {
    if (currentLevelValue <= 0) {
      emit(LEVEL_DEBUG, op, msg, ctx);
    }
  }

  /**
   * Logs a message at info level if allowed by configuration.
   */
  public function info(op:String, msg:String, ?ctx:Dynamic):Void {
    if (currentLevelValue <= 1) {
      emit(LEVEL_INFO, op, msg, ctx);
    }
  }

  /**
   * Logs a message at warn level if allowed by configuration.
   */
  public function warn(op:String, msg:String, ?ctx:Dynamic):Void {
    if (currentLevelValue <= 2) {
      emit(LEVEL_WARN, op, msg, ctx);
    }
  }

  /**
   * Logs a message at error level if allowed by configuration.
   */
  public function error(op:String, msg:String, ?ctx:Dynamic):Void {
    if (currentLevelValue <= 3) {
      emit(LEVEL_ERROR, op, msg, ctx);
    }
  }

  private function emit(level:String, op:String, msg:String, ?ctx:Dynamic):Void {
    if (logger == null) {
      return;
    }
    var sanitizedCtx:Dynamic = sanitizeContext(ctx);
    if (sanitizedCtx == null) {
      sanitizedCtx = {op: op};
    } else {
      Reflect.setField(sanitizedCtx, "op", op);
    }
    logger.log(level, msg, sanitizedCtx);
  }

  /**
   * Masks patient names into initial + *** format (e.g., 'Budi Santoso' -> 'B*** S***').
   */
  public static function maskName(name:Null<String>):String {
    if (name == null || name.length == 0) {
      return "";
    }
    var parts = name.split(" ");
    var maskedParts = new Array<String>();
    for (part in parts) {
      if (part.length == 0) {
        continue;
      }
      maskedParts.push(part.substr(0, 1).toUpperCase() + "***");
    }
    return maskedParts.join(" ");
  }

  /**
   * Masks medical record number / NIK showing only the last 4 characters.
   */
  public static function maskIdentifier(id:Null<String>):String {
    if (id == null || id.length == 0) {
      return "";
    }
    if (id.length <= 4) {
      return "****";
    }
    var prefixLength = id.length - 4;
    var stars = "";
    for (i in 0...prefixLength) {
      stars += "*";
    }
    return stars + id.substr(prefixLength);
  }

  /**
   * Masks date of birth preserving only the year (e.g., '1990-05-15' -> '1990-**-**').
   */
  public static function maskDateOfBirth(dob:Null<String>):String {
    if (dob == null || dob.length < 4) {
      return "****";
    }
    var year = dob.substr(0, 4);
    return year + "-**-**";
  }

  /**
   * Scrubs sensitive fields from arbitrary logging context objects.
   */
  public static function sanitizeContext(ctx:Dynamic):Dynamic {
    if (ctx == null) {
      return null;
    }
    var out:Dynamic = {};
    for (field in Reflect.fields(ctx)) {
      var val:Dynamic = Reflect.field(ctx, field);
      switch (field.toLowerCase()) {
        case "apikey", "secret", "webhooksecret", "password", "token", "auth":
          Reflect.setField(out, field, "[REDACTED]");
        case "first_name", "last_name", "patient_name", "name":
          if (Std.isOfType(val, String)) {
            Reflect.setField(out, field, maskName(cast val));
          } else {
            Reflect.setField(out, field, "[REDACTED]");
          }
        case "medical_record_number", "mrn", "patient_mrn", "nik":
          if (Std.isOfType(val, String)) {
            Reflect.setField(out, field, maskIdentifier(cast val));
          } else {
            Reflect.setField(out, field, "[REDACTED]");
          }
        case "date_of_birth", "dob":
          if (Std.isOfType(val, String)) {
            Reflect.setField(out, field, maskDateOfBirth(cast val));
          } else {
            Reflect.setField(out, field, "[REDACTED]");
          }
        case "results", "body", "rawbody", "requestbody", "responsebody":
          Reflect.setField(out, field, "[REDACTED]");
        default:
          Reflect.setField(out, field, val);
      }
    }
    return out;
  }
}

