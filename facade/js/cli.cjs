#!/usr/bin/env node
/**
 * `bridgelis-tama-connection init`: creates the integration folder once (HLD D15).
 * Developer tooling, not library logic: it copies templates and prints a route snippet. It never
 * overwrites an existing file without --force and never edits the user's own files.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_DIR = 'client/bridgelis-tama-connection';
const TEMPLATES_DIR = path.join(__dirname, 'templates');

const USAGE = `Usage: bridgelis-tama-connection init [options]

Options:
  --dir <folder>        Where to create the files (default: ${DEFAULT_DIR})
  --lang <ts|js>        Template language (default: ts when tsconfig.json exists, else js)
  --framework <name>    Print the webhook route for: express, fastify, koa, hono, next, nest
  --force               Overwrite files that already exist (they are listed first)
  --help                Show this help`;

/** Webhook route snippets; \`REQUIRE\` is replaced by the path to the generated file. */
const ROUTES = {
  express: `app.post('/lis/webhook', async (req, res) => {
  const r = await handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});`,
  fastify: `app.post('/lis/webhook', async (request, reply) => {
  const r = await handleWebhook(request);
  reply.code(r.status).headers(r.headers).send(r.body);
});`,
  koa: `router.post('/lis/webhook', async (ctx) => {
  const r = await handleWebhook(ctx.request);
  ctx.status = r.status;
  ctx.set(r.headers);
  ctx.body = r.body;
});`,
  hono: `app.post('/lis/webhook', async (c) => {
  const r = await handleWebhook(c.req.raw);
  return new Response(r.body, r);
});`,
  next: `// app/lis/webhook/route.ts
export async function POST(request: Request) {
  const r = await handleWebhook(request);
  return new Response(r.body, r);
}`,
  nest: `@Post('lis/webhook')
async webhook(@Req() req: Request, @Res() res: Response) {
  const r = await handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
}`
};

function parseArgs(argv) {
  const options = { dir: DEFAULT_DIR, lang: null, framework: null, force: false, help: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const [flag, inline] = arg.startsWith('--') ? arg.split(/=(.*)/s) : [arg];
    const takeValue = () => (inline !== undefined ? inline : argv[++i]);
    if (flag === '--dir') options.dir = takeValue();
    else if (flag === '--lang') options.lang = takeValue();
    else if (flag === '--framework') options.framework = takeValue();
    else if (flag === '--force') options.force = true;
    else if (flag === '--help' || flag === '-h') options.help = true;
    else if (arg.startsWith('-')) throw new Error(`Unknown option: ${arg}`);
    else rest.push(arg);
  }
  return { command: rest[0], options };
}

function chooseLanguage(lang, cwd) {
  const chosen = lang || (fs.existsSync(path.join(cwd, 'tsconfig.json')) ? 'ts' : 'js');
  if (chosen !== 'ts' && chosen !== 'js') {
    throw new Error(`--lang must be ts or js, got "${chosen}".`);
  }
  return chosen;
}

/** Plans the files of one `init` run: [{ target, content }]. */
function planFiles(targetDir, lang) {
  const templateName = lang === 'ts' ? 'lis.ts' : 'lis.cjs';
  const readme = fs
    .readFileSync(path.join(TEMPLATES_DIR, 'README.md'), 'utf8')
    .replace(/\{\{FILE\}\}/g, templateName)
    .replace(/\{\{DIR\}\}/g, targetDir);
  return [
    {
      target: path.join(targetDir, templateName),
      content: fs.readFileSync(path.join(TEMPLATES_DIR, templateName), 'utf8')
    },
    { target: path.join(targetDir, 'README.md'), content: readme }
  ];
}

/** Writes the planned files. Returns { created, kept, replaced } lists of paths. */
function writeFiles(files, force) {
  const result = { created: [], kept: [], replaced: [] };
  for (const { target, content } of files) {
    const exists = fs.existsSync(target);
    if (exists && !force) {
      result.kept.push(target);
      continue;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
    (exists ? result.replaced : result.created).push(target);
  }
  return result;
}

function run(argv, cwd, out) {
  const { command, options } = parseArgs(argv);
  if (options.help || !command) {
    out(USAGE);
    return command || options.help ? 0 : 2;
  }
  if (command !== 'init') {
    throw new Error(`Unknown command: ${command}`);
  }
  if (options.framework && !ROUTES[options.framework]) {
    throw new Error(
      `Unknown --framework "${options.framework}". Choose: ${Object.keys(ROUTES).join(', ')}.`
    );
  }

  const lang = chooseLanguage(options.lang, cwd);
  const targetDir = path.resolve(cwd, options.dir);
  const shownDir = (path.relative(cwd, targetDir) || '.').split(path.sep).join('/');
  const files = planFiles(shownDir, lang);
  const planned = files.map((f) => ({ ...f, target: path.resolve(cwd, f.target) }));

  if (options.force) {
    for (const f of planned.filter((p) => fs.existsSync(p.target))) {
      out(`Will overwrite: ${path.relative(cwd, f.target)}`);
    }
  }
  const result = writeFiles(planned, options.force);

  for (const f of result.created) out(`Created   ${path.relative(cwd, f)}`);
  for (const f of result.replaced) out(`Replaced  ${path.relative(cwd, f)}`);
  for (const f of result.kept) {
    out(`Kept      ${path.relative(cwd, f)} (already exists; use --force to replace)`);
  }

  const moduleFile = path.posix.join(shownDir, lang === 'ts' ? 'lis' : 'lis.cjs');
  out(`\nNext: open ${shownDir}/README.md. Set LIS_BASE_URL and LIS_API_KEY,`);
  out('then fill the parts marked with a star.');
  if (options.framework) {
    const importLine =
      lang === 'ts'
        ? `import { handleWebhook } from './${moduleFile}';`
        : `const { handleWebhook } = require('./${moduleFile}');`;
    out(`\nWebhook route for ${options.framework} (adjust the path of the import):\n`);
    out(`${importLine}\n\n${ROUTES[options.framework]}`);
  } else {
    const names = Object.keys(ROUTES).join('|');
    out(`Run again with --framework <${names}> to print the webhook route.`);
  }
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = run(process.argv.slice(2), process.cwd(), (line) => console.log(line));
  } catch (error) {
    console.error(`Error: ${error.message}\n\n${USAGE}`);
    process.exitCode = 2;
  }
}

module.exports = { run, ROUTES };
