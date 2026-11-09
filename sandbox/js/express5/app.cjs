const express = require('express');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient();
const h = require('./_shared/handlers.cjs')(lis);
const app = express();
const out = (res) => (r) => res.status(r.status).json(r.json);

// Express 5 variant: NO body parser on the webhook, library reads the stream itself.
app.post('/lis/webhook', async (req, res) => {
  const r = await lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});
app.get('/health', async (q, s) => out(s)(await h.health()));
app.get('/catalog', async (q, s) => out(s)(await h.catalog()));
app.get('/events', (q, s) => s.json(h.events));
app.post('/orders', express.json(), async (q, s) => out(s)(await h.create(q.body)));
app.get('/orders/:id', async (q, s) => out(s)(await h.get(q.params.id)));
app.get('/orders/:id/result', async (q, s) => out(s)(await h.result(q.params.id)));
app.delete('/orders/:id', async (q, s) => out(s)(await h.del(q.params.id)));
app.listen(3000, () => console.log('listening 3000'));
