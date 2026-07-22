-- Tree-sitter support for Agent Script.
--
-- Upstream ships the official grammar (parser.c + scanner.c) and highlight
-- queries in `@sf-agentscript/parser-tree-sitter`, but no plain dynamic
-- library that Neovim can load (the npm prebuilds are Node.js bindings, Linux
-- only). :AgentScriptTSBuild fetches the package via `npm pack`, compiles the
-- grammar with any available C compiler (cc/gcc/clang/zig), and installs the
-- parser + official queries under stdpath('data'). Requires `npm`, `tar`
-- (both ship with Node.js/Windows 10+) and a C compiler.

local M = {}

M.PIN = '2.7.2'

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agentscript-nvim', 'ts')
end

function M.parser_path()
  local ext = vim.fn.has('win32') == 1 and 'dll' or 'so'
  return vim.fs.joinpath(M.dir(), 'parser', 'agentscript.' .. ext)
end

--- Directory to add to runtimepath; contains queries/agentscript/*.scm.
function M.queries_rtp()
  return vim.fs.joinpath(M.dir(), 'runtime')
end

function M.available()
  return vim.uv.fs_stat(M.parser_path()) ~= nil
    and vim.uv.fs_stat(vim.fs.joinpath(M.queries_rtp(), 'queries', 'agentscript', 'highlights.scm')) ~= nil
end

local registered = false

--- Register the parser and queries with Neovim. Returns true on success.
function M.register()
  if not M.available() then
    return false
  end
  if not registered then
    vim.opt.runtimepath:append(M.queries_rtp())
    local ok, err = pcall(vim.treesitter.language.add, 'agentscript', { path = M.parser_path() })
    if not ok then
      vim.notify('agentscript-nvim: failed to load tree-sitter parser: ' .. tostring(err), vim.log.levels.WARN)
      return false
    end
    registered = true
  end
  return true
end

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
    if vim.fn.executable(c) == 1 then
      return c
    end
  end
end

local function run(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd }):wait()
  if res.code ~= 0 then
    error(('`%s` failed (exit %d): %s'):format(table.concat(cmd, ' '), res.code, res.stderr or ''), 0)
  end
  return res
end

--- Fetch, compile and install the grammar. Synchronous (a few seconds).
---@param opts? { compiler?: string, src_dir?: string }  src_dir: use an
--- already-extracted package directory instead of downloading via npm.
function M.build(opts)
  opts = opts or {}
  local compiler = find_compiler(opts.compiler)
  if not compiler then
    error('no C compiler found (need cc, gcc, clang or zig on PATH — or pass { compiler = ... })', 0)
  end
  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')

  local pkg = opts.src_dir
  if not pkg then
    if vim.fn.executable('npm') == 0 or vim.fn.executable('tar') == 0 then
      error('npm and tar are required to download the grammar', 0)
    end
    local spec = '@sf-agentscript/parser-tree-sitter@' .. M.PIN
    local pack = { 'npm', 'pack', spec, '--pack-destination', dir }
    if vim.fn.has('win32') == 1 then
      pack = vim.list_extend({ 'cmd.exe', '/c' }, pack)
    end
    run(pack)
    local tgz = vim.fs.joinpath(dir, 'sf-agentscript-parser-tree-sitter-' .. M.PIN .. '.tgz')
    run({ 'tar', '-xzf', tgz, '-C', dir })
    pkg = vim.fs.joinpath(dir, 'package')
  end

  local src = vim.fs.joinpath(pkg, 'src')
  local out = M.parser_path()
  vim.fn.mkdir(vim.fs.dirname(out), 'p')
  local cc = compiler:match('zig') and { compiler, 'cc' } or { compiler }
  local args = { '-O2', '-shared', '-Isrc', 'src/parser.c', 'src/scanner.c', '-o', out }
  if vim.fn.has('win32') == 0 then
    table.insert(args, 1, '-fPIC')
  end
  run(vim.list_extend(cc, args), pkg)

  local qdir = vim.fs.joinpath(M.queries_rtp(), 'queries', 'agentscript')
  vim.fn.mkdir(qdir, 'p')
  local scm = vim.fs.joinpath(pkg, 'queries', 'highlights.scm')
  assert(vim.uv.fs_stat(scm), 'highlights.scm missing from grammar package')
  vim.uv.fs_copyfile(scm, vim.fs.joinpath(qdir, 'highlights.scm'))

  registered = false
  if not M.register() then
    error('parser built but failed to register', 0)
  end
  return out
end

return M
