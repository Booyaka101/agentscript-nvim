-- :AgentScriptValidate and :AgentScriptPreview, both through the Salesforce
-- CLI. Validate compiles on the org, not locally, so both need an
-- authenticated org.

local install = require('agentscript-nvim.install')

local M = {}

M.ns = vim.api.nvim_create_namespace('agentscript-sf')

M.VALIDATE_TIMEOUT_MS = 120000
M.START_TIMEOUT_MS = 120000
M.SEND_TIMEOUT_MS = 60000
M.END_TIMEOUT_MS = 60000

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
  if resolved and resolved.exe == exe then
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
      on_done(nil, "could not find sf's run.js via `sf version --verbose`: " .. one_line(res.stderr))
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
      vim.list_extend(
        found,
        vim.fs.find(function(n, dir)
          local bundle = vim.fs.basename(dir)
          return n == bundle .. '.agent'
            and (not name or bundle == name)
            and vim.fs.basename(vim.fs.dirname(dir)) == 'aiAuthoringBundles'
        end, { path = vim.fs.joinpath(root, pkg.path), type = 'file', limit = name and 1 or math.huge })
      )
    end
  end
  return found
end

---@class agentscript.Bundle
---@field name string api name, which is also the directory name
---@field root string directory holding sfdx-project.json; sf runs from here
---@field file? string the .agent file, if found locally

--- Resolve a bundle from an explicit api name, or from the current buffer's
--- path, …/aiAuthoringBundles/<Name>/<Name>.agent.
---@param name? string
---@return agentscript.Bundle? bundle, string? err
function M.bundle(name)
  local path = vim.api.nvim_buf_get_name(0)
  local file
  if not name then
    if path == '' then
      return nil, 'this buffer has no file; pass the bundle name'
    end
    local dir = vim.fs.dirname(path)
    if vim.fn.glob(vim.fs.joinpath(dir, '*.bundle-meta.xml')) == '' then
      return nil, 'not an authoring bundle: no *.bundle-meta.xml in ' .. dir
    end
    name, file = vim.fs.basename(dir), path
  end
  local start = path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd()
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
  local path = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd(), 'sfdx-project.json')
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

--- Run `sf <args> --json` from the bundle's project. Calls on_done(result)
--- on success, or on_done(nil, one-line message, decoded error envelope).
---@param bundle agentscript.Bundle
---@param args string[]
---@param timeout_ms integer
---@param on_done fun(result: table?, err: string?, envelope: table?)
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
      local ok, env = pcall(vim.json.decode, (res.stdout or ''):match('{.*') or '')
      env = ok and type(env) == 'table' and env or nil
      if res.code == 0 and env and type(env.result) == 'table' then
        on_done(env.result)
      elseif res.code == 124 then
        on_done(nil, ('sf %s %s'):format(table.concat(args, ' ', 1, 3), res.stderr))
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

--- :AgentScriptValidate [name]
---@param name? string
function M.validate(name)
  local bundle, err = M.bundle(name)
  if not bundle then
    notify(err, vim.log.levels.ERROR)
    return
  end
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
      if not msg then
        if bufnr then
          vim.diagnostic.reset(M.ns, bufnr)
        end
        if vim.fn.getqflist({ title = 0 }).title == title then
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
      vim.fn.setqflist({}, ' ', { title = title, items = vim.diagnostic.toqflist(diags) })
      notify(('%s: %d error%s'):format(bundle.name, #diags, #diags == 1 and '' or 's'), vim.log.levels.ERROR)
    end
  )
end

-- Preview sessions by bundle name.
M.sessions = {}

local PROMPT = '> '

local function append(s, lines)
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  vim.api.nvim_buf_set_lines(s.buf, s.prompt_row, s.prompt_row, false, lines)
  s.prompt_row = s.prompt_row + #lines
end

local function prefixed(label, text)
  local lines = vim.split(text, '\r?\n')
  lines[1] = label .. ': ' .. lines[1]
  return lines
end

local function send(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, s.prompt_row, -1, false)
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
  vim.api.nvim_buf_set_lines(s.buf, s.prompt_row, -1, false, vim.list_extend(vim.list_extend({}, user), { PROMPT }))
  s.prompt_row = s.prompt_row + #user
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
  M.sessions[s.bundle.name] = nil
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

local function open(bundle, id, live)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'agentscript-preview://' .. bundle.name)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'agentscript-preview'
  local s = { bundle = bundle, id = id, buf = buf, prompt_row = 1 }
  M.sessions[bundle.name] = s
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    ('# %s preview, %s actions. <CR> sends the prompt.'):format(bundle.name, live and 'live' or 'simulated'),
    PROMPT,
  })
  vim.api.nvim_open_win(buf, true, { split = 'below' })
  vim.api.nvim_win_set_cursor(0, { 2, #PROMPT })
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    send(s)
  end, { buffer = buf, desc = 'Send the prompt to the agent' })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      end_session(s)
    end,
  })
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('agentscript-sf', { clear = true }),
  callback = function()
    local pending = 0
    for _, s in pairs(M.sessions) do
      if s.id then
        pending = pending + 1
        end_session(s, function()
          pending = pending - 1
        end)
      end
    end
    vim.wait(M.END_TIMEOUT_MS + 1000, function()
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
  local s = M.sessions[bundle.name]
  if s then
    if s.buf then
      -- bufhidden=wipe: while the session lives, its buffer is in a window.
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(s.buf)[1])
    else
      notify('preview of ' .. bundle.name .. ' is still starting')
    end
    return
  end
  M.sessions[bundle.name] = {}
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
    function(result, msg)
      M.sessions[bundle.name] = nil
      if not result or type(result.sessionId) ~= 'string' then
        notify(msg or 'sf agent preview start returned no sessionId', vim.log.levels.ERROR)
        return
      end
      open(bundle, result.sessionId, live)
    end
  )
end

return M
