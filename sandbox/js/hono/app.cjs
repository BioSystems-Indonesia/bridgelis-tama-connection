const { Hono } = require('hono');
const { serve } = require('@hono/node-server');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient();
const h = require('./_shared/handlers.cjs')(lis);
const app = new Hono();
const out = (c, r) => c.json(r.json, r.status);

app.post('/lis/webhook', async (c) => {
  const r = await lis.handleWebhook(c.req.raw); // fetch-style Request
  return new Response(r.body, r);
});
app.get('/health', async (c) => out(c, await h.health()));
app.get('/catalog', async (c) => out(c, await h.catalog()));
app.get('/events', (c) => c.json(h.events));
app.post('/orders', async (c) => out(c, await h.create(await c.req.json())));
app.get('/orders/:id', async (c) => out(c, await h.get(c.req.param('id'))));
app.get('/orders/:id/result', async (c) => out(c, await h.result(c.req.param('id'))));
app.delete('/orders/:id', async (c) => out(c, await h.del(c.req.param('id'))));
serve({ fetch: app.fetch, port: 3000 }, () => console.log('listening 3000'));
