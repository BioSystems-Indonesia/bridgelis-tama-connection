/**
 * Your integration with LIS Tama. This file belongs to your project: edit it freely.
 * Created by `npx bridgelis-tama-connection init`; the library itself stays in node_modules.
 *
 * Set these environment variables (see README.md next to this file):
 *   LIS_BASE_URL        address of the LIS server, for example http://192.168.1.10:8322
 *   LIS_API_KEY         same as SimrsApiKey in the LIS settings
 *   LIS_WEBHOOK_SECRET  same as the webhook auth in LIS (leave empty to accept any caller)
 *
 * Parts marked with a star need your database.
 */
const { LisClient, LisError } = require('bridgelis-tama-connection');

const lis = new LisClient();

// ★ 1. DATABASE. This Map only makes the template run out of the box; it forgets everything
// when the process stops. Replace saveResult() and hasFinalResult() with real database calls.
const demoResults = new Map();

/**
 * Saves one lab result event. LIS can send the same result more than once (Resend, a revised
 * and approved-again result, reconcile), so ALWAYS upsert, never plain insert.
 * If this function throws, LIS records the delivery as FAILED and the lab can press Resend.
 *
 * `event` = { order_id, is_final, received_at, patient, order: { results: [...] } }
 */
async function saveResult(event) {
  for (const row of event.order.results || []) {
    // ★ Example SQL: INSERT ... ON DUPLICATE KEY UPDATE (order_id, test_code are the key).
    demoResults.set(`${event.order_id}:${row.test_code}`, {
      order_id: event.order_id,
      test_code: row.test_code,
      result: row.result,
      unit: row.unit,
      status: row.status
    });
  }
}

/** ★ True when your database already holds the final result of this order (used by reconcile). */
async function hasFinalResult(orderId) {
  return [...demoResults.values()].some((r) => r.order_id === orderId && r.status === 'Final');
}

lis.onResult(saveResult);

/**
 * 2. SEND AN ORDER. Call it when the doctor orders lab tests. `order` has `patient` and
 * `lis_order` (see README.md). Sending the same order twice is safe: identical orders are
 * skipped ('UNCHANGED'). It rejects with LisError; `error.retryable` tells if trying again
 * later can help (LIS down) or the data must be fixed first.
 */
async function sendOrder(order) {
  return lis.createOrder(order);
}

/** 3. WEBHOOK. Give it the request of your framework; send back what it returns. */
async function handleWebhook(request) {
  return lis.handleWebhook(request);
}

/**
 * 4. RECOVERY. Fetches results LIS finished but your system never received (webhook failed and
 * nobody pressed Resend). Run it from a cron job or an admin button, for example
 * `recoverMissedResults('2026-11-04')`. `since` is the date the ORDERS were created.
 */
async function recoverMissedResults(since) {
  return lis.reconcile({ since, skip: hasFinalResult });
}

module.exports = { lis, LisError, sendOrder, handleWebhook, recoverMissedResults, demoResults };
