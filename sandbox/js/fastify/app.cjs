const Fastify = require('fastify');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient();
const h = require('./_shared/handlers.cjs')(lis);
const app = Fastify();
const out = (reply, r) => reply.code(r.status).send(r.json);

app.post('/lis/webhook', async (request, reply) => {
  const r = await lis.handleWebhook(request); // Fastify request (JSON body already parsed)
  reply.code(r.status).headers(r.headers).send(r.body);
});
app.get('/health', async (q, s) => out(s, await h.health()));
app.get('/catalog', async (q, s) => out(s, await h.catalog()));
app.get('/events', async () => h.events);
app.post('/orders', async (q, s) => out(s, await h.create(q.body)));
app.get('/orders/:id', async (q, s) => out(s, await h.get(q.params.id)));
app.get('/orders/:id/result', async (q, s) => out(s, await h.result(q.params.id)));
app.delete('/orders/:id', async (q, s) => out(s, await h.del(q.params.id)));
app.listen({ port: 3000, host: '0.0.0.0' }).then(() => console.log('listening 3000'));
