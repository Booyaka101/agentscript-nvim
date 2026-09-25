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
      'npx runs whatever @sf-agentscript/lsp-server is currently published, unverified',
      'run :AgentScriptInstall for a version-verified local install (historical startup-crash background: salesforce/agentscript#73)',
    })
  else
    health.ok(msg)
  end

  local install = require('agentscript-nvim.install')
  local state = install.state()
  if state then
    local line = ('managed install: %s via %s path — %s (%s)'):format(
      tostring(state.version),
      tostring(state.path),
      state.verified and 'verification passed' or 'verification FAILED',
      tostring(state.reason)
    )
    if state.verified then
      health.ok(line)
    else
      health.warn(line, { 'run :AgentScriptInstall to retry' })
    end
  else
    health.info('managed install: never run (:AgentScriptInstall installs a version-verified server)')
  end

  local ts = require('agentscript-nvim.treesitter')
  if ts.available() then
    local st = ts.state()
    if not st then
      health.warn('tree-sitter grammar: version unknown (built before agentscript-nvim 0.3.0): ' .. ts.parser_path(), {
        'run :AgentScriptTSBuild to build and verify the currently published grammar',
      })
    else
      local line = ('tree-sitter grammar: %s via %s path, %s (%s)'):format(
        tostring(st.version),
        tostring(st.path),
        st.verified and 'verification passed' or 'verification FAILED',
        tostring(st.reason)
      )
      if st.path == 'fallback' or st.path == 'pinned-offline' or not st.verified then
        health.warn(line, {
          'the pinned ' .. ts.PIN .. ' cannot parse 3.x syntax such as `escalate`',
          'run :AgentScriptTSBuild to retry the published grammar',
        })
      else
        health.ok(line)
        if st.path == 'requested' then
          health.info(
            'pinned by :AgentScriptTSBuild ' .. st.version .. '; run it with no argument to track the published grammar'
          )
        end
      end
      if type(st.rejected) == 'table' then
        health.warn(
          ('tree-sitter grammar: published %s failed to build or verify (%s): %s'):format(
            tostring(st.rejected.version),
            tostring(st.rejected.at),
            tostring(st.rejected.reason)
          ),
          { 'kept ' .. st.version .. '; run :AgentScriptTSBuild to retry' }
        )
      end
    end
  else
    health.info('tree-sitter parser not built (using fallback regex syntax)', {
      'run :AgentScriptTSBuild (needs npm, tar and a C compiler: cc/gcc/clang/zig)',
    })
  end
end

return M
