// Black-box HTTP driver. Same checks for every framework app (JS or PHP).
// Usage: node driver.mjs <baseUrl> <label>
const [base, label = 'app'] = process.argv.slice(2);
const SECRET = process.env.LIS_WEBHOOK_SECRET || 'whsec-sbx';
const MODE = process.env.MODE || "real";
const code = MODE === "mock" ? "GLU" : (process.env.TEST_CODE || "HGB");
let skipped = 0;
const skip = (name, why) => { skipped++; console.log(`  SKIP  ${name}  (${why})`); };
const orderId = `SBX-${label}-${Date.now()}`;
let pass = 0, fail = 0;

const j = async (method, path, body, headers = {}) => {
  const res = await fetch(base + path, {
    method,
    headers: { ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json, headers: res.headers };
};
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}  ->  ${JSON.stringify(detail)?.slice(0, 400)}`); }
};
const info = (name, v) => console.log(`  INFO  ${name}: ${JSON.stringify(v)?.slice(0, 300)}`);

// wait for app
for (let i = 0; i < 900; i++) {
  try { await fetch(base + '/events'); break; } catch { await new Promise((r) => setTimeout(r, 1000)); }
  if (i === 899) { console.log('  FAIL  app never came up'); process.exit(2); }
}

// 1. health
let r = await j('GET', '/health');
check('health 200, lisReachable', r.status === 200 && r.json.lisReachable === true, r);
check('health: apiKeySet + webhookSecretSet', r.json.apiKeySet === true && r.json.webhookSecretSet === true, r.json);
check('health: no secret leaked', !JSON.stringify(r.json).includes('qwerty') && !JSON.stringify(r.json).includes(SECRET), r.json);

// 2. catalog from real LIS
r = await j('GET', '/catalog');
check('catalog fetch from LIS', r.status === 200 && typeof r.json.count === 'number', r);
info('LIS catalog size', r.json);

// 3. validation: invalid sex must be rejected locally, non-retryable
const patient = { medical_record_number: 'RM-SBX', first_name: 'Budi', last_name: 'Sandbox', date_of_birth: '15/05/1990', sex: 'L' };
r = await j('POST', '/orders', { patient: { ...patient, sex: 'ALIEN' }, lis_order: { order_id: orderId + '-bad', tests: [{ code }] } });
check('invalid sex -> rejected, retryable=false', r.status === 422 && r.json.retryable === false && !!r.json.error, r);
r = await j('POST', '/orders', { patient, lis_order: { order_id: 'has/slash', tests: [{ code }] } });
check('order_id with "/" -> rejected', r.status === 422 && r.json.retryable === false, r);

// 4. create order (L -> M, dd/mm/yyyy normalised)
const order = { patient, lis_order: { order_id: orderId, tests: [{ code }] } };
if (MODE === "mock") {
  r = await j("POST", "/orders", { patient, lis_order: { order_id: orderId + "-unk", tests: [{ code: "NOPE-XYZ" }] } });
  check("unknown test code rejected by catalog check", r.status === 422 && r.json.retryable === false, r);
}
r = await j("POST", "/orders", order);
let created = r.status === 200 && r.json.status === "SENT";
if (MODE === "real" && r.status === 422 && /no valid test types/i.test(r.json.message || "")) {
  skip("createOrder SENT + lifecycle", "real LIS has an empty test catalog; it rejects any order (library surfaced LIS_REJECTED correctly)");
  check("LIS rejection mapped to LIS_REJECTED, retryable=false", r.json.error === "LIS_REJECTED" && r.json.retryable === false, r);
} else {
  check("createOrder SENT", created, r);
  info("receipt", r.json);
}
if (created) {
  check("sanitizer/receipt has warnings array", Array.isArray(r.json.warnings), r.json);
  r = await j("POST", "/orders", order);
  check("identical resubmit -> UNCHANGED", r.status === 200 && r.json.status === "UNCHANGED", r);
  r = await j("GET", `/orders/${orderId}`);
  check("getOrder", r.status === 200, r);
  r = await j("GET", `/orders/${orderId}/result`);
  if (MODE === "mock") check("getResult -> AVAILABLE", r.status === 200 && r.json.state === "AVAILABLE", r);
  else check("getResult -> PENDING", r.status === 200 && r.json.state === "PENDING", r);
}

// 5. webhook
const wh = (body, headers) => j('POST', '/lis/webhook', body, headers);
r = await wh({ order_no: orderId, status: 'COMPLETED' }, { 'x-api-key': 'wrong' });
check('webhook wrong secret -> 401', r.status === 401, r);
r = await wh({ order_no: orderId, status: 'COMPLETED' });
check('webhook no secret -> 401', r.status === 401, r);
r = await wh({ status: 'COMPLETED' }, { 'x-api-key': SECRET });
check('webhook missing order id -> 400', r.status === 400, r);
r = await wh('{not json', { 'x-api-key': SECRET });
check('webhook malformed JSON -> 4xx', r.status >= 400 && r.status < 500, r);
if (created) {
  r = await wh({ order_no: orderId, status: "COMPLETED" }, { "x-api-key": SECRET });
  info("webhook valid -> reply", { status: r.status, body: r.json });
  if (MODE === "mock") check("webhook valid secret -> 200", r.status === 200, r);
  else check("webhook for not-yet-approved result -> 404 pending (LIS will mark FAILED, operator can Resend)", r.status === 404 && /pending/i.test(JSON.stringify(r.json)), r);
  const ev = (await j("GET", "/events")).json;
  info("events received by onResult", ev);
  if (MODE === "mock") check("onResult handler received the event", Array.isArray(ev) && ev.some((x) => x.order_id === orderId && x.is_final === true), ev);
}

// 6. delete
if (created) {
  r = await j("DELETE", `/orders/${orderId}`);
  check("deleteOrder", r.status === 200, r);
  if (MODE === "real") {
    r = await j("GET", `/orders/${orderId}`);
    check("getOrder after delete -> not found, non-retryable", r.status === 422 && r.json.retryable === false, r);
  }
}

console.log(`  == ${label}: ${pass} passed, ${fail} failed, ${skipped} skipped`);
process.exit(fail ? 1 : 0);
