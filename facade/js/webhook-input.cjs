/**
 * Turns a webhook request in whatever shape a JS app has into a raw body and header object.
 * Only type conversion lives here; webhook rules (secret, order id, statuses) stay in the core.
 * Frameworks are recognized by duck typing, without dependencies (Node >= 18).
 */

/**
 * Accepted shapes:
 * - fetch `Request` (Next.js route handlers, Hono, Bun, Deno, Remix): `handleWebhook(request)`;
 * - Node / Express / NestJS / Fastify / Koa request objects: `handleWebhook(req)`;
 *   uses `req.body` when a body parser filled it, otherwise reads the stream;
 * - a raw body (string, Buffer/Uint8Array, or parsed object) plus headers
 *   (plain object with string | string[] values, `Headers`, `Map`, or `[name, value]` pairs).
 *
 * @returns {Promise<{ body: string, headers: Record<string, string | string[]> }>}
 */
async function normalizeWebhookInput(request, headers) {
  if (headers === undefined && isFetchRequest(request)) {
    return { body: await request.text(), headers: toHeaderObject(request.headers) };
  }
  if (headers === undefined && isNodeRequest(request)) {
    return { body: await readNodeBody(request), headers: toHeaderObject(request.headers) };
  }
  return { body: toBodyString(request), headers: toHeaderObject(headers) };
}

function isFetchRequest(value) {
  return Boolean(value) && typeof value.text === 'function' && hasForEach(value.headers);
}

/** Node `IncomingMessage` and framework wrappers: a headers object plus a body or a stream. */
function isNodeRequest(value) {
  return Boolean(value) && typeof value === 'object' && typeof value.headers === 'object'
    && ('body' in value || typeof value.on === 'function');
}

async function readNodeBody(req) {
  if (req.body !== undefined && req.body !== null) {
    return toBodyString(req.body);
  }
  // Nothing to read when another middleware already consumed the stream.
  if (typeof req.on !== 'function' || req.readableEnded) {
    return '';
  }
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function toBodyString(body) {
  if (body === undefined || body === null) {
    return '';
  }
  if (typeof body === 'string') {
    return body;
  }
  if (body instanceof Uint8Array) {
    return Buffer.from(body).toString('utf8');
  }
  // Already parsed by a body parser; re-encode it for the core.
  return JSON.stringify(body);
}

function hasForEach(value) {
  return Boolean(value) && typeof value.forEach === 'function';
}

function toHeaderObject(headers) {
  const out = {};
  if (!headers) {
    return out;
  }
  if (Array.isArray(headers)) {
    for (const [name, value] of headers) {
      out[String(name)] = value;
    }
    return out;
  }
  if (hasForEach(headers)) {
    // fetch Headers and Map call back with (value, name).
    headers.forEach((value, name) => {
      out[String(name)] = value;
    });
    return out;
  }
  for (const [name, value] of Object.entries(headers)) {
    if (value !== undefined && value !== null) {
      out[name] = value;
    }
  }
  return out;
}

module.exports = { normalizeWebhookInput };
