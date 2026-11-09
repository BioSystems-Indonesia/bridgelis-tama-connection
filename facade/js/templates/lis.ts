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
import { LisClient, LisError } from 'bridgelis-tama-connection';
import type {
  OrderReceipt,
  OrderRequest,
  ReconcileReport,
  ResultEvent,
  WebhookResponse
} from 'bridgelis-tama-connection';

export const lis = new LisClient();
export { LisError };

interface StoredResult {
  order_id: string;
  test_code: string;
  result?: string;
  unit?: string;
  status: string;
}

// ★ 1. DATABASE. This Map only makes the template run out of the box; it forgets everything
// when the process stops. Replace saveResult() and hasFinalResult() with real database calls.
export const demoResults = new Map<string, StoredResult>();

/**
 * Saves one lab result event. LIS can send the same result more than once (Resend, a revised
 * and approved-again result, reconcile), so ALWAYS upsert, never plain insert.
 * If this function throws, LIS records the delivery as FAILED and the lab can press Resend.
 */
async function saveResult(event: ResultEvent): Promise<void> {
  for (const row of event.order.results ?? []) {
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
async function hasFinalResult(orderId: string): Promise<boolean> {
  return [...demoResults.values()].some((r) => r.order_id === orderId && r.status === 'Final');
}

lis.onResult(saveResult);

/**
 * 2. SEND AN ORDER. Call it when the doctor orders lab tests. Sending the same order twice is
 * safe: identical orders are skipped ('UNCHANGED'). It rejects with LisError; `error.retryable`
 * tells if trying again later can help (LIS down) or the data must be fixed first.
 */
export async function sendOrder(order: OrderRequest): Promise<OrderReceipt> {
  return lis.createOrder(order);
}

/** 3. WEBHOOK. Give it the request of your framework; send back what it returns. */
export async function handleWebhook(
  request: Parameters<LisClient['handleWebhook']>[0]
): Promise<WebhookResponse> {
  return lis.handleWebhook(request as never);
}

/**
 * 4. RECOVERY. Fetches results LIS finished but your system never received (webhook failed and
 * nobody pressed Resend). Run it from a cron job or an admin button, for example
 * `recoverMissedResults('2026-11-04')`. `since` is the date the ORDERS were created.
 */
export async function recoverMissedResults(since: string): Promise<ReconcileReport> {
  return lis.reconcile({ since, skip: hasFinalResult });
}
