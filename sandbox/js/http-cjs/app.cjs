const http = require('node:http');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient(); // config from process.env
const h = require('./_shared/handlers.cjs')(lis);

http.createServer(async (req, res) => {
  const send = (r) => { res.writeHead(r.status, { 'content-type': 'application/json' }); res.end(JSON.stringify(r.json)); };
  try {
    if (req.method === 'POST' && req.url === '/lis/webhook') {
      // Plain node http: pass the raw request, library reads the stream itself.
      const r = await lis.handleWebhook(req);
      res.writeHead(r.status, r.headers); return res.end(r.body);
    }
    let body = ''; for await (const c of req) body += c;
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
