-- Headless test for tree-sitter support (:AgentScriptTSBuild path).
-- Run from the repo root:  nvim -l tests/test_treesitter.lua
--
-- Builds real grammars from scratch/ts/pkg-<version>/package (fetched with
-- npm on the first run only) into tests/tmp-ts, with version resolution and
-- the package download stubbed, and asserts: the current / fallback /
-- pinned-offline / requested install paths and their ts-state.json, that a
-- failed update keeps the working parser (also for a same-version rebuild),
-- verify rejecting a query that does not compile, the new keywords parsing
-- clean and highlighted, broken.agent still yielding an ERROR node, the
-- :AgentScriptTSBuild command, a 0.2.0-style install with no state file, and
-- :checkhealth.

-- Dual-mode: runs standalone via `nvim -l`, or as part of test_lsp.lua when
-- _G.__AGENTSCRIPT_SUITE is set (then it skips env setup and returns the
-- failure count instead of exiting).
local standalone = not _G.__AGENTSCRIPT_SUITE

local script = arg[0]
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ':p:h:h'))

local failures = 0
local function check(ok, label, detail)
  if ok then
    print(('PASS  %s'):format(label))
  else
    failures = failures + 1
    print(('FAIL  %s%s'):format(label, detail and (' — ' .. detail) or ''))
  end
end

if standalone then
  vim.opt.runtimepath:prepend(root)
  vim.cmd('filetype plugin on')
end

local ts = require('agentscript-nvim.treesitter')
local install = require('agentscript-nvim.install')
local ext = vim.fn.has('win32') == 1 and 'dll' or 'so'
local fixtures = vim.fs.joinpath(root, 'tests', 'fixtures')

-- Compiler: any system one, else the portable zig in scratch/ ------------

local compiler
if
  vim.fn.executable('cc') == 0
  and vim.fn.executable('gcc') == 0
  and vim.fn.executable('clang') == 0
  and vim.fn.executable('zig') == 0
then
  compiler = vim.fn.glob(vim.fs.joinpath(root, 'scratch', 'zig-extract', '*', 'zig.exe'))
  if compiler == '' then
    -- Bootstrap: extract the pre-downloaded portable zig.
    local zip = vim.fs.joinpath(root, 'scratch', 'zig.zip')
    assert(vim.uv.fs_stat(zip), 'no C compiler on PATH and no scratch zig.zip; download zig first')
    local dest = vim.fs.joinpath(root, 'scratch', 'zig-extract')
    vim.fn.mkdir(dest, 'p')
    print('extracting portable zig ...')
    -- `tar` reads zip only with a libarchive/bsdtar build (Windows System32,
    -- macOS, most Linux). Under Git Bash on Windows it can resolve to GNU tar,
    -- which cannot read zip and treats `D:` as a remote host — fall back to
    -- PowerShell's Expand-Archive there.
    local res = vim.system({ 'tar', '-xf', zip, '-C', dest }):wait()
    if res.code ~= 0 and vim.fn.has('win32') == 1 then
      res = vim
        .system({
          'powershell',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          ("Expand-Archive -LiteralPath '%s' -DestinationPath '%s' -Force"):format(zip, dest),
        })
        :wait()
    end
    assert(res.code == 0, 'zig extraction failed: ' .. (res.stderr or ''))
    compiler = vim.fn.glob(vim.fs.joinpath(dest, '*', 'zig.exe'))
    assert(compiler ~= '', 'zig.exe not found after extraction')
  end
end
print('compiler: ' .. (compiler or 'system'))

-- Absolute, so the npm-missing case can empty PATH.
local cc_abs = compiler
for _, c in ipairs({ 'cc', 'gcc', 'clang', 'zig' }) do
  if not cc_abs and vim.fn.executable(c) == 1 then
    cc_abs = vim.fn.exepath(c)
  end
end

-- Grammar sources: real published packages, fetched once with the plugin's
-- own ts.fetch into scratch/ts/ (gitignored) ----------------------------

local real_dir, real_fetch, real_resolve = ts.dir, ts.fetch, install.resolve_latest

local function source(version)
  local dest = vim.fs.joinpath(root, 'scratch', 'ts', 'pkg-' .. version)
  local pkg = vim.fs.joinpath(dest, 'package')
  if not vim.uv.fs_stat(vim.fs.joinpath(pkg, 'src', 'parser.c')) then
    print('fetching ' .. version .. ' sources (first run only) ...')
    assert(ts.fetch(version, false, dest))
  end
  return pkg
end

local sources = { ['3.2.1'] = source('3.2.1'), [ts.PIN] = source(ts.PIN) }

local tmp_root = vim.fs.joinpath(root, 'tests', 'tmp-ts')
vim.fn.delete(tmp_root, 'rf')

-- A 3.2.1 package whose highlights.scm names a node its grammar lacks.
local broken_pkg = vim.fs.joinpath(tmp_root, 'broken-pkg')
for _, sub in ipairs({ 'src', 'queries' }) do
  local from = vim.fs.joinpath(sources['3.2.1'], sub)
  for name, kind in vim.fs.dir(from, { depth = 5 }) do
    local dst = vim.fs.joinpath(broken_pkg, sub, name)
    if kind == 'directory' then
      vim.fn.mkdir(dst, 'p')
    else
      vim.fn.mkdir(vim.fs.dirname(dst), 'p')
      assert(vim.uv.fs_copyfile(vim.fs.joinpath(from, name), dst))
    end
  end
end
local hf = assert(io.open(vim.fs.joinpath(broken_pkg, 'queries', 'highlights.scm'), 'a'))
hf:write('\n(no_such_node) @keyword\n')
hf:close()

-- Stubs ----------------------------------------------------------------------

local latest, resolved_pkg, fetched_offline
local calls = { resolve = 0, fetch = 0 }
local broken = { ['9.9.9'] = true }
local function use_dir(name)
  ts.dir = function()
    return vim.fs.joinpath(tmp_root, name)
  end
end
ts.fetch = function(version, offline)
  calls.fetch = calls.fetch + 1
  fetched_offline = offline
  if version == '6.6.6' then
    error('boom: not a handled failure')
  end
  if broken[version] then
    return broken_pkg
  end
  if sources[version] then
    return sources[version]
  end
  return nil, 'npm pack: 404 Not Found - ' .. version
end
install.resolve_latest = function(on_done, pkg)
  calls.resolve = calls.resolve + 1
  resolved_pkg = pkg
  vim.schedule(function()
    on_done(latest)
  end)
end

local function run_install(opts)
  opts = vim.tbl_extend('force', { compiler = compiler }, opts or {})
  local done, ok_r, msg_r, level_r = false, nil, nil, nil
  ts.install(function(ok, msg, level)
    done, ok_r, msg_r, level_r = true, ok, msg, level
  end, opts)
  local finished = vim.wait(600000, function()
    return done
  end, 100)
  print('  -> ' .. tostring(msg_r))
  return finished and ok_r, tostring(msg_r), level_r
end

local function health()
  vim.cmd('checkhealth agentscript-nvim')
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  vim.cmd('bwipeout')
  return text
end

local function read(path)
  local f = io.open(path, 'r')
  local s = f and f:read('*a') or ''
  if f then
    f:close()
  end
  return s
end

-- Parse fixture text on whatever parser ts.parser_path() now points at,
-- independent of the `agentscript` language loaded this session.
local test_langs = 0
local function parse_with_built(file)
  test_langs = test_langs + 1
  local lang = 'agentscript_test_' .. test_langs
  assert(vim.treesitter.language.add(lang, { path = ts.parser_path(), symbol_name = 'agentscript' }))
  local text = read(file)
  return vim.treesitter.get_string_parser(text, lang):parse()[1]:root(), lang, text
end

local function installed_query()
  return read(vim.fs.joinpath(ts.queries_rtp(), 'queries', 'agentscript', 'highlights.scm'))
end

local function parser_files()
  local names = {}
  for name in vim.fs.dir(vim.fs.joinpath(ts.dir(), 'parser')) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local pid = tostring(vim.uv.os_getpid())
local function esc(s)
  return (s:gsub('%p', '%%%0'))
end

use_dir('main')
if standalone then
  require('agentscript-nvim').setup({ cmd = { 'node', '--version' } }) -- LSP irrelevant here
end

-- Up-front rejections ----------------------------------------------------------

local saved_path, saved_cc = vim.env.PATH, vim.env.CC
vim.env.PATH, vim.env.CC = '', nil
local ok, msg, level = run_install({ compiler = false })
vim.env.PATH, vim.env.CC = saved_path, saved_cc
check(not ok and msg:match('no C compiler') ~= nil, 'no compiler: one clear error', msg)
check(calls.resolve == 0 and calls.fetch == 0, 'no compiler: rejected before resolving or fetching', vim.inspect(calls))

ok, msg = run_install({ version = 'latest' })
check(not ok and msg:match('expected a version') ~= nil, 'non-version argument rejected', msg)

-- (a) current: the published grammar verifies and is adopted ---------------

latest = '3.2.1'
ok, msg = run_install()
check(ok and msg:match('3%.2%.1 verified') ~= nil, 'current: 3.2.1 built and verified', msg)
check(resolved_pkg == '@sf-agentscript/parser-tree-sitter', 'current: resolves the grammar package', resolved_pkg)
local st = ts.state()
check(
  st and st.version == '3.2.1' and st.path == 'current' and st.verified == true and st.builtAt ~= nil,
  'current: ts-state.json records 3.2.1/current/verified',
  vim.inspect(st)
)
check(
  ts.parser_path() == vim.fs.joinpath(tmp_root, 'main', 'parser', 'agentscript-3.2.1.' .. ext),
  'current: versioned parser file',
  ts.parser_path()
)
check(
  ts.queries_rtp() == vim.fs.joinpath(tmp_root, 'main', 'runtime', '3.2.1'),
  'current: versioned query dir',
  ts.queries_rtp()
)
check(ts.available(), 'current: parser + queries installed')
check(not vim.uv.fs_stat(vim.fs.joinpath(ts.dir(), 'work', pid)), 'current: work dir removed after the build')
check(installed_query():match('%(escalate_statement%) @keyword') ~= nil, 'current: escalate capture added to query')

local root_v3 = parse_with_built(vim.fs.joinpath(fixtures, 'v3.agent'))
check(not root_v3:has_error(), 'v3.agent parses clean on the built grammar', root_v3:sexpr())
check(root_v3:sexpr():match('%(escalate_statement%)') ~= nil, 'v3.agent contains (escalate_statement)')

local root_kw, lang_kw, kw_text = parse_with_built(vim.fs.joinpath(fixtures, 'v3-keywords.agent'))
check(not root_kw:has_error(), 'v3-keywords.agent parses clean on the built grammar', root_kw:sexpr())
local keywords = {}
local kw_query = vim.treesitter.query.parse(lang_kw, installed_query())
for id, node in kw_query:iter_captures(root_kw, kw_text) do
  if kw_query.captures[id] == 'keyword' then
    keywords[vim.treesitter.get_node_text(node, kw_text)] = true
  end
end
for _, kw in ipairs({ 'escalate', 'render', 'show_and_return', 'when', 'is', 'is not', 'not' }) do
  check(keywords[kw], ('`%s` captured as @keyword'):format(kw), vim.inspect(vim.tbl_keys(keywords)))
end

local root_sample, lang_sample, sample_text = parse_with_built(vim.fs.joinpath(fixtures, 'sample.agent'))
check(not root_sample:has_error(), 'sample.agent parses clean on the built grammar')
local query = vim.treesitter.query.parse(lang_sample, installed_query())
local captures = 0
for _ in query:iter_captures(root_sample, sample_text) do
  captures = captures + 1
end
check(captures >= 10, 'installed highlights query yields captures on sample.agent', 'got ' .. captures)

local root_broken = parse_with_built(vim.fs.joinpath(fixtures, 'broken.agent'))
check(root_broken:has_error(), 'broken.agent still yields an ERROR node')

-- The real FileType path. In suite mode test_lsp may have loaded the user's
-- own parser as `agentscript` first, and this session keeps it.
if standalone then
  check(msg:match('Reopen') ~= nil, 'current: first build registers for this session', msg)
end
vim.cmd.edit(vim.fs.joinpath(fixtures, 'v3.agent'))
local v3_buf = vim.api.nvim_get_current_buf()
check(vim.treesitter.highlighter.active[v3_buf] ~= nil, 'tree-sitter highlighter active on v3.agent')
if pcall(vim.treesitter.query.parse, 'agentscript', '(escalate_statement) @x') then
  vim.treesitter.get_parser(v3_buf):parse()
  local caps = vim.tbl_map(function(c)
    return c.capture
  end, vim.treesitter.get_captures_at_pos(v3_buf, 3, 9))
  check(vim.tbl_contains(caps, 'keyword'), '`escalate` highlighted as @keyword', vim.inspect(caps))
else
  print('SKIP  `escalate` capture check (this session loaded a parser without escalate as agentscript)')
end

check(
  health():match('tree%-sitter grammar: 3%.2%.1 via current path, verification passed') ~= nil,
  'checkhealth: 3.2.1 via current path, verification passed'
)

-- Rebuilding what is already current ------------------------------------------

-- Plus a superseded parser that an earlier session still had loaded.
local old_parser = vim.fs.joinpath(ts.dir(), 'parser', 'agentscript-3.0.0.' .. ext)
local old_rtp = vim.fs.joinpath(ts.dir(), 'runtime', '3.0.0')
assert(vim.uv.fs_copyfile(ts.parser_path(), old_parser))
vim.fn.mkdir(vim.fs.joinpath(old_rtp, 'queries', 'agentscript'), 'p')
local fetches = calls.fetch
ok, msg = run_install()
check(ok and msg:match('already built') ~= nil and calls.fetch == fetches, 'up to date: nothing rebuilt', msg)
check(
  not vim.uv.fs_stat(old_parser) and not vim.uv.fs_stat(old_rtp),
  'up to date: a superseded parser and its queries are removed',
  vim.inspect(parser_files())
)

-- One build at a time per session.
local first_done, second
ts.install(function()
  first_done = true
end, { compiler = compiler })
ts.install(function(ok2, msg2)
  second = { ok2, msg2 }
end, { compiler = compiler })
vim.wait(600000, function()
  return first_done
end, 50)
check(
  second and second[1] == false and second[2]:match('already running') ~= nil,
  'busy: a second build while one runs is refused',
  vim.inspect(second)
)

-- The user command; `!` forces a rebuild of the current version.
vim.g.agentscript_nvim_no_auto_setup = 1
vim.cmd.runtime('plugin/agentscript-nvim.lua')
local notified = {}
local real_notify = vim.notify
vim.notify = function(m)
  notified[#notified + 1] = m
end
vim.env.CC = cc_abs
vim.cmd('AgentScriptTSBuild!')
local cmd_msg
vim.wait(600000, function()
  cmd_msg = vim.iter(notified):find(function(m)
    return m:match('^agentscript%-nvim: tree%-sitter grammar ') ~= nil
  end)
  return cmd_msg ~= nil
end, 100)
vim.notify, vim.env.CC = real_notify, saved_cc
print('  -> ' .. tostring(cmd_msg))
check(
  tostring(cmd_msg):match('3%.2%.1 verified') ~= nil,
  ':AgentScriptTSBuild! rebuilds the current version',
  tostring(cmd_msg)
)
-- Windows can't delete the renamed-aside file while this session holds it.
local after_rebuild = parser_files()
check(
  vim.deep_equal(after_rebuild, { 'agentscript-3.2.1.' .. ext })
    or (vim.fn.has('win32') == 1 and #after_rebuild == 2 and after_rebuild[2]:match('%.old$') ~= nil),
  'same-version rebuild: the old file is renamed aside, then removed',
  vim.inspect(after_rebuild)
)

-- A failed update keeps the working parser -----------------------------------

-- Same version: the rejected build must not replace or delete the parser in
-- place, even though both would be agentscript-3.2.1.
broken['3.2.1'] = true
ok, msg, level = run_install({ force = true })
broken['3.2.1'] = nil
st = ts.state()
check(
  not ok and msg:match('not updated: 3%.2%.1: highlights%.scm does not compile') ~= nil,
  'same-version failure: reported as not updated',
  msg
)
check(level == vim.log.levels.WARN, 'same-version failure: a warning, not an error', tostring(level))
check(
  st and st.version == '3.2.1' and st.path == 'current' and st.rejected and st.rejected.version == '3.2.1',
  'same-version failure: state kept, rejection recorded',
  vim.inspect(st)
)
root_v3 = parse_with_built(vim.fs.joinpath(fixtures, 'v3.agent'))
check(not root_v3:has_error(), 'same-version failure: the working parser survives')
check(
  health():match('WARNING tree%-sitter grammar: published 3%.2%.1 failed to build or verify') ~= nil,
  'checkhealth: warns about the rejected build'
)

latest = '9.9.9'
ok, msg = run_install()
st = ts.state()
check(
  not ok and msg:match('not updated: 9%.9%.9: .*keeping 3%.2%.1 %(current%)') ~= nil,
  'newer failure: 3.2.1 kept instead of falling back to the pin',
  msg
)
check(
  st and st.version == '3.2.1' and st.rejected and st.rejected.version == '9.9.9',
  'newer failure: rejection recorded',
  vim.inspect(st)
)

-- verify() --------------------------------------------------------------------

local built_321 = ts.parser_path()
local vok, vdetail = ts.verify(built_321, broken_pkg)
check(not vok and vdetail:match('does not compile') ~= nil, 'verify rejects a broken query file', vdetail)
vok, vdetail = ts.verify(vim.fs.joinpath(tmp_root, 'missing.' .. ext), sources['3.2.1'])
check(not vok and vdetail:match('failed to load') ~= nil, 'verify rejects a missing parser file', vdetail)

-- (b) fallback: nothing built and the published grammar fails -> pin ----------

local main_dir = ts.dir()
use_dir('fallback')
ok, msg = run_install()
check(ok and msg:match(ts.PIN .. ' %(fallback%) verified') ~= nil, 'fallback: pinned grammar adopted', msg)
if standalone then
  check(msg:match('Restart Neovim') ~= nil, 'fallback: says to restart when a parser is already loaded', msg)
end
st = ts.state()
check(
  st and st.version == ts.PIN and st.path == 'fallback' and tostring(st.reason):match('9%.9%.9.*does not compile'),
  'fallback: ts-state.json records the pin and why 9.9.9 was rejected',
  vim.inspect(st)
)
check(
  health():match('WARNING tree%-sitter grammar: ' .. esc(ts.PIN) .. ' via fallback path') ~= nil,
  'checkhealth: warns on fallback'
)
check(
  vim.deep_equal(parser_files(), { 'agentscript-' .. ts.PIN .. '.' .. ext }),
  'fallback: only the pin in parser/',
  vim.inspect(parser_files())
)

-- Scratch names are unique per call: with a reused name the middle call
-- would re-check the 2.7.2 library and fail.
local built_pin = ts.parser_path()
local r1, d1 = ts.verify(built_pin, sources[ts.PIN])
local r2 = ts.verify(built_321, sources['3.2.1'])
local r3 = ts.verify(built_pin, sources[ts.PIN])
check(r1 == false and r2 == true and r3 == false, 'verify: escalate snippet fails on 2.7.2, passes on 3.2.1')
check(d1:match('ERROR node') ~= nil, 'verify: 2.7.2 detail names the ERROR node', d1)

local pin_query = ts.highlights(sources[ts.PIN])
check(
  pin_query:match('"is not" @keyword') ~= nil and pin_query:match('escalate_statement') == nil,
  'extra captures: only the nodes 2.7.2 defines are added'
)

-- (c) offline: keep a recorded parser; build the pin from npm's cache only
-- when there is none ------------------------------------------------------

ts.dir = function()
  return main_dir
end
latest = nil
ok, msg, level = run_install()
st = ts.state()
check(
  not ok and msg:match('keeping 3%.2%.1 %(current%)') ~= nil and level == vim.log.levels.WARN and st.path == 'current',
  'offline: an existing parser is kept, not replaced by the pin',
  msg
)

use_dir('offline')
ok, msg = run_install()
st = ts.state()
check(ok and st and st.version == ts.PIN and st.path == 'pinned-offline', 'pinned-offline: pin built', vim.inspect(st))
check(fetched_offline == true, 'pinned-offline: fetched from the npm cache only (--offline)')
check(
  health():match('WARNING tree%-sitter grammar: [%d.]+ via pinned%-offline path') ~= nil,
  'checkhealth: warns on pinned-offline'
)
ts.dir = function()
  return main_dir
end

-- (d) explicit version: no resolution, no fallback --------------------------

latest, resolved_pkg = '9.9.9', nil
ok, msg = run_install({ version = ts.PIN })
st = ts.state()
check(ok and resolved_pkg == nil, 'requested: builds ' .. ts.PIN .. ' without resolving', msg)
check(st and st.version == ts.PIN and st.path == 'requested', 'requested: ts-state.json records it', vim.inspect(st))
check(
  health():match('pinned by :AgentScriptTSBuild ' .. esc(ts.PIN)) ~= nil,
  'checkhealth: says how to track the published grammar again'
)

ok, msg = run_install({ version = '0.0.1' })
check(not ok and msg:match('404') ~= nil, 'requested: unknown version fails with the npm error', msg)
st = ts.state()
check(
  st and st.version == ts.PIN and st.path == 'requested' and ts.available(),
  'requested: failure leaves the working parser in place',
  vim.inspect(st)
)

-- An unexpected error still ends the build with a message, and frees it.
ok, msg = run_install({ version = '6.6.6' })
check(not ok and msg:match('^build failed: .*boom') ~= nil, 'unexpected error: reported through on_done', msg)
ok, msg = run_install({ version = ts.PIN })
check(ok, 'unexpected error: the next build runs', msg)

-- Real failure output, reduced to one line -----------------------------------

local pkg, err = real_fetch('0.0.0-nonexistent', true, vim.fs.joinpath(tmp_root, 'no-such-version'))
check(
  pkg == nil and tostring(err):match('npm pack .* failed %(exit %d+%): %S') ~= nil and not err:find('\n'),
  'npm failure: one line from npm, no dump',
  tostring(err)
)

local bad_src = vim.fs.joinpath(tmp_root, 'bad-src')
vim.fn.mkdir(vim.fs.joinpath(bad_src, 'src'), 'p')
local bf = assert(io.open(vim.fs.joinpath(bad_src, 'src', 'parser.c'), 'w'))
bf:write('int x = ;\n')
bf:close()
assert(io.open(vim.fs.joinpath(bad_src, 'src', 'scanner.c'), 'w')):close()
local file
file, err = ts.build({ src_dir = bad_src, version = '0.0.0', compiler = cc_abs })
check(
  file == nil and tostring(err):match('failed %(exit %d+%): .*parser%.c.*error:') ~= nil and not err:find('\n'),
  'compiler failure: the error: line, not the first line of output',
  tostring(err)
)

-- (e) npm missing: the real resolve + fetch under an empty PATH -------------

ts.fetch, install.resolve_latest = real_fetch, real_resolve
use_dir('no-npm')
vim.env.PATH = ''
ok, msg = run_install({ compiler = cc_abs })
vim.env.PATH = saved_path
ts.dir = function()
  return main_dir
end
check(not ok and msg:match('npm and tar are required') ~= nil, 'npm missing: clear error', msg)

-- (f) a 0.2.0 install: unversioned parser, no ts-state.json ----------------

local legacy_from = ts.parser_path()
local legacy_query = installed_query()
use_dir('legacy')
vim.fn.mkdir(vim.fs.joinpath(ts.dir(), 'parser'), 'p')
assert(vim.uv.fs_copyfile(legacy_from, vim.fs.joinpath(ts.dir(), 'parser', 'agentscript.' .. ext)))
local qdir = vim.fs.joinpath(ts.queries_rtp(), 'queries', 'agentscript')
vim.fn.mkdir(qdir, 'p')
local qf = assert(io.open(vim.fs.joinpath(qdir, 'highlights.scm'), 'w'))
qf:write(legacy_query)
qf:close()
check(ts.available() and ts.state() == nil, 'legacy: 0.2.0 install still available without state')
check(health():match('tree%-sitter grammar: version unknown') ~= nil, 'checkhealth: legacy reported as version unknown')

ts.dir = real_dir
if vim.fn.has('win32') == 0 then
  vim.fn.delete(tmp_root, 'rf')
end

print(failures == 0 and 'TREESITTER TEST PASSED' or (failures .. ' TREESITTER TEST(S) FAILED'))
if standalone then
  os.exit(failures == 0 and 0 or 1)
end
return failures
