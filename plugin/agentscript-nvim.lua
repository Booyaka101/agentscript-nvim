if vim.g.loaded_agentscript_nvim then
  return
end
vim.g.loaded_agentscript_nvim = true

vim.api.nvim_create_user_command('AgentScriptInstall', function()
  require('agentscript-nvim.install').install()
end, { desc = 'Install a patched @sf-agentscript/lsp-server into stdpath("data")' })

vim.api.nvim_create_user_command('AgentScriptTSBuild', function()
  local ok, err = pcall(require('agentscript-nvim.treesitter').build)
  if ok then
    vim.notify('agentscript-nvim: tree-sitter parser built. Reopen your .agent buffer.', vim.log.levels.INFO)
  else
    vim.notify('agentscript-nvim: tree-sitter build failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end, { desc = 'Build + install the official AgentScript tree-sitter parser and queries' })

-- Auto-setup with defaults; call require('agentscript-nvim').setup({...}) from
-- your config to override (setup is idempotent and re-applies options).
if vim.g.agentscript_nvim_no_auto_setup ~= 1 then
  require('agentscript-nvim').setup()
end
