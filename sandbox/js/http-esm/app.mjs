import http from 'node:http';
import { createRequire } from 'node:module';
import { LisClient } from 'bridgelis-tama-connection';

const lis = new LisClient();
const h = createRequire(import.meta.url)('./_shared/handlers.cjs')(lis);

http.createServer(async (req, res) => {
  const send = (r) => { res.writeHead(r.status, { 'content-type': 'application/json' }); res.end(JSON.stringify(r.json)); };
  let body = ''; for await (const c of req) body += c;
  try {
    if (req.method === 'POST' && req.url === '/lis/webhook') {
      const r = await lis.handleWebhook(body, req.headers); // raw body + headers form
      res.writeHead(r.status, r.headers); return res.end(r.body);
    }
    const m = req.url.match(/^\/orders\/([^/]+)(\/result)?$/);
    if (req.method === 'GET' && req.url === '/health') return send(await h.health());
    if (req.method === 'GET' && req.url === '/catalog') return send(await h.catalog());
    if (req.method === 'GET' && req.url === '/events') return send({ status: 200, json: h.events });
    if (req.method === 'POST' && req.url === '/orders') return send(await h.create(JSON.parse(body)));
    if (m && req.method === 'GET' && m[2]) return send(await h.result(decodeURIComponent(m[1])));
    if (m && req.method === 'GET') return send(await h.get(decodeURIComponent(m[1])));
    if (m && req.method === 'DELETE') return send(await h.del(decodeURIComponent(m[1])));
    send({ status: 404, json: { error: 'ROUTE' } });
  } catch (e) { send({ status: 500, json: { error: 'NOT_LIS_ERROR', message: String(e.stack) } }); }
}).listen(3000, () => console.log('listening 3000'));
