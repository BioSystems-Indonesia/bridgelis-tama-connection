// Production-style start: next build, then next start on :3000.
const { spawnSync, spawn } = require('node:child_process');
const b = spawnSync('npx', ['next', 'build'], { stdio: 'inherit' });
if (b.status !== 0) process.exit(b.status || 1);
spawn('npx', ['next', 'start', '-p', '3000', '-H', '0.0.0.0'], { stdio: 'inherit' }).on('exit', (c) => process.exit(c || 0));
