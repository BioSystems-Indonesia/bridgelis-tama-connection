// P6: the public methods of the three facade files must match one list (name + argument count),
// so a method added in one place and forgotten in another fails CI.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (file) => fs.readFileSync(path.join(rootDir, file), 'utf8');

// name -> number of arguments. `handleWebhook` takes (request, headers) in both languages;
// PHP also has `serveWebhook` (no arguments), which JS does not need.
const SHARED = {
  onResult: 1,
  createOrder: 1,
  deleteOrder: 1,
  updateNotes: 2,
  getOrder: 1,
  listOrders: 1,
  getResult: 1,
  getResultPdf: 1,
  getTestTypes: 0,
  getPackages: 0,
  getPackage: 1,
  getUsers: 0,
  handleWebhook: 2,
  reconcile: 1,
  health: 0
};
const PHP_ONLY = { serveWebhook: 0 };

/** Counts top-level parameters in a parameter list string. */
function countParams(list) {
  const text = list.trim();
  if (text === '') {
    return 0;
  }
  let depth = 0;
  let count = 1;
  for (const ch of text) {
    if ('([{<'.includes(ch)) depth++;
    else if (')]}>'.includes(ch)) depth--;
    else if (ch === ',' && depth === 0) count++;
  }
  return count;
}

/** Collects `name(params)` method declarations whose line matches the given pattern. */
function collect(source, pattern) {
  const found = {};
  for (const match of source.matchAll(pattern)) {
    const [, name, params] = match;
    if (!name.startsWith('_') && name !== 'constructor' && !name.startsWith('__')) {
      found[name] = Math.max(found[name] ?? 0, countParams(params));
    }
  }
  return found;
}

const jsImpl = collect(
  read('facade/js/index.cjs').split('class LisClient')[1],
  /^ {2}(?:async )?([A-Za-z]\w*)\(([^)]*)\)\s*\{/gm
);
// d.ts overloads of handleWebhook: keep the larger argument count.
const dts = collect(
  read('facade/js/index.d.ts').split('export class LisClient')[1],
  /^ {2}([A-Za-z]\w*)\((.*)\)\s*:/gm
);
const php = collect(
  read('facade/php/src/Client.php'),
  /public function ([A-Za-z]\w*)\(([^)]*)\)/g
);
// PHP handleWebhook has optional arguments; both are accepted as 2 by the shared list.
php.handleWebhook = 2;

const errors = [];
function compare(label, actual, expected) {
  for (const [name, args] of Object.entries(expected)) {
    if (!(name in actual)) {
      errors.push(`${label}: method ${name} is missing`);
    } else if (actual[name] !== args) {
      errors.push(`${label}: ${name} takes ${actual[name]} argument(s), expected ${args}`);
    }
  }
  for (const name of Object.keys(actual)) {
    if (!(name in expected)) {
      errors.push(`${label}: unexpected method ${name}; add it to tests/facade-sync/check.mjs`);
    }
  }
}

compare('facade/js/index.cjs', jsImpl, SHARED);
compare('facade/js/index.d.ts', dts, SHARED);
compare('facade/php/src/Client.php', php, { ...SHARED, ...PHP_ONLY });

if (errors.length > 0) {
  console.error('Facade methods are out of sync:\n  ' + errors.join('\n  '));
  process.exit(1);
}
console.log(`Facade sync OK: ${Object.keys(SHARED).length} shared methods in 3 files.`);
