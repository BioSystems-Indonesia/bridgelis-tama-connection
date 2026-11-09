import sbx from '../../lib.cjs';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
const { h } = sbx;
const j = (r) => Response.json(r.json, { status: r.status });
export async function GET() { return j(await h.health()); }
