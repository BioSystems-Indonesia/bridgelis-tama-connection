const Koa = require('koa');
const Router = require('@koa/router');
const bodyParser = require('koa-bodyparser');
const { LisClient } = require('bridgelis-tama-connection');
const lis = new LisClient();
const h = require('./_shared/handlers.cjs')(lis);
const app = new Koa();
const router = new Router();
const out = (ctx, r) => { ctx.status = r.status; ctx.body = r.json; };

router.post('/lis/webhook', async (ctx) => {
  const r = await lis.handleWebhook(ctx.request); // Koa request (bodyparser ON)
  ctx.status = r.status; ctx.set(r.headers); ctx.body = r.body;
});
router.get('/health', async (c) => out(c, await h.health()));
router.get('/catalog', async (c) => out(c, await h.catalog()));
router.get('/events', (c) => { c.body = h.events; });
router.post('/orders', async (c) => out(c, await h.create(c.request.body)));
router.get('/orders/:id', async (c) => out(c, await h.get(c.params.id)));
router.get('/orders/:id/result', async (c) => out(c, await h.result(c.params.id)));
router.delete('/orders/:id', async (c) => out(c, await h.del(c.params.id)));
app.use(bodyParser()).use(router.routes()).listen(3000, () => console.log('listening 3000'));
