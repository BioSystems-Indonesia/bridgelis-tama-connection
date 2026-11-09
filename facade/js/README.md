# bridgelis-tama-connection

Client library connecting SIMRS to LIS Tama through the HIS V2 API. Node.js >= 18, ESM and CommonJS, TypeScript types included.

## Install

```bash
npm install bridgelis-tama-connection
```

## Configuration

Read from environment variables. The library does not read `.env` files by itself (use `dotenv` or your framework).

| Env | Required | Meaning |
|---|---|---|
| `LIS_BASE_URL` | yes | LIS address, e.g. `http://192.168.1.10:8322` |
| `LIS_API_KEY` | recommended | Same as **SimrsApiKey** in LIS settings |
| `LIS_WEBHOOK_SECRET` | recommended | Same as the webhook auth value in LIS |
| `LIS_WEBHOOK_SECRET_HEADER` | no | Default `X-API-Key` (or `Authorization` for bearer) |
| `LIS_STORAGE_DIR` | no | Cache folder. Keep it outside the public web folder |
| `LIS_TIMEOUT_MS` / `LIS_CONNECT_TIMEOUT_MS` | no | Default 8000 / 3000 |
| `LIS_UNKNOWN_TEST_POLICY` | no | `reject` (default), `warn`, `off` |
| `LIS_LOG_LEVEL` | no | Default `info` |

Or pass them directly: `new LisClient({ baseUrl, apiKey, ... })`.

## Quick start

```js
import { LisClient, LisError } from 'bridgelis-tama-connection';

const lis = new LisClient();

console.log(await lis.health()); // check config and connection

try {
  const receipt = await lis.createOrder({
    patient: {
      medical_record_number: 'RM-001234',
      first_name: 'Budi',
      date_of_birth: '1990-01-31',
      sex: 'L',
    },
    lis_order: { order_id: 'ORD-001', tests: [{ code: 'HB' }] },
  });
  console.log(receipt.status); // 'SENT' or 'UNCHANGED'
} catch (e) {
  if (e instanceof LisError) console.error(e.code, e.retryable, e.message);
  else throw e;
}
```

Field names are `snake_case`, same as the HIS V2 API.

## Receive results (webhook)

Results arrive only through the webhook, and only after they are approved in LIS.

```js
lis.onResult(async (event) => {
  await db.upsertLabResult(event); // upsert per (order_id, test_code)
});

app.post('/lis/webhook', async (req, res) => {
  const r = await lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});
```

`handleWebhook` accepts a request from Express, NestJS, Fastify, Koa, Next.js, Hono, Bun, Deno, or a raw `(body, headers)` pair.
Edge runtimes are not supported.

## Methods

| Method | Purpose |
|---|---|
| `createOrder(order)` | Send or replace an order |
| `deleteOrder(orderId)` | **Permanently** delete an order |
| `updateNotes(orderId, notes)` | Change order notes |
| `getOrder(orderId)` / `listOrders(filter)` | Read orders |
| `getResult(orderId)` | Get result, `state: 'PENDING'` if not ready |
| `getResultPdf(orderId)` | Result as PDF |
| `getTestTypes()` / `getPackages()` / `getPackage(code)` | LIS catalog |
| `getUsers()` | Doctors and analysts |
| `onResult(handler)` / `handleWebhook(request)` | Receive results |
| `reconcile(options)` | Recover missed results on request (see below) |
| `health()` | Check config and connection |

Hover any method in your editor for details and examples.

## Read before integrating

1. `deleteOrder()` deletes permanently, whatever the status, even when the result is approved.
2. `createOrder()` with an existing `order_id` replaces the order. If auto-approve is off in LIS, approval is reset. Identical resubmission is skipped (`UNCHANGED`); a changed one returns warning `ORDER_RESUBMITTED`.
3. Results come by webhook, and only after approval. If your app is down, LIS marks delivery FAILED and the lab operator can press "Resend". If that is missed, call `reconcile({ since })` from your own cron job or admin button: it re-delivers final results of orders created since that date to your `onResult` handler. It never runs by itself, and it looks at the order *creation* date, not the approval date (LIS has no "changed since" filter), so recovering a revision means fetching every order in the window again; use `skip` and a narrow `since`.
4. The result handler must be idempotent (upsert), because the same result can arrive more than once (webhook, Resend, `reconcile`).
5. A second `createOrder()` for the same `order_id` while the first is still sending fails at once with `ORDER_IN_PROGRESS` (`retryable: true`).
6. Several servers sharing one LIS? Pass `new LisClient({ storage })` with a shared, synchronous store (`get`, `set`, `delete`, `setIfAbsent`). The default file storage is per server. Experimental until 1.0.

## Quick start

```
npx bridgelis-tama-connection init --framework express
```

Creates `client/bridgelis-tama-connection/` with `lis.ts` or `lis.cjs` and a README (never overwrites existing files). Fill the parts marked with a star with your database calls and paste the printed webhook route.

## Errors

Every method throws `LisError` with `code`, `retryable`, and optional `httpStatus`, `requestId`, `field`.
`retryable: true` means LIS is unavailable, try later. `false` means fix the data or configuration.
After 5 consecutive failures the library stops calling LIS for 30 seconds, so your app does not hang.

## Notes

- Test codes are checked against the LIS catalog (LIS code, alias, or LOINC) before sending.
- Sex is normalized (`L`/`P` becomes `M`/`F`). Other values are rejected.
- `order_id` must not contain `/`.
- No patient data is stored on disk. Logs mask patient names and ID numbers.

