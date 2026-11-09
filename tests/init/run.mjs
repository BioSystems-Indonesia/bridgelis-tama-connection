// `init` end to end: creates the integration folder in a scratch project, runs the generated
// template against the mock LIS (create order -> webhook -> onResult -> reconcile), and checks
// that init never overwrites existing files. Run after `npm run build`.
import assert from 'node:assert';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createMockServer } from '../contract/mock/server.mjs';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const scratchRoot = path.join(rootDir, 'tmp/init-test');
const PORT = 8397;
const BASE_URL = `http://127.0.0.1:${PORT}`;
/** Environment of a template run; each project gets its own storage so runs never share dedup state. */
function envFor(project) {
  return {
    ...process.env,
    LIS_BASE_URL: BASE_URL,
    LIS_API_KEY: 'test-api-key',
    LIS_STORAGE_DIR: path.join(project, '.lis-storage')
  };
}

const mock = createMockServer(PORT);
let passed = 0;
let failed = 0;

async function test(name, fn) {
  try {
    await fn();
    console.log(`  ✅ PASS: ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ❌ FAIL: ${name}\n`, err);
    failed++;
  }
}

/** Runs a command without blocking this process (the mock LIS lives in it). */
function runAsync(command, args, options) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { output += chunk; });
    child.on('close', (code) => resolve({ code, output }));
  });
}

function runSync(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  return { code: result.status, output: result.stdout + result.stderr };
}

function freshProject(name) {
  const dir = path.join(scratchRoot, name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const sampleOrder = {
  patient: {
    medical_record_number: 'RM-INIT',
    first_name: 'Budi',
    sex: 'L',
    date_of_birth: '1990-05-15'
  },
  lis_order: { order_id: 'ORD-INIT-1', tests: [{ loinc_code: '2345-7' }] }
};

const webhookRequest = {
  headers: { 'content-type': 'application/json' },
  body: { order_no: 'ORD-INIT-1' }
};

/** Installs the built JS package into a scratch project like `npm install` would. */
function installJsPackage(projectDir) {
  const target = path.join(projectDir, 'node_modules/bridgelis-tama-connection');
  fs.cpSync(path.join(rootDir, 'targets/js'), target, { recursive: true });
}

async function main() {
  await mock.start();
  await fetch(`${BASE_URL}/__mock/reset`, { method: 'POST' });
  fs.rmSync(scratchRoot, { recursive: true, force: true });
  const jsCli = path.join(rootDir, 'targets/js/cli.cjs');
  const phpCli = path.join(rootDir, 'targets/php/bin/bridgelis-tama-connection');

  await test('JS: init creates the folder, keeps existing files, replaces with --force', () => {
    const project = freshProject('js-cli');
    const first = runSync('node', [jsCli, 'init'], project);
    assert.strictEqual(first.code, 0, first.output);
    const lisFile = path.join(project, 'client/bridgelis-tama-connection/lis.cjs');
    assert.ok(fs.existsSync(lisFile));
    assert.ok(fs.existsSync(path.join(project, 'client/bridgelis-tama-connection/README.md')));

    fs.writeFileSync(lisFile, '// my own code');
    const second = runSync('node', [jsCli, 'init'], project);
    assert.ok(second.output.includes('Kept'), second.output);
    assert.strictEqual(fs.readFileSync(lisFile, 'utf8'), '// my own code');

    const forced = runSync('node', [jsCli, 'init', '--force'], project);
    assert.ok(forced.output.includes('Will overwrite'), forced.output);
    assert.notStrictEqual(fs.readFileSync(lisFile, 'utf8'), '// my own code');

    const route = runSync('node', [jsCli, 'init', '--framework', 'express'], project);
    assert.ok(route.output.includes("app.post('/lis/webhook'"), route.output);
    const bad = runSync('node', [jsCli, 'init', '--framework', 'nope'], project);
    assert.strictEqual(bad.code, 2);
  });

  await test('JS: the generated lis.cjs sends an order, saves a webhook result, reconciles', async () => {
    const project = freshProject('js-template');
    installJsPackage(project);
    runSync('node', [jsCli, 'init', '--lang', 'js', '--dir', 'lis'], project);
    fs.writeFileSync(
      path.join(project, 'check.cjs'),
      `
const assert = require('node:assert');
const lisModule = require('./lis/lis.cjs');
(async () => {
  const receipt = await lisModule.sendOrder(${JSON.stringify(sampleOrder)});
  assert.strictEqual(receipt.status, 'SENT');
  const reply = await lisModule.handleWebhook(${JSON.stringify(webhookRequest)});
  assert.strictEqual(reply.status, 200, reply.body);
  assert.ok(lisModule.demoResults.has('ORD-INIT-1:GLU'), 'result must be saved by saveResult');
  const report = await lisModule.recoverMissedResults('2026-11-04');
  assert.strictEqual(typeof report.checked, 'number');
  console.log('OK');
})().catch((e) => { console.error(e); process.exit(1); });
`
    );
    const result = await runAsync('node', ['check.cjs'], { cwd: project, env: envFor(project) });
    assert.strictEqual(result.code, 0, result.output);
  });

  const stripsTypes = ['strip', 'transform'].includes(String(process.features.typescript));
  await test(
    stripsTypes ? 'TS: the generated lis.ts runs' : 'TS: skipped (this Node cannot run .ts files)',
    async () => {
      if (!stripsTypes) {
        return;
      }
      const project = freshProject('ts-template');
      installJsPackage(project);
      fs.writeFileSync(path.join(project, 'tsconfig.json'), '{}');
      const created = runSync('node', [jsCli, 'init', '--dir', 'lis'], project);
      assert.ok(fs.existsSync(path.join(project, 'lis/lis.ts')), created.output);
      fs.writeFileSync(
        path.join(project, 'check.mts'),
        `
import assert from 'node:assert';
import { sendOrder, handleWebhook, demoResults } from './lis/lis.ts';
const receipt = await sendOrder(${JSON.stringify(sampleOrder)});
assert.strictEqual(receipt.status, 'SENT');
const reply = await handleWebhook(${JSON.stringify(webhookRequest)} as never);
assert.strictEqual(reply.status, 200, reply.body);
assert.ok(demoResults.has('ORD-INIT-1:GLU'));
console.log('OK');
`
      );
      const result = await runAsync('node', ['check.mts'], { cwd: project, env: envFor(project) });
      assert.strictEqual(result.code, 0, result.output);
    }
  );

  await test('PHP: init creates lis.php, webhook.php, README and never overwrites', () => {
    const project = freshProject('php-cli');
    const first = runSync('php', [phpCli, 'init', '--dir', 'client/lis'], project);
    assert.strictEqual(first.code, 0, first.output);
    const lisFile = path.join(project, 'client/lis/lis.php');
    for (const name of ['lis.php', 'webhook.php', 'README.md']) {
      assert.ok(fs.existsSync(path.join(project, 'client/lis', name)), name);
    }
    assert.ok(fs.readFileSync(lisFile, 'utf8').includes("'/../../vendor/autoload.php'"));

    fs.writeFileSync(lisFile, '<?php // my own code');
    const second = runSync('php', [phpCli, 'init', '--dir', 'client/lis'], project);
    assert.ok(second.output.includes('Kept'), second.output);
    assert.strictEqual(fs.readFileSync(lisFile, 'utf8'), '<?php // my own code');

    const route = runSync('php', [phpCli, 'init', '--dir', 'client/lis', '--framework', 'laravel'], project);
    assert.ok(route.output.includes("Route::post('/lis/webhook'"), route.output);
    assert.strictEqual(runSync('php', [phpCli, 'init', '--framework', 'nope'], project).code, 2);

    // vendor/bin holds a Composer proxy that includes the real script. On PHP < 8 the proxy strips
    // the shebang first (an included shebang is output before declare()), so this copy has none.
    fs.mkdirSync(path.join(project, 'pkg/bin'), { recursive: true });
    fs.cpSync(path.join(path.dirname(phpCli), '../templates'), path.join(project, 'pkg/templates'), { recursive: true });
    fs.writeFileSync(
      path.join(project, 'pkg/bin/cli'),
      fs.readFileSync(phpCli, 'utf8').replace(/^#!.*\r?\n/, '')
    );
    fs.writeFileSync(path.join(project, 'proxy.php'), `<?php return include __DIR__ . '/pkg/bin/cli';\n`);
    const proxied = runSync('php', ['proxy.php', 'init', '--dir', 'client/proxied'], project);
    assert.ok(fs.existsSync(path.join(project, 'client/proxied/lis.php')), proxied.output);
  });

  await test('PHP: the generated lis.php sends an order, saves a webhook result, reconciles', async () => {
    const project = freshProject('php-template');
    runSync('php', [phpCli, 'init', '--dir', 'client/lis'], project);
    fs.mkdirSync(path.join(project, 'vendor'), { recursive: true });
    const autoload = path.join(rootDir, 'targets/php/autoload.php').split(path.sep).join('/');
    fs.writeFileSync(path.join(project, 'vendor/autoload.php'), `<?php require '${autoload}';\n`);
    fs.writeFileSync(
      path.join(project, 'check.php'),
      `<?php
require __DIR__ . '/client/lis/lis.php';
@unlink(lisDemoStorePath());
$receipt = lisSendOrder(json_decode('${JSON.stringify(sampleOrder)}', true));
if ($receipt['status'] !== 'SENT') { fwrite(STDERR, 'not sent'); exit(1); }
$reply = lisHandleWebhook(json_encode(['order_no' => 'ORD-INIT-1']));
if ($reply['status'] !== 200) { fwrite(STDERR, 'webhook ' . $reply['body']); exit(1); }
if (!isset(lisDemoResults()['ORD-INIT-1:GLU'])) { fwrite(STDERR, 'result not saved'); exit(1); }
$report = lisRecoverMissedResults('2026-11-04');
if (!is_int($report['checked'])) { fwrite(STDERR, 'reconcile failed'); exit(1); }
echo "OK";
`
    );
    const result = await runAsync('php', ['check.php'], { cwd: project, env: envFor(project) });
    assert.strictEqual(result.code, 0, result.output);

    const endpoint = await runAsync('php', ['client/lis/webhook.php'], { cwd: project, env: envFor(project) });
    assert.ok(endpoint.output.includes('Bad Request'), 'webhook.php answers 400 without a body: ' + endpoint.output);
  });

  await mock.close();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===\n`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('init test run failed:', err);
  process.exit(1);
});
