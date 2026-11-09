import sbx from '../../../lib.cjs';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
const { h } = sbx;
const j = (r) => Response.json(r.json, { status: r.status });
export async function GET(_r, { params }) { return j(await h.get((await params).id)); }
export async function DELETE(_r, { params }) { return j(await h.del((await params).id)); }
