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
local fixture_project = vim.fs.joinpath(root, 'tests', 'fixtures', 'sf', 'project')
local function copy_project(to)
  for name, type in vim.fs.dir(fixture_project, { depth = 10 }) do
    if type == 'file' then
      write(vim.fs.joinpath(to, name), read(vim.fs.joinpath(fixture_project, name)))
    end
  end
end
local project = vim.fs.joinpath(tmp, 'project')
local bundle_dir = vim.fs.joinpath(project, 'force-app', 'main', 'default', 'aiAuthoringBundles', 'Nvim_Probe')
local agent_file = vim.fs.joinpath(bundle_dir, 'Nvim_Probe.agent')
copy_project(project)
local agent_text = read(agent_file)

local function same_path(a, b)
  a, b = vim.fs.normalize(a), vim.fs.normalize(b)
  return is_win and a:lower() == b:lower() or a == b
end

--- Run an ex command and wait until it has notified `n` more times.
local function run(cmd, n)
  local before = #notes
  vim.cmd(cmd)
  local ok = vim.wait(15000, function()
    return #notes >= before + (n or 2)
  end, 20)
  if not ok then
    check(false, ':' .. cmd .. ' notified ' .. (n or 2) .. ' times', vim.inspect(vim.list_slice(notes, before + 1)))
  end
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
  last_note():match('not an authoring bundle: no .*[/\\]loose%.bundle%-meta%.xml$') and not last_note():find('\n'),
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

vim.env.FAKE_SF_MODE = 'noisy'
run('AgentScriptValidate')
check(last_note() == 'agentscript-nvim: validated Nvim_Probe', 'json after a line of other output', last_note())

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
local nr = vim.fn.getqflist({ nr = '$' }).nr
run('AgentScriptValidate')
check(
  vim.fn.getqflist({ nr = '$' }).nr == nr and #vim.fn.getqflist() == 2,
  'validate fail again: replaces its quickfix list instead of stacking another'
)

vim.env.FAKE_SF_MODE = 'pass'
run('AgentScriptValidate')
check(
  #sf_diags() == 0 and #vim.fn.getqflist() == 0,
  'validate pass after fail: clears diagnostics and its quickfix list'
)

-- Two validates in flight: the later one wins even if it returns first
vim.env.FAKE_SF_MODE = 'fail'
vim.env.FAKE_SF_DELAY = '1500'
local n_before = #calls()
run('AgentScriptValidate', 1)
vim.wait(5000, function()
  return #calls() > n_before
end, 20)
local slow_pid = last_call().pid
vim.env.FAKE_SF_MODE = 'pass'
vim.env.FAKE_SF_DELAY = nil
run('AgentScriptValidate')
vim.wait(10000, function()
  return not pcall(assert, vim.uv.kill(slow_pid, 0))
end, 50)
vim.wait(500)
check(
  last_note() == 'agentscript-nvim: validated Nvim_Probe' and #sf_diags() == 0,
  "concurrent validate: the earlier run's late failure is dropped",
  last_note()
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

saved = sf.START_TIMEOUT_MS
sf.START_TIMEOUT_MS = 1500
run('AgentScriptPreview')
check(
  last_note():match('sf agent preview start timed out after .*; is Agentforce turned on in the org%?$')
    and next(sf.sessions) == nil,
  'preview start timeout: asks whether Agentforce is on, no session left',
  last_note()
)
sf.START_TIMEOUT_MS = saved

-- Preview: start, three turns, end on wipeout -------------------------------

local function only_session()
  return select(2, next(sf.sessions))
end
local function wait_preview()
  vim.wait(15000, function()
    return vim.bo.filetype == 'agentscript-preview'
  end, 20)
  return vim.api.nvim_get_current_buf()
end
--- Type `text` at the prompt, which is always the last line, and send it.
local function say(pbuf, text)
  local lines = vim.split(text, '\n')
  lines[1] = '> ' .. lines[1]
  vim.api.nvim_buf_set_lines(pbuf, -2, -1, false, lines)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local s = only_session()
  vim.wait(15000, function()
    return not s.busy
  end, 20)
end
local function send_argv(session, text)
  return {
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
  }
end

vim.env.FAKE_SF_MODE = 'pass'
local src_win = vim.api.nvim_get_current_win()
run('AgentScriptPreview', 1)
local pbuf = wait_preview()
local pname = vim.api.nvim_buf_get_name(pbuf)
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
local session = only_session()
check(session and session.id == '4a9ba646-a103-4d73-8dc4-8efaa8fb1af3', 'preview: stores result.sessionId')

local n_calls = #calls()
vim.api.nvim_set_current_win(src_win)
vim.cmd('AgentScriptPreview')
check(
  vim.api.nvim_get_current_buf() == pbuf and #calls() == n_calls and #vim.fn.win_findbuf(pbuf) == 1,
  'preview: a second call focuses the existing split'
)
vim.cmd('AgentScriptPreview')
check(
  vim.api.nvim_get_current_buf() == pbuf and #calls() == n_calls and vim.tbl_count(sf.sessions) == 1,
  'preview: called from the chat itself, stays on its session'
)

local turns = { 'Hi there', 'Can you say "hello"\non two lines?', 'I want to talk to a human' }
for i, text in ipairs(turns) do
  say(pbuf, text)
  c = last_call()
  check(
    vim.deep_equal(c.args, send_argv(session, text)),
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

vim.cmd('silent normal! u')
check(
  vim.deep_equal(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), transcript),
  'preview: undo leaves the transcript alone'
)
vim.api.nvim_buf_set_lines(pbuf, 1, 3, false, {})
say(pbuf, 'after an edit')
c = last_call()
transcript = vim.api.nvim_buf_get_lines(pbuf, -4, -1, false)
check(
  vim.deep_equal(c.args, send_argv(session, 'after an edit'))
    and vim.deep_equal(transcript, { 'user: after an edit', 'agent: Hello! How can I assist you today?', '> ' }),
  'preview: the prompt survives deleting transcript lines above it',
  vim.inspect(c.args) .. '\n' .. table.concat(transcript, '\n')
)

run('AgentScriptValidate')
c = last_call()
check(
  c.args[3] == 'authoring-bundle' and c.args[5] == 'Nvim_Probe' and same_path(c.cwd, project),
  "validate from the chat: validates the chat's bundle in its project",
  vim.inspect(c)
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
check(next(sf.sessions) == nil, 'preview: session forgotten after end')

-- Same bundle name in two projects: two sessions ----------------------------

local project2 = vim.fs.joinpath(tmp, 'project2')
copy_project(project2)
local agent_file2 = project2 .. agent_file:sub(#project + 1)
vim.cmd.edit(vim.fn.fnameescape(agent_file))
run('AgentScriptPreview', 1)
local pbuf1 = wait_preview()
vim.cmd.wincmd('p')
vim.cmd.edit(vim.fn.fnameescape(agent_file2))
run('AgentScriptPreview', 1)
local pbuf2 = wait_preview()
local starts = vim.tbl_filter(function(e)
  return e.args[3] == 'start'
end, calls())
check(
  pbuf1 ~= pbuf2
    and vim.tbl_count(sf.sessions) == 2
    and same_path(starts[#starts - 1].cwd, project)
    and same_path(starts[#starts].cwd, project2),
  'two projects, same bundle name: separate sessions, each run from its project'
)
run('silent bwipeout ' .. pbuf1 .. ' ' .. pbuf2, 2)
check(next(sf.sessions) == nil, 'two projects: both sessions end')

-- The split can't open: the session sf started is ended, not leaked ---------

local blocker = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_name(blocker, pname)
vim.cmd.edit(vim.fn.fnameescape(agent_file))
local wins = #vim.api.nvim_list_wins()
local ends_before = #vim.tbl_filter(function(e)
  return e.args[3] == 'end'
end, calls())
run('AgentScriptPreview', 3)
local failed = vim.tbl_filter(function(n)
  return n.msg:match('could not open the preview of Nvim_Probe: .*E95')
end, notes)
check(
  #failed == 1
    and #vim.api.nvim_list_wins() == wins
    and next(sf.sessions) == nil
    and #vim.tbl_filter(function(e)
      return e.args[3] == 'end'
    end, calls()) == ends_before + 1,
  'preview window fails to open: error shown, session ended, nothing left open',
  vim.inspect(vim.list_slice(notes, #notes - 2))
)
vim.api.nvim_buf_delete(blocker, { force = true })

-- Start failure: error, no split ---------------------------------------------

vim.env.FAKE_SF_MODE = 'noorg'
wins = #vim.api.nvim_list_wins()
run('AgentScriptPreview')
check(
  last_note():match('No default environment found') and #vim.api.nvim_list_wins() == wins and next(sf.sessions) == nil,
  'preview start failure: error, no split, no session',
  last_note()
)

-- Bang, and VimLeavePre ending every session exactly once -------------------

vim.env.FAKE_SF_MODE = 'pass'
run('AgentScriptPreview!', 1)
pbuf = wait_preview()
check(last_call().args[6] == '--use-live-actions', 'preview!: live actions', vim.inspect(last_call().args))

vim.env.FAKE_SF_MODE = 'expired'
say(pbuf, 'still there?')
local tail = vim.api.nvim_buf_get_lines(pbuf, -3, -1, false)
check(
  tail[1]
      == "error: Preview session '00000000-dead-beef-0000-000000000000' is invalid or has expired. " .. 'Start a new session with "sf agent preview start".'
    and tail[2] == '> ',
  "preview: a failed send shows sf's error in the transcript",
  table.concat(tail, '\n')
)

-- A second preview still starting when Neovim quits.
vim.env.FAKE_SF_MODE = 'pass'
vim.cmd.wincmd('p')
vim.cmd.edit(vim.fn.fnameescape(agent_file2))
vim.env.FAKE_SF_DELAY = '1500'
run('AgentScriptPreview', 1)
vim.env.FAKE_SF_DELAY = nil
local function ends()
  return #vim.tbl_filter(function(e)
    return e.args[3] == 'end'
  end, calls())
end
ends_before = ends()
wins = #vim.api.nvim_list_wins()
vim.api.nvim_exec_autocmds('VimLeavePre', {})
check(
  ends() == ends_before + 2 and next(sf.sessions) == nil and #vim.api.nvim_list_wins() == wins,
  'VimLeavePre: ends the open session and the one that was starting, opens nothing',
  ('%d ends, %d sessions, %d windows'):format(
    ends() - ends_before,
    vim.tbl_count(sf.sessions),
    #vim.api.nvim_list_wins()
  )
)
vim.cmd('bwipeout ' .. pbuf)
vim.wait(1000)
check(ends() == ends_before + 2, 'VimLeavePre then wipeout: end runs once per session')

-- :checkhealth runs the same sf the commands do -----------------------------

vim.cmd('silent checkhealth agentscript-nvim')
local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(
  report:find('sf: @salesforce/cli/2.151.7 win32-x64 node-v22.18.0', 1, true)
    and report:find('sf agent validate authoring-bundle --help exits 0', 1, true),
  'checkhealth: sf version and the agent command',
  report:match('agentscript%-nvim: sf.*') or report
)

vim.env.PATH = real_path
vim.fn.delete(tmp, 'rf')
print(failures == 0 and 'SF TEST PASSED' or (failures .. ' TEST(S) FAILED'))
os.exit(failures == 0 and 0 or 1)
