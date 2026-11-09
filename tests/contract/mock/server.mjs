import http from 'node:http';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

// Order list rows follow the HIS V2 DTO (see fixtures/list-orders.json).
const listFixture = JSON.parse(
  fs.readFileSync(new URL('../fixtures/list-orders.json', import.meta.url), 'utf8')
);

/** Sends a HIS V2 message envelope {code, status, message} (errors and plain acks). */
function sendMessage(res, code, status, message, headers = {}) {
  res.writeHead(code, { 'Content-Type': 'application/json', ...headers });
  res.end(JSON.stringify({ code, status, message }));
}

/** Sends a HIS V2 success envelope {code: 200, status: 'SUCCESS', data}. */
function sendData(res, data) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ code: 200, status: 'SUCCESS', data }));
}

export function createMockServer(port = 8322) {
  let requestLogs = [];
  let behavior = {
    orderStatus: 200,
    orderErrorCount: 0,
    orderErrorType: 503,
    customOrderMessage: 'Invalid request',
    authRequired: false,
    authKey: 'test-api-key',
    rateLimitCount: 0,
    failPing: false,
    resultOverrides: {}, // orderId -> { status, data }
    orderDelayMs: 0, // delay before POST /order answers (to keep concurrent calls overlapping)
    listRows: null // array of order rows served by GET /order (default: fixtures/list-orders.json)
  };

  const defaultCatalogTestTypes = [
    {
      code: 'GLU',
      loinc_code: '2345-7',
      name: 'Glukosa Sewaktu',
      alias_code: 'GDS',
      alternative_codes: ['GLUCOSE']
    },
    {
      code: 'CHOL',
      loinc_code: '14682-9',
      name: 'Kolesterol Total',
      alias_code: 'CHOL-T',
      alternative_codes: []
    },
    {
      code: 'TG',
      loinc_code: '58410-2',
      name: 'Trigliserida',
      alias_code: 'TRIG',
      alternative_codes: []
    }
  ];

  const defaultCatalogPackages = [
    { id: 1, code: 'PKG-LIPID', loinc_code: '24326-1', name: 'Paket Lipid Lengkap' }
  ];

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${port}`);
    const pathname = url.pathname;

    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      let parsedBody = null;
      try { parsedBody = JSON.parse(body); } catch (_) {}

      // Log request
      const logEntry = {
        method: req.method,
        path: pathname,
        search: url.search,
        headers: req.headers,
        body: parsedBody || body
      };
      requestLogs.push(logEntry);

      // Handle Mock Control API
      if (pathname === '/__mock/reset') {
        requestLogs = [];
        behavior = {
          orderStatus: 200,
          orderErrorCount: 0,
          orderErrorType: 503,
          customOrderMessage: 'Invalid request',
          authRequired: false,
          authKey: 'test-api-key',
          rateLimitCount: 0,
          failPing: false,
          resultOverrides: {},
          orderDelayMs: 0,
          listRows: null
        };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      if (pathname === '/__mock/set_behavior') {
        Object.assign(behavior, parsedBody || {});
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, behavior }));
        return;
      }

      if (pathname === '/__mock/requests') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(requestLogs));
        return;
      }

      // Check Auth if required
      if (behavior.authRequired) {
        const apiKey = req.headers['x-api-key'];
        if (apiKey !== behavior.authKey) {
          sendMessage(res, 401, 'UNAUTHORIZED', 'Invalid or missing API key');
          return;
        }
      }

      // 429 Rate Limit simulation
      if (behavior.rateLimitCount > 0) {
        behavior.rateLimitCount--;
        const rateLimitHeaders = { 'Retry-After': '7', 'X-Request-Id': 'req-429' };
        sendMessage(res, 429, 'TOO_MANY_REQUESTS', 'Rate limit exceeded', rateLimitHeaders);
        return;
      }

      // Ping endpoint
      if (pathname === '/api/v1/ping') {
        if (behavior.failPing) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ status: 'error' }));
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ status: 'ok' }));
        }
        return;
      }

      // Test Types Catalog
      if (pathname === '/api/v2/his/test-types') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 200, status: 'SUCCESS', data: defaultCatalogTestTypes }));
        return;
      }

      // Packages Catalog
      if (pathname === '/api/v2/his/packages') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 200, status: 'SUCCESS', data: defaultCatalogPackages }));
        return;
      }

      if (pathname.startsWith('/api/v2/his/packages/')) {
        const pkgCode = pathname.replace('/api/v2/his/packages/', '');
        const pkg = defaultCatalogPackages.find(p => p.code === pkgCode);
        if (pkg) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ code: 200, status: 'SUCCESS', data: pkg }));
        } else {
          sendMessage(res, 404, 'NOT_FOUND', 'Package not found');
        }
        return;
      }

      // Users
      if (pathname === '/api/v2/his/users') {
        sendData(res, [{ id: 1, name: 'dr. Budi Sp.PK' }]);
        return;
      }

      // POST /order
      if (pathname === '/api/v2/his/order' && req.method === 'POST') {
        if (behavior.orderErrorCount > 0) {
          behavior.orderErrorCount--;
          const errCode = behavior.orderErrorType || 503;
          sendMessage(res, errCode, 'ERROR', behavior.customOrderMessage || 'Temporary LIS Error');
          return;
        }

        if (behavior.orderStatus === 400) {
          const message = behavior.customOrderMessage || 'Validation failed on server';
          sendMessage(res, 400, 'BAD_REQUEST', message);
          return;
        }

        if (behavior.orderStatus === 403) {
          sendMessage(res, 403, 'FORBIDDEN', 'Bridging mode is not API');
          return;
        }

        const orderId = parsedBody?.lis_order?.order_id || 'UNKNOWN';
        const accept = () => {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            code: 200,
            status: 'SUCCESS',
            data: {
              id: 12345,
              barcode: '2611040001',
              barcode_simrs: orderId,
              status: 'NEW',
              verified_status: 'Pending'
            }
          }));
        };
        if (behavior.orderDelayMs > 0) {
          setTimeout(accept, behavior.orderDelayMs);
        } else {
          accept();
        }
        return;
      }

      // DELETE /order/:id
      if (pathname.startsWith('/api/v2/his/order/') && req.method === 'DELETE') {
        res.writeHead(204);
        res.end();
        return;
      }

      // PATCH /order/:id/notes
      if (pathname.includes('/notes') && req.method === 'PATCH') {
        sendMessage(res, 200, 'SUCCESS', 'Notes updated');
        return;
      }

      // GET /order/:id
      const isOrderDetail = pathname.startsWith('/api/v2/his/order/') && req.method === 'GET';
      if (isOrderDetail && !pathname.includes('result')) {
        const orderId = pathname.replace('/api/v2/his/order/', '');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          code: 200,
          status: 'SUCCESS',
          data: {
            id: 101, order_id: orderId, barcode: '2611040001', barcode_simrs: orderId,
            status: 'NEW', work_order_status: 'NEW', received_date_time: '2026-11-04T10:00:00+07:00',
            patient: { medical_record_number: 'RM-001234', first_name: 'Budi', date_of_birth: '1990-05-15', sex: 'M' },
            tests: [{ code: 'GLU', name: 'Glukosa' }], specimens: [], total_request: 1
          }
        }));
        return;
      }

      // GET /order listing
      if (pathname === '/api/v2/his/order' && req.method === 'GET') {
        // Like the real LIS: a plain array, page starts at 1, no total.
        const rows = behavior.listRows || listFixture.data;
        const page = Math.max(1, Number(url.searchParams.get('page')) || 1);
        const limit = Math.min(1000, Number(url.searchParams.get('limit')) || 100);
        sendData(res, rows.slice((page - 1) * limit, page * limit));
        return;
      }

      // GET /result/:id/pdf
      if (pathname.includes('/result/') && pathname.endsWith('/pdf')) {
        res.writeHead(200, { 'Content-Type': 'application/pdf' });
        res.end('%PDF-1.4 sample pdf binary data');
        return;
      }

      // GET /result/:id
      if (pathname.startsWith('/api/v2/his/result/')) {
        const orderId = pathname.replace('/api/v2/his/result/', '');
        if (behavior.resultOverrides[orderId]) {
          const override = behavior.resultOverrides[orderId];
          res.writeHead(override.status, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(override.body));
          return;
        }

        if (orderId === 'ORD-LIS-DOWN') {
          sendMessage(res, 503, 'ERROR', 'Upstream LIS is down');
          return;
        }

        if (orderId === 'ORD-PENDING') {
          sendMessage(res, 404, 'NOT_FOUND', 'Result not verified or ready');
          return;
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          code: 200,
          status: 'SUCCESS',
          data: {
            patient: { medical_record_number: 'RM-001234', first_name: 'Budi', date_of_birth: '1990-05-15', sex: 'M' },
            order: {
              order_id: orderId,
              status: 'COMPLETED',
              order_date_time: '',
              received_date_time: '2026-11-04T10:00:00+07:00',
              validation_date_time: '2026-11-04T10:30:00+07:00',
              ordering_physician: { id: 0 },
              attending_physician: null,
              technologist: null,
              validator: { id: 1, name: 'Analis Lab' },
              results: [
                {
                  package_name: 'Paket Gula',
                  package_code: 'PKT_GULA',
                  test_code: 'GLU',
                  test_name: 'Glukosa',
                  result: '95',
                  unit: 'mg/dL',
                  reference_range: '70 - 140',
                  abnormal_flag: 'N',
                  is_critical: false,
                  status: 'Final',
                  validated_at: '2026-11-04T10:29:00+07:00'
                }
              ]
            }
          }
        }));
        return;
      }

      // Default 404
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 404, message: 'Not Found' }));
    });
  });

  return {
    server,
    start: () => new Promise(resolve => server.listen(port, resolve)),
    close: () => new Promise(resolve => server.close(resolve))
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const mock = createMockServer(8322);
  mock.start().then(() => {
    console.log('Mock LIS Server listening on port 8322');
  });
}
