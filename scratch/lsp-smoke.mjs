// Smoke test: spawn agentscript-lsp over stdio, open a broken .agent doc,
// assert at least one publishDiagnostics arrives. Exit 0 on success.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverJs = path.join(here, 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js');

const brokenText = [
  'config:',
  '    agent_name "MissingColonBot"',
  '',
  'bogus_block_keyword:',
  '    whatever',
  '',
].join('\n');

const child = spawn(process.execPath, [serverJs, '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'] });

let buf = Buffer.alloc(0);
let nextId = 1;
let sawInitResult = false;
let diags = null;

function send(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8');
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
}

function onMessage(msg) {
  if (msg.id === 1 && msg.result) {
    sawInitResult = true;
    console.log('initialize OK. capabilities:', Object.keys(msg.result.capabilities || {}).join(', '));
    send({ jsonrpc: '2.0', method: 'initialized', params: {} });
    send({
      jsonrpc: '2.0',
      method: 'textDocument/didOpen',
      params: {
        textDocument: {
          uri: 'file:///' + path.join(here, 'broken.agent').replace(/\\/g, '/'),
          languageId: 'agentscript',
          version: 1,
          text: brokenText,
        },
      },
    });
  } else if (msg.method === 'textDocument/publishDiagnostics') {
    diags = msg.params.diagnostics;
    console.log(`publishDiagnostics: ${diags.length} diagnostic(s)`);
    for (const d of diags.slice(0, 5)) {
      console.log(`  [${d.severity}] L${d.range.start.line + 1}: ${d.message}`);
    }
    finish(diags.length >= 1 ? 0 : 1);
  } else if (msg.method === 'window/logMessage') {
    // ignore
  }
}

function finish(code) {
  try { child.kill(); } catch {}
  process.exit(code);
}

child.stdout.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const headerEnd = buf.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;
    const header = buf.slice(0, headerEnd).toString('utf8');
    const m = /Content-Length: *(\d+)/i.exec(header);
    if (!m) { buf = buf.slice(headerEnd + 4); continue; }
    const len = parseInt(m[1], 10);
    if (buf.length < headerEnd + 4 + len) break;
    const body = buf.slice(headerEnd + 4, headerEnd + 4 + len).toString('utf8');
    buf = buf.slice(headerEnd + 4 + len);
    try { onMessage(JSON.parse(body)); } catch (e) { console.error('parse error', e); }
  }
});

child.stderr.on('data', (d) => console.error('[server stderr]', d.toString().trim()));
child.on('exit', (code) => {
  if (diags === null) {
    console.error(`server exited early (code ${code}), initResult=${sawInitResult}`);
    process.exit(1);
  }
});

send({
  jsonrpc: '2.0', id: nextId++, method: 'initialize',
  params: { processId: process.pid, rootUri: null, capabilities: {}, workspaceFolders: null },
});

setTimeout(() => {
  console.error(`TIMEOUT. initResult=${sawInitResult}, diags=${JSON.stringify(diags)}`);
  finish(1);
}, 20000);
