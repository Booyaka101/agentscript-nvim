// Test stub: reproduces the historic @sf-agentscript/lsp-server@2.2.30
// crash-on-import shape — a node-style uncaught TypeError on stderr, exit 1.
process.stderr.write(
  '/fake/node_modules/@sf-agentscript/lsp-server/dist/index.js:1\n' +
    'variantMatch(node)\n' +
    '^\n' +
    '\n' +
    'TypeError: variantMatch is not a function\n' +
    '    at Object.<anonymous> (/fake/node_modules/@sf-agentscript/lsp-server/dist/index.js:1:1)\n'
);
process.exit(1);
