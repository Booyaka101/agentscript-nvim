-- Managed install of the AgentScript language server.
--
-- Strategy: measure, don't pin. `:AgentScriptInstall` resolves the currently
-- published `@sf-agentscript/lsp-server` from the npm registry, installs it
-- with NO overrides, and verifies it by actually speaking LSP to it (spawn +
-- `initialize` + wait for `result.capabilities`). On a first install only,
-- a failed verification falls back to the legacy recipe in `M.PINS` — the
-- 2.2.30 + `@sf-agentscript/language`@2.8.4 override that worked around the
-- launch-week publish defect (salesforce/agentscript#73: `agentforce-dialect`
-- pinned a stale `language` and crashed at import with "variantMatch is not a
-- function"). The override must never be applied pre-emptively: on a current
-- release it would DOWNGRADE `@sf-agentscript/language` by many minor
-- versions. The outcome of every install is recorded in
-- `<dir>/agentscript-nvim-state.json` for `:checkhealth`.

local M = {}

local PKG = '@sf-agentscript/lsp-server'

-- Legacy fallback recipe only — used after a fresh install fails verification
-- (or offline, when the registry cannot be consulted). Never the primary path.
M.PINS = {
  lsp_server = '2.2.30',
  language_override = '2.8.4',
}

M.RESOLVE_TIMEOUT_MS = 15000
M.VERIFY_TIMEOUT_MS = 15000
M.INSTALL_TIMEOUT_MS = 120000
M.CLEANUP_TIMEOUT_MS = 5000

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agentscript-nvim', 'server')
end

local function generation_dir(name)
  if name == '.' then
    return M.dir() -- pre-versioned installs remain usable and can be rolled back to
  end
  if type(name) == 'string' and name:match('^versions/%d+%-%d+$') then
    return vim.fs.joinpath(M.dir(), name)
  end
end

function M.active()
  local path = vim.fs.joinpath(M.dir(), 'active.json')
  if not vim.uv.fs_stat(path) then
    return
  end
  local active = M.read_json(path)
  if
    not active
    or not generation_dir(active.current)
    or (active.previous ~= nil and not generation_dir(active.previous))
  then
    return nil,
      'invalid active server pointer: ' .. path .. '; restore its current/previous generation names before retrying'
  end
  return active
end

function M.server_js(dir)
  if not dir then
    local active = M.active()
    if vim.uv.fs_stat(vim.fs.joinpath(M.dir(), 'active.json')) then
      dir = active and generation_dir(active.current)
      if not dir then
        return
      end
    else
      dir = M.dir()
    end
  end
  local p = vim.fs.joinpath(dir, 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
  local stat = vim.uv.fs_stat(p)
  if stat and stat.type == 'file' then
    return p
  end
end

--- Returns the LSP cmd for the managed install, or nil if not installed.
function M.cmd()
  local js = M.server_js()
  if js and vim.fn.executable('node') == 1 then
    return { 'node', js, '--stdio' }
  end
end

---@return string?
function M.read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return
  end
  local s = f:read('*a')
  f:close()
  return s
end

--- Decode a JSON object from a file, or nil if missing or malformed.
--- Shared with treesitter.lua, which keeps its own state file.
---@return table?
function M.read_json(path)
  local ok, t = pcall(vim.json.decode, M.read_file(path))
  if ok and type(t) == 'table' then
    return t
  end
end

--- Write via a temp file and a rename, so a reader never sees half a file.
---@return boolean? ok, string? err
function M.write_file(path, text)
  local tmp = ('%s.%d.tmp'):format(path, vim.uv.os_getpid())
  local f, err = io.open(tmp, 'wb')
  if not f then
    return nil, err
  end
  local ok, werr = f:write(text)
  local closed, cerr = f:close()
  if not ok or not closed then
    os.remove(tmp)
    return nil, werr or cerr
  end
  local rok, rerr = vim.uv.fs_rename(tmp, path)
  if not rok then
    os.remove(tmp)
    return nil, rerr
  end
  return true
end

---@return boolean? ok, string? err
function M.write_json(path, t)
  return M.write_file(path, vim.json.encode(t))
end

--- Active server state, plus a rejected attempt if the active server was kept.
---@return { version: string, path: string, verified: boolean, reason: string, installedAt: string }?
function M.state()
  local active, err = M.active()
  if err then
    return
  end
  local dir = active and generation_dir(active.current) or M.dir()
  local state = dir and M.read_json(vim.fs.joinpath(dir, 'agentscript-nvim-state.json'))
  local attempt = M.read_json(vim.fs.joinpath(M.dir(), 'last-attempt.json'))
  if state then
    if attempt and not attempt.verified and attempt.current == (active and active.current or '.') then
      state.rejected = attempt
    end
    return state
  end
  if attempt and not attempt.verified and attempt.current == (active and active.current or '.') then
    return attempt
  end
end

local function write_state(dir, state)
  state.installedAt = os.date('!%Y-%m-%dT%H:%M:%SZ')
  return M.write_json(vim.fs.joinpath(dir, 'agentscript-nvim-state.json'), state)
end

function M.npm_install_cmd()
  local cmd = { 'npm', 'install', '--no-audit', '--no-fund', '--loglevel=error' }
  if vim.fn.has('win32') == 1 then
    -- npm is a .cmd shim on Windows; spawn through cmd.exe to be safe.
    return vim.list_extend({ 'cmd.exe', '/c' }, cmd)
  end
  return cmd
end

--- vim.system() with a timeout that also holds for npm on Windows. Calls
--- on_exit(res) on the main loop, once; on timeout res.code is 124 and the
--- process tree is killed.
---@param cmd string[]
---@param opts vim.SystemOpts
---@param timeout_ms integer
---@param on_exit fun(res: vim.SystemCompleted)
function M.system(cmd, opts, timeout_ms, on_exit)
  local settled = false
  local timer = assert(vim.uv.new_timer())
  local timed_out, exited, killed = false, false, false
  local function settle(res)
    if settled then
      return
    end
    settled = true
    timer:stop()
    timer:close()
    vim.schedule(function()
      on_exit(res)
    end)
  end
  -- A separate Unix process group lets us stop npm's children, not just its shell.
  opts = vim.tbl_extend('force', opts, { detach = vim.fn.has('win32') == 0 })
  local function timeout_result(unsafe)
    settle({
      code = 124,
      signal = 0,
      stdout = '',
      stderr = ('timed out after %.3gs'):format(timeout_ms / 1000),
      cleanup_pending = unsafe,
    })
  end
  local function stopped()
    if exited and killed then
      timeout_result(false)
    end
  end
  local ok, proc = pcall(vim.system, cmd, opts, function(res)
    exited = true
    if timed_out then
      stopped()
    else
      settle(res)
    end
  end)
  if not ok then
    settle({ code = -1, signal = 0, stdout = '', stderr = tostring(proc) })
    return
  end
  -- Not vim.system's own timeout: on Windows that kills cmd.exe only, and the
  -- exit callback then waits for npm's node child (~70s offline) to close
  -- the pipe.
  timer:start(timeout_ms, 0, function()
    timed_out = true
    timer:start(M.CLEANUP_TIMEOUT_MS, 0, function()
      timeout_result(true)
    end)
    vim.schedule(function()
      if vim.fn.has('win32') == 1 then
        local spawned = pcall(vim.system, { 'taskkill', '/T', '/F', '/PID', tostring(proc.pid) }, {}, function(res)
          killed = res.code == 0
          stopped()
        end)
        if not spawned then
          timeout_result(true)
        end
      else
        killed = not not vim.uv.kill(-proc.pid, 9)
        stopped()
      end
    end)
  end)
end

-- A published version, e.g. 3.2.1 or 3.3.0-beta.1.
M.VERSION_PATTERN = '^%d+%.%d+%.%d+[%w%.%+%-]*$'

--- Ask the npm registry for the currently published version (async, never
--- blocks the UI thread). Calls on_done with the version string, or nil on
--- any failure (no npm, no network, timeout, unparseable output).
---@param on_done fun(version: string?, cleanup_pending: boolean?)
---@param pkg? string defaults to the language server package
function M.resolve_latest(on_done, pkg)
  local cmd = { 'npm', 'view', pkg or PKG, 'version', '--json' }
  if vim.fn.has('win32') == 1 then
    cmd = vim.list_extend({ 'cmd.exe', '/c' }, cmd)
  end
  M.system(cmd, {}, M.RESOLVE_TIMEOUT_MS, function(res)
    local ok, v = pcall(vim.json.decode, vim.trim(res.stdout or ''))
    on_done(
      res.code == 0 and ok and type(v) == 'string' and v:match(M.VERSION_PATTERN) and v or nil,
      res.cleanup_pending
    )
  end)
end

--- Verify an installed server by speaking LSP to it: spawn `node <js_path>
--- --stdio`, send one framed `initialize` request and wait for a response
--- carrying `result.capabilities`. A crash-on-import server exits instead;
--- its stderr error line is captured into `detail` (that is what the user
--- needs to see). The child is always killed — on success, failure and
--- timeout alike — so no orphan node process is left behind.
---@param js_path string
---@param on_done fun(ok: boolean, detail: string)
---@param timeout_ms? integer defaults to M.VERIFY_TIMEOUT_MS (15s)
function M.verify(js_path, on_done, timeout_ms)
  timeout_ms = timeout_ms or M.VERIFY_TIMEOUT_MS
  local stdout_buf, stderr_buf = '', ''
  local done = false
  local exited, emitted, outcome, description = false, false, false, ''
  local proc
  local timer = vim.uv.new_timer()
  local t0 = vim.uv.hrtime()

  local function emit(unsafe)
    if emitted then
      return
    end
    emitted = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      on_done(outcome and not unsafe, description, unsafe)
    end)
  end

  local function finish(ok, detail)
    if done then
      return
    end
    done, outcome, description = true, ok, detail
    if exited or not proc then
      emit(false)
      return
    end
    -- Do not delete staging or release the lock while node still has files open.
    timer:stop()
    timer:start(M.CLEANUP_TIMEOUT_MS, 0, function()
      emit(true)
    end)
    pcall(proc.kill, proc, 9)
  end

  local function stderr_line()
    return stderr_buf:match('[^\r\n]*Error[^\r\n]*') or stderr_buf:match('[^\r\n]+')
  end

  -- Scan the accumulated stdout for complete Content-Length-framed messages;
  -- notifications (logMessage etc.) may arrive before the initialize response.
  local function scan_stdout()
    while true do
      local header_end = stdout_buf:find('\r\n\r\n', 1, true)
      if not header_end then
        return
      end
      local len = tonumber(stdout_buf:sub(1, header_end - 1):lower():match('content%-length:%s*(%d+)'))
      if not len then
        finish(false, 'malformed LSP framing from server')
        return
      end
      local body_start = header_end + 4
      if #stdout_buf < body_start + len - 1 then
        return
      end
      local body = stdout_buf:sub(body_start, body_start + len - 1)
      stdout_buf = stdout_buf:sub(body_start + len)
      local ok, msg = pcall(vim.json.decode, body)
      if
        ok
        and type(msg) == 'table'
        and msg.id == 1
        and type(msg.result) == 'table'
        and type(msg.result.capabilities) == 'table'
      then
        finish(true, ('initialize answered in %dms'):format(math.floor((vim.uv.hrtime() - t0) / 1e6)))
        return
      end
      if ok and type(msg) == 'table' and msg.id == 1 then
        finish(false, 'initialize response did not contain capabilities')
        return
      end
    end
  end

  local spawn_ok, err = pcall(function()
    proc = vim.system({ 'node', js_path, '--stdio' }, {
      stdin = true,
      stdout = function(_, data)
        if data and not done then
          stdout_buf = stdout_buf .. data
          if #stdout_buf > 1024 * 1024 then
            finish(false, 'server exceeded verification output limit')
            return
          end
          scan_stdout()
        end
      end,
      stderr = function(_, data)
        if data and #stderr_buf < 8192 then
          stderr_buf = stderr_buf .. data
        end
      end,
    }, function(res)
      exited = true
      if done then
        emit(false)
      else
        finish(false, stderr_line() or ('server exited with code ' .. tostring(res.code) .. ' before answering'))
      end
    end)
  end)
  if not spawn_ok then
    finish(false, 'failed to spawn node: ' .. tostring(err))
    return
  end

  local request = vim.json.encode({
    jsonrpc = '2.0',
    id = 1,
    method = 'initialize',
    params = {
      processId = vim.uv.os_getpid(),
      rootUri = vim.NIL,
      capabilities = vim.empty_dict(),
    },
  })
  local wrote, write_err = pcall(proc.write, proc, ('Content-Length: %d\r\n\r\n%s'):format(#request, request))
  if not wrote then
    finish(false, 'cannot send initialize: ' .. tostring(write_err))
    return
  end

  timer:start(timeout_ms, 0, function()
    finish(false, ('verify timed out after %dms'):format(timeout_ms))
  end)
end

local function callback(on_done)
  return on_done
    or function(ok, msg)
      vim.notify('agentscript-nvim: ' .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
end

-- Exclusive across Neovim processes, not just repeated commands in one session.
-- A crash leaves the lock for explicit recovery rather than risking a live npm child.
local function lock(on_done)
  local dir = M.dir()
  local made, err = pcall(vim.fn.mkdir, dir, 'p')
  if not made then
    on_done(false, 'cannot create install directory: ' .. tostring(err))
    return
  end
  local path = vim.fs.joinpath(dir, 'install.lock')
  local fd, open_err = vim.uv.fs_open(path, 'wx', 384)
  if not fd then
    on_done(
      false,
      'install/rollback unavailable: '
        .. tostring(open_err)
        .. '. If an earlier Neovim crashed, confirm its npm/node children have stopped before removing '
        .. path
    )
    return
  end
  vim.uv.fs_write(fd, tostring(vim.uv.os_getpid()), 0)
  vim.uv.fs_close(fd)
  local finished = false
  return function(ok, msg, retain_lock)
    if finished then
      return
    end
    finished = true
    if retain_lock then
      msg = msg .. '; process cleanup unconfirmed, lock retained: ' .. path
    else
      vim.uv.fs_unlink(path)
    end
    on_done(ok, msg)
  end
end

local function activate(current, previous)
  local ok, err = M.write_json(vim.fs.joinpath(M.dir(), 'active.json'), { current = current, previous = previous })
  if ok then
    -- Activation has committed. A config error must not leave the install locked.
    local configured, config_err = pcall(function()
      local plugin = require('agentscript-nvim')
      vim.lsp.config('agentscript', { cmd = plugin.resolve_cmd(plugin.opts) })
    end)
    if not configured then
      vim.notify(
        'agentscript-nvim: server activated; reopen Neovim to refresh LSP config: ' .. tostring(config_err),
        vim.log.levels.WARN
      )
    end
  end
  return ok, err
end

--- Install into an immutable generation. Only a verified server can replace
--- active.json; existing clients keep their old command and files.
function M.install(on_done)
  on_done = callback(on_done)
  if vim.fn.executable('npm') == 0 or vim.fn.executable('node') == 0 then
    on_done(false, 'node/npm not found on PATH; install Node.js first')
    return
  end
  local finish = lock(on_done)
  if not finish then
    return
  end
  local old, pointer_err = M.active()
  if pointer_err then
    finish(false, pointer_err)
    return
  end
  local previous = old and old.current or (M.server_js() and '.')
  local function result(ok, state, msg, retain_lock)
    state.installedAt = os.date('!%Y-%m-%dT%H:%M:%SZ')
    local active = M.active()
    state.current = active and active.current or '.'
    local saved, err = M.write_json(vim.fs.joinpath(M.dir(), 'last-attempt.json'), state)
    if not saved then
      msg = msg .. '; could not record attempt: ' .. tostring(err)
    end
    if not ok and M.server_js() then
      msg = msg .. '; upgrade rejected, previous version retained'
    end
    finish(ok, msg, retain_lock)
  end
  local function attempt(version, with_override, path, on_result)
    local name = ('versions/%d-%d'):format(vim.uv.os_getpid(), vim.uv.hrtime())
    local dir = generation_dir(name)
    local made, err = pcall(vim.fn.mkdir, dir, 'p')
    if not made then
      on_result(false, 'cannot create staging directory: ' .. tostring(err))
      return
    end
    local function reject(detail)
      vim.fn.delete(dir, 'rf') -- only this attempt's unique, unselected generation
      on_result(false, detail)
    end
    local manifest = { name = 'agentscript-nvim-server', private = true, dependencies = { [PKG] = version } }
    if with_override then
      manifest.overrides = { ['@sf-agentscript/language'] = M.PINS.language_override }
    end
    local wrote, write_err = M.write_json(vim.fs.joinpath(dir, 'package.json'), manifest)
    if not wrote then
      reject('cannot write manifest: ' .. tostring(write_err))
      return
    end
    M.system(M.npm_install_cmd(), { cwd = dir }, M.INSTALL_TIMEOUT_MS, function(res)
      if res.code ~= 0 then
        if res.cleanup_pending then
          on_result(false, 'npm process cleanup unconfirmed; staging directory retained: ' .. dir, true)
          return
        end
        reject('npm install failed (exit ' .. tostring(res.code) .. '): ' .. vim.trim(res.stderr or ''))
        return
      end
      local js = M.server_js(dir)
      if not js then
        reject('npm install succeeded but the server entrypoint is missing')
        return
      end
      M.verify(js, function(ok, detail, cleanup_pending)
        if cleanup_pending then
          on_result(false, 'server cleanup unconfirmed; staging directory retained: ' .. dir, true)
          return
        end
        if not ok then
          reject(detail)
          return
        end
        local saved, save_err = write_state(dir, { version = version, path = path, verified = true, reason = detail })
        if saved then
          saved, save_err = activate(name, previous)
        end
        if not saved then
          reject('cannot activate verified server: ' .. tostring(save_err))
          return
        end
        on_result(true, detail)
      end)
    end)
  end
  M.resolve_latest(function(latest, cleanup_pending)
    if cleanup_pending then
      result(
        false,
        { verified = false, reason = 'registry process cleanup unconfirmed' },
        'registry process cleanup unconfirmed',
        true
      )
      return
    end
    -- Offline must not silently downgrade an already installed server.
    if not latest and M.server_js() then
      result(false, { verified = false, reason = 'npm registry unavailable' }, 'npm registry unavailable')
      return
    end
    local function run(version, override, path, failed_latest)
      attempt(version, override, path, function(ok, detail, retain_lock)
        if not ok and not retain_lock and path == 'current' and not M.server_js() then
          run(M.PINS.lsp_server, true, 'fallback', version .. ': ' .. detail)
          return
        end
        local reason = failed_latest and not ok and (failed_latest .. ' | ' .. version .. ': ' .. detail) or detail
        result(
          ok,
          { version = version, path = path, verified = ok, reason = reason },
          ok and (version .. ' verified (' .. path .. '). Reopen your .agent buffer.') or reason,
          retain_lock
        )
      end)
    end
    run(latest or M.PINS.lsp_server, not latest, latest and 'current' or 'pinned-offline')
  end)
end

--- Reverify the previous generation before atomically switching back to it.
function M.rollback(on_done)
  local finish = lock(callback(on_done))
  if not finish then
    return
  end
  local active, pointer_err = M.active()
  if pointer_err then
    finish(false, pointer_err)
    return
  end
  local dir = active and generation_dir(active.previous)
  local js = dir and M.server_js(dir)
  if not js then
    finish(false, 'no previous managed server available for rollback')
    return
  end
  M.verify(js, function(ok, detail, cleanup_pending)
    if not ok then
      finish(false, 'rollback rejected; current version retained: ' .. detail, cleanup_pending)
      return
    end
    local saved, err = activate(active.previous, active.current)
    if saved then
      vim.uv.fs_unlink(vim.fs.joinpath(M.dir(), 'last-attempt.json'))
    end
    finish(
      not not saved,
      saved and 'previous server verified and restored. Reopen your .agent buffer.'
        or ('rollback activation failed; current version retained: ' .. tostring(err))
    )
  end)
end

return M
