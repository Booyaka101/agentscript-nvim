if vim.g.loaded_agentscript_nvim then
  return
end
vim.g.loaded_agentscript_nvim = true

vim.api.nvim_create_user_command('AgentScriptInstall', function()
  require('agentscript-nvim.install').install()
end, { desc = 'Install a version-verified @sf-agentscript/lsp-server into stdpath("data")' })

vim.api.nvim_create_user_command('AgentScriptTSBuild', function(args)
  require('agentscript-nvim.treesitter').install(
    nil,
    { version = args.args ~= '' and args.args or nil, force = args.bang }
  )
end, {
  nargs = '?',
  bang = true,
  desc = 'Build + verify the published AgentScript tree-sitter grammar (or [version]) into stdpath("data")',
})

-- Auto-setup with defaults; call require('agentscript-nvim').setup({...}) from
-- your config to override (setup is idempotent and re-applies options).
if vim.g.agentscript_nvim_no_auto_setup ~= 1 then
  require('agentscript-nvim').setup()
end
