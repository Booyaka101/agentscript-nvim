-- Headless end-to-end test for agentscript-nvim.
-- Run from the repo root:  nvim -l tests/test_lsp.lua
--
-- Asserts:
--  1. *.agent files get the `agentscript` filetype (and the fallback syntax loads)
--  2. the agentscript LSP client attaches (the :LspInfo acceptance check)
--  3. the broken fixture yields >= 1 diagnostic via vim.diagnostic.get
--  4. the valid fixture yields 0 ERROR-severity diagnostics

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))

local failures = 0
local function check(ok, label, detail)
  if ok then
    print(('PASS  %s'):format(label))
  else
    failures = failures + 1
    print(('FAIL  %s%s'):format(label, detail and (' — ' .. detail) or ''))
  end
end

vim.opt.runtimepath:prepend(root)
-- `nvim -l` skips the normal startup sequence; enable detection explicitly.
vim.cmd('filetype plugin on')
vim.cmd('syntax enable')

-- Find a working server: prefer the plugin's managed install, fall back to the
-- repo-local scratch install, and create the scratch install if neither exists.
local install = require('agentscript-nvim.install')
local server_js = install.server_js()
if not server_js then
  local scratch = vim.fs.joinpath(root, 'scratch')
  local p = vim.fs.joinpath(scratch, 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
  if not vim.uv.fs_stat(p) then
    print('installing server into scratch/ (first run) ...')
    local npm = vim.fn.has('win32') == 1 and { 'cmd.exe', '/c', 'npm', 'install', '--no-audit', '--no-fund' }
      or { 'npm', 'install', '--no-audit', '--no-fund' }
    local res = vim.system(npm, { cwd = scratch }):wait()
    assert(res.code == 0, 'npm install failed: ' .. (res.stderr or ''))
  end
  server_js = p
end
print('server: ' .. server_js)

require('agentscript-nvim').setup({
  cmd = { 'node', server_js, '--stdio' },
})

-- 1 + 3: broken fixture ---------------------------------------------------
vim.cmd.edit(vim.fs.joinpath(root, 'tests', 'fixtures', 'broken.agent'))
local broken_buf = vim.api.nvim_get_current_buf()
check(
  vim.bo[broken_buf].filetype == 'agentscript',
  'filetype detected as agentscript',
  'got ' .. vim.bo[broken_buf].filetype
)
-- With a built tree-sitter parser, vim.treesitter.start() supersedes the
-- regex syntax (b:current_syntax stays unset by design); otherwise the
-- fallback syntax file must be active.
if require('agentscript-nvim.treesitter').available() then
  check(
    vim.treesitter.highlighter.active[broken_buf] ~= nil,
    'tree-sitter highlighting active (supersedes fallback syntax)'
  )
else
  check(
    vim.b[broken_buf].current_syntax == 'agentscript',
    'fallback syntax loaded',
    'b:current_syntax=' .. tostring(vim.b[broken_buf].current_syntax)
  )
  local syn_group = vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name')
  check(syn_group == 'agentscriptBlock', 'keyword "config" highlighted', 'group=' .. tostring(syn_group))
end

-- filetype rules beyond *.agent
check(vim.filetype.match({ filename = 'foo.ascript' }) == 'agentscript', '*.ascript maps to agentscript')
local hdr_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(hdr_buf, vim.fs.joinpath(root, 'tests', 'noext_dialect_file'))
vim.api.nvim_buf_set_lines(hdr_buf, 0, -1, false, { '# @dialect: agentforce', 'config:' })
check(vim.filetype.match({ buf = hdr_buf }) == 'agentscript', 'extensionless "# @dialect:" header detected')

local attached = vim.wait(30000, function()
  return #vim.lsp.get_clients({ name = 'agentscript', bufnr = broken_buf }) > 0
end, 100)
check(attached, 'agentscript LSP client attached (LspInfo equivalent)')

local got_diags = vim.wait(30000, function()
  return #vim.diagnostic.get(broken_buf) > 0
end, 100)
local diags = vim.diagnostic.get(broken_buf)
check(got_diags and #diags >= 1, 'broken.agent produced diagnostics', 'count=' .. #diags)
for _, d in ipairs(diags) do
  print(('      L%d [%s] %s'):format(d.lnum + 1, vim.diagnostic.severity[d.severity], d.message))
end

-- 4: valid fixture ---------------------------------------------------------
vim.cmd.edit(vim.fs.joinpath(root, 'tests', 'fixtures', 'sample.agent'))
local sample_buf = vim.api.nvim_get_current_buf()
vim.wait(30000, function()
  return #vim.lsp.get_clients({ name = 'agentscript', bufnr = sample_buf }) > 0
end, 100)
-- Give the server a moment to publish (it pushes diagnostics on open).
vim.wait(5000, function()
  return #vim.diagnostic.get(sample_buf) > 0
end, 100)
local errors = vim.diagnostic.get(sample_buf, { severity = vim.diagnostic.severity.ERROR })
check(#errors == 0, 'sample.agent has no ERROR diagnostics', 'errors=' .. #errors)
for _, d in ipairs(vim.diagnostic.get(sample_buf)) do
  print(('      L%d [%s] %s'):format(d.lnum + 1, vim.diagnostic.severity[d.severity], d.message))
end

-- :checkhealth agentscript-nvim runs without error and reports a server
local health_ok = pcall(vim.cmd, 'checkhealth agentscript-nvim')
local health_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(
  health_ok and health_lines:match('agentscript%-nvim') and health_lines:match('server:') ~= nil,
  'checkhealth agentscript-nvim reports a server'
)

-- tree-sitter section (builds the parser if a compiler is available; the
-- shared file returns its own failure count in suite mode)
_G.__AGENTSCRIPT_SUITE = true
local ts_ok, ts_failures = pcall(dofile, vim.fs.joinpath(root, 'tests', 'test_treesitter.lua'))
if ts_ok then
  failures = failures + (tonumber(ts_failures) or 0)
else
  failures = failures + 1
  print('FAIL  tree-sitter section errored — ' .. tostring(ts_failures))
end

print(failures == 0 and 'ALL TESTS PASSED' or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
