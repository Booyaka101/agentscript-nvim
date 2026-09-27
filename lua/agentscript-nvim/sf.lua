-- :AgentScriptValidate and :AgentScriptPreview, both through the Salesforce
-- CLI. Validate compiles on the org, not locally, so both need an
-- authenticated org.

local install = require('agentscript-nvim.install')

local M = {}

M.ns = vim.api.nvim_create_namespace('agentscript-sf')
local prompt_ns = vim.api.nvim_create_namespace('agentscript-sf-prompt')

M.VALIDATE_TIMEOUT_MS = 120000
M.START_TIMEOUT_MS = 120000
M.SEND_TIMEOUT_MS = 60000
M.END_TIMEOUT_MS = 60000
-- How long quitting Neovim waits for open previews to end.
M.EXIT_WAIT_MS = 10000

M.INSTALL_DOC =
  'https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm'

local function notify(msg, level)
  vim.notify('agentscript-nvim: ' .. msg, level or vim.log.levels.INFO)
end

--- sf's human-readable errors wrap across lines and start with »; flatten.
function M.one_line(s)
  return vim.trim(((s or ''):gsub('»', ''):gsub('%s+', ' ')))
end

local one_line = M.one_line

--- Full path of sf on PATH, or nil. On Windows exepath() follows 'shell',
--- and with a POSIX shell it returns npm's extensionless sh script, which
--- can't be spawned; ask for the .cmd first.
---@return string?
function M.exe()
  local exe = vim.fn.has('win32') == 1 and vim.fn.exepath('sf.cmd') or ''
  exe = exe ~= '' and exe or vim.fn.exepath('sf')
  return exe ~= '' and exe or nil
end

local resolved -- { exe = <sf on PATH>, prefix = <argv that runs it> }

--- Resolve the argv prefix that runs sf. On Windows sf is a .cmd shim, and
--- cmd.exe cuts an argument at its first newline and re-parses its quotes,
--- so run sf's own node entry point (from `sf version --verbose`) instead.
---@param on_done fun(prefix: string[]?, err: string?)
function M.resolve(on_done)
  local exe = M.exe()
  if not exe then
    on_done(nil, 'sf not found on PATH; install the Salesforce CLI: ' .. M.INSTALL_DOC)
    return
  end
  -- An sf update can move run.js.
  if resolved and resolved.exe == exe and vim.uv.fs_stat(resolved.prefix[#resolved.prefix]) then
    on_done(resolved.prefix)
    return
  end
  if vim.fn.has('win32') == 0 then
    resolved = { exe = exe, prefix = { exe } }
    on_done(resolved.prefix)
    return
  end
  install.system({ exe, 'version', '--verbose', '--json' }, {}, M.SEND_TIMEOUT_MS, function(res)
    local ok, v = pcall(vim.json.decode, res.stdout or '')
    local root = ok and type(v) == 'table' and v.rootPath
    local run
    for _, name in ipairs(root and { 'run.js', 'run' } or {}) do
      local p = vim.fs.joinpath(root, 'bin', name)
      if vim.uv.fs_stat(p) then
        run = p
        break
      end
    end
    if not run then
      local why = one_line(res.stderr)
      on_done(nil, "could not find sf's run.js via `sf version --verbose`" .. (why ~= '' and ': ' .. why or ''))
      return
    end
    local node = vim.fs.joinpath(root, 'bin', 'node.exe')
    resolved = { exe = exe, prefix = { vim.uv.fs_stat(node) and node or 'node', '--no-deprecation', run } }
    on_done(resolved.prefix)
  end)
end

--- The .agent files of the project's authoring bundles, or of the one called
--- `name`. Searches the package directories only, like sf.
---@param root string
---@param name? string
---@return string[]
local function find_agents(root, name)
  local project = install.read_json(vim.fs.joinpath(root, 'sfdx-project.json')) or {}
  local found = {}
  for _, pkg in ipairs(type(project.packageDirectories) == 'table' and project.packageDirectories or {}) do
    if type(pkg.path) == 'string' then
      local files = vim.fs.find(name and name .. '.agent' or function(n)
        return vim.endswith(n, '.agent')
      end, { path = vim.fs.joinpath(root, pkg.path), type = 'file', limit = math.huge })
      for _, file in ipairs(files) do
        local dir = vim.fs.dirname(file)
        if
          vim.fs.basename(file) == vim.fs.basename(dir) .. '.agent'
          and vim.fs.basename(vim.fs.dirname(dir)) == 'aiAuthoringBundles'
        then
          table.insert(found, file)
        end
      end
    end
  end
  return found
end

---@class agentscript.Bundle
---@field name string api name, which is also the directory name
---@field root string directory holding sfdx-project.json; sf runs from here
---@field file? string the .agent file, if found locally

--- The current buffer's path if it is a file, else nil.
local function buf_file()
  local path = vim.api.nvim_buf_get_name(0)
  return vim.bo.buftype == '' and path ~= '' and path or nil
end

--- Where to look for sfdx-project.json from the current buffer.
local function start_dir()
  local path, here = buf_file(), vim.b.agentscript_bundle
  return path and vim.fs.dirname(path) or here and here.root or vim.fn.getcwd()
end

--- Resolve a bundle from an explicit api name, from the current buffer's
--- path, …/aiAuthoringBundles/<Name>/<Name>.agent, or from the preview
--- buffer it is called in.
---@param name? string
---@return agentscript.Bundle? bundle, string? err
function M.bundle(name)
  if not name and vim.b.agentscript_bundle then
    return vim.b.agentscript_bundle
  end
  local file
  if not name then
    file = buf_file()
    if not file then
      return nil, 'this buffer has no file; pass the bundle name'
    end
    local dir = vim.fs.dirname(file)
    name = vim.fs.basename(dir)
    local meta = vim.fs.joinpath(dir, name .. '.bundle-meta.xml')
    if not vim.uv.fs_stat(meta) then
      return nil, 'not an authoring bundle: no ' .. meta
    end
  end
  local start = start_dir()
  local root = vim.fs.root(start, 'sfdx-project.json')
  if not root then
    return nil, 'no sfdx-project.json above ' .. start .. '; sf agent commands run inside a Salesforce DX project'
  end
  return { name = name, root = root, file = file or find_agents(root, name)[1] }
end

--- Completion for the [name] argument: the bundles in the project.
---@param arglead string
---@return string[]
function M.complete(arglead)
  local root = vim.fs.root(start_dir(), 'sfdx-project.json')
  local names = {}
  for _, file in ipairs(root and find_agents(root) or {}) do
    local name = vim.fs.basename(vim.fs.dirname(file))
    if vim.startswith(name, arglead) then
      names[name] = true
    end
  end
  names = vim.tbl_keys(names)
  table.sort(names)
  return names
end

--- Bundles are only unique within a project.
---@param bundle agentscript.Bundle
local function key(bundle)
  return vim.fs.joinpath(bundle.root, bundle.name)
end

--- sf --json prints one JSON document, possibly after other output.
local function decode(stdout)
  for _, s in ipairs({ stdout, ('\n' .. stdout):match('\n({.*)') }) do
    local ok, v = pcall(vim.json.decode, s)
    if ok and type(v) == 'table' then
      return v
    end
  end
end

--- Run `sf <args> --json` from the bundle's project. Calls on_done(result)
--- on success, or on_done(nil, one-line message, decoded error envelope,
--- timed_out).
---@param bundle agentscript.Bundle
---@param args string[]
---@param timeout_ms integer
---@param on_done fun(result: table?, err: string?, envelope: table?, timed_out: boolean?)
function M.run(bundle, args, timeout_ms, on_done)
  M.resolve(function(prefix, err)
    if not prefix then
      on_done(nil, err)
      return
    end
    local cmd = vim.list_extend(vim.list_extend({}, prefix), args)
    table.insert(cmd, '--json')
    local org = require('agentscript-nvim').opts.target_org
    if org then
      vim.list_extend(cmd, { '--target-org', org })
    end
    install.system(cmd, { cwd = bundle.root }, timeout_ms, function(res)
      local env = decode(res.stdout or '')
      if res.code == 0 and env and type(env.result) == 'table' then
        on_done(env.result)
      elseif res.code == 124 then
        on_done(nil, ('sf %s %s'):format(table.concat(args, ' ', 1, 3), res.stderr), nil, true)
      else
        local msg = env and type(env.message) == 'string' and env.message or res.stderr
        on_done(nil, one_line(msg ~= '' and msg or ('sf exited with code ' .. res.code)), env)
      end
    end)
  end)
end

--- Diagnostics for a failed validate: data.errors from sf's error envelope,
--- else the `[Ln X, Col Y]` suffix on each line of its message.
---@return vim.Diagnostic[]?
function M.diagnostics(bufnr, envelope)
  local entries = {}
  local errors = envelope and type(envelope.data) == 'table' and envelope.data.errors
  if type(errors) == 'table' and #errors > 0 then
    for _, e in ipairs(errors) do
      if type(e.lineStart) == 'number' and type(e.colStart) == 'number' then
        table.insert(entries, {
          text = ('%s: %s'):format(e.errorType, e.description),
          lnum = e.lineStart,
          col = e.colStart,
          end_lnum = e.lineEnd,
          end_col = e.colEnd,
        })
      end
    end
  elseif envelope and type(envelope.message) == 'string' then
    for line in envelope.message:gmatch('[^\r\n]+') do
      local text, l, c = line:match('^(.-)%s*%[Ln (%d+), Col (%d+)%]%s*$')
      if text then
        table.insert(entries, { text = text, lnum = tonumber(l), col = tonumber(c) })
      end
    end
  end
  if #entries == 0 then
    return
  end

  vim.fn.bufload(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- sf reports 0-based lines and 0-based columns counted in characters
  -- (UTF-16 code units, from the JS compiler); diagnostics want byte columns.
  local function pos(lnum, col)
    lnum = math.max(0, math.min(lnum, #lines - 1))
    local line = lines[lnum + 1] or ''
    local ok, byte = pcall(vim.str_byteindex, line, 'utf-16', col, false)
    return lnum, ok and byte or math.min(col, #line)
  end
  local diags = {}
  for _, e in ipairs(entries) do
    local lnum, col = pos(e.lnum, e.col)
    local d = {
      bufnr = bufnr,
      lnum = lnum,
      col = col,
      severity = vim.diagnostic.severity.ERROR,
      source = 'sf agent validate',
      message = e.text,
    }
    if type(e.end_lnum) == 'number' and type(e.end_col) == 'number' then
      d.end_lnum, d.end_col = pos(e.end_lnum, e.end_col)
    end
    table.insert(diags, d)
  end
  return diags
end

-- The latest validate per bundle; results of earlier ones are dropped.
local validating = {}

--- :AgentScriptValidate [name]
---@param name? string
function M.validate(name)
  local bundle, err = M.bundle(name)
  if not bundle then
    notify(err, vim.log.levels.ERROR)
    return
  end
  local k = key(bundle)
  local gen = (validating[k] or 0) + 1
  validating[k] = gen
  local bufnr = bundle.file and vim.fn.bufadd(bundle.file)
  local title = 'sf agent validate ' .. bundle.name
  if bufnr and vim.bo[bufnr].modified then
    notify(bundle.name .. ' has unsaved changes; sf validates the file on disk', vim.log.levels.WARN)
  end
  notify('validating ' .. bundle.name .. ' on the org ...')
  M.run(
    bundle,
    { 'agent', 'validate', 'authoring-bundle', '--api-name', bundle.name },
    M.VALIDATE_TIMEOUT_MS,
    function(_, msg, envelope)
      if validating[k] ~= gen then
        return
      end
      local ours = vim.fn.getqflist({ title = 0 }).title == title
      if not msg then
        if bufnr then
          vim.diagnostic.reset(M.ns, bufnr)
        end
        if ours then
          vim.fn.setqflist({}, 'r', { title = title, items = {} })
        end
        notify('validated ' .. bundle.name)
        return
      end
      local diags = bufnr and M.diagnostics(bufnr, envelope)
      if not diags then
        notify(msg, vim.log.levels.ERROR)
        return
      end
      vim.diagnostic.set(M.ns, bufnr, diags)
      vim.fn.setqflist({}, ours and 'r' or ' ', { title = title, items = vim.diagnostic.toqflist(diags) })
      notify(('%s: %d error%s'):format(bundle.name, #diags, #diags == 1 and '' or 's'), vim.log.levels.ERROR)
    end
  )
end

-- Preview sessions by project and bundle name.
M.sessions = {}

local exiting = false

local PROMPT = '> '

-- The prompt row is an extmark so it follows the user's edits above it.
local function prompt_row(s)
  return vim.api.nvim_buf_get_extmark_by_id(s.buf, prompt_ns, s.mark, {})[1]
end

local function set_prompt_row(s, row)
  s.mark = vim.api.nvim_buf_set_extmark(s.buf, prompt_ns, row, 0, { id = s.mark, right_gravity = false })
end

local function append(s, lines)
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  local row = prompt_row(s)
  vim.api.nvim_buf_set_lines(s.buf, row, row, false, lines)
  set_prompt_row(s, row + #lines)
end

local function prefixed(label, text)
  local lines = vim.split(text, '\r?\n')
  lines[1] = label .. ': ' .. lines[1]
  return lines
end

local function send(s)
  local row = prompt_row(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, row, -1, false)
  lines[1] = (lines[1] or ''):gsub('^>%s?', '')
  local text = table.concat(lines, '\n')
  if vim.trim(text) == '' then
    return
  end
  if s.busy then
    notify('still waiting for the agent', vim.log.levels.WARN)
    return
  end
  s.busy = true
  local user = prefixed('user', text)
  vim.api.nvim_buf_set_lines(s.buf, row, -1, false, vim.list_extend(vim.list_extend({}, user), { PROMPT }))
  set_prompt_row(s, row + #user)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(s.buf), #PROMPT })
  M.run(
    s.bundle,
    { 'agent', 'preview', 'send', '--authoring-bundle', s.bundle.name, '--session-id', s.id, '--utterance', text },
    M.SEND_TIMEOUT_MS,
    function(result, msg)
      s.busy = false
      if not result then
        append(s, prefixed('error', msg))
        return
      end
      local out = {}
      for _, m in ipairs(type(result.messages) == 'table' and result.messages or {}) do
        if type(m.message) == 'string' then
          vim.list_extend(out, prefixed(m.role or 'agent', m.message))
        end
      end
      append(s, #out > 0 and out or { 'agent: (no reply)' })
    end
  )
end

---@param on_done? fun()
local function end_session(s, on_done)
  if s.ended then
    return
  end
  s.ended = true
  if M.sessions[key(s.bundle)] == s then
    M.sessions[key(s.bundle)] = nil
  end
  M.run(
    s.bundle,
    { 'agent', 'preview', 'end', '--authoring-bundle', s.bundle.name, '--session-id', s.id },
    M.END_TIMEOUT_MS,
    function(result, msg)
      if result then
        notify(('ended preview of %s, traces in %s'):format(s.bundle.name, tostring(result.tracesPath)))
      else
        notify('ending preview of ' .. s.bundle.name .. ' failed: ' .. msg, vim.log.levels.WARN)
      end
      if on_done then
        on_done()
      end
    end
  )
end

local function open(s, live)
  local buf = vim.api.nvim_create_buf(false, true)
  s.buf = buf
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      end_session(s)
    end,
  })
  vim.api.nvim_buf_set_name(buf, 'agentscript-preview://' .. key(s.bundle))
  vim.bo[buf].bufhidden = 'wipe'
  -- Undo would take back transcript lines under the prompt mark.
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = 'agentscript-preview'
  vim.b[buf].agentscript_bundle = s.bundle
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    ('# %s preview, %s actions. <CR> sends the prompt.'):format(s.bundle.name, live and 'live' or 'simulated'),
    PROMPT,
  })
  set_prompt_row(s, 1)
  vim.api.nvim_open_win(buf, true, { split = 'below' })
  vim.api.nvim_win_set_cursor(0, { 2, #PROMPT })
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    send(s)
  end, { buffer = buf, desc = 'Send the prompt to the agent' })
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('agentscript-sf', { clear = true }),
  callback = function()
    exiting = true
    local pending = 0
    local function done()
      pending = pending - 1
    end
    for _, s in pairs(M.sessions) do
      pending = pending + 1
      if s.id then
        end_session(s, done)
      else
        s.on_started = done
      end
    end
    vim.wait(M.EXIT_WAIT_MS, function()
      return pending == 0
    end, 50)
  end,
})

--- :AgentScriptPreview[!] [name]
---@param name? string
---@param live? boolean use live actions instead of simulated ones
function M.preview(name, live)
  local bundle, err = M.bundle(name)
  if not bundle then
    notify(err, vim.log.levels.ERROR)
    return
  end
  local k = key(bundle)
  local s = M.sessions[k]
  if s then
    if not s.buf then
      notify('preview of ' .. bundle.name .. ' is still starting')
      return
    end
    -- bufhidden=wipe: while the session lives, its buffer is in a window.
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(s.buf)[1])
    return
  end
  s = { bundle = bundle }
  M.sessions[k] = s
  notify('starting preview of ' .. bundle.name .. ' ...')
  M.run(
    bundle,
    {
      'agent',
      'preview',
      'start',
      '--authoring-bundle',
      bundle.name,
      live and '--use-live-actions' or '--simulate-actions',
    },
    M.START_TIMEOUT_MS,
    function(result, msg, _, timed_out)
      if not result or type(result.sessionId) ~= 'string' then
        M.sessions[k] = nil
        msg = msg or 'sf agent preview start returned no sessionId'
        notify(msg .. (timed_out and '; is Agentforce turned on in the org?' or ''), vim.log.levels.ERROR)
        if s.on_started then
          s.on_started()
        end
        return
      end
      s.id = result.sessionId
      if exiting then
        end_session(s, s.on_started)
        return
      end
      local ok, open_err = pcall(open, s, live)
      if not ok then
        if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
          vim.api.nvim_buf_delete(s.buf, { force = true })
        end
        end_session(s)
        notify('could not open the preview of ' .. bundle.name .. ': ' .. open_err, vim.log.levels.ERROR)
      end
    end
  )
end

return M
