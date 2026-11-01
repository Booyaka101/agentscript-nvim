-- Child process used by test_upgrades.lua; must not touch npm or the active pointer.
vim.opt.runtimepath:prepend(arg[1])
local install = require('agentscript-nvim.install')
install.dir = function()
  return arg[2]
end
install.resolve_latest = function()
  error('lock did not prevent registry lookup')
end
local called = false
install.install(function(ok, msg)
  assert(not ok and msg:find('install/rollback unavailable', 1, true), msg)
  called = true
end)
assert(called, 'busy lock must return immediately')
