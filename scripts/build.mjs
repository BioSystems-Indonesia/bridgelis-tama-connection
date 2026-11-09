#!/usr/bin/env node
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

/** Copies a file, both paths relative to the repository root. */
function copyFromRoot(from, to) {
  fs.copyFileSync(path.join(rootDir, from), path.join(rootDir, to));
}

/** Copies a facade folder (relative to the repository root) with its sub-folders. */
function copyDir(from, to) {
  fs.mkdirSync(path.join(rootDir, to), { recursive: true });
  for (const entry of fs.readdirSync(path.join(rootDir, from), { withFileTypes: true })) {
    const source = path.posix.join(from, entry.name);
    const target = path.posix.join(to, entry.name);
    if (entry.isDirectory()) {
      copyDir(source, target);
    } else {
      copyFromRoot(source, target);
    }
  }
}

// One version for every language (rules 11). HisApi.VERSION is sent in the User-Agent and shown
// by health(), so the build fails when it differs from package.json.
const { version } = JSON.parse(fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'));
const hisApiSource = fs.readFileSync(path.join(rootDir, 'src/core/HisApi.hx'), 'utf8');
if (!hisApiSource.includes(`VERSION:String = "${version}"`)) {
  throw new Error(`[build] HisApi.VERSION must be "${version}" (the version in package.json).`);
}

console.log('[build] Starting build pipeline...');

// 1. Start from clean output. Stale files from older builds would otherwise be published,
//    and on case-insensitive Windows an old `Core/` folder would capture the new `core/`
//    namespace, which then fails PSR-4 autoload on Linux.
fs.rmSync(path.join(rootDir, 'targets/php/lib'), { recursive: true, force: true });
fs.rmSync(path.join(rootDir, 'targets/php/src'), { recursive: true, force: true });
fs.rmSync(path.join(rootDir, 'targets/js'), { recursive: true, force: true });
fs.mkdirSync(path.join(rootDir, 'targets/js'), { recursive: true });
fs.mkdirSync(path.join(rootDir, 'targets/php/src'), { recursive: true });

// 2. Compile Haxe JS
console.log('[build] Compiling Haxe to JS...');
execSync('node scripts/run-haxe.mjs build-js.hxml', { cwd: rootDir, stdio: 'inherit' });

// 3. Compile Haxe PHP
console.log('[build] Compiling Haxe to PHP with prefix BridgeLisTamaConnection...');
execSync('node scripts/run-haxe.mjs build-php.hxml', { cwd: rootDir, stdio: 'inherit' });

const repoUrl = 'https://github.com/BioSystems-Indonesia/bridgelis-tama-connection';

// 4. Copy JS Facade files
console.log('[build] Copying JS facade...');
copyDir('facade/js', 'targets/js');
// CommonJS consumers need their own declaration file (TypeScript module=node16/nodenext).
copyFromRoot('facade/js/index.d.ts', 'targets/js/index.d.cts');

// 5. Generate targets/js/package.json
const jsPkg = {
  name: 'bridgelis-tama-connection',
  version,
  description: 'Client library connecting SIMRS to LIS Tama via HIS V2 API',
  keywords: ['lis', 'simrs', 'his', 'laboratory', 'tama'],
  homepage: `${repoUrl}#readme`,
  repository: { type: 'git', url: `git+${repoUrl}.git` },
  bugs: { url: `${repoUrl}/issues` },
  type: 'module',
  bin: { 'bridgelis-tama-connection': './cli.cjs' },
  main: './index.cjs',
  module: './index.mjs',
  types: './index.d.ts',
  // "types" must come first inside each condition: TypeScript picks the first match.
  exports: {
    '.': {
      import: { types: './index.d.ts', default: './index.mjs' },
      require: { types: './index.d.cts', default: './index.cjs' }
    }
  },
  engines: {
    node: '>=18.0.0'
  },
  license: 'MIT'
};
fs.writeFileSync(path.join(rootDir, 'targets/js/package.json'), JSON.stringify(jsPkg, null, 2));

// 6. Copy PHP Facade files
console.log('[build] Copying PHP facade...');
copyDir('facade/php/src', 'targets/php/src');
copyFromRoot('facade/php/README.md', 'targets/php/README.md');
// `vendor/bin/bridgelis-tama-connection init` and the files it creates.
copyDir('facade/php/bin', 'targets/php/bin');
copyDir('facade/php/templates', 'targets/php/templates');
for (const target of ['targets/js', 'targets/php']) {
  copyFromRoot('LICENSE', `${target}/LICENSE`);
}

// 7. Generate targets/php/autoload.php
const phpAutoload = `<?php
// Autoloader for bridgeLIS Tama Connection (PHP >= 7.4)
require_once __DIR__ . '/lib/BridgeLisTamaConnection/php/Boot.php';

spl_autoload_register(function ($class) {
    $prefix = 'BridgeLisTamaConnection\\\\';
    $len = strlen($prefix);
    if (strncmp($prefix, $class, $len) !== 0) {
        return;
    }

    $relative = substr($class, $len);
    $relPath = str_replace('\\\\', '/', $relative) . '.php';

    $facadeFile = __DIR__ . '/src/' . $relPath;
    if (file_exists($facadeFile)) {
        require_once $facadeFile;
        return;
    }

    $libFile = __DIR__ . '/lib/BridgeLisTamaConnection/' . $relPath;
    if (file_exists($libFile)) {
        require_once $libFile;
        return;
    }
});
`;
fs.writeFileSync(path.join(rootDir, 'targets/php/autoload.php'), phpAutoload);

// 8. Generate composer.json: targets/php for local path installs (sandbox), and the repository
//    root because Packagist only reads a composer.json there. Paths are relative to each file.
function composerManifest(base) {
  return {
    name: 'tama-connection/bridgelis-tama-connection',
    description: 'Client library connecting SIMRS to LIS Tama via HIS V2 API',
    type: 'library',
    license: 'MIT',
    keywords: ['lis', 'simrs', 'his', 'laboratory', 'tama'],
    homepage: repoUrl,
    support: { issues: `${repoUrl}/issues`, source: repoUrl },
    bin: [`${base}bin/bridgelis-tama-connection`],
    require: {
      php: '>=7.4',
      'ext-json': '*'
    },
    suggest: {
      'ext-curl': 'Recommended for performant HTTP communication with LIS',
      'ext-openssl': 'Required when LIS base URL uses HTTPS'
    },
    autoload: {
      files: [`${base}lib/BridgeLisTamaConnection/php/Boot.php`],
      'psr-4': {
        'BridgeLisTamaConnection\\': [`${base}src/`, `${base}lib/BridgeLisTamaConnection/`]
      }
    }
  };
}
for (const [file, base] of [['targets/php/composer.json', ''], ['composer.json', 'targets/php/']]) {
  fs.writeFileSync(path.join(rootDir, file), JSON.stringify(composerManifest(base), null, 2) + '\n');
}

// 9. Guard against a casing mismatch between Haxe package folders and namespaces.
const phpLibDir = path.join(rootDir, 'targets/php/lib/BridgeLisTamaConnection');
for (const pkg of ['core', 'platform', 'haxe', 'php']) {
  if (!fs.readdirSync(phpLibDir).includes(pkg)) {
    throw new Error(`[build] Expected folder "${pkg}" (lowercase) in ${phpLibDir}`);
  }
}

console.log('[build] Build completed successfully.');
