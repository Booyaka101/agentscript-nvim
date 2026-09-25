-- Headless test for the managed server install (:AgentScriptInstall path).
-- Run from the repo root:  nvim -l tests/test_install.lua
--
-- Part 1 (no network): stubbed resolve/npm/server exercising every install
-- path — current adopted, fallback adopted, pinned-offline, both-fail — plus
-- M.verify against the crash and hang stubs, checking the state file each
-- time. Part 2 (network): the real install into stdpath('data') and that cmd
-- resolution then prefers it.

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))
vim.opt.runtimepath:prepend(root)

local install = require('agentscript-nvim.install')

local failures = 0
local function check(ok, label, detail)
  if ok then
    print(('PASS  %s'):format(label))
  else
    failures = failures + 1
    print(('FAIL  %s%s'):format(label, detail and (' — ' .. detail) or ''))
  end
end

local function run_install()
  local done, ok_r, msg_r = false, nil, nil
  install.install(function(ok, msg)
    done, ok_r, msg_r = true, ok, msg
  end)
  local finished = vim.wait(120000, function()
    return done
  end, 100)
  return finished, ok_r, msg_r
end

-- Part 1: stubbed install paths (no network) -------------------------------

local real_dir, real_npm, real_resolve = install.dir, install.npm_install_cmd, install.resolve_latest
local tmp_root = vim.fs.joinpath(root, 'tests', 'tmp-install')
vim.fn.delete(tmp_root, 'rf')
local pinned = install.PINS.lsp_server

local function use_stub(case, behavior_map, latest)
  install.dir = function()
    return vim.fs.joinpath(tmp_root, case)
  end
  install.npm_install_cmd = function()
    return { 'node', vim.fs.joinpath(root, 'tests', 'fake_npm.js'), behavior_map }
  end
  install.resolve_latest = function(on_done)
    vim.schedule(function()
      on_done(latest)
    end)
  end
end

-- (a) latest verifies and is adopted
use_stub('current', '9.9.9=ok', '9.9.9')
local finished, ok_r, msg_r = run_install()
print('  -> ' .. tostring(msg_r))
check(finished and ok_r, 'current: install succeeds')
check(tostring(msg_r):match('9%.9%.9 verified') ~= nil, 'current: message names the verified version', msg_r)
local st = install.state()
check(
  st and st.version == '9.9.9' and st.path == 'current' and st.verified == true and st.installedAt ~= nil,
  'current: state file records current/verified',
  vim.inspect(st)
)

-- (b) latest fails verification -> fallback recipe is adopted
use_stub('fallback', '9.9.9=crash,' .. pinned .. '=ok', '9.9.9')
finished, ok_r, msg_r = run_install()
print('  -> ' .. tostring(msg_r))
check(finished and ok_r, 'fallback: install succeeds via fallback')
check(tostring(msg_r):match('fallback') ~= nil, 'fallback: message names the fallback path', msg_r)
st = install.state()
check(
  st and st.version == pinned and st.path == 'fallback' and st.verified == true,
  'fallback: state file records fallback/verified',
  vim.inspect(st)
)

-- (c) npm view unavailable -> pinned-offline
use_stub('offline', pinned .. '=ok', nil)
finished, ok_r, msg_r = run_install()
print('  -> ' .. tostring(msg_r))
check(finished and ok_r, 'pinned-offline: install succeeds without the registry')
st = install.state()
check(
  st and st.version == pinned and st.path == 'pinned-offline' and st.verified == true,
  'pinned-offline: state file records pinned-offline/verified',
  vim.inspect(st)
)

-- (d) both attempts fail -> reported as failure, never a silent success
use_stub('bothfail', '9.9.9=crash,' .. pinned .. '=crash', '9.9.9')
finished, ok_r, msg_r = run_install()
print('  -> ' .. tostring(msg_r))
check(finished and ok_r == false, 'both-fail: install reports failure')
check(tostring(msg_r):match('variantMatch') ~= nil, 'both-fail: message carries the server stderr detail', msg_r)
st = install.state()
check(st and st.verified == false, 'both-fail: state file records verified=false', vim.inspect(st))

-- M.verify directly: crash stub surfaces the stderr error line
local vdone, vok, vdetail = false, nil, nil
install.verify(vim.fs.joinpath(root, 'tests', 'stub_server_crash.js'), function(ok, detail)
  vdone, vok, vdetail = true, ok, detail
end)
vim.wait(30000, function()
  return vdone
end, 50)
check(
  vdone and vok == false and tostring(vdetail):match('variantMatch is not a function') ~= nil,
  'verify: crash stub yields the stderr error line',
  tostring(vdetail)
)

-- M.verify directly: hanging server hits the timeout (and gets killed)
vdone, vok, vdetail = false, nil, nil
install.verify(vim.fs.joinpath(root, 'tests', 'stub_server_hang.js'), function(ok, detail)
  vdone, vok, vdetail = true, ok, detail
end, 2000)
vim.wait(30000, function()
  return vdone
end, 50)
check(
  vdone and vok == false and tostring(vdetail):match('timed out') ~= nil,
  'verify: hanging server times out',
  tostring(vdetail)
)

-- The real resolve_latest against a fake npm on PATH. The timeout has to hold
-- on Windows too, where npm runs under cmd.exe.
local fakebin = vim.fs.joinpath(tmp_root, 'fakebin')
vim.fn.mkdir(fakebin, 'p')
local view_js = vim.fs.joinpath(fakebin, 'view.js')
local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
write(view_js, "const v = process.env.FAKE_VIEW; if (v === 'hang') setTimeout(() => {}, 60000); else console.log(v);\n")
local is_win = vim.fn.has('win32') == 1
if is_win then
  write(vim.fs.joinpath(fakebin, 'npm.cmd'), '@echo off\r\nnode "' .. view_js .. '" %*\r\n')
else
  write(vim.fs.joinpath(fakebin, 'npm'), '#!/bin/sh\nexec node "' .. view_js .. '" "$@"\n')
  vim.uv.fs_chmod(vim.fs.joinpath(fakebin, 'npm'), 493) -- 0755
end
local saved_path, saved_timeout = vim.env.PATH, install.RESOLVE_TIMEOUT_MS
vim.env.PATH = fakebin .. (is_win and ';' or ':') .. saved_path
local function resolve(view)
  vim.env.FAKE_VIEW = view
  local calls, got = 0, nil
  local t0 = vim.uv.hrtime()
  real_resolve(function(v)
    calls, got = calls + 1, v
  end)
  vim.wait(20000, function()
    return calls > 0
  end, 50)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  vim.wait(300, function()
    return calls > 1
  end, 50)
  return got, calls, ms
end
local got = resolve('"3.2.1"')
check(got == '3.2.1', 'resolve_latest: reads the version npm prints', tostring(got))
got = resolve('"<html>oops</html>"')
check(got == nil, 'resolve_latest: rejects output that is not a version', tostring(got))
install.RESOLVE_TIMEOUT_MS = 1500
local calls, ms
got, calls, ms = resolve('hang')
check(
  got == nil and calls == 1 and ms < 6000,
  'resolve_latest: a hanging npm times out once, on time',
  ('got=%s calls=%d after %dms'):format(tostring(got), calls, ms)
)
install.RESOLVE_TIMEOUT_MS, vim.env.PATH, vim.env.FAKE_VIEW = saved_timeout, saved_path, nil

install.dir, install.npm_install_cmd, install.resolve_latest = real_dir, real_npm, real_resolve
vim.fn.delete(tmp_root, 'rf')

-- Part 2: the real install (network) ---------------------------------------

finished, ok_r, msg_r = run_install()
print(('install finished=%s ok=%s: %s'):format(tostring(finished), tostring(ok_r), tostring(msg_r)))
check(finished and ok_r, 'real install succeeds')
check(install.server_js() ~= nil, 'server_js present after install')
st = install.state()
check(st and st.verified == true, 'real install state file records verified=true', vim.inspect(st))
print('  state: ' .. vim.inspect(st))

local cmd, source = require('agentscript-nvim').resolve_cmd({})
print(('resolve_cmd source=%s cmd=%s'):format(source, table.concat(cmd or {}, ' ')))
check(source == 'managed', 'managed install wins resolution', 'got ' .. tostring(source))

print(failures == 0 and ('INSTALL TEST PASSED  (dir: ' .. install.dir() .. ')') or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
