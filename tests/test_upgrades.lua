-- No network or user data: real npm/server stubs against an isolated install.
-- Run: nvim -l tests/test_upgrades.lua
local root = vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p:h:h'))
vim.opt.runtimepath:prepend(root)
local install = require('agentscript-nvim.install')
local tmp = vim.fn.tempname()
local failures = 0
local function check(ok, label)
  print((ok and 'PASS  ' or 'FAIL  ') .. label)
  if not ok then
    failures = failures + 1
  end
end
install.dir = function()
  return tmp
end
local version, behavior = '9.9.1', '9.9.1=ok'
install.resolve_latest = function(done)
  vim.schedule(function()
    done(version)
  end)
end
install.npm_install_cmd = function()
  return { 'node', vim.fs.joinpath(root, 'tests', 'fake_npm.js'), behavior }
end
local function run(action)
  local done, result, message = false, nil, nil
  action(function(ok, msg)
    done, result, message = true, ok, msg
  end)
  assert(
    vim.wait(15000, function()
      return done
    end, 10),
    'test action timed out'
  )
  return result, message
end
local function verify(js)
  return run(function(done)
    install.verify(js, done)
  end)
end
local function snapshot()
  return install.read_file(vim.fs.joinpath(tmp, 'active.json')), install.server_js()
end
local function unchanged(pointer, js, label)
  local now, cmd = snapshot()
  check(now == pointer and cmd == js and verify(js), label)
  check(not vim.uv.fs_stat(vim.fs.joinpath(tmp, 'install.lock')), label .. ': lock released')
end

local ok = run(install.install)
check(ok and install.state().version == version, 'initial install is verified')
local first_pointer, first_js = snapshot()
check(first_js:find('versions', 1, true) ~= nil, 'server resolves to immutable generation')

for _, mode in ipairs({ 'crash', 'download-fail', 'missing', 'hang' }) do
  version, behavior = '9.9.2', '9.9.2=' .. mode
  local saved_timeout = install.INSTALL_TIMEOUT_MS
  install.INSTALL_TIMEOUT_MS = 300
  local accepted, message = run(install.install)
  install.INSTALL_TIMEOUT_MS = saved_timeout
  check(not accepted and message:find('previous version retained', 1, true), mode .. ': upgrade rejected')
  unchanged(first_pointer, first_js, mode .. ': previous server still initializes')
  local state = install.state()
  check(
    state.verified and state.version == '9.9.1' and state.rejected,
    mode .. ': health retains active version and rejection'
  )
end

version = nil
ok = run(install.install)
check(not ok, 'offline upgrade does not silently install historical pin')
unchanged(first_pointer, first_js, 'offline: active server untouched')

-- Hold resolution open: a second command cannot write or launch npm.
local resolve = install.resolve_latest
local pending
install.resolve_latest = function(done)
  pending = done
end
local completed = false
install.install(function()
  completed = true
end)
local busy, busy_message = run(install.install)
check(not busy and busy_message:find('install/rollback unavailable', 1, true), 'overlapping install rejected')
local rollback_busy = run(install.rollback)
check(not rollback_busy, 'rollback shares install lock')
check(not completed, 'first operation still owns lock')
pending(nil)
check(completed, 'first operation releases its own lock')
install.resolve_latest = resolve

-- A different Neovim process sees the same filesystem lock.
local fd = assert(vim.uv.fs_open(vim.fs.joinpath(tmp, 'install.lock'), 'wx', 384))
vim.uv.fs_close(fd)
local child = vim
  .system({
    vim.v.progpath,
    '--headless',
    '-u',
    'NONE',
    '-n',
    '-l',
    vim.fs.joinpath(root, 'tests', 'test_upgrade_lock.lua'),
    root,
    tmp,
  }, { text = true })
  :wait(10000)
check(child.code == 0, 'cross-process install lock rejects second Neovim')
vim.uv.fs_unlink(vim.fs.joinpath(tmp, 'install.lock'))

-- A filesystem activation failure cannot retire the existing command.
version, behavior = '9.9.2', '9.9.2=ok'
local write_json = install.write_json
install.write_json = function(path, value)
  if path == vim.fs.joinpath(tmp, 'active.json') then
    return nil, 'simulated disk failure'
  end
  return write_json(path, value)
end
ok = run(install.install)
install.write_json = write_json
check(not ok, 'failed pointer write rejects upgrade')
unchanged(first_pointer, first_js, 'failed activation: old pointer and server preserved')

install.write_json = function(path, value)
  if path:match('agentscript%-nvim%-state%.json$') then
    return nil, 'simulated state write failure'
  end
  return write_json(path, value)
end
ok = run(install.install)
install.write_json = write_json
check(not ok, 'failed generation state write rejects upgrade')
unchanged(first_pointer, first_js, 'failed state write: old pointer and server preserved')

local health_messages = {}
local health, sf = vim.health, package.loaded['agentscript-nvim.sf']
vim.health = setmetatable({}, {
  __index = function()
    return function(message)
      table.insert(health_messages, message)
    end
  end,
})
package.loaded['agentscript-nvim.sf'] = {
  exe = function()
    return nil
  end,
  INSTALL_DOC = 'test',
}
require('agentscript-nvim.health').check()
vim.health, package.loaded['agentscript-nvim.sf'] = health, sf
check(
  table.concat(health_messages, '\n'):find('server upgrade rejected; previous version retained', 1, true),
  'checkhealth reports rejected upgrade separately from active verification'
)

local plugin = require('agentscript-nvim')
plugin.opts.cmd = { 'node', 'user-command.js' }
ok = run(install.install)
check(ok and install.state().version == '9.9.2', 'successful upgrade activates new version')
check(vim.lsp.config.agentscript.cmd[2] == 'user-command.js', 'explicit cmd override survives install')
plugin.opts.cmd = nil
local second_pointer, second_js = snapshot()
check(first_js ~= second_js and verify(first_js), 'successful upgrade keeps old generation usable by existing clients')
check(not install.state().rejected, 'successful install clears rejected-upgrade health status')

ok = run(install.rollback)
check(ok and install.server_js() == first_js, 'rollback verifies and restores previous generation')
ok = run(install.rollback)
check(ok and install.server_js() == second_js, 'rollback retains the replaced version for switching back')

install.write_json = function(path, value)
  if path == vim.fs.joinpath(tmp, 'active.json') then
    return nil, 'simulated rollback disk failure'
  end
  return write_json(path, value)
end
ok = run(install.rollback)
install.write_json = write_json
check(not ok, 'rollback pointer failure is reported')
unchanged(second_pointer, second_js, 'failed rollback activation: current version untouched')

-- Corrupting only the rollback candidate must not switch the active pointer.
assert(install.write_file(first_js, install.read_file(vim.fs.joinpath(root, 'tests', 'stub_server_crash.js'))))
ok = run(install.rollback)
check(not ok, 'broken rollback candidate rejected')
unchanged(second_pointer, second_js, 'failed rollback: current server still initializes')

-- Existing pre-generation installs work unchanged and remain rollback targets.
local legacy = tmp .. '-legacy'
install.dir = function()
  return legacy
end
local legacy_js = vim.fs.joinpath(legacy, 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
vim.fn.mkdir(vim.fs.dirname(legacy_js), 'p')
assert(install.write_file(legacy_js, install.read_file(vim.fs.joinpath(root, 'tests', 'stub_server_ok.js'))))
assert(
  install.write_json(
    vim.fs.joinpath(legacy, 'agentscript-nvim-state.json'),
    { version = '8.0.0', verified = true, path = 'current' }
  )
)
check(install.server_js() == legacy_js, 'legacy managed server still resolves')
ok = run(install.install)
check(ok and install.active().previous == '.', 'legacy upgrade records previous install without moving its files')
ok = run(install.rollback)
check(ok and install.server_js() == legacy_js and install.state().version == '8.0.0', 'legacy rollback succeeds')

vim.fn.delete(tmp, 'rf')
vim.fn.delete(legacy, 'rf')
print(failures == 0 and 'UPGRADE TESTS PASSED' or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
