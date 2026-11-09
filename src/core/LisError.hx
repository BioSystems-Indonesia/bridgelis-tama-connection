/**
 * Error definitions and standard factory helpers according to LLD §5.
 * Provides normalized error codes, human-actionable messages, and retryability flags.
 */
package core;

/**
 * Standard error representation across core and facades.
 */
typedef LisError = {
  code:String,
  message:String,
  retryable:Bool,
  ?httpStatus:Int,
  ?requestId:String,
  ?field:String,
  ?details:Dynamic
};

/**
 * Registry of standard error codes and creation helper functions.
 */
class LisErrorHelper {
  public static inline var VALIDATION_FAILED:String = "VALIDATION_FAILED";
  public static inline var UNKNOWN_TEST_CODE:String = "UNKNOWN_TEST_CODE";
  public static inline var LIS_REJECTED:String = "LIS_REJECTED";
  public static inline var AUTH_FAILED:String = "AUTH_FAILED";
  public static inline var BRIDGING_DISABLED:String = "BRIDGING_DISABLED";
  public static inline var NOT_FOUND:String = "NOT_FOUND";
  public static inline var ORDER_IN_PROGRESS:String = "ORDER_IN_PROGRESS";
  public static inline var RATE_LIMITED:String = "RATE_LIMITED";
  public static inline var LIS_UNAVAILABLE:String = "LIS_UNAVAILABLE";
  public static inline var LIS_SERVER_ERROR:String = "LIS_SERVER_ERROR";
  public static inline var INTERNAL:String = "INTERNAL";

  /**
   * Constructs a validation error for invalid inputs or configurations.
   */
  public static function validationFailed(
    message:String,
    ?field:String,
    ?details:Dynamic
  ):LisError {
    return {
      code: VALIDATION_FAILED,
      message: message,
      retryable: false,
      field: field,
      details: details
    };
  }

  /**
   * Constructs an unknown test code error when tests are rejected by catalog policy.
   */
  public static function unknownTestCode(message:String, unrecognisedCodes:Array<String>):LisError {
    return {
      code: UNKNOWN_TEST_CODE,
      message: message,
      retryable: false,
      details: {codes: unrecognisedCodes}
    };
  }

  /**
   * Constructs an error mapping from HTTP status code according to LLD §5.
   */
  public static function fromHttpStatus(
    status:Int,
    message:String,
    ?requestId:String,
    ?details:Dynamic
  ):LisError {
    return switch (status) {
      case 400:
        {
          code: LIS_REJECTED,
          message: orDefault(message, "Request rejected by LIS server."),
          retryable: false,
          httpStatus: 400,
          requestId: requestId,
          details: details
        };
      case 401:
        {
          code: AUTH_FAILED,
          message: "LIS authentication failed. Check LIS_API_KEY.",
          retryable: false,
          httpStatus: 401,
          requestId: requestId,
          details: details
        };
      case 403:
        {
          code: BRIDGING_DISABLED,
          message: "LIS bridging is disabled or not set to API mode in LIS settings.",
          retryable: false,
          httpStatus: 403,
          requestId: requestId,
          details: details
        };
      case 404:
        {
          code: NOT_FOUND,
          message: orDefault(message, "Resource not found on LIS."),
          retryable: false,
          httpStatus: 404,
          requestId: requestId,
          details: details
        };
      case 429:
        {
          code: RATE_LIMITED,
          message: "Rate limit reached on LIS server. Please wait before retrying.",
          retryable: true,
          httpStatus: 429,
          requestId: requestId,
          details: details
        };
      case 502, 503, 504:
        {
          code: LIS_UNAVAILABLE,
          message: "LIS server unavailable or gateway error (HTTP " + status + ").",
          retryable: true,
          httpStatus: status,
          requestId: requestId,
          details: details
        };
      default:
        {
          code: LIS_SERVER_ERROR,
          message: orDefault(message, "LIS server error (HTTP " + status + ")."),
          retryable: true,
          httpStatus: status,
          requestId: requestId,
          details: details
        };
    };
  }

  /**
   * Constructs the error for a second createOrder of the same order while the first still runs.
   * It is retryable: the first call finishes within seconds (HLD D13).
   */
  public static function orderInProgress(orderId:String):LisError {
    return {
      code: ORDER_IN_PROGRESS,
      message: "Order '" + orderId + "' is already being sent. Wait a few seconds and retry.",
      retryable: true,
      field: "lis_order.order_id"
    };
  }

  /**
   * Constructs a network or timeout availability error.
   */
  public static function unavailable(message:String, ?breakerOpen:Bool = false):LisError {
    return {
      code: LIS_UNAVAILABLE,
      message: message,
      retryable: true,
      details: breakerOpen ? {breakerOpen: true} : null
    };
  }

  /**
   * Constructs an internal library bug error.
   */
  public static function internalError(message:String):LisError {
    return {
      code: INTERNAL,
      message: message,
      retryable: false
    };
  }

  /** Keeps the server message when there is one, otherwise uses a readable fallback. */
  private static function orDefault(message:Null<String>, fallback:String):String {
    return message != null && message.length > 0 ? message : fallback;
  }
}
