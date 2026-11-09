import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { createMockServer } from '../mock/server.mjs';
import { LisClient, LisError } from '../../../targets/js/index.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '../../..');

/** Reads a shared scenario file from tests/contract/scenarios (same files as the PHP runner). */
function loadScenario(name) {
  const file = path.join(rootDir, 'tests/contract/scenarios', name + '.json');
  return JSON.parse(fs.readFileSync(file));
}

const PORT = 8399;
const BASE_URL = `http://127.0.0.1:${PORT}`;
const mock = createMockServer(PORT);

async function setMock(opts) {
  await fetch(`${BASE_URL}/__mock/set_behavior`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(opts)
  });
}

async function resetMock() {
  await fetch(`${BASE_URL}/__mock/reset`, { method: 'POST' });
}

async function countTestTypeRequests() {
  const reqs = await getMockRequests();
  return reqs.filter((r) => r.path === '/api/v2/his/test-types').length;
}

async function getMockRequests() {
  const res = await fetch(`${BASE_URL}/__mock/requests`);
  return res.json();
}

async function run() {
  console.log('=== Starting Contract Tests (Node.js Runner) ===\n');
  fs.rmSync(path.join(rootDir, 'tmp/test-storage-js'), { recursive: true, force: true });
  await mock.start();

  let passed = 0;
  let failed = 0;

  async function test(name, fn) {
    await resetMock();
    try {
      await fn();
      console.log(`  ✅ PASS: ${name}`);
      passed++;
    } catch (err) {
      console.error(`  ❌ FAIL: ${name}`);
      console.error(err);
      failed++;
    }
  }

  const client = new LisClient({
    baseUrl: BASE_URL,
    apiKey: 'test-api-key',
    storageDir: path.join(rootDir, 'tmp/test-storage-js')
  });

  // Scenario 1: Create order success then identical unchanged
  await test('01: Identical create returns UNCHANGED with 1 server request', async () => {
    const sc = loadScenario('01-create-order-success');
    const r1 = await client.createOrder(sc.order);
    assert.strictEqual(r1.status, 'SENT');
    assert.strictEqual(r1.order_id, 'ORD-CONTRACT-01');

    const r2 = await client.createOrder(sc.order);
    assert.strictEqual(r2.status, 'UNCHANGED');
    assert.strictEqual(r2.order_id, 'ORD-CONTRACT-01');

    const reqs = await getMockRequests();
    const orderPosts = reqs.filter(r => r.path === '/api/v2/his/order' && r.method === 'POST');
    assert.strictEqual(orderPosts.length, 1, 'Server should receive exactly 1 POST /order');
  });

  // Scenario 2: Create order updated payload emits ORDER_RESUBMITTED
  await test('02: Create order with changed payload emits ORDER_RESUBMITTED warning', async () => {
    const sc = loadScenario('02-create-order-resubmitted');
    const r1 = await client.createOrder(sc.order_initial);
    assert.strictEqual(r1.status, 'SENT');

    const r2 = await client.createOrder(sc.order_updated);
    assert.strictEqual(r2.status, 'SENT');
    const resubWarning = r2.warnings.find(w => w.code === 'ORDER_RESUBMITTED');
    assert.ok(resubWarning, 'Should include ORDER_RESUBMITTED warning');
  });

  // Scenario 3: Unknown test code rejected with 0 requests
  await test('03: Unknown test code rejected by catalog with 0 requests to /order', async () => {
    const sc = loadScenario('03-unknown-test-code');
    let threw = false;
    try {
      await client.createOrder(sc.order);
    } catch (err) {
      threw = true;
      assert.strictEqual(err.code, 'UNKNOWN_TEST_CODE');
      assert.strictEqual(err.retryable, false);
    }
    assert.ok(threw, 'Should throw UNKNOWN_TEST_CODE');

    const reqs = await getMockRequests();
    const orderPosts = reqs.filter(r => r.path === '/api/v2/his/order' && r.method === 'POST');
    assert.strictEqual(orderPosts.length, 0, 'No order request should reach server');
  });

  // Scenario 4: Patient sex and DOB sanitization
  await test('04: Normalizes patient sex to F and DOB to YYYY-MM-DD on wire', async () => {
    const sc = loadScenario('04-sanitize-patient');
    const receipt = await client.createOrder(sc.order);
    assert.strictEqual(receipt.status, 'SENT');

    const reqs = await getMockRequests();
    const orderPosts = reqs.filter(r => r.path === '/api/v2/his/order' && r.method === 'POST');
    assert.strictEqual(orderPosts.length, 1);
    const sentBody = orderPosts[0].body;
    assert.strictEqual(sentBody.patient.sex, 'F');
    assert.strictEqual(sentBody.patient.date_of_birth, '1990-05-15');
  });

  // Scenario 5: Transient 503 retry
  await test('05: 503 error on first attempt retries once and succeeds', async () => {
    await setMock({ orderErrorCount: 1, orderErrorType: 503 });
    const sc = loadScenario('05-retry-transient');
    const receipt = await client.createOrder(sc.order);
    assert.strictEqual(receipt.status, 'SENT');

    const reqs = await getMockRequests();
    const orderPosts = reqs.filter(r => r.path === '/api/v2/his/order' && r.method === 'POST');
    assert.strictEqual(orderPosts.length, 2, 'Should retry once upon transient 503');
  });

  // Scenario 6: Circuit breaker
  await test('06: 5 consecutive transient failures trip circuit breaker open', async () => {
    await setMock({ orderErrorCount: 100, orderErrorType: 503 });
    const sc = loadScenario('06-circuit-breaker');

    // Trigger 5 failures
    for (let i = 0; i < 5; i++) {
      try {
        await client.createOrder({
          ...sc.order,
          lis_order: { ...sc.order.lis_order, order_id: `ORD-CB-${i}` }
        });
      } catch (_) {}
    }

    // Now breaker should be open
    let trippedError = null;
    try {
      await client.createOrder({
        ...sc.order,
        lis_order: { ...sc.order.lis_order, order_id: 'ORD-CB-FAST-FAIL' }
      });
    } catch (err) {
      trippedError = err;
    }
    assert.ok(trippedError, 'Should throw circuit breaker open error');
    assert.strictEqual(trippedError.code, 'LIS_UNAVAILABLE');
    assert.strictEqual(trippedError.details?.breakerOpen, true);

    // Verify request works again after cooldown expires (LLD §8 & §12)
    function resetBreakerCooldown(dir) {
      if (!fs.existsSync(dir)) {
        return;
      }
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          resetBreakerCooldown(full);
        }
        else if (full.endsWith('.json')) {
          try {
            const raw = fs.readFileSync(full, 'utf8');
            if (raw.includes('openUntil')) {
              const outer = JSON.parse(raw);
              const inner = JSON.parse(outer.v);
              inner.openUntil = 1;
              outer.v = JSON.stringify(inner);
              fs.writeFileSync(full, JSON.stringify(outer));
            }
          } catch (_) {}
        }
      }
    }
    resetBreakerCooldown(path.join(rootDir, 'tmp/test-storage-js'));

    await setMock({ orderStatus: 200, orderErrorCount: 0 });
    const recoveredOrder = await client.createOrder({
      ...sc.order,
      lis_order: { ...sc.order.lis_order, order_id: 'ORD-CB-RECOVERED' }
    });
    assert.strictEqual(recoveredOrder.status, 'SENT');
  });

  // Scenario 7: 400 LIS_REJECTED without negative cache
  await test('07: 400 produces LIS_REJECTED without negative caching', async () => {
    // Reset test storage to clear tripped circuit breaker from scenario 06
    fs.rmSync(path.join(rootDir, 'tmp/test-storage-js'), { recursive: true, force: true });
    await setMock({ orderStatus: 400, customOrderMessage: 'Invalid patient ward' });
    const sc = loadScenario('07-lis-rejected-no-negative-cache');

    let threw = false;
    try {
      await client.createOrder(sc.order);
    } catch (err) {
      threw = true;
      assert.strictEqual(err.code, 'LIS_REJECTED');
      assert.strictEqual(err.retryable, false);
      assert.strictEqual(err.httpStatus, 400);
    }
    assert.ok(threw);

    // Resubmit again to verify request is not blocked by negative cache
    try {
      await client.createOrder(sc.order);
    } catch (_) {}

    const reqs = await getMockRequests();
    const orderPosts = reqs.filter(r => r.path === '/api/v2/his/order' && r.method === 'POST');
    assert.strictEqual(orderPosts.length, 2, 'Both requests must reach the server');
  });

  // Scenario 8: Status code mappings
  await test('08: Status code mappings (401, 403, 429)', async () => {
    // 401
    await setMock({ authRequired: true, authKey: 'correct-key' });
    const clientBadAuth = new LisClient({ baseUrl: BASE_URL, apiKey: 'wrong-key' });
    try {
      await clientBadAuth.getTestTypes();
      assert.fail('Should fail with 401');
    } catch (err) {
      assert.strictEqual(err.code, 'AUTH_FAILED');
      assert.strictEqual(err.retryable, false);
    }

    // 403
    await setMock({ authRequired: false, orderStatus: 403 });
    try {
      await client.createOrder({
        patient: {
          medical_record_number: 'RM-1',
          first_name: 'A',
          sex: 'M',
          date_of_birth: '1990-01-01'
        },
        lis_order: { order_id: 'ORD-403', tests: [{ loinc_code: '2345-7' }] }
      });
      assert.fail('Should fail with 403');
    } catch (err) {
      assert.strictEqual(err.code, 'BRIDGING_DISABLED');
      assert.strictEqual(err.retryable, false);
    }

    // 429 (not retried)
    await setMock({ orderStatus: 200, rateLimitCount: 1 });
    const reqsBefore429 = await countTestTypeRequests();
    try {
      await client.getTestTypes();
      assert.fail('Should fail with 429');
    } catch (err) {
      assert.strictEqual(err.code, 'RATE_LIMITED');
      assert.strictEqual(err.retryable, true);
      // Response headers must reach the core (regression: NodeHttp dropped all headers).
      assert.strictEqual(err.details?.retryAfterSec, 7);
      assert.strictEqual(err.requestId, 'req-429');
    }
    const reqsAfter429 = await countTestTypeRequests();
    assert.strictEqual(reqsAfter429 - reqsBefore429, 1, '429 must not be retried');
  });

  // Scenario 9: getResult 404 -> PENDING
  await test('09: getResult maps 404 to { state: "PENDING" }', async () => {
    const res = await client.getResult('ORD-PENDING');
    assert.strictEqual(res.state, 'PENDING');
  });

  // Field names verified against a real LIS: result / abnormal_flag / is_critical (not result_value / flag).
  await test('09b: getResult AVAILABLE keeps real LIS field names', async () => {
    const res = await client.getResult('ORD-REAL-SHAPE');
    assert.strictEqual(res.state, 'AVAILABLE');
    const row = res.order.results[0];
    assert.strictEqual(row.result, '95');
    assert.strictEqual(row.abnormal_flag, 'N');
    assert.strictEqual(row.is_critical, false);
    assert.strictEqual(row.result_value, undefined);
    assert.strictEqual(res.order.order_id, 'ORD-REAL-SHAPE');
  });

  // Scenario 10: Webhook handling
  await test('10: Webhook secret, order id, result dispatch and 500 on throw', async () => {
    const webhookClient = new LisClient({
      baseUrl: BASE_URL,
      apiKey: 'test-api-key',
      webhook: { secret: 'secret-key-123', secretHeader: 'X-API-Key' }
    });

    let receivedEvent = null;
    webhookClient.onResult(async (event) => {
      receivedEvent = event;
      if (event.order_id === 'ORD-FAIL-HANDLER') {
        throw new Error('Database write error');
      }
    });

    // 1. Missing or invalid secret -> 401
    const rAuthFail = await webhookClient.handleWebhook(
      JSON.stringify({ order_no: 'ORD-1' }),
      { 'x-api-key': 'wrong-secret' }
    );
    assert.strictEqual(rAuthFail.status, 401);

    // 2. Missing order id in body -> 400
    const rNoOrderId = await webhookClient.handleWebhook(
      JSON.stringify({ status: 'SUCCESS' }),
      { 'x-api-key': 'secret-key-123' }
    );
    assert.strictEqual(rNoOrderId.status, 400);

    // 2b. Upstream LIS 503 -> 502 Bad Gateway (LLD §7.2 & §12)
    const rUpstream503 = await webhookClient.handleWebhook(
      JSON.stringify({ order_no: 'ORD-LIS-DOWN' }),
      { 'x-api-key': 'secret-key-123' }
    );
    assert.strictEqual(rUpstream503.status, 502, 'LIS 503 must cause webhook to return 502');

    // 3. Valid webhook -> 200 and onResult called with is_final
    const rSuccess = await webhookClient.handleWebhook(
      JSON.stringify({ order_no: 'ORD-WEBHOOK-OK' }),
      { 'x-api-key': 'secret-key-123' }
    );
    assert.strictEqual(rSuccess.status, 200);
    assert.ok(receivedEvent);
    assert.strictEqual(receivedEvent.order_id, 'ORD-WEBHOOK-OK');
    assert.strictEqual(receivedEvent.is_final, true);

    // 4. Handler throw -> 500
    const rFail = await webhookClient.handleWebhook(
      JSON.stringify({ order_no: 'ORD-FAIL-HANDLER' }),
      { 'x-api-key': 'secret-key-123' }
    );
    assert.strictEqual(rFail.status, 500);
  });

  // Scenario 11: Webhook Bearer auth
  await test('11: Webhook with Authorization: Bearer secret', async () => {
    const bearerClient = new LisClient({
      baseUrl: BASE_URL,
      webhook: { secret: 'bearer-token-xyz', secretHeader: 'Authorization' }
    });
    bearerClient.onResult(() => {});

    const res = await bearerClient.handleWebhook(
      JSON.stringify({ order_no: 'ORD-BEARER' }),
      { authorization: 'Bearer bearer-token-xyz' }
    );
    assert.strictEqual(res.status, 200);
  });

  // Scenario 12: deleteOrder evicts dedup hash
  await test('12: deleteOrder evicts hash allowing identical order recreate', async () => {
    const sc = loadScenario('12-delete-order-recreate');
    const orderData = {
      patient: {
        medical_record_number: 'RM-DEL',
        first_name: 'Budi',
        sex: 'M',
        date_of_birth: '1990-01-01'
      },
      lis_order: { order_id: 'ORD-DELETE-RECREATE', tests: [{ loinc_code: '2345-7' }] }
    };

    const r1 = await client.createOrder(orderData);
    assert.strictEqual(r1.status, 'SENT');

    // Identical resubmission is UNCHANGED
    const r2 = await client.createOrder(orderData);
    assert.strictEqual(r2.status, 'UNCHANGED');

    // Delete order
    const delRes = await client.deleteOrder('ORD-DELETE-RECREATE');
    assert.strictEqual(delRes.status, 'SENT');

    // Now recreate identical order -> SENT again!
    const r3 = await client.createOrder(orderData);
    assert.strictEqual(r3.status, 'SENT');
  });

  // Scenario 13: Config resolution
  await test('13: Config env resolution and missing baseUrl error', async () => {
    let threw = false;
    try {
      new LisClient({ baseUrl: '' });
    } catch (err) {
      threw = true;
      assert.strictEqual(err.code, 'VALIDATION_FAILED');
      assert.strictEqual(err.field, 'config.baseUrl');
    }
    assert.ok(threw);

    // Test process.env resolution and explicit override (LLD §9 & §12)
    process.env.LIS_BASE_URL = 'http://env-url:8000';
    process.env.LIS_API_KEY = 'env-secret-key';
    const envClient = new LisClient();
    const envHealth = await envClient.health();
    assert.strictEqual(envHealth.baseUrl, 'http://env-url:8000');
    assert.strictEqual(envHealth.apiKeySet, true);

    const explicitClient = new LisClient({ baseUrl: 'http://custom-url:9999' });
    const health = await explicitClient.health();
    assert.strictEqual(health.baseUrl, 'http://custom-url:9999');

    delete process.env.LIS_BASE_URL;
    delete process.env.LIS_API_KEY;
  });

  // Health and other methods coverage
  await test('14: Other endpoints end to end (orders, PDF, catalog, users, health)', async () => {
    const order = await client.getOrder('ORD-TEST');
    assert.ok(order);

    const list = await client.listOrders({ limit: 10 });
    assert.ok(Array.isArray(list));

    const noteRes = await client.updateNotes('ORD-TEST', 'Urgent note');
    assert.strictEqual(noteRes.status, 'SENT');

    const pdfBuf = await client.getResultPdf('ORD-TEST');
    assert.ok(Buffer.isBuffer(pdfBuf));
    assert.ok(pdfBuf.length > 0);

    const pkgs = await client.getPackages();
    assert.ok(Array.isArray(pkgs));

    const pkg = await client.getPackage('PKG-LIPID');
    assert.strictEqual(pkg.code, 'PKG-LIPID');

    const users = await client.getUsers();
    assert.ok(Array.isArray(users));

    const health = await client.health();
    assert.strictEqual(health.lisReachable, true);
    assert.strictEqual(health.apiKeySet, true);
  });

  await test('16: Webhook accepts the request shapes of common JS frameworks', async () => {
    const sc = loadScenario('16-webhook-request-shapes');
    const shapeClient = new LisClient({
      baseUrl: BASE_URL,
      apiKey: 'test-api-key',
      webhook: { secret: sc.secret }
    });
    shapeClient.onResult(() => {});
    const raw = JSON.stringify({ order_no: sc.order_no });
    const url = `${BASE_URL}/lis/webhook`;

    const shapes = {
      'raw string + plain headers': (secret) => [raw, { 'X-API-Key': secret }],
      'Buffer + string[] values': (secret) => [Buffer.from(raw), { 'x-api-key': [secret] }],
      'parsed object + fetch Headers': (secret) => [
        { order_no: sc.order_no },
        new Headers({ 'X-API-Key': secret })
      ],
      'raw + Map': (secret) => [raw, new Map([['X-API-Key', secret]])],
      'raw + pairs': (secret) => [raw, [['X-API-Key', secret]]],
      'fetch Request': (secret) => [
        new Request(url, { method: 'POST', body: raw, headers: { 'X-API-Key': secret } })
      ],
      'Express req with parsed body': (secret) => [
        { headers: { 'x-api-key': secret }, body: { order_no: sc.order_no } }
      ],
      'Node stream without body parser': (secret) => {
        const stream = Readable.from([Buffer.from(raw)]);
        stream.headers = { 'x-api-key': secret };
        return [stream];
      }
    };

    for (const [label, build] of Object.entries(shapes)) {
      const ok = await shapeClient.handleWebhook(...build(sc.secret));
      assert.strictEqual(ok.status, sc.expectedStatus, `${label}: expected ${sc.expectedStatus}`);
      assert.strictEqual(ok.headers['Content-Type'], sc.expectedContentType, `${label}: headers`);

      const denied = await shapeClient.handleWebhook(...build('wrong-secret'));
      assert.strictEqual(denied.status, 401, `${label}: wrong secret must be rejected`);
    }
  });

  await test('17: Concurrent createOrder for one order_id reaches the LIS once', async () => {
    const sc = loadScenario('17-create-order-concurrent');
    await setMock({ orderDelayMs: sc.orderDelayMs });
    const raceDir = path.join(rootDir, 'tmp/test-storage-js-race');
    fs.rmSync(raceDir, { recursive: true, force: true });
    const racer = new LisClient({ baseUrl: BASE_URL, apiKey: 'test-api-key', storageDir: raceDir });

    const outcomes = await Promise.allSettled(
      Array.from({ length: sc.parallel }, () => racer.createOrder(sc.order))
    );

    const sent = outcomes.filter((o) => o.status === 'fulfilled' && o.value.status === 'SENT');
    assert.strictEqual(sent.length, 1, 'exactly one call must be sent');
    for (const o of outcomes) {
      if (o.status === 'rejected') {
        assert.strictEqual(o.reason.code, 'ORDER_IN_PROGRESS');
        assert.strictEqual(o.reason.retryable, true);
      }
    }
    const reqs = await getMockRequests();
    const posts = reqs.filter((r) => r.method === 'POST' && r.path === '/api/v2/his/order');
    assert.strictEqual(posts.length, 1);

    // The lock is released: a changed order is accepted right after.
    await setMock({ orderDelayMs: 0 });
    const changed = structuredClone(sc.order);
    changed.lis_order.clinical_notes = 'changed';
    assert.strictEqual((await racer.createOrder(changed)).status, 'SENT');
  });

  await test('18: reconcile delivers missed final results', async () => {
    const sc = loadScenario('18-reconcile');
    await setMock({ listRows: sc.rows });
    const delivered = [];
    const reconcileClient = new LisClient({
      baseUrl: BASE_URL,
      apiKey: 'test-api-key',
      storageDir: path.join(rootDir, 'tmp/test-storage-js')
    });
    reconcileClient.onResult((event) => {
      if (sc.failIds.includes(event.order_id)) {
        throw new Error('db down');
      }
      delivered.push(event.order_id);
    });

    const report = await reconcileClient.reconcile({
      since: sc.since,
      skip: async (orderId) => sc.skipIds.includes(orderId)
    });

    for (const [key, value] of Object.entries(sc.expectedReport)) {
      assert.strictEqual(report[key], value, 'report.' + key);
    }
    assert.deepStrictEqual(delivered, sc.expectedDeliveredIds);
    assert.deepStrictEqual(
      report.failed.map((f) => f.order_id),
      sc.expectedFailedIds
    );

    const reqs = await getMockRequests();
    const listReq = reqs.find((r) => r.method === 'GET' && r.path === '/api/v2/his/order');
    assert.ok(listReq.search.includes('status=COMPLETED'), listReq.search);
    assert.ok(listReq.search.includes('from=' + sc.since), listReq.search);
    for (const id of sc.unexpectedResultRequests) {
      const fetched = reqs.some((r) => r.path === '/api/v2/his/result/' + id);
      assert.ok(!fetched, id + ' must not be fetched');
    }

    await assert.rejects(
      () => reconcileClient.reconcile({}),
      (e) => e.code === 'VALIDATION_FAILED' && e.field === 'since'
    );
    const noHandler = new LisClient({ baseUrl: BASE_URL });
    await assert.rejects(
      () => noHandler.reconcile({ since: sc.since }),
      (e) => e.code === 'VALIDATION_FAILED' && e.field === 'handler'
    );
  });

  await test('19: Custom storage replaces the file storage', async () => {
    const sc = loadScenario('19-custom-storage');
    const entries = new Map();
    const lockKeys = [];
    const storage = {
      get: (key) => (entries.has(key) ? entries.get(key) : null),
      set: (key, value) => {
        entries.set(key, value);
      },
      delete: (key) => {
        entries.delete(key);
      },
      setIfAbsent: (key, value) => {
        lockKeys.push(key);
        if (entries.has(key)) {
          return false;
        }
        entries.set(key, value);
        return true;
      }
    };
    const custom = new LisClient({ baseUrl: BASE_URL, apiKey: 'test-api-key', storage });

    assert.strictEqual((await custom.createOrder(sc.order)).status, 'SENT');
    assert.strictEqual((await custom.createOrder(sc.order)).status, 'UNCHANGED');
    assert.ok(lockKeys.includes('inflight:ORD-CONTRACT-STORE'));
    assert.ok(entries.has('sent:ORD-CONTRACT-STORE'));
    assert.ok(!entries.has('inflight:ORD-CONTRACT-STORE'), 'lock must be released');
    assert.strictEqual((await custom.health()).storage, 'custom');

    entries.set('inflight:ORD-CONTRACT-STORE', 'held');
    const changed = structuredClone(sc.order);
    changed.lis_order.clinical_notes = 'x';
    await assert.rejects(
      () => custom.createOrder(changed),
      (e) => e.code === 'ORDER_IN_PROGRESS'
    );

    assert.throws(
      () => new LisClient({ baseUrl: BASE_URL, storage: { get() {} } }),
      (e) => e.code === 'VALIDATION_FAILED' && e.field === 'config.storage'
    );
  });

  await mock.close();

  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===\n`);
  if (failed > 0) {
    process.exit(1);
  }
}

run().catch((err) => {
  console.error('Test execution failed:', err);
  process.exit(1);
});
