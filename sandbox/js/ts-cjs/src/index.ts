import http from 'node:http';
import {
  LisClient, LisError,
  type OrderRequest, type ResultEvent, type WebhookResponse, type HealthStatus,
} from 'bridgelis-tama-connection';

const lis = new LisClient(); // config from process.env
const events: Array<{ order_id: string; is_final: boolean }> = [];
const rows = new Map<string, { test_code: string; result?: string; flag?: string; critical?: boolean }>();
lis.onResult(async (e: ResultEvent) => {
  events.push({ order_id: e.order_id, is_final: e.is_final });
  for (const r of e.order.results ?? []) {            // typed: TestResultItem
    rows.set(e.order_id + "|" + r.test_code, { test_code: r.test_code, result: r.result, flag: r.abnormal_flag, critical: r.is_critical });
  }
});

async function call<T>(fn: () => Promise<T>): Promise<{ status: number; json: unknown }> {
  try {
    return { status: 200, json: await fn() };
  } catch (e) {
    if (e instanceof LisError) {
      return { status: e.retryable ? 503 : 422, json: { error: e.code, retryable: e.retryable, httpStatus: e.httpStatus, message: e.message } };
    }
    return { status: 500, json: { error: 'NOT_LIS_ERROR', message: String(e) } };
  }
}

http.createServer(async (req, res) => {
  const send = (r: { status: number; json: unknown }) => { res.writeHead(r.status, { 'content-type': 'application/json' }); res.end(JSON.stringify(r.json)); };
  let body = ''; for await (const c of req) body += c;
  const url = req.url ?? '/';
  if (req.method === 'POST' && url === '/lis/webhook') {
    const r: WebhookResponse = await lis.handleWebhook(body, req.headers); // raw body + headers
    res.writeHead(r.status, r.headers); res.end(r.body); return;
  }
  const m = url.match(/^\/orders\/([^/]+)(\/result)?$/);
  const id = m ? decodeURIComponent(m[1]) : '';
  if (req.method === 'GET' && url === '/health') return send(await call<HealthStatus>(() => lis.health()));
  if (req.method === 'GET' && url === '/catalog') return send(await call(async () => ({ count: (await lis.getTestTypes()).length })));
  if (req.method === 'GET' && url === '/events') return send({ status: 200, json: events });
  if (req.method === 'POST' && url === '/orders') return send(await call(() => lis.createOrder(JSON.parse(body) as OrderRequest)));
  if (m && req.method === 'GET' && m[2]) return send(await call(() => lis.getResult(id)));
  if (m && req.method === 'GET') return send(await call(() => lis.getOrder(id)));
  if (m && req.method === 'DELETE') return send(await call(() => lis.deleteOrder(id)));
  send({ status: 404, json: { error: 'ROUTE' } });
}).listen(3000, () => console.log('listening 3000'));
