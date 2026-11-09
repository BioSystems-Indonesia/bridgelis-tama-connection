// Resilience phases against a running sandbox app. Usage: node resilience.mjs <baseUrl> <phase> [label]
// phases: baseline | down | recovered
const [base, phase, label = base] = process.argv.slice(2);
let fail = 0;
const t = async (method, path, body) => {
  const s = Date.now();
  const res = await fetch(base + path, { method, headers: body ? { 'content-type': 'application/json' } : {}, body: body && JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const text = await res.text(); let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json, ms: Date.now() - s };
};
const ck = (n, ok, d) => { if (!ok) fail++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${n}${ok ? '' : '  ->  ' + JSON.stringify(d)?.slice(0, 300)}`); };
const info = (n, v) => console.log(`  INFO  ${n}: ${JSON.stringify(v)?.slice(0, 250)}`);
const patient = { medical_record_number: 'RM-RES', first_name: 'Res', date_of_birth: '1990-05-15', sex: 'M' };
const mk = (id) => ({ patient, lis_order: { order_id: id, tests: [{ code: 'HGB' }] } });
const id = (n) => `SBX-RES-${n}-${Date.now()}`;
console.log(`== ${label} [${phase}]`);

if (phase === 'baseline') {
  let r = await t('GET', '/catalog'); ck('warm catalog cache', r.status === 200 && r.json.count > 0, r);
  r = await t('GET', '/health'); ck('lisReachable=true', r.json.lisReachable === true, r.json);
}

if (phase === 'down') {
  let r = await t('GET', '/health');
  ck('health does not crash when LIS is down', r.status === 200, r);
  ck('health: lisReachable=false', r.json.lisReachable === false, r.json);
  const oid = id('down');
  r = await t('POST', '/orders', mk(oid));
  info('createOrder while down', { status: r.status, ms: r.ms, body: r.json });
  ck('createOrder -> retryable error (503)', r.status === 503 && r.json.retryable === true, r);
  ck('fails fast (< 12s, no hang)', r.ms < 12000, r.ms);
  // push past the breaker threshold (5 consecutive failures)
  const times = [];
  for (let i = 0; i < 6; i++) { const x = await t('POST', '/orders', mk(id('loop' + i))); times.push(x.ms); }
  info('latency of repeated failing calls (ms)', times);
  r = await t('GET', '/health'); info('health breaker', r.json.breaker);
  ck('breaker opened after repeated failures', r.json.breaker && r.json.breaker.open === true, r.json);
  const s = await t('POST', '/orders', mk(id('open')));
  ck('breaker open -> immediate fail (< 500ms)', s.ms < 500 && s.status === 503, s);
  r = await t('POST', '/lis/webhook', undefined);
  r = await fetch(base + '/lis/webhook', { method: 'POST', headers: { 'content-type': 'application/json', 'x-api-key': process.env.LIS_WEBHOOK_SECRET || 'whsec-sbx' }, body: JSON.stringify({ order_no: 'SBX-RES-WH', status: 'COMPLETED' }) });
  const body = await r.text();
  info('webhook while LIS down', { status: r.status, body });
  ck('webhook -> 5xx so LIS marks FAILED and can Resend', r.status >= 500, r.status);
  const ev = await t('GET', '/events'); ck('no bogus onResult event', Array.isArray(ev.json) && !ev.json.some((e) => e.order_id === 'SBX-RES-WH'), ev.json);
}

if (phase === 'recovered') {
  // breaker cools down after 30s; caller waits before invoking this phase
  let r = await t('GET', '/health'); ck('lisReachable=true again', r.json.lisReachable === true, r.json);
  const oid = id('rec');
  r = await t('POST', '/orders', mk(oid)); ck('createOrder works after recovery', r.status === 200 && r.json.status === 'SENT', r);
  ck('breaker closed', (await t('GET', '/health')).json.breaker.open === false, null);
  r = await t('DELETE', `/orders/${oid}`); ck('cleanup deleteOrder', r.status === 200, r);
}

console.log(`  => ${fail ? fail + ' FAILED' : 'ok'}`);
process.exit(fail ? 1 : 0);
