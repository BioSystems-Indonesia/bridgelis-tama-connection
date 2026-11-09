#!/usr/bin/env node
// Records a real `GET /order` response into tests/contract/fixtures/list-orders.json with the
// patient data masked. Needs a reachable LIS:
//   LIS_BASE_URL=http://localhost:8322 LIS_API_KEY=... node scripts/record-list-fixture.mjs
// Review the file before committing: only masking of the fields below is done here.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const baseUrl = (process.env.LIS_BASE_URL || '').replace(/\/+$/, '');
const apiKey = process.env.LIS_API_KEY || '';
if (!baseUrl) {
  console.error('Set LIS_BASE_URL (and LIS_API_KEY when the LIS requires it).');
  process.exit(2);
}

const url = `${baseUrl}/api/v2/his/order?status=COMPLETED&page=1&limit=3`;
const response = await fetch(url, { headers: apiKey ? { 'X-API-Key': apiKey } : {} });
const body = await response.json();
if (response.status !== 200 || !Array.isArray(body.data)) {
  console.error(`Unexpected reply (HTTP ${response.status}):`, JSON.stringify(body).slice(0, 300));
  process.exit(1);
}

/** Replaces identifying values; keeps the shape and the non-identifying fields. */
function maskRow(row, index) {
  const masked = { ...row };
  if (masked.order_id) masked.order_id = `ORD-FIXTURE-${index + 1}`;
  if (masked.barcode_simrs) masked.barcode_simrs = masked.order_id;
  if (masked.encounter_id) masked.encounter_id = `ENC-${index + 1}`;
  if (masked.patient) {
    masked.patient = {
      ...masked.patient,
      medical_record_number: `MRN-${index + 1}`,
      first_name: 'Budi',
      last_name: 'Santoso',
      date_of_birth: '1990-01-01'
    };
  }
  return masked;
}

const fixture = {
  _source: `Recorded from a real LIS on ${new Date().toISOString().slice(0, 10)}; patient data masked.`,
  code: body.code,
  status: body.status,
  data: body.data.map(maskRow)
};
const target = path.join(rootDir, 'tests/contract/fixtures/list-orders.json');
fs.writeFileSync(target, JSON.stringify(fixture, null, 2) + '\n');
console.log(`Wrote ${fixture.data.length} row(s) to ${path.relative(rootDir, target)}.`);
console.log('Fields of the first row:', Object.keys(body.data[0] || {}).join(', '));
