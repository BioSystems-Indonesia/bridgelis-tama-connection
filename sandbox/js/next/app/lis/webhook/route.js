import sbx from '../../../lib.cjs';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
const { lis } = sbx;

export async function POST(request) {
  const r = await lis.handleWebhook(request);   // README: Next.js App Router
  return new Response(r.body, r);
}
