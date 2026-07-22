-- :checkhealth agentscript-nvim

local M = {}

local SOURCE_LABEL = {
  user = 'user-configured cmd',
  managed = 'managed install (:AgentScriptInstall)',
  path = 'agentscript-lsp on PATH',
  npx = 'npx fallback',
}

function M.check()
  local health = vim.health
  health.start('agentscript-nvim')

  if vim.fn.has('nvim-0.11') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.11+ required')
  end

  for _, tool in ipairs({ 'node', 'npm', 'npx' }) do
    if vim.fn.executable(tool) == 1 then
      health.ok(tool .. ': ' .. vim.fn.exepath(tool))
    else
      health.warn(tool .. ' not found on PATH (needed for the language server)')
    end
  end

  local agentscript = require('agentscript-nvim')
  local cmd, source = agentscript.resolve_cmd(agentscript.opts)
  if not cmd then
    health.error('no language server available', { 'install Node.js, then run :AgentScriptInstall' })
    return
  end
  local msg = 'server: ' .. SOURCE_LABEL[source] .. ' -> ' .. table.concat(cmd, ' ')
  if source == 'npx' then
    health.warn(msg, {
      'the published @sf-agentscript/lsp-server currently crashes (upstream dependency-pin bug, salesforce/agentscript#71)',
      'run :AgentScriptInstall for a patched local install',
    })
  else
    health.ok(msg)
  end

  local ts = require('agentscript-nvim.treesitter')
  if ts.available() then
    health.ok('tree-sitter parser installed: ' .. ts.parser_path())
  else
    health.info('tree-sitter parser not built (using fallback regex syntax)', {
      'run :AgentScriptTSBuild (needs npm, tar and a C compiler: cc/gcc/clang/zig)',
    })
  end
end

return M
