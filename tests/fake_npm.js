// Test stub standing in for `npm install`: reads package.json in the cwd,
// looks up the requested @sf-agentscript/lsp-server version in the behavior
// map given as argv[2] (e.g. "9.9.9=crash,2.2.30=ok"), and materialises
// dist/index.js as the matching stub server. No network.
const fs = require('fs');
const path = require('path');

const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const version = pkg.dependencies['@sf-agentscript/lsp-server'];
const map = Object.fromEntries(
  (process.argv[2] || '')
    .split(',')
    .filter(Boolean)
    .map((s) => s.split('='))
);
const mode = map[version];
if (!mode) {
  process.stderr.write(`fake_npm: no behavior mapped for version ${version}\n`);
  process.exit(1);
}
const dist = path.join('node_modules', '@sf-agentscript', 'lsp-server', 'dist');
fs.mkdirSync(dist, { recursive: true });
fs.copyFileSync(
  path.join(__dirname, mode === 'crash' ? 'stub_server_crash.js' : 'stub_server_ok.js'),
  path.join(dist, 'index.js')
);
