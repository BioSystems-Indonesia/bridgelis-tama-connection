#!/usr/bin/env node
// Runs `haxe <hxml>` from the repository root. Libraries come from haxelib (`-lib`).
// Offline fallback: set HAXE_LIBS_DIR to a folder holding `utest/` and `hxnodejs/` source
// checkouts, and each `-lib <name>` line is swapped for `-cp <dir>/<name>/src`.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hxml = process.argv[2];
if (!hxml) {
  console.error('usage: node scripts/run-haxe.mjs <file.hxml>');
  process.exit(2);
}

let target = hxml;
let tempDir = null;
const libsDir = process.env.HAXE_LIBS_DIR;
if (libsDir) {
  const text = fs.readFileSync(path.join(rootDir, hxml), 'utf8').replace(
    /^-lib\s+(\S+)\s*$/gm,
    (_, name) => `-cp ${path.join(libsDir, name, 'src').split(path.sep).join('/')}`
  );
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridgelis-hxml-'));
  target = path.join(tempDir, path.basename(hxml));
  fs.writeFileSync(target, text);
}

const result = spawnSync('haxe', [target], { cwd: rootDir, stdio: 'inherit', shell: true });
if (tempDir) {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
if (result.error) {
  console.error(`Could not start haxe: ${result.error.message}. Is Haxe installed and on PATH?`);
}
process.exit(result.status ?? 1);
