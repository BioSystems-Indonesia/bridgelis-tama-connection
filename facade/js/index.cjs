/**
 * Node.js CommonJS facade for bridgeLIS Tama Connection.
 */
const {
  LisCore,
  Platform,
  NodeHttp,
  NodeStorage,
  NodeEnv,
  NodeClock,
  NodeHash,
  NodeLogger
} = require('./core.cjs');
const { normalizeWebhookInput } = require('./webhook-input.cjs');

class LisError extends Error {
  constructor(message, code, retryable, httpStatus, requestId, details, field) {
    super(message);
    this.name = 'LisError';
    this.code = code || 'INTERNAL';
    this.retryable = Boolean(retryable);
    this.httpStatus = httpStatus;
    this.requestId = requestId;
    this.details = details;
    this.field = field;
  }
}

const STORAGE_METHODS = ['get', 'set', 'delete', 'setIfAbsent'];

/** Rejects a custom storage object that lacks a method the core calls. */
function assertStorage(storage) {
  const missing = STORAGE_METHODS.filter((name) => !storage || typeof storage[name] !== 'function');
  if (missing.length > 0) {
    throw new LisError(
      'config.storage must have the methods ' + STORAGE_METHODS.join(', ') +
        '. Missing: ' + missing.join(', ') + '.',
      'VALIDATION_FAILED',
      false,
      undefined,
      undefined,
      undefined,
      'config.storage'
    );
  }
  return storage;
}

/**
 * Wires the Node platform. The storage location is resolved by the core so it follows
 * exactly the same config rules (explicit config, then env, then default). A storage object
 * given by the application replaces the built-in file storage.
 */
function createDefaultPlatform(configJson, customLogger, customStorage) {
  const env = new NodeEnv();
  const clock = new NodeClock();
  const hash = new NodeHash();
  const logger = new NodeLogger(customLogger);

  const settings = JSON.parse(LisCore.resolveStorageSettings(configJson, env));
  const onFallback = () => {
    logger.log('warn', 'Storage directory is not writable. Using in-memory storage.', null);
  };
  const storage = customStorage
    ? assertStorage(customStorage)
    : new NodeStorage(settings.baseUrl, settings.storageDir, hash, clock, onFallback);
  return new Platform(new NodeHttp(), storage, env, clock, hash, logger, 'node');
}

/** Converts a value thrown while building the core (a thrown LisError) to LisError. */
function toLisError(e) {
  const err = (e && e.value) || e || {};
  if (!err.code) {
    return new LisError(String((err && err.message) || err), 'INTERNAL', false);
  }
  return new LisError(
    err.message,
    err.code,
    err.retryable,
    err.httpStatus,
    err.requestId,
    err.details,
    err.field
  );
}

class LisClient {
  constructor(config = null, platform = null) {
    // The logger and the storage are objects, not configuration data; they never go to the
    // core as JSON.
    const { logger, storage, ...configData } = config || {};
    const configJson = config ? JSON.stringify(configData) : null;

    try {
      this._core = new LisCore(configJson, platform || createDefaultPlatform(configJson, logger, storage));
    } catch (e) {
      throw toLisError(e);
    }
    this._onResultHandler = null;
  }

  onResult(handler) {
    this._onResultHandler = handler;
  }

  createOrder(order) {
    return this._promisify((cb) => this._core.createOrder(JSON.stringify(order), cb));
  }

  deleteOrder(orderId) {
    return this._promisify((cb) => this._core.deleteOrder(orderId, cb));
  }

  updateNotes(orderId, notes) {
    return this._promisify((cb) => this._core.updateNotes(orderId, notes, cb));
  }

  getOrder(orderId) {
    return this._promisify((cb) => this._core.getOrder(orderId, cb));
  }

  listOrders(filter = null) {
    const filterJson = filter ? JSON.stringify(filter) : '';
    return this._promisify((cb) => this._core.listOrders(filterJson, cb));
  }

  getResult(orderId) {
    return this._promisify((cb) => this._core.getResult(orderId, cb));
  }

  async getResultPdf(orderId) {
    const b64 = await this._promisify((cb) => this._core.getResultPdf(orderId, cb));
    return Buffer.from(b64, 'base64');
  }

  getTestTypes() {
    return this._promisify((cb) => this._core.getTestTypes(cb));
  }

  getPackages() {
    return this._promisify((cb) => this._core.getPackages(cb));
  }

  getPackage(code) {
    return this._promisify((cb) => this._core.getPackage(code, cb));
  }

  getUsers() {
    return this._promisify((cb) => this._core.getUsers(cb));
  }

  /**
   * Handles a result webhook from the LIS and resolves to the HTTP reply to send back:
   * `{ status, headers, body }`. Works in any framework: pass the framework's request
   * (fetch Request, Node/Express/NestJS/Fastify request) or a raw body plus headers.
   * Reply examples: `new Response(r.body, r)` or
   * `res.status(r.status).set(r.headers).send(r.body)`.
   */
  async handleWebhook(request, headers) {
    const input = await normalizeWebhookInput(request, headers);
    return this._promisify((cb) =>
      this._core.handleWebhook(input.body, JSON.stringify(input.headers), this._resultHandler(), cb)
    );
  }

  /**
   * Re-delivers results that were missed (webhook failed, Resend not pressed). Runs only when
   * called. `options`: `{ since, until?, limit?, skip? }`; `skip(orderId)` may return a boolean
   * or a promise of one. A `skip` that throws puts that order in `failed`.
   */
  reconcile(options) {
    const { skip, ...coreOptions } = options || {};
    const skipWrapper =
      typeof skip === 'function'
        ? (orderId, answer) => {
            Promise.resolve()
              .then(() => skip(orderId))
              .then(
                (shouldSkip) => answer(Boolean(shouldSkip), null),
                (error) => answer(false, (error && error.message) || String(error))
              );
          }
        : null;
    const handler = this._onResultHandler ? this._resultHandler() : null;
    return this._promisify((cb) =>
      this._core.reconcile(JSON.stringify(coreOptions), skipWrapper, handler, cb)
    );
  }

  /** Adapts the registered onResult handler (sync or async) to the core callback style. */
  _resultHandler() {
    return (eventJson, done) => {
      if (!this._onResultHandler) {
        done('No onResult handler registered on LisClient.');
        return;
      }
      try {
        const event = JSON.parse(eventJson);
        const res = this._onResultHandler(event);
        if (res && typeof res.then === 'function') {
          res.then(() => done(null)).catch((err) => done(err?.message || String(err)));
        } else {
          done(null);
        }
      } catch (err) {
        done(err?.message || String(err));
      }
    };
  }

  health() {
    return this._promisify((cb) => this._core.health(cb));
  }

  _promisify(fn) {
    return new Promise((resolve, reject) => {
      fn((outcomeJson) => {
        try {
          const outcome = JSON.parse(outcomeJson);
          if (outcome.ok) {
            resolve(outcome.value);
          } else {
            const err = outcome.error || {};
            reject(
              new LisError(
                err.message || 'Unknown error',
                err.code,
                err.retryable,
                err.httpStatus,
                err.requestId,
                err.details,
                err.field
              )
            );
          }
        } catch (e) {
          reject(new LisError('Failed to parse core response: ' + e.message, 'INTERNAL', false));
        }
      });
    });
  }
}

module.exports = {
  LisClient,
  LisError
};
