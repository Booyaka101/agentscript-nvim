-- agentscript-nvim: filetype detection, fallback syntax and LSP wiring for
-- Salesforce Agent Script (.agent files). Requires Neovim 0.11+.

local M = {}

local install = require('agentscript-nvim.install')

M.opts = {
  -- Explicit LSP command override, e.g. { 'node', '/path/to/index.js', '--stdio' }.
  cmd = nil,
  -- Register `*.ascript` in addition to the official `*.agent`.
  extra_extensions = true,
  -- Notify (once) when no working server is found, with install instructions.
  install_hint = true,
}

local function register_filetypes(opts)
  local extension = { agent = 'agentscript' }
  if opts.extra_extensions then
    -- Not used by upstream (which only registers .agent); kept for compatibility.
    extension.ascript = 'agentscript'
  end
  vim.filetype.add({
    extension = extension,
    pattern = {
      -- Upstream's VS Code extension detects Agent Script by this first line.
      ['.*'] = {
        function(_, bufnr)
          local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
          if first and first:match('^#%s*@dialect:') then
            return 'agentscript'
          end
        end,
        { priority = -math.huge },
      },
    },
  })
end

--- Resolve the LSP command, in priority order:
--- 1. opts.cmd (explicit override)
--- 2. managed install from :AgentScriptInstall (patched against the upstream
---    dependency-pin bug, see install.lua)
--- 3. `agentscript-lsp` on PATH (global npm install)
--- 4. `npx --yes @sf-agentscript/lsp-server` (works only once upstream fixes
---    its published pins; kept as a self-healing fallback)
---@return string[]? cmd, string source
function M.resolve_cmd(opts)
  if opts.cmd then
    return opts.cmd, 'user'
  end
  local managed = install.cmd()
  if managed then
    return managed, 'managed'
  end
  if vim.fn.executable('agentscript-lsp') == 1 then
    local exe = 'agentscript-lsp'
    if vim.fn.has('win32') == 1 then
      -- npm global installs are .cmd shims; resolve the full path so uv can
      -- spawn them (same workaround as nvim-lspconfig#3704).
      exe = vim.fn.exepath(exe)
    end
    return { exe, '--stdio' }, 'path'
  end
  if vim.fn.executable('npx') == 1 then
    local cmd = { 'npx', '--yes', '@sf-agentscript/lsp-server', '--stdio' }
    if vim.fn.has('win32') == 1 then
      cmd = vim.list_extend({ 'cmd.exe', '/c' }, cmd)
    end
    return cmd, 'npx'
  end
  return nil, 'none'
end

local hinted = false
local function maybe_hint(source)
  if hinted or (source ~= 'npx' and source ~= 'none') then
    return
  end
  hinted = true
  vim.schedule(function()
    if source == 'none' then
      vim.notify(
        'agentscript-nvim: no language server found and node/npx is not on PATH. '
          .. 'Install Node.js, then run :AgentScriptInstall.',
        vim.log.levels.WARN
      )
    else
      vim.notify(
        'agentscript-nvim: agentscript-lsp not installed; falling back to npx. '
          .. 'Note: the published @sf-agentscript/lsp-server currently crashes due to an '
          .. 'upstream dependency pin — run :AgentScriptInstall for a patched local install.',
        vim.log.levels.WARN
      )
    end
  end)
end

function M.setup(opts)
  if vim.fn.has('nvim-0.11') == 0 then
    vim.notify('agentscript-nvim requires Neovim 0.11+', vim.log.levels.ERROR)
    return
  end
  opts = vim.tbl_deep_extend('force', M.opts, opts or {})
  M.opts = opts

  register_filetypes(opts)

  -- The base config ships as lsp/agentscript.lua on this plugin's runtimepath
  -- (same file as the nvim-lspconfig submission); only the cmd needs resolving.
  local cmd = M.resolve_cmd(opts)
  if cmd then
    vim.lsp.config('agentscript', { cmd = cmd })
  end
  vim.lsp.enable('agentscript')

  local treesitter = require('agentscript-nvim.treesitter')
  treesitter.register() -- no-op unless :AgentScriptTSBuild has been run

  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'agentscript',
    group = vim.api.nvim_create_augroup('agentscript-nvim-ft', { clear = true }),
    callback = function(ev)
      if treesitter.available() and treesitter.register() then
        pcall(vim.treesitter.start, ev.buf, 'agentscript')
      end
      if M.opts.install_hint then
        local _, src = M.resolve_cmd(M.opts)
        maybe_hint(src)
      end
    end,
  })
end

return M
