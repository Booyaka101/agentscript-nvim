-- Headless test for the managed server install (:AgentScriptInstall path).
-- Run from the repo root:  nvim -l tests/test_install.lua
-- Installs the patched server into stdpath('data') and checks that cmd
-- resolution then prefers it.

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))
vim.opt.runtimepath:prepend(root)

local install = require('agentscript-nvim.install')

local done, ok_r, msg_r = false, nil, nil
install.install(function(ok, msg)
  done, ok_r, msg_r = true, ok, msg
end)
local finished = vim.wait(180000, function()
  return done
end, 200)

print(('install finished=%s ok=%s: %s'):format(tostring(finished), tostring(ok_r), tostring(msg_r)))
assert(finished and ok_r, 'managed install failed')
assert(install.server_js(), 'server_js missing after install')

local cmd, source = require('agentscript-nvim').resolve_cmd({})
print(('resolve_cmd source=%s cmd=%s'):format(source, table.concat(cmd or {}, ' ')))
assert(source == 'managed', 'expected managed install to win resolution, got ' .. source)

print('INSTALL TEST PASSED  (dir: ' .. install.dir() .. ')')
os.exit(0)
