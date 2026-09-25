-- Tree-sitter support for Agent Script.
--
-- Upstream ships the official grammar (parser.c + scanner.c) and highlight
-- queries in `@sf-agentscript/parser-tree-sitter`, but no plain dynamic
-- library that Neovim can load (the npm prebuilds are Node.js bindings, Linux
-- only). :AgentScriptTSBuild fetches the package via `npm pack`, compiles the
-- grammar with any available C compiler (cc/gcc/clang/zig), and installs the
-- parser + official queries under stdpath('data'). Requires `npm`, `tar`
-- (both ship with Node.js/Windows 10+) and a C compiler.
--
-- M.install resolves the published grammar version, builds it and verifies
-- it (loads it under a scratch language name, compiles its highlights query,
-- parses a snippet of 3.x syntax without an ERROR node) before moving it into
-- place. If that fails, a parser that is already built is kept; with none,
-- M.PIN is built instead. The outcome is recorded in `<dir>/ts-state.json`
-- for `:checkhealth`.
--
-- Layout under M.dir():
--   parser/agentscript-<version>.<ext>
--   runtime/<version>/queries/agentscript/highlights.scm
--   work/<pid>/         downloads and unverified builds of one Nvim instance
--   ts-state.json

local M = {}

local PKG = '@sf-agentscript/parser-tree-sitter'
local install = require('agentscript-nvim.install')

-- Built when the published grammar fails and nothing is built yet, or when
-- the registry cannot be consulted.
M.PIN = '2.7.2'

M.FETCH_TIMEOUT_MS = 60000
M.COMPILE_TIMEOUT_MS = 300000

-- Verification snippets. `escalate` comes from upstream's corpus
-- (test/corpus/procedures.txt) and is an ERROR node under 2.7.2. The pin,
-- and any version the user asks for by name, only has to parse the baseline.
M.SNIPPETS = {
  escalate = 'topic test:\n   instructions: ->\n      if @var.escalate_needed:\n         escalate\n',
  baseline = 'topic test:\n   instructions: ->\n      if @var.escalate_needed:\n         transition to @topic.escalation\n',
}

-- Upstream's highlights.scm (3.2.1) has no captures for these. Each pattern
-- is appended only when the grammar's node-types.json defines its node,
-- because a query naming an unknown node does not compile.
local EXTRA_HIGHLIGHTS = {
  '(escalate_statement) @keyword',
  '"render" @keyword',
  '"show_and_return" @keyword',
  '"when" @keyword',
  '"is" @keyword',
  '"is not" @keyword',
  '"not" @keyword',
}

local function ext()
  return vim.fn.has('win32') == 1 and 'dll' or 'so'
end

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agentscript-nvim', 'ts')
end

local function versioned_path(version)
  return vim.fs.joinpath(M.dir(), 'parser', ('agentscript-%s.%s'):format(version, ext()))
end

local function legacy_path()
  return vim.fs.joinpath(M.dir(), 'parser', 'agentscript.' .. ext())
end

local function state_file()
  return vim.fs.joinpath(M.dir(), 'ts-state.json')
end

local function work_dir()
  return vim.fs.joinpath(M.dir(), 'work', tostring(vim.uv.os_getpid()))
end

--- Outcome of the last successful :AgentScriptTSBuild, or nil if never run,
--- built by agentscript-nvim 0.2.0 and earlier (which kept no state), or its
--- parser file is gone.
---@return { version: string, path: string, verified: boolean, reason: string, builtAt: string, rejected?: { version: string, reason: string, at: string } }?
function M.state()
  local st = install.read_json(state_file())
  if st and type(st.version) == 'string' and vim.uv.fs_stat(versioned_path(st.version)) then
    return st
  end
end

--- The parser recorded in ts-state.json, else the unversioned name 0.2.0
--- and earlier built.
function M.parser_path()
  local st = M.state()
  return st and versioned_path(st.version) or legacy_path()
end

--- Directory to add to runtimepath; contains queries/agentscript/*.scm.
--- Versioned like the parser, so a build never changes the queries of a
--- parser another session has loaded.
function M.queries_rtp()
  local st = M.state()
  local rtp = vim.fs.joinpath(M.dir(), 'runtime')
  return st and vim.fs.joinpath(rtp, st.version) or rtp
end

local function highlights_file(rtp)
  return vim.fs.joinpath(rtp, 'queries', 'agentscript', 'highlights.scm')
end

function M.available()
  return vim.uv.fs_stat(M.parser_path()) ~= nil and vim.uv.fs_stat(highlights_file(M.queries_rtp())) ~= nil
end

-- A language is loaded once per session; a later build cannot replace it.
---@type { path: string, rtp: string }?
local registered

--- Register the parser and queries with Neovim. Returns true on success.
function M.register()
  if not M.available() then
    return false
  end
  if not registered then
    local path, rtp = M.parser_path(), M.queries_rtp()
    local ok, loaded, err = pcall(vim.treesitter.language.add, 'agentscript', { path = path })
    if not ok or not loaded then
      vim.notify(
        'agentscript-nvim: failed to load tree-sitter parser: ' .. tostring(ok and err or loaded),
        vim.log.levels.WARN
      )
      return false
    end
    vim.opt.runtimepath:append(rtp)
    registered = { path = path, rtp = rtp }
  end
  return true
end

--- The compiler command to use, e.g. { 'gcc' } or { 'zig', 'cc' }. $CC may
--- carry arguments ("zig cc"); an explicit path may contain spaces.
local function find_compiler(override)
  -- Build the list explicitly: nil entries in a table literal would make
  -- ipairs stop before reaching the real candidates.
  local candidates = { 'cc', 'gcc', 'clang', 'zig' }
  if vim.env.CC and vim.env.CC ~= '' then
    table.insert(candidates, 1, vim.env.CC)
  end
  if override then
    table.insert(candidates, 1, override)
  end
  for _, c in ipairs(candidates) do
    local argv = vim.fn.executable(c) == 1 and { c } or vim.split(vim.trim(c), '%s+')
    if vim.fn.executable(argv[1]) == 1 then
      if #argv == 1 and vim.fn.fnamemodify(c, ':t:r') == 'zig' then
        argv[2] = 'cc'
      end
      return argv
    end
  end
end

-- A compiler's first `error:` line, else the first line of npm's output that
-- isn't boilerplate (code, syscall, errno, log path).
local NOISE = { npm = true, code = true, syscall = true, errno = true }

local function first_error(stderr)
  local lines = vim.split(stderr or '', '\n', { trimempty = true })
  for _, line in ipairs(lines) do
    if line:find('error:', 1, true) then
      return vim.trim(line)
    end
  end
  for _, line in ipairs(lines) do
    line = vim.trim((line:gsub('^npm error ', '')))
    if line ~= '' and not NOISE[line:match('^%a+') or ''] then
      return line
    end
  end
  return ''
end

-- Coroutines started by M.install, mapped to the function that resumes them.
local driven = setmetatable({}, { __mode = 'k' })

-- Call start(cb) and return what cb receives. Inside M.install this yields,
-- so the UI stays responsive; anywhere else it blocks.
local function await(start, timeout_ms)
  local step = driven[coroutine.running()]
  if step then
    start(step)
    return coroutine.yield()
  end
  local result
  start(function(...)
    result = { ... }
  end)
  vim.wait(timeout_ms, function()
    return result ~= nil
  end, 50)
  return unpack(result or {})
end

---@return vim.SystemCompleted? res, string? err
local function run(cmd, cwd, timeout_ms)
  local res = await(function(cb)
    install.system(cmd, { cwd = cwd }, timeout_ms, cb)
  end, timeout_ms + 5000)
  if not res or res.code ~= 0 then
    res = res or { code = 124, stderr = 'timed out' }
    return nil, ('`%s` failed (exit %d): %s'):format(table.concat(cmd, ' '), res.code, first_error(res.stderr))
  end
  return res
end

--- Download and unpack one published version.
---@param version string
---@param offline? boolean serve it from npm's cache only
---@param dest? string defaults to this instance's work dir
---@return string? pkg_dir, string? err
function M.fetch(version, offline, dest)
  if vim.fn.executable('npm') == 0 or vim.fn.executable('tar') == 0 then
    return nil, 'npm and tar are required to download the grammar'
  end
  dest = dest or vim.fs.joinpath(work_dir(), 'pkg-' .. version)
  vim.fn.delete(dest, 'rf')
  vim.fn.mkdir(dest, 'p')
  -- npm pack writes to cwd. A --pack-destination path would go through
  -- cmd.exe, which reinterprets & and ^ in it.
  local pack = { 'npm', 'pack', PKG .. '@' .. version }
  if offline then
    table.insert(pack, '--offline')
  end
  if vim.fn.has('win32') == 1 then
    pack = vim.list_extend({ 'cmd.exe', '/c' }, pack)
  end
  local ok, err = run(pack, dest, M.FETCH_TIMEOUT_MS)
  if not ok then
    return nil, err
  end
  local tgz = vim.fn.glob(vim.fs.joinpath(dest, '*.tgz'))
  -- Relative name + cwd: GNU tar (Git Bash) reads `D:/...` as a remote host.
  ok, err = run({ 'tar', '-xzf', vim.fs.basename(tgz) }, dest, M.FETCH_TIMEOUT_MS)
  if not ok then
    return nil, err
  end
  return vim.fs.joinpath(dest, 'package')
end

--- Compile one grammar version into the work dir. Does not verify, install
--- or register it.
---@param opts? { version?: string, compiler?: string, src_dir?: string, offline?: boolean }
--- src_dir: use an already-extracted package directory instead of npm;
--- version then defaults to the one in its package.json.
---@return string? parser_file, string pkg_dir_or_err
function M.build(opts)
  opts = opts or {}
  local cc = find_compiler(opts.compiler)
  if not cc then
    return nil, 'no C compiler found (need cc, gcc, clang or zig on PATH, or pass { compiler = ... })'
  end
  local pkg, err = opts.src_dir, nil
  if not pkg then
    pkg, err = M.fetch(opts.version or M.PIN, opts.offline)
    if not pkg then
      return nil, err
    end
  end
  local version = opts.version
  if not version then
    local ok, manifest = pcall(vim.json.decode, install.read_file(vim.fs.joinpath(pkg, 'package.json')) or '')
    version = ok and type(manifest) == 'table' and manifest.version or M.PIN
  end

  -- Unique per build: a rejected library stays loaded under its scratch
  -- name, and Windows won't let it be overwritten.
  local file = vim.fs.joinpath(work_dir(), ('agentscript-%s-%d.%s'):format(version, vim.uv.hrtime(), ext()))
  vim.fn.mkdir(work_dir(), 'p')
  local args = { '-O2', '-shared', '-Isrc', 'src/parser.c', 'src/scanner.c', '-o', file }
  if vim.fn.has('win32') == 0 then
    table.insert(args, 1, '-fPIC')
  end
  local ok, cerr = run(vim.list_extend(cc, args), pkg, M.COMPILE_TIMEOUT_MS)
  if not ok then
    return nil, cerr
  end
  return file, pkg
end

--- The highlights query to install for a package: upstream's highlights.scm
--- plus whichever EXTRA_HIGHLIGHTS its grammar has nodes for.
---@param pkg_dir string
---@return string
function M.highlights(pkg_dir)
  local text = install.read_file(vim.fs.joinpath(pkg_dir, 'queries', 'highlights.scm'))
  if not text then
    error('highlights.scm missing from grammar package', 0)
  end
  local ok, types = pcall(vim.json.decode, install.read_file(vim.fs.joinpath(pkg_dir, 'src', 'node-types.json')) or '')
  local have = {}
  for _, t in ipairs(ok and type(types) == 'table' and types or {}) do
    have[t.named and ('(' .. t.type .. ')') or ('"' .. t.type .. '"')] = true
  end
  local extra = vim.tbl_filter(function(p)
    return have[p:match('^%b()') or p:match('^%b""')]
  end, EXTRA_HIGHLIGHTS)
  if #extra == 0 then
    return text
  end
  return text
    .. '\n; agentscript-nvim: nodes the upstream query leaves uncaptured\n'
    .. table.concat(extra, '\n')
    .. '\n'
end

local verify_count = 0

--- Check a built parser without touching the `agentscript` language: load
--- it under a scratch name, compile the highlights query that would be
--- installed with it, and parse M.SNIPPETS[snippet] without an ERROR node.
---@param parser_file string
---@param pkg_dir string
---@param snippet? 'escalate'|'baseline' defaults to 'escalate'
---@return boolean ok, string detail
function M.verify(parser_file, pkg_dir, snippet)
  snippet = snippet or 'escalate'
  -- language.add() returns early for a name already loaded this session, so
  -- reusing one would verify the previously loaded library, not this one.
  verify_count = verify_count + 1
  local lang = 'agentscript_verify_' .. verify_count
  local ok, loaded, err = pcall(vim.treesitter.language.add, lang, { path = parser_file, symbol_name = 'agentscript' })
  if not ok or not loaded then
    return false, 'parser failed to load: ' .. tostring(ok and err or loaded)
  end
  local qok, query = pcall(M.highlights, pkg_dir)
  if qok then
    qok, query = pcall(vim.treesitter.query.parse, lang, query)
  end
  if not qok then
    local qerr = tostring(query):gsub('^.-%.lua:%d+: ', ''):match('[^\n]*'):gsub(':$', '')
    return false, 'highlights.scm does not compile against its own parser: ' .. qerr
  end
  local root = vim.treesitter.get_string_parser(M.SNIPPETS[snippet], lang):parse()[1]:root()
  if root:has_error() then
    return false, snippet .. ' snippet parses to an ERROR node: ' .. root:sexpr()
  end
  return true, 'highlights compile, ' .. snippet .. ' snippet parses clean'
end

-- Move a verified build to parser/agentscript-<version>.<ext>. A loaded
-- library can't be overwritten or deleted on Windows, but it can be renamed
-- aside; remove_stale() deletes the leftover once nothing holds it.
local function place(file, version)
  local out = versioned_path(version)
  vim.fn.mkdir(vim.fs.dirname(out), 'p')
  local aside
  if vim.uv.fs_stat(out) then
    aside = ('%s.%d.old'):format(out, vim.uv.hrtime())
    local ok, err = vim.uv.fs_rename(out, aside)
    if not ok then
      return nil, 'could not move the old parser aside: ' .. tostring(err)
    end
  end
  local ok, err = vim.uv.fs_rename(file, out)
  if not ok then
    if aside then
      vim.uv.fs_rename(aside, out)
    end
    return nil, 'could not move the built parser into place: ' .. tostring(err)
  end
  return out
end

-- Downloads and builds left by this instance's earlier runs, or by instances
-- that have exited. A build running in another instance keeps its dir.
local function sweep_work()
  local wdir = vim.fs.joinpath(M.dir(), 'work')
  local me = vim.uv.os_getpid()
  for name in vim.fs.dir(wdir) do
    local pid = tonumber(name)
    if not pid or pid == me or vim.uv.kill(pid, 0) ~= 0 then
      vim.fn.delete(vim.fs.joinpath(wdir, name), 'rf')
    end
  end
end

-- Best-effort: delete every parser file except `keep`; one still loaded
-- somewhere survives on Windows until a later build. A query dir goes once
-- its parser is gone, unless the previous build or this session uses it.
local function remove_stale(keep, prev_rtp)
  local pdir = vim.fs.joinpath(M.dir(), 'parser')
  for name in vim.fs.dir(pdir) do
    local p = vim.fs.joinpath(pdir, name)
    if p ~= keep then
      pcall(vim.uv.fs_unlink, p)
    end
  end
  local in_use = { [prev_rtp] = true, [registered and registered.rtp or ''] = true }
  local rdir = vim.fs.joinpath(M.dir(), 'runtime')
  for name in vim.fs.dir(rdir) do
    -- 0.2.0 used runtime/ itself as the rtp.
    local legacy = name == 'queries'
    local rtp = legacy and rdir or vim.fs.joinpath(rdir, name)
    if not in_use[rtp] and not vim.uv.fs_stat(legacy and legacy_path() or versioned_path(name)) then
      vim.fn.delete(vim.fs.joinpath(rdir, name), 'rf')
    end
  end
  -- 0.2.0 downloaded into M.dir() itself.
  for name in vim.fs.dir(M.dir()) do
    if name:match('^pkg%-') or name == 'package' or name:match('%.tgz$') then
      vim.fn.delete(vim.fs.joinpath(M.dir(), name), 'rf')
    end
  end
end

local function now()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

-- The body of M.install, run as a driven coroutine.
local function build_flow(opts, done)
  sweep_work()
  if M.available() then
    remove_stale(M.parser_path(), M.queries_rtp())
  end

  local function progress(msg)
    vim.notify('agentscript-nvim: ' .. msg, vim.log.levels.INFO)
  end

  -- Build and verify one version. Returns the parser file, still in the
  -- work dir, and its package; or nil and why not.
  local function attempt(version, snippet, offline)
    progress('building tree-sitter grammar ' .. version .. ' ...')
    local file, pkg = M.build({ version = version, compiler = opts.compiler, offline = offline })
    if not file then
      return nil, pkg
    end
    local ok, detail = M.verify(file, pkg, snippet)
    if not ok then
      return nil, detail
    end
    return file, pkg, detail
  end

  local function finish(state, file, pkg, msg)
    local prev_rtp = M.queries_rtp()
    local rtp = vim.fs.joinpath(M.dir(), 'runtime', state.version)
    vim.fn.mkdir(vim.fs.dirname(highlights_file(rtp)), 'p')
    local ok, err = install.write_file(highlights_file(rtp), M.highlights(pkg))
    local out
    if ok then
      out, err = place(file, state.version)
    end
    if out then
      state.verified = true
      state.builtAt = now()
      ok, err = install.write_json(state_file(), state)
    end
    if not ok or not out then
      return done(false, 'build failed: ' .. tostring(err))
    end
    remove_stale(out, prev_rtp)
    if not registered then
      M.register()
      msg = msg .. ' Reopen your .agent buffer.'
    elseif registered.path ~= out then
      msg = msg .. ' Restart Neovim to load it; this session keeps ' .. vim.fs.basename(registered.path) .. '.'
    end
    done(true, msg)
  end

  if opts.version then
    local file, pkg, detail = attempt(opts.version, 'baseline')
    if not file then
      return done(false, 'build failed: ' .. opts.version .. ': ' .. pkg)
    end
    return finish(
      { version = opts.version, path = 'requested', reason = detail },
      file,
      pkg,
      opts.version .. ' (requested) verified.'
    )
  end

  progress('resolving ' .. PKG .. ' ...')
  local latest = await(function(cb)
    install.resolve_latest(cb, PKG)
  end)
  local current = M.available() and M.state()
  local why
  if not latest then
    why = 'npm view failed (offline?)'
  elseif current and current.version == latest and current.path == 'current' and not opts.force then
    return done(true, latest .. ' is already built and verified; :AgentScriptTSBuild! rebuilds it.')
  else
    local file, pkg, detail = attempt(latest, 'escalate')
    if file then
      return finish(
        { version = latest, path = 'current', reason = detail },
        file,
        pkg,
        latest .. ' verified (' .. detail .. ').'
      )
    end
    why = latest .. ': ' .. pkg
    if current then
      current.rejected = { version = latest, reason = pkg, at = now() }
      install.write_json(state_file(), current)
    end
  end

  -- Neither an unreachable registry nor a broken release says anything
  -- against the parser already built; the pin could only be a downgrade.
  if current then
    return done(
      false,
      ('not updated: %s; keeping %s (%s)'):format(why, current.version, tostring(current.path)),
      vim.log.levels.WARN
    )
  end
  local path = latest and 'fallback' or 'pinned-offline'
  progress(why .. '; building the pinned ' .. M.PIN .. (latest and '' or ' from the npm cache') .. ' ...')
  local file, pkg = attempt(M.PIN, 'baseline', not latest)
  if not file then
    return done(false, 'build failed: ' .. why .. ' | ' .. M.PIN .. ' (' .. path .. '): ' .. pkg)
  end
  finish({ version = M.PIN, path = path, reason = why }, file, pkg, M.PIN .. ' (' .. path .. ') verified.')
end

local building = false

--- Build and verify the published grammar in the background. Keeps an
--- existing parser if that fails, else builds M.PIN. Calls
--- on_done(ok, msg, level?). opts.version skips resolution and never falls
--- back: a version asked for by name either works or leaves the current
--- parser alone. opts.force rebuilds a version that is already current.
---@param on_done? fun(ok: boolean, msg: string, level?: integer)
---@param opts? { version?: string, compiler?: string, force?: boolean }
function M.install(on_done, opts)
  opts = opts or {}
  local report = on_done
    or function(ok, msg, level)
      vim.notify(
        'agentscript-nvim: tree-sitter grammar ' .. msg,
        level or (ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      )
    end
  if building then
    report(false, 'build already running', vim.log.levels.WARN)
    return
  end
  -- Checked up front so a missing compiler is one error, not a failed build
  -- followed by an identical failed fallback.
  if not find_compiler(opts.compiler) then
    report(false, 'build failed: no C compiler found (need cc, gcc, clang or zig on PATH)')
    return
  end
  if opts.version and not opts.version:match(install.VERSION_PATTERN) then
    report(false, 'build failed: expected a version like ' .. M.PIN .. ', got ' .. opts.version)
    return
  end

  building = true
  local function done(ok, msg, level)
    building = false
    sweep_work()
    report(ok, msg, level)
  end
  local co = coroutine.create(build_flow)
  driven[co] = function(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok and building then
      done(false, 'build failed: ' .. tostring(err))
    elseif not ok then
      error(err, 0)
    end
  end
  driven[co](opts, done)
end

return M
