-- Managed install of the AgentScript language server.
--
-- As of 2026-07-22 the published `@sf-agentscript/lsp-server@2.2.30` crashes at
-- import time ("variantMatch is not a function"): `@sf-agentscript/agentforce-dialect@2.13.4`
-- was built against a newer `@sf-agentscript/language` than the 2.5.4 it pins
-- (2.8.4 shipped one day after it). A plain `npx @sf-agentscript/lsp-server`
-- therefore fails. This module installs the server into Neovim's data dir with
-- an npm `overrides` pin that is verified to work.

local M = {}

M.PINS = {
  lsp_server = '2.2.30',
  language_override = '2.8.4',
}

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agentscript-nvim', 'server')
end

function M.server_js()
  local p = vim.fs.joinpath(M.dir(), 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
  if vim.uv.fs_stat(p) then
    return p
  end
end

--- Returns the LSP cmd for the managed install, or nil if not installed.
function M.cmd()
  local js = M.server_js()
  if js and vim.fn.executable('node') == 1 then
    return { 'node', js, '--stdio' }
  end
end

local function npm_install_cmd()
  local cmd = { 'npm', 'install', '--no-audit', '--no-fund', '--loglevel=error' }
  if vim.fn.has('win32') == 1 then
    -- npm is a .cmd shim on Windows; spawn through cmd.exe to be safe.
    return vim.list_extend({ 'cmd.exe', '/c' }, cmd)
  end
  return cmd
end

--- Install (or update) the patched server. Calls on_done(ok, msg) when finished.
---@param on_done? fun(ok: boolean, msg: string)
function M.install(on_done)
  on_done = on_done
    or function(ok, msg)
      vim.notify('agentscript-nvim: ' .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
  if vim.fn.executable('npm') == 0 or vim.fn.executable('node') == 0 then
    on_done(false, 'node/npm not found on PATH; install Node.js first')
    return
  end
  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')
  local manifest = vim.json.encode({
    name = 'agentscript-nvim-server',
    private = true,
    dependencies = { ['@sf-agentscript/lsp-server'] = M.PINS.lsp_server },
    overrides = { ['@sf-agentscript/language'] = M.PINS.language_override },
  })
  local f = assert(io.open(vim.fs.joinpath(dir, 'package.json'), 'w'))
  f:write(manifest)
  f:close()
  vim.notify(
    'agentscript-nvim: installing @sf-agentscript/lsp-server@' .. M.PINS.lsp_server .. ' ...',
    vim.log.levels.INFO
  )
  vim.system(npm_install_cmd(), { cwd = dir }, function(res)
    vim.schedule(function()
      if res.code == 0 and M.server_js() then
        -- Point the active config at the fresh install for new buffers.
        vim.lsp.config('agentscript', { cmd = M.cmd() })
        on_done(true, 'server installed. Reopen your .agent buffer (or :LspRestart) to attach.')
      else
        on_done(false, 'npm install failed (exit ' .. tostring(res.code) .. '): ' .. (res.stderr or ''))
      end
    end)
  end)
end

return M
