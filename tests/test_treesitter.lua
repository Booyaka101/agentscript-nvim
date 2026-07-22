-- Headless test for tree-sitter support.
-- Run from the repo root:  nvim -l tests/test_treesitter.lua
--
-- Builds the official grammar if needed (uses scratch/ts/package sources and,
-- when no system C compiler exists, the portable zig in scratch/), then
-- asserts: parser loads, highlighter attaches, official highlights query
-- yields captures, sample parses clean, broken yields an ERROR node.

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
if not ts.available() then
  local opts = { src_dir = vim.fs.joinpath(root, 'scratch', 'ts', 'package') }
  local have_system_cc = vim.fn.executable('cc') == 1
    or vim.fn.executable('gcc') == 1
    or vim.fn.executable('clang') == 1
    or vim.fn.executable('zig') == 1
  if not have_system_cc then
    local zig = vim.fn.glob(vim.fs.joinpath(root, 'scratch', 'zig-extract', '*', 'zig.exe'))
    if zig == '' then
      -- Bootstrap: extract the pre-downloaded portable zig (bsdtar reads zip).
      local zip = vim.fs.joinpath(root, 'scratch', 'zig.zip')
      assert(vim.uv.fs_stat(zip), 'no C compiler on PATH and no scratch zig.zip; download zig first')
      local dest = vim.fs.joinpath(root, 'scratch', 'zig-extract')
      vim.fn.mkdir(dest, 'p')
      print('extracting portable zig ...')
      local res = vim.system({ 'tar', '-xf', zip, '-C', dest }):wait()
      assert(res.code == 0, 'zig extraction failed: ' .. (res.stderr or ''))
      zig = vim.fn.glob(vim.fs.joinpath(dest, '*', 'zig.exe'))
      assert(zig ~= '', 'zig.exe not found after extraction')
    end
    opts.compiler = zig
  end
  print('building parser (compiler: ' .. (opts.compiler or 'system') .. ') ...')
  local built = ts.build(opts)
  print('built: ' .. built)
end
check(ts.available(), 'parser + queries installed')

if standalone then
  require('agentscript-nvim').setup({ cmd = { 'node', '--version' } }) -- LSP irrelevant here
end

vim.cmd.edit(vim.fs.joinpath(root, 'tests', 'fixtures', 'sample.agent'))
local sample_buf = vim.api.nvim_get_current_buf()
check(vim.treesitter.highlighter.active[sample_buf] ~= nil, 'tree-sitter highlighter active on sample.agent')

local parser = vim.treesitter.get_parser(sample_buf, 'agentscript')
local tree = parser:parse()[1]
check(tree ~= nil and tree:root() ~= nil, 'sample.agent parses to a tree')
check(not tree:root():has_error(), 'sample.agent parse tree has no ERROR nodes')

local query = vim.treesitter.query.get('agentscript', 'highlights')
check(query ~= nil, 'official highlights query loads')
local captures = 0
if query then
  for _ in query:iter_captures(tree:root(), sample_buf) do
    captures = captures + 1
  end
end
check(captures >= 10, 'highlights query yields captures', 'got ' .. captures)

vim.cmd.edit(vim.fs.joinpath(root, 'tests', 'fixtures', 'broken.agent'))
local broken_buf = vim.api.nvim_get_current_buf()
local btree = vim.treesitter.get_parser(broken_buf, 'agentscript'):parse()[1]
check(btree:root():has_error(), 'broken.agent parse tree contains an ERROR node')

print(failures == 0 and 'TREESITTER TEST PASSED' or (failures .. ' TREESITTER TEST(S) FAILED'))
if standalone then
  os.exit(failures == 0 and 0 or 1)
end
return failures
