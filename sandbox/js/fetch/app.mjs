// Bun and Deno: fetch-style Request/Response, handleWebhook(request) as README shows.
import { createRequire } from 'node:module';
import { LisClient } from 'bridgelis-tama-connection';

const lis = new LisClient();
const h = createRequire(import.meta.url)('./_shared/handlers.cjs')(lis);
const json = (r) => new Response(JSON.stringify(r.json), { status: r.status, headers: { 'content-type': 'application/json' } });

async function handle(request) {
  const { pathname } = new URL(request.url);
  const m = pathname.match(/^\/orders\/([^/]+)(\/result)?$/);
  if (request.method === 'POST' && pathname === '/lis/webhook') {
    const r = await lis.handleWebhook(request);
    return new Response(r.body, r);
  }
  if (request.method === 'GET' && pathname === '/health') return json(await h.health());
  if (request.method === 'GET' && pathname === '/catalog') return json(await h.catalog());
  if (request.method === 'GET' && pathname === '/events') return json({ status: 200, json: h.events });
  if (request.method === 'POST' && pathname === '/orders') return json(await h.create(await request.json()));
  if (m && request.method === 'GET' && m[2]) return json(await h.result(decodeURIComponent(m[1])));
  if (m && request.method === 'GET') return json(await h.get(decodeURIComponent(m[1])));
  if (m && request.method === 'DELETE') return json(await h.del(decodeURIComponent(m[1])));
  return json({ status: 404, json: { error: 'ROUTE' } });
}

if (typeof Bun !== 'undefined') Bun.serve({ port: 3000, fetch: handle });
else Deno.serve({ port: 3000, hostname: '0.0.0.0' }, handle);
console.log('listening 3000');
