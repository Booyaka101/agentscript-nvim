-- Managed install of the AgentScript language server.
--
-- Strategy: measure, don't pin. `:AgentScriptInstall` resolves the currently
-- published `@sf-agentscript/lsp-server` from the npm registry, installs it
-- with NO overrides, and verifies it by actually speaking LSP to it (spawn +
-- `initialize` + wait for `result.capabilities`). Only if that verification
-- fails does it fall back to the legacy recipe in `M.PINS` — the
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

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agentscript-nvim', 'server')
end

function M.server_js()
  local p = vim.fs.joinpath(M.dir(), 'node_modules', '@sf-agentscript', 'lsp-server', 'dist', 'index.js')
  if vim.uv.fs_stat(p) then
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

--- Outcome of the last `:AgentScriptInstall` run, or nil if never installed.
---@return { version: string, path: string, verified: boolean, reason: string, installedAt: string }?
function M.state()
  local f = io.open(vim.fs.joinpath(M.dir(), 'agentscript-nvim-state.json'), 'r')
  if not f then
    return
  end
  local s = f:read('*a')
  f:close()
  local ok, t = pcall(vim.json.decode, s)
  if ok and type(t) == 'table' then
    return t
  end
end

local function write_state(dir, state)
  state.installedAt = os.date('!%Y-%m-%dT%H:%M:%SZ')
  local f = io.open(vim.fs.joinpath(dir, 'agentscript-nvim-state.json'), 'w')
  if f then
    f:write(vim.json.encode(state))
    f:close()
  end
end

function M.npm_install_cmd()
  local cmd = { 'npm', 'install', '--no-audit', '--no-fund', '--loglevel=error' }
  if vim.fn.has('win32') == 1 then
    -- npm is a .cmd shim on Windows; spawn through cmd.exe to be safe.
    return vim.list_extend({ 'cmd.exe', '/c' }, cmd)
  end
  return cmd
end

--- Ask the npm registry for the currently published version (async, never
--- blocks the UI thread). Calls on_done with the trimmed version string, or
--- nil on any failure (no npm, no network, timeout, unparseable output).
---@param on_done fun(version: string?)
function M.resolve_latest(on_done)
  local cmd = { 'npm', 'view', PKG, 'version', '--json' }
  if vim.fn.has('win32') == 1 then
    cmd = vim.list_extend({ 'cmd.exe', '/c' }, cmd)
  end
  local ok = pcall(vim.system, cmd, { timeout = M.RESOLVE_TIMEOUT_MS }, function(res)
    local version
    if res.code == 0 and res.stdout then
      local s = vim.trim(res.stdout)
      local okj, decoded = pcall(vim.json.decode, s)
      local v = (okj and type(decoded) == 'string' and decoded) or s:match('"(%d[^"]*)"') or s
      if type(v) == 'string' and v:match('^%d+%.%d+%.%d+') then
        version = v
      end
    end
    vim.schedule(function()
      on_done(version)
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_done(nil)
    end)
  end
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
  local proc
  local timer = vim.uv.new_timer()
  local t0 = vim.uv.hrtime()

  local function finish(ok, detail)
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if proc then
      pcall(proc.kill, proc, 9)
    end
    vim.schedule(function()
      on_done(ok, detail)
    end)
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
      local len = tonumber(stdout_buf:sub(1, header_end - 1):match('Content%-Length:%s*(%d+)'))
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
      if ok and type(msg) == 'table' and msg.id == 1 and type(msg.result) == 'table' and msg.result.capabilities then
        finish(true, ('initialize answered in %dms'):format(math.floor((vim.uv.hrtime() - t0) / 1e6)))
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
          scan_stdout()
        end
      end,
      stderr = function(_, data)
        if data and #stderr_buf < 8192 then
          stderr_buf = stderr_buf .. data
        end
      end,
    }, function(res)
      if not done then
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
  proc:write(('Content-Length: %d\r\n\r\n%s'):format(#request, request))

  timer:start(timeout_ms, 0, function()
    finish(false, ('verify timed out after %dms'):format(timeout_ms))
  end)
end

--- Install (or update) the server, verified. Two attempts against the same
--- dir: (a) the currently published version, no overrides; (b) only if (a)
--- fails verification, the legacy pinned recipe. Calls on_done(ok, msg).
---@param on_done? fun(ok: boolean, msg: string)
function M.install(on_done)
  on_done = on_done
    or function(ok, msg)
      vim.notify('agentscript-nvim: ' .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
  if vim.fn.executable('npm') == 0 or vim.fn.executable('node') == 0 then
    on_done(false, 'node/npm not found on PATH; install Node.js first')
    return
  end
  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')

  local function notify(msg)
    vim.notify('agentscript-nvim: ' .. msg, vim.log.levels.INFO)
  end

  -- Write the manifest for one recipe, npm install it, then LSP-verify it.
  local function attempt(version, with_override, on_result)
    local manifest = {
      name = 'agentscript-nvim-server',
      private = true,
      dependencies = { [PKG] = version },
    }
    if with_override then
      manifest.overrides = { ['@sf-agentscript/language'] = M.PINS.language_override }
    end
    local f = assert(io.open(vim.fs.joinpath(dir, 'package.json'), 'w'))
    f:write(vim.json.encode(manifest))
    f:close()
    -- The two recipes resolve differently; a lock from the other one must not
    -- constrain (or conflict with) this install.
    vim.uv.fs_unlink(vim.fs.joinpath(dir, 'package-lock.json'))
    vim.system(M.npm_install_cmd(), { cwd = dir }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          on_result(false, 'npm install failed (exit ' .. tostring(res.code) .. '): ' .. vim.trim(res.stderr or ''))
          return
        end
        local js = M.server_js()
        if not js then
          on_result(false, 'npm install succeeded but the server entrypoint is missing')
          return
        end
        M.verify(js, on_result)
      end)
    end)
  end

  local function finish(ok, state, msg)
    write_state(dir, state)
    if ok then
      -- Point the active config at the fresh install for new buffers.
      vim.lsp.config('agentscript', { cmd = M.cmd() })
    end
    on_done(ok, msg)
  end

  notify('resolving ' .. PKG .. ' ...')
  M.resolve_latest(function(latest)
    if not latest then
      notify('npm view failed (offline?); installing the pinned ' .. M.PINS.lsp_server .. ' workaround directly ...')
      attempt(M.PINS.lsp_server, true, function(ok, detail)
        finish(
          ok,
          { version = M.PINS.lsp_server, path = 'pinned-offline', verified = ok, reason = detail },
          ok and (M.PINS.lsp_server .. ' (pinned-offline) verified. Reopen your .agent buffer.')
            or (M.PINS.lsp_server .. ' (pinned-offline) failed: ' .. detail)
        )
      end)
      return
    end
    notify('installing ' .. latest .. ' ...')
    attempt(latest, false, function(ok, detail)
      if ok then
        finish(
          true,
          { version = latest, path = 'current', verified = true, reason = detail },
          latest .. ' verified (' .. detail .. '). Reopen your .agent buffer.'
        )
        return
      end
      notify(
        latest
          .. ' failed to start ('
          .. detail
          .. '); falling back to the pinned '
          .. M.PINS.lsp_server
          .. ' + language@'
          .. M.PINS.language_override
          .. ' workaround ...'
      )
      attempt(M.PINS.lsp_server, true, function(ok2, detail2)
        finish(
          ok2,
          {
            version = M.PINS.lsp_server,
            path = 'fallback',
            verified = ok2,
            reason = ok2 and detail2 or (latest .. ': ' .. detail .. ' | ' .. M.PINS.lsp_server .. ': ' .. detail2),
          },
          ok2 and (M.PINS.lsp_server .. ' (fallback) verified. Reopen your .agent buffer.')
            or (
              'both installs failed verification — '
              .. latest
              .. ': '
              .. detail
              .. ' | '
              .. M.PINS.lsp_server
              .. ' (fallback): '
              .. detail2
            )
        )
      end)
    end)
  end)
end

return M
