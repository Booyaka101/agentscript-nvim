-- Simulates the post-merge nvim-lspconfig world, on Windows, end to end:
--   * runtimepath contains ONLY the real nvim-lspconfig checkout
--     (scratch/nvim-lspconfig, with lsp/agentscript.lua copied in — the PR)
--   * `agentscript-lsp` is provided as an npm-style .cmd shim on PATH
--   * filetype is registered manually, exactly as the PR docstring instructs
--   * the DEFAULT cmd from the PR file must attach and publish diagnostics
--   * :LspInfo (nvim-lspconfig's command) must show the agentscript client
--
-- Run from the repo root:  nvim -l tests/test_upstream_config.lua

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))
local lspconfig_dir = vim.fs.joinpath(root, 'scratch', 'nvim-lspconfig')
assert(vim.uv.fs_stat(lspconfig_dir), 'clone nvim-lspconfig into scratch/ first')
assert(
  vim.uv.fs_stat(vim.fs.joinpath(lspconfig_dir, 'lsp', 'agentscript.lua')),
  'copy lsp/agentscript.lua into the clone first'
)

local failures = 0
local function check(ok, label, detail)
  if ok then
    print(('PASS  %s'):format(label))
  else
    failures = failures + 1
    print(('FAIL  %s%s'):format(label, detail and (' — ' .. detail) or ''))
  end
end

local server_js = vim.fs.joinpath(root, 'scratch', 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
assert(vim.uv.fs_stat(server_js), 'run tests/test_lsp.lua first to install the scratch server')

-- Fake npm global install: a .cmd shim (Windows) / shell script (unix) on PATH.
local bin = vim.fs.joinpath(root, 'scratch', 'bin')
vim.fn.mkdir(bin, 'p')
local is_win = vim.fn.has('win32') == 1
if is_win then
  local f = assert(io.open(vim.fs.joinpath(bin, 'agentscript-lsp.cmd'), 'w'))
  f:write('@echo off\r\nnode "' .. server_js:gsub('/', '\\') .. '" %*\r\n')
  f:close()
else
  local p = vim.fs.joinpath(bin, 'agentscript-lsp')
  local f = assert(io.open(p, 'w'))
  f:write('#!/bin/sh\nexec node "' .. server_js .. '" "$@"\n')
  f:close()
  vim.uv.fs_chmod(p, 493) -- 0755
end
vim.env.PATH = bin .. (is_win and ';' or ':') .. vim.env.PATH
check(vim.fn.executable('agentscript-lsp') == 1, 'agentscript-lsp shim found on PATH')

vim.opt.runtimepath:prepend(lspconfig_dir)
vim.cmd('filetype plugin on')
vim.cmd('runtime! plugin/lspconfig.lua') -- provides :LspInfo

-- Exactly what the PR docstring tells users to do:
vim.filetype.add({ extension = { agent = 'agentscript' } })
vim.lsp.enable('agentscript')

vim.cmd.edit(vim.fs.joinpath(root, 'tests', 'fixtures', 'broken.agent'))
local buf = vim.api.nvim_get_current_buf()
check(vim.bo[buf].filetype == 'agentscript', 'filetype via manual vim.filetype.add')

local attached = vim.wait(30000, function()
  return #vim.lsp.get_clients({ name = 'agentscript', bufnr = buf }) > 0
end, 100)
check(attached, 'DEFAULT PR cmd (bare `agentscript-lsp`) attached')

if not attached then
  -- Fallback probe: does it work with the exepath-resolved shim instead?
  vim.lsp.config('agentscript', { cmd = { vim.fn.exepath('agentscript-lsp'), '--stdio' } })
  vim.cmd.edit()
  local attached2 = vim.wait(30000, function()
    return #vim.lsp.get_clients({ name = 'agentscript', bufnr = vim.api.nvim_get_current_buf() }) > 0
  end, 100)
  check(attached2, 'exepath-resolved cmd attached (Windows .cmd shim caveat)')
  buf = vim.api.nvim_get_current_buf()
end

local got = vim.wait(30000, function()
  return #vim.diagnostic.get(buf) > 0
end, 100)
check(got, 'diagnostics published with upstream config', 'count=' .. #vim.diagnostic.get(buf))

-- :LspInfo is nvim-lspconfig's alias for `:checkhealth vim.lsp`; on Nvim 0.12+
-- lspconfig's plugin file defers to the core `:lsp` command and defines no
-- alias, so fall back to the aliased command directly.
local info_cmd = vim.fn.exists(':LspInfo') == 2 and 'LspInfo' or 'checkhealth vim.lsp'
local lspinfo_ok = pcall(vim.cmd, info_cmd)
local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(lspinfo_ok and lines:lower():match('agentscript') ~= nil, (':%s shows agentscript client'):format(info_cmd))

print(failures == 0 and 'UPSTREAM CONFIG TEST PASSED' or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
