// One LisClient per server process (route bundles are separate modules, so keep it on globalThis).
const { LisClient } = require('bridgelis-tama-connection');
if (!globalThis.__sbx) {
  const lis = new LisClient();
  globalThis.__sbx = { lis, h: require('./_shared/handlers.cjs')(lis) };
}
module.exports = globalThis.__sbx;
