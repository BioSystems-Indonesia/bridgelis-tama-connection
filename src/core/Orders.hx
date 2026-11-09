/**
 * Order operations against the LIS: create (with dedup and the in-progress lock), delete,
 * notes, read and list (LLD §6).
 */
package core;

import platform.Platform.Platform;
import core.Config.ClientConfig;
import core.LisError.LisErrorHelper;
import haxe.Json;

/** Result of `createOrder`: `SENT` or `UNCHANGED` (identical resubmission, HLD F1). */
typedef Receipt = {
  status:String,
  order_id:String,
  lab_work_order_id:Null<Dynamic>,
  lab_barcode:Null<Dynamic>,
  warnings:Array<Sanitizer.SanitizerWarning>
};

class Orders {
  // Dedup hash lifetime: 30 days (LLD §3.1, key `sent:<order_id>`).
  static inline var SENT_HASH_TTL_SEC:Int = 2592000;
  // In-progress lock lifetime: longer than one request (8 s timeout) plus its single retry, so a
  // crashed process frees the order by itself (LLD §3.1, key `inflight:<order_id>`).
  static inline var ORDER_LOCK_TTL_SEC:Int = 30;

  private var platform:Platform;
  private var config:ClientConfig;
  private var log:Log;
  private var his:HisClient;
  private var catalog:Catalog;
  private var outcomes:Outcomes;

  public function new(
    platform:Platform,
    config:ClientConfig,
    log:Log,
    his:HisClient,
    catalog:Catalog,
    outcomes:Outcomes
  ) {
    this.platform = platform;
    this.config = config;
    this.log = log;
    this.his = his;
    this.catalog = catalog;
    this.outcomes = outcomes;
  }

  /**
   * Validates and sends an order. Throws LisError for invalid input; the caller's `run`
   * converts that to an outcome.
   */
  public function create(done:String->Void, orderJson:String):Void {
    var rawInput:Dynamic = parseOrderJson(orderJson);
    var sanitized = Sanitizer.sanitizeOrder(rawInput, config.sexMap, platform.clock.nowMs());
    OrderValidator.check(sanitized.order);

    var lisOrder:Dynamic = Reflect.field(sanitized.order, "lis_order");
    var orderId:String = Reflect.field(lisOrder, "order_id");
    var warnings = sanitized.warnings;

    catalog.check(lisOrder, function(catErr, catWarns) {
      outcomes.protect(done, "createOrder", function() {
        if (catErr != null) {
          Outcomes.error(done, catErr);
          return;
        }
        if (catWarns != null) {
          for (w in catWarns) {
            warnings.push(w);
          }
        }
        withOrderLock(done, orderId, function(unlocked) {
          checkDedupAndSend(sanitized.order, orderId, warnings, unlocked);
        });
      });
    });
  }

  private static function parseOrderJson(orderJson:String):Dynamic {
    try {
      return Json.parse(orderJson);
    } catch (e:Dynamic) {
      throw LisErrorHelper.validationFailed("Invalid order JSON: " + Std.string(e), "order");
    }
  }

  /**
   * Lets only one `createOrder` per order id run between the dedup check and the stored hash.
   * A second concurrent call is rejected at once instead of waiting (HLD D13). The lock is
   * released on every way out: success, LIS error and exception.
   */
  private function withOrderLock(
    done:String->Void,
    orderId:String,
    body:(String->Void)->Void
  ):Void {
    var key = "inflight:" + orderId;
    var marker = Std.string(platform.clock.nowMs());
    var acquired = platform.storage.setIfAbsent(key, marker, ORDER_LOCK_TTL_SEC);
    if (!acquired) {
      log.warn("createOrder", "Another submission of this order is still running.", {
        orderId: orderId
      });
      Outcomes.error(done, LisErrorHelper.orderInProgress(orderId));
      return;
    }

    var unlocked = function(outcomeJson:String) {
      releaseLock(key, orderId);
      done(outcomeJson);
    };
    outcomes.protect(unlocked, "createOrder", function() {
      body(unlocked);
    });
  }

  private function releaseLock(key:String, orderId:String):Void {
    try {
      platform.storage.delete(key);
    } catch (e:Dynamic) {
      // The lock expires by TTL, so a failed release only delays a retry of this order.
      log.warn("storage", "Failed to release order lock: " + Std.string(e), {orderId: orderId});
    }
  }

  private function checkDedupAndSend(
    order:Dynamic,
    orderId:String,
    warnings:Array<Sanitizer.SanitizerWarning>,
    done:String->Void
  ):Void {
    var payloadHash = platform.hash.sha256Hex(Canonical.json(order));
    var storageKey = "sent:" + orderId;
    var prevHash = platform.storage.get(storageKey);

    if (prevHash != null && prevHash == payloadHash) {
      log.info("createOrder", "Order identical to last successful submission.", {
        orderId: orderId
      });
      Outcomes.ok(done, ({
        status: "UNCHANGED",
        order_id: orderId,
        lab_work_order_id: null,
        lab_barcode: null,
        warnings: warnings
      } : Receipt));
      return;
    }

    if (prevHash != null) {
      // Resubmitting a changed order resets result approval on the LIS (HLD F1, HLD §10).
      warnings.push({
        code: "ORDER_RESUBMITTED",
        field: "lis_order.order_id",
        from: prevHash,
        to: payloadHash
      });
    }

    his.send(done, "POST", "/order", Json.stringify(order), function(err, envelope) {
      if (err != null) {
        Outcomes.error(done, err);
        return;
      }
      storeSentHash(storageKey, payloadHash);
      var data:Dynamic = envelope.data;
      Outcomes.ok(done, ({
        status: "SENT",
        order_id: orderId,
        lab_work_order_id: data != null ? Reflect.field(data, "id") : null,
        lab_barcode: data != null ? Reflect.field(data, "barcode") : null,
        warnings: warnings
      } : Receipt));
    });
  }

  private function storeSentHash(storageKey:String, payloadHash:String):Void {
    try {
      platform.storage.set(storageKey, payloadHash, SENT_HASH_TTL_SEC);
    } catch (e:Dynamic) {
      // The order is already accepted by the LIS; only dedup of the next resubmission is lost.
      log.warn("storage", "Failed to store sent order hash: " + Std.string(e));
    }
  }

  /** Deletes the order, then its dedup hash so the same order can be sent again. */
  public function delete(done:String->Void, orderId:String):Void {
    OrderValidator.validateOrderId(orderId);
    var path = "/order/" + HisApi.encodePathParam(orderId);
    his.send(done, "DELETE", path, null, function(err, _) {
      if (err != null) {
        Outcomes.error(done, err);
        return;
      }
      removeSentHash(orderId);
      Outcomes.ok(done, {status: "SENT"});
    });
  }

  private function removeSentHash(orderId:String):Void {
    try {
      platform.storage.delete("sent:" + orderId);
    } catch (e:Dynamic) {
      // The order is deleted on the LIS; a stale hash only makes an identical resend UNCHANGED.
      log.warn("storage", "Failed to remove sent order hash: " + Std.string(e), {orderId: orderId});
    }
  }

  /** Replaces the clinical notes of an existing order. */
  public function updateNotes(done:String->Void, orderId:String, notes:String):Void {
    OrderValidator.validateOrderId(orderId);
    var path = "/order/" + HisApi.encodePathParam(orderId) + "/notes";
    var body = Json.stringify({notes: notes != null ? notes : ""});
    his.send(done, "PATCH", path, body, function(err, _) {
      if (err != null) {
        Outcomes.error(done, err);
        return;
      }
      Outcomes.ok(done, {status: "SENT"});
    });
  }

  public function get(done:String->Void, orderId:String):Void {
    OrderValidator.validateOrderId(orderId);
    his.fetchData(done, "/order/" + HisApi.encodePathParam(orderId));
  }

  /** Lists orders; only the filters the LIS supports are forwarded (LLD §4). */
  public function list(done:String->Void, filterJson:String):Void {
    his.fetchData(done, "/order" + HisApi.buildOrderQueryString(filterJson));
  }
}
