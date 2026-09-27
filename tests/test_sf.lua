-- Headless test for :AgentScriptValidate and :AgentScriptPreview.
-- Run from the repo root:  nvim -l tests/test_sf.lua
--
-- A stub sf (tests/fake_sf.js) goes first on PATH, as a .cmd on Windows and a
-- shell script elsewhere. It replays output captured from a real org
-- (tests/fixtures/sf) and records the argv it was given, so every case here
-- checks both what the plugin sent and what it did with sf's answer.

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))
vim.opt.runtimepath:prepend(root)
vim.g.agentscript_nvim_no_auto_setup = 1
vim.cmd.runtime('plugin/agentscript-nvim.lua')
require('agentscript-nvim').setup()

local sf = require('agentscript-nvim.sf')
local opts = require('agentscript-nvim').opts

-- io.write, not print: after the <CR> keypresses print() drops newlines.
local failures = 0
local function check(ok, label, detail)
  if not ok then
    failures = failures + 1
  end
  io.write(('%s  %s%s\n'):format(ok and 'PASS' or 'FAIL', label, not ok and detail and (' — ' .. detail) or ''))
end

local notes = {}
vim.notify = function(msg, level)
  table.insert(notes, { msg = msg, level = level })
end
local function last_note()
  return (notes[#notes] or {}).msg or ''
end

local is_win = vim.fn.has('win32') == 1
local sep = is_win and ';' or ':'
local tmp = vim.fs.joinpath(root, 'tests', 'tmp-sf')
vim.fn.delete(tmp, 'rf')
vim.fn.mkdir(tmp, 'p')

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end
local function read(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

-- The stub sf. On Windows it mirrors npm's layout: a .cmd on PATH and a
-- node entry point under <rootPath>/bin, which the plugin runs directly.
local fake_js = vim.fs.joinpath(root, 'tests', 'fake_sf.js')
local fakebin = vim.fs.joinpath(tmp, 'bin')
local sfroot = vim.fs.joinpath(tmp, 'sfroot')
if is_win then
  write(vim.fs.joinpath(sfroot, 'bin', 'run.js'), ('require(%s);\n'):format(vim.json.encode(fake_js)))
  write(vim.fs.joinpath(fakebin, 'sf.cmd'), '@echo off\r\nnode "' .. fake_js .. '" %*\r\n')
else
  write(vim.fs.joinpath(fakebin, 'sf'), '#!/bin/sh\nexec node "' .. fake_js .. '" "$@"\n')
  vim.uv.fs_chmod(vim.fs.joinpath(fakebin, 'sf'), 493) -- 0755
end
local log = vim.fs.joinpath(tmp, 'argv.jsonl')
vim.env.FAKE_SF_LOG = log
vim.env.FAKE_SF_ROOT = sfroot
local real_path = vim.env.PATH

local function calls()
  local out = {}
  if vim.uv.fs_stat(log) then
    for line in read(log):gmatch('[^\n]+') do
      table.insert(out, vim.json.decode(line))
    end
  end
  return out
end
local function last_call()
  local c = calls()
  return c[#c] or { args = {} }
end

-- A copy of the captured project, so cases can rewrite the .agent file.
local project = vim.fs.joinpath(tmp, 'project')
local bundle_dir = vim.fs.joinpath(project, 'force-app', 'main', 'default', 'aiAuthoringBundles', 'Nvim_Probe')
local agent_file = vim.fs.joinpath(bundle_dir, 'Nvim_Probe.agent')
local fixture_project = vim.fs.joinpath(root, 'tests', 'fixtures', 'sf', 'project')
for name, type in vim.fs.dir(fixture_project, { depth = 10 }) do
  if type == 'file' then
    write(vim.fs.joinpath(project, name), read(vim.fs.joinpath(fixture_project, name)))
  end
end
local agent_text = read(agent_file)

local function same_path(a, b)
  a, b = vim.fs.normalize(a), vim.fs.normalize(b)
  return is_win and a:lower() == b:lower() or a == b
end

--- Run an ex command and wait until it has notified `n` more times.
local function run(cmd, n)
  local before = #notes
  vim.cmd(cmd)
  return vim.wait(15000, function()
    return #notes >= before + (n or 2)
  end, 20)
end

local function sf_diags()
  local d = vim.diagnostic.get(vim.fn.bufnr(agent_file), { namespace = sf.ns })
  table.sort(d, function(a, b)
    return a.lnum < b.lnum
  end)
  return d
end

local function edit(text)
  write(agent_file, text)
  vim.cmd('edit! ' .. vim.fn.fnameescape(agent_file))
end

-- sf missing: one error naming the install doc, nothing spawned ------------

local empty = vim.fs.joinpath(tmp, 'empty')
vim.fn.mkdir(empty, 'p')
vim.env.PATH = empty
edit(agent_text)
run('AgentScriptValidate', 1)
check(
  last_note():match('sf not found on PATH') and last_note():find(sf.INSTALL_DOC, 1, true),
  'sf missing: error names the install doc',
  last_note()
)
check(#calls() == 0, 'sf missing: nothing spawned')

vim.env.PATH = fakebin .. sep .. real_path

-- Not a bundle: one error saying what it looked for, nothing spawned -------

local loose = vim.fs.joinpath(project, 'loose', 'Loose.agent')
write(loose, agent_text)
vim.cmd('edit ' .. vim.fn.fnameescape(loose))
run('AgentScriptValidate', 1)
check(
  last_note():match('no %*%.bundle%-meta%.xml in ') and not last_note():find('\n'),
  'no bundle-meta.xml: one-line error saying what it looked for',
  last_note()
)
check(#calls() == 0, 'no bundle-meta.xml: nothing spawned')

-- Completion: bundles in the package directories, not the rest of the project

local bundles = vim.fs.dirname(bundle_dir)
write(vim.fs.joinpath(bundles, 'Another_Bot', 'Another_Bot.agent'), agent_text)
write(vim.fs.joinpath(project, 'unpackaged', 'aiAuthoringBundles', 'Hidden', 'Hidden.agent'), agent_text)
local names = vim.fn.getcompletion('AgentScriptValidate ', 'cmdline')
check(
  vim.deep_equal(names, { 'Another_Bot', 'Nvim_Probe' }),
  'completion: bundles in packageDirectories',
  vim.inspect(names)
)
names = vim.fn.getcompletion('AgentScriptPreview! Nv', 'cmdline')
check(vim.deep_equal(names, { 'Nvim_Probe' }), 'completion: filters by prefix', vim.inspect(names))
vim.fn.delete(vim.fs.joinpath(bundles, 'Another_Bot'), 'rf')

-- validate pass -------------------------------------------------------------

vim.env.FAKE_SF_MODE = 'pass'
edit(agent_text)
local buf = vim.api.nvim_get_current_buf()
vim.diagnostic.set(sf.ns, buf, { { lnum = 0, col = 0, message = 'stale', severity = vim.diagnostic.severity.ERROR } })
run('AgentScriptValidate')
check(last_note() == 'agentscript-nvim: validated Nvim_Probe', 'validate pass: notifies', last_note())
check(#sf_diags() == 0, 'validate pass: clears the namespace')
local c = last_call()
check(
  vim.deep_equal(c.args, { 'agent', 'validate', 'authoring-bundle', '--api-name', 'Nvim_Probe', '--json' }),
  'validate pass: argv',
  vim.inspect(c.args)
)
check(same_path(c.cwd, project), 'validate pass: runs from the sfdx project root', c.cwd)
if is_win then
  local all = calls()
  check(
    #all == 2 and all[1].args[1] == 'version',
    'windows: resolves sf once via `sf version --verbose`',
    vim.inspect(vim.tbl_map(function(e)
      return e.args[1]
    end, all))
  )
end

opts.target_org = 'agentscript-dev'
run('AgentScriptValidate Nvim_Probe')
c = last_call()
check(
  vim.deep_equal(c.args, {
    'agent',
    'validate',
    'authoring-bundle',
    '--api-name',
    'Nvim_Probe',
    '--json',
    '--target-org',
    'agentscript-dev',
  }),
  'explicit name + target_org: argv',
  vim.inspect(c.args)
)
opts.target_org = nil

-- validate fail: two errors as diagnostics and quickfix ---------------------

local function check_two_errors(label, with_ranges)
  local d = sf_diags()
  check(#d == 2, label .. ': two diagnostics', vim.inspect(d))
  if #d ~= 2 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(agent_file), 0, -1, false)
  check(
    d[1].lnum == 41 and d[1].col == 51 and d[2].lnum == 42 and d[2].col == 50,
    label .. ': positions',
    ('%d:%d %d:%d'):format(d[1].lnum, d[1].col, d[2].lnum, d[2].col)
  )
  check(
    d[1].message == "CompilationError: 'nowhere' is not defined in subagent"
      and d[2].message == "CompilationError: 'elsewhere' is not defined in subagent",
    label .. ': messages',
    d[1].message .. ' | ' .. d[2].message
  )
  check(
    d[1].severity == vim.diagnostic.severity.ERROR and d[1].source == 'sf agent validate',
    label .. ': severity and source'
  )
  if with_ranges then
    check(
      lines[42]:sub(d[1].col + 1, d[1].end_col) == '@subagent.nowhere'
        and lines[43]:sub(d[2].col + 1, d[2].end_col) == '@subagent.elsewhere',
      label .. ': ranges cover the bad references',
      lines[42]:sub(d[1].col + 1, d[1].end_col) .. ' | ' .. lines[43]:sub(d[2].col + 1, d[2].end_col)
    )
  end
end

vim.env.FAKE_SF_MODE = 'fail'
run('AgentScriptValidate')
check(last_note() == 'agentscript-nvim: Nvim_Probe: 2 errors', 'validate fail: notifies the count', last_note())
check_two_errors('validate fail', true)
local qf = vim.fn.getqflist({ title = 0, items = 0 })
check(
  qf.title == 'sf agent validate Nvim_Probe'
    and #qf.items == 2
    and qf.items[1].lnum == 42
    and qf.items[1].col == 52
    and qf.items[2].lnum == 43
    and qf.items[2].col == 51
    and qf.items[1].bufnr == vim.fn.bufnr(agent_file)
    and qf.items[1].text:match('nowhere'),
  'validate fail: quickfix list',
  vim.inspect(qf)
)

vim.env.FAKE_SF_MODE = 'pass'
run('AgentScriptValidate')
check(
  #sf_diags() == 0 and #vim.fn.getqflist() == 0,
  'validate pass after fail: clears diagnostics and its quickfix list'
)

vim.api.nvim_buf_set_lines(0, 0, 0, false, { '# unsaved' })
run('AgentScriptValidate', 3)
check(
  notes[#notes - 2].msg == 'agentscript-nvim: Nvim_Probe has unsaved changes; sf validates the file on disk'
    and notes[#notes - 2].level == vim.log.levels.WARN,
  'unsaved buffer: warns that sf reads the file on disk',
  notes[#notes - 2].msg
)
vim.cmd('edit!')

-- Fallback: no data.errors, positions from `[Ln X, Col Y]` ------------------

vim.env.FAKE_SF_MODE = 'fail-nodata'
run('AgentScriptValidate')
check_two_errors('fallback regex', false)

-- CRLF file: same columns ---------------------------------------------------

vim.env.FAKE_SF_MODE = 'fail'
edit((agent_text:gsub('\n', '\r\n')))
check(vim.bo.fileformat == 'dos', 'crlf: buffer reads as dos')
run('AgentScriptValidate')
check_two_errors('crlf', true)

-- Non-ASCII before the error: sf counts characters, diagnostics want bytes --

vim.env.FAKE_SF_MODE = 'unicode'
local unicode_line = '            go_to_escalatiön: @utils.transition to @subagent.nöwhere'
edit((agent_text:gsub('            go_to_escalation: @utils%.transition to @subagent%.nowhere', unicode_line)))
run('AgentScriptValidate')
local d = sf_diags()
local hit = vim.tbl_filter(function(x)
  return x.lnum == 41
end, d)[1]
check(
  #d == 4 and hit and hit.col == 26 and hit.end_col == #unicode_line,
  'unicode: character columns become byte columns',
  hit and ('col=%d end_col=%d #line=%d'):format(hit.col, hit.end_col, #unicode_line) or vim.inspect(d)
)
edit(agent_text)

-- No usable positions: sf's message as one line -----------------------------

vim.diagnostic.reset(sf.ns)
vim.env.FAKE_SF_MODE = 'noorg'
run('AgentScriptValidate')
check(
  last_note() == 'agentscript-nvim: No default environment found. Use -o or --target-org to specify an environment.',
  'no default org: shows NoDefaultEnvError message',
  last_note()
)
check(#sf_diags() == 0, 'no default org: no diagnostics')

vim.env.FAKE_SF_MODE = 'unknown'
run('AgentScriptValidate')
check(
  last_note():match('^agentscript%-nvim: Warning: agent frobnicate is not a sf command%.')
    and not last_note():find('[\n»]'),
  "plugin-agent missing: sf's unknown-command message on one line",
  last_note()
)

-- Timeout: reported once, on time, and the process is killed ----------------

vim.env.FAKE_SF_MODE = 'hang'
local saved = sf.VALIDATE_TIMEOUT_MS
sf.VALIDATE_TIMEOUT_MS = 1500
local t0 = vim.uv.hrtime()
run('AgentScriptValidate')
local ms = (vim.uv.hrtime() - t0) / 1e6
check(
  last_note():match('sf agent validate authoring%-bundle timed out after') and ms < 6000,
  'timeout: reported on time',
  ('%s after %dms'):format(last_note(), ms)
)
local pid = last_call().pid
local dead = vim.wait(10000, function()
  return not pcall(assert, vim.uv.kill(pid, 0))
end, 100)
check(dead, 'timeout: the hung sf is killed', 'pid ' .. tostring(pid))
sf.VALIDATE_TIMEOUT_MS = saved

-- Preview: start, three turns, end on wipeout -------------------------------

vim.env.FAKE_SF_MODE = 'pass'
local src_win = vim.api.nvim_get_current_win()
run('AgentScriptPreview', 1)
vim.wait(15000, function()
  return vim.bo.filetype == 'agentscript-preview'
end, 20)
local pbuf = vim.api.nvim_get_current_buf()
check(vim.bo.filetype == 'agentscript-preview', 'preview: opens the scratch split')
c = last_call()
check(
  vim.deep_equal(c.args, {
    'agent',
    'preview',
    'start',
    '--authoring-bundle',
    'Nvim_Probe',
    '--simulate-actions',
    '--json',
  }),
  'preview: start argv',
  vim.inspect(c.args)
)
local session = sf.sessions.Nvim_Probe
check(session and session.id == '4a9ba646-a103-4d73-8dc4-8efaa8fb1af3', 'preview: stores result.sessionId')

local n_calls = #calls()
vim.api.nvim_set_current_win(src_win)
vim.cmd('AgentScriptPreview')
check(
  vim.api.nvim_get_current_buf() == pbuf and #calls() == n_calls and #vim.fn.win_findbuf(pbuf) == 1,
  'preview: a second call focuses the existing split'
)

local turns = { 'Hi there', 'Can you say "hello"\non two lines?', 'I want to talk to a human' }
for i, text in ipairs(turns) do
  local lines = vim.split(text, '\n')
  lines[1] = '> ' .. lines[1]
  vim.api.nvim_buf_set_lines(pbuf, session.prompt_row, -1, false, lines)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  vim.wait(15000, function()
    return not session.busy
  end, 20)
  c = last_call()
  check(
    vim.deep_equal(c.args, {
      'agent',
      'preview',
      'send',
      '--authoring-bundle',
      'Nvim_Probe',
      '--session-id',
      session.id,
      '--utterance',
      text,
      '--json',
    }),
    ('preview: turn %d sends the prompt as one argv element'):format(i),
    vim.inspect(c.args)
  )
end
local transcript = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
local expected = {
  'user: Hi there',
  'agent: Hello! How can I assist you today?',
  'user: Can you say "hello"',
  'on two lines?',
  'agent: Hello!',
  'How can I help you with questions related to my capabilities?',
  'user: I want to talk to a human',
  'agent: I am connecting you to a human agent now. If you have any specific questions in the meantime, please let me know!',
  '> ',
}
check(
  vim.deep_equal(vim.list_slice(transcript, 2), expected),
  'preview: transcript, prompt last',
  table.concat(transcript, '\n')
)

run('bwipeout ' .. pbuf, 1)
c = last_call()
check(
  vim.deep_equal(c.args, {
    'agent',
    'preview',
    'end',
    '--authoring-bundle',
    'Nvim_Probe',
    '--session-id',
    '4a9ba646-a103-4d73-8dc4-8efaa8fb1af3',
    '--json',
  }),
  'preview: wipeout runs end',
  vim.inspect(c.args)
)
local ended = vim.json.decode(read(vim.fs.joinpath(root, 'tests', 'fixtures', 'sf', 'preview-end.json')))
check(
  last_note() == 'agentscript-nvim: ended preview of Nvim_Probe, traces in ' .. ended.result.tracesPath,
  'preview: prints the trace location',
  last_note()
)
check(sf.sessions.Nvim_Probe == nil, 'preview: session forgotten after end')

-- Bang, and VimLeavePre ending the session exactly once ---------------------

run('AgentScriptPreview!', 1)
vim.wait(15000, function()
  return vim.bo.filetype == 'agentscript-preview'
end, 20)
pbuf = vim.api.nvim_get_current_buf()
check(last_call().args[6] == '--use-live-actions', 'preview!: live actions', vim.inspect(last_call().args))

vim.env.FAKE_SF_MODE = 'expired'
session = sf.sessions.Nvim_Probe
vim.api.nvim_buf_set_lines(pbuf, session.prompt_row, -1, false, { '> still there?' })
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
vim.wait(15000, function()
  return not session.busy
end, 20)
local tail = vim.api.nvim_buf_get_lines(pbuf, -3, -1, false)
check(
  tail[1]
      == "error: Preview session '00000000-dead-beef-0000-000000000000' is invalid or has expired. " .. 'Start a new session with "sf agent preview start".'
    and tail[2] == '> ',
  "preview: a failed send shows sf's error in the transcript",
  table.concat(tail, '\n')
)
vim.env.FAKE_SF_MODE = 'pass'
local function ends()
  return #vim.tbl_filter(function(e)
    return e.args[3] == 'end'
  end, calls())
end
local ends_before = ends()
vim.api.nvim_exec_autocmds('VimLeavePre', {})
check(ends() == ends_before + 1, 'VimLeavePre: ends the session before returning')
vim.cmd('bwipeout ' .. pbuf)
vim.wait(1000)
check(ends() == ends_before + 1, 'VimLeavePre then wipeout: end runs once')

vim.env.FAKE_SF_MODE = 'noorg'
vim.cmd.edit(vim.fn.fnameescape(agent_file))
local wins = #vim.api.nvim_list_wins()
run('AgentScriptPreview')
check(
  last_note():match('No default environment found')
    and #vim.api.nvim_list_wins() == wins
    and sf.sessions.Nvim_Probe == nil,
  'preview start failure: error, no split, no session',
  last_note()
)

vim.env.PATH = real_path
vim.fn.delete(tmp, 'rf')
print(failures == 0 and 'SF TEST PASSED' or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
