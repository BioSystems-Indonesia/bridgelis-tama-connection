// Shared route logic (not framework glue): maps LisClient calls to {status, json}.
module.exports = function buildHandlers(lis) {
  const events = [];
  // Upsert per (order_id, test_code), exactly what the README tells SIMRS to do.
  const results = new Map();
  lis.onResult(async (event) => {
    events.push({ order_id: event.order_id, is_final: event.is_final, received_at: event.received_at });
    for (const r of (event.order && event.order.results) || []) {
      results.set(event.order_id + "|" + r.test_code, { order_id: event.order_id, test_code: r.test_code, result: r.result, flag: r.abnormal_flag, critical: r.is_critical, validated_at: r.validated_at });
    }
  });
  const wrap = (fn) => async (...a) => {
    try { return { status: 200, json: await fn(...a) }; }
    catch (e) {
      if (typeof e.retryable !== 'boolean') return { status: 500, json: { error: 'NOT_LIS_ERROR', message: String(e && e.stack || e) } };
      return { status: e.retryable ? 503 : 422, json: { error: e.code, retryable: e.retryable, httpStatus: e.httpStatus, message: e.message } };
    }
  };
  return {
    events,
    results,
    health: wrap(() => lis.health()),
    catalog: wrap(async () => ({ count: (await lis.getTestTypes()).length })),
    create: wrap((b) => lis.createOrder(b)),
    get: wrap((id) => lis.getOrder(id)),
    result: wrap((id) => lis.getResult(id)),
    del: wrap((id) => lis.deleteOrder(id)),
  };
};
