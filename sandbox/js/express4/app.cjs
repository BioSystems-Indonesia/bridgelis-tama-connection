const express = require('express');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient();
const h = require('./_shared/handlers.cjs')(lis);
const app = express();
const out = (res) => (r) => res.status(r.status).json(r.json);

app.post('/lis/webhook', express.json(), async (req, res) => { // body parser ON
  const r = await lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});
app.get('/health', async (q, s) => out(s)(await h.health()));
app.get('/catalog', async (q, s) => out(s)(await h.catalog()));
app.get('/results', (q, s) => s.json([...h.results.values()]));
app.get('/events', (q, s) => s.json(h.events));
app.post('/orders', express.json(), async (q, s) => out(s)(await h.create(q.body)));
app.get('/orders/:id', async (q, s) => out(s)(await h.get(q.params.id)));
app.get('/orders/:id/result', async (q, s) => out(s)(await h.result(q.params.id)));
app.delete('/orders/:id', async (q, s) => out(s)(await h.del(q.params.id)));
app.listen(3000, () => console.log('listening 3000'));
