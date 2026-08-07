// Test stub: a minimal healthy LSP server. Answers the framed `initialize`
// request with a capabilities result, then stays alive until killed.
let buf = '';
process.stdin.on('data', (d) => {
  buf += d.toString('utf8');
  const headerEnd = buf.indexOf('\r\n\r\n');
  if (headerEnd === -1) return;
  const m = /Content-Length:\s*(\d+)/i.exec(buf.slice(0, headerEnd));
  if (!m) return;
  const len = parseInt(m[1], 10);
  const body = buf.slice(headerEnd + 4, headerEnd + 4 + len);
  if (body.length < len) return;
  const msg = JSON.parse(body);
  if (msg.method === 'initialize') {
    const resp = JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { capabilities: {} } });
    process.stdout.write(`Content-Length: ${Buffer.byteLength(resp)}\r\n\r\n${resp}`);
  }
});
setInterval(() => {}, 1 << 30);
