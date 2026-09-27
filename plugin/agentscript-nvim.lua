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

vim.api.nvim_create_user_command('AgentScriptValidate', function(args)
  require('agentscript-nvim.sf').validate(args.args ~= '' and args.args or nil)
end, {
  nargs = '?',
  desc = 'Compile the current authoring bundle (or [name]) on the org and show its errors',
})

vim.api.nvim_create_user_command('AgentScriptPreview', function(args)
  require('agentscript-nvim.sf').preview(args.args ~= '' and args.args or nil, args.bang)
end, {
  nargs = '?',
  bang = true,
  desc = 'Chat with the current authoring bundle (or [name]) in a preview session; ! uses live actions',
})

-- Auto-setup with defaults; call require('agentscript-nvim').setup({...}) from
-- your config to override (setup is idempotent and re-applies options).
if vim.g.agentscript_nvim_no_auto_setup ~= 1 then
  require('agentscript-nvim').setup()
end
