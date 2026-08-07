# agentscript-nvim

Neovim support for **Agent Script** — Salesforce's open agent specification
language ([salesforce/agentscript](https://github.com/salesforce/agentscript),
Apache 2.0, generally available since July 2026 when it replaced the legacy
Agentforce Builder).

What you get:

- **Filetype detection** for `*.agent` (and `*.ascript`), plus first-line
  detection of the upstream `# @dialect:` header.
- **LSP integration** with the official `agentscript-lsp` server — diagnostics,
  completions, hover, go-to-definition, references, rename, symbols, code
  actions, semantic tokens. The same `lsp/agentscript.lua` config file is
  merged upstream in [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
  ([#4483](https://github.com/neovim/nvim-lspconfig/pull/4483)).
- **`:AgentScriptInstall`** — one-command managed server install into
  `stdpath('data')` that installs the currently published server and
  **verifies it actually starts** before trusting it (below).
- **Fallback syntax highlighting** (`syntax/agentscript.vim`) with the real
  language keywords, so `.agent` files are readable even without the LSP.

Requires **Neovim 0.11+** and **Node.js** (for the language server).

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'Booyaka101/agentscript-nvim',
  ---@type table
  opts = {},
}
```

Or any plugin manager — the plugin auto-configures with defaults; call
`require('agentscript-nvim').setup({ ... })` to override:

```lua
require('agentscript-nvim').setup({
  cmd = nil,               -- explicit server command override
  extra_extensions = true, -- also register *.ascript
  install_hint = true,     -- notify when no working server is found
})
```

Then open any `.agent` file. If no server is found you'll get a one-time hint;
run `:AgentScriptInstall` and reopen the buffer. `:LspInfo` (or
`:checkhealth vim.lsp`) shows the `agentscript` client attached.

### Why `:AgentScriptInstall` instead of plain `npm install -g`?

Because it **verifies instead of trusting**. A plain `npm install -g` gives you
whatever is published right now, sight unseen — and Agent Script's launch week
proved that can be a server that doesn't start: `lsp-server@2.2.30` crashed at
import (`variantMatch is not a function`) because `agentforce-dialect@2.13.4`
shipped with a stale exact pin on `@sf-agentscript/language@2.5.4`
([salesforce/agentscript#73](https://github.com/salesforce/agentscript/issues/73),
filed by this project). Upstream's `2.2.96` (2026-07-24) restructured the
dependency tree and bumps that pair in lockstep, which fixes the crash — but
#73 is still open with no comments, so nothing tells us (or you) when the next
publish breaks.

`:AgentScriptInstall` therefore measures:

1. resolves the currently published version from the npm registry
   (`npm view`), installs it with **no** overrides, and
2. **verifies** it by spawning it and completing a real LSP `initialize`
   round-trip;
3. only if that fails does it fall back to the historically verified recipe
   (`2.2.30` + npm override `@sf-agentscript/language` → `2.8.4`) — applying
   that override to a current release pre-emptively would *downgrade*
   `language` by many minor versions, so it is strictly a fallback;
4. if the registry is unreachable it installs the pinned recipe directly and
   says so.

The outcome (version, install path, verification result) is recorded in
`agentscript-nvim-state.json` next to the install and shown by
`:checkhealth agentscript-nvim`.

## Server resolution order

1. `opts.cmd` if you set it
2. the managed `:AgentScriptInstall` install (version-verified)
3. `agentscript-lsp` on `$PATH`
4. `npx --yes @sf-agentscript/lsp-server --stdio` (runs whatever is currently
   published, unverified)

`:checkhealth agentscript-nvim` reports Node/npm availability, which server
the plugin resolved, the managed install's version / install path /
verification result, and tree-sitter status.

## Tree-sitter highlighting

Upstream ships the official grammar and highlight queries in
`@sf-agentscript/parser-tree-sitter` but no Neovim-loadable library.
`:AgentScriptTSBuild` downloads the package via `npm pack`, compiles the
grammar with any C compiler on PATH (`cc`/`gcc`/`clang`/`zig`, or `$CC`), and
installs the parser plus the official `highlights.scm` under `stdpath('data')`.
Once built, `.agent` buffers use tree-sitter highlighting automatically
(superseding the fallback regex syntax); without it the fallback syntax keeps
files readable.

## Tests

Headless end-to-end tests (they run the real server against real fixtures):

```sh
nvim -l tests/test_lsp.lua              # filetype rules (.agent, .ascript,
                                        # "# @dialect:" header), highlighting,
                                        # attach, diagnostics, checkhealth,
                                        # + the tree-sitter section
nvim -l tests/test_install.lua          # stubbed install paths (current /
                                        # fallback / pinned-offline / both-fail,
                                        # verify crash + timeout; no network),
                                        # then the real verified install into
                                        # stdpath('data')
nvim -l tests/test_upstream_config.lua  # post-merge nvim-lspconfig simulation:
                                        # real clone on rtp, npm-style shim on
                                        # PATH, default PR cmd, :checkhealth
nvim -l tests/test_treesitter.lua       # grammar builds, parser loads, official
                                        # queries yield captures, ERROR node on
                                        # the broken fixture
```

Verified passing (2026-07-22) on **Linux** — all four suites, tree-sitter
built with gcc 12 (node:22-bookworm container, Neovim 0.12.4; run
`docker run --rm -v "<repo>:/work" node:22-bookworm bash
/work/scratch/linux/run-tests.sh`) — and on **Windows 11** (Neovim 0.12.2,
Node 22.18) for all four suites, with the tree-sitter grammar built via
portable zig 0.16.0 (`zig cc`). `broken.agent` yields `L2 [ERROR] Missing :`
and `L4 [ERROR] Unknown block: bogus_block_keyword`; `sample.agent` yields only
an INFO-level unused-variable lint. `lsp/agentscript.lua` passes
nvim-lspconfig's own stylua config (as does all Lua in this repo), and the
upstream test proves a bare `agentscript-lsp` npm shim (`.cmd` on Windows,
shell script on Linux) spawns fine through the native `vim.lsp` client.

## Repo layout

```
lsp/agentscript.lua        vim.lsp.Config — ALSO the nvim-lspconfig PR file
lua/agentscript-nvim/      plugin core: setup/resolution (init), managed server
                           install (install), grammar build (treesitter),
                           :checkhealth (health)
plugin/agentscript-nvim.lua auto-setup, :AgentScriptInstall, :AgentScriptTSBuild
syntax/agentscript.vim     fallback highlighting (used when no parser built)
ftplugin/agentscript.vim   indent/comment settings
tests/                     headless e2e tests + real fixtures
upstream/                  nvim-lspconfig PR text + agentscript bug report
scratch/                   test tooling: server install, nvim-lspconfig clone,
                           grammar sources, Linux runner (mostly gitignored)
```

## Upstream status

- **nvim-lspconfig: MERGED.**
  [neovim/nvim-lspconfig#4483](https://github.com/neovim/nvim-lspconfig/pull/4483)
  (`feat: agentscript`) was merged on 2026-07-23, so the base `agentscript`
  config now ships in nvim-lspconfig itself. This plugin layers on top of it:
  filetype detection for `*.agent` / `*.ascript` / `# @dialect:` headers, the
  verified managed install, tree-sitter highlighting, and
  `:checkhealth agentscript-nvim`.
- **Launch-week packaging bug:**
  [salesforce/agentscript#73](https://github.com/salesforce/agentscript/issues/73)
  (filed by this project) reports the historical
  `@sf-agentscript/lsp-server@2.2.30` startup crash. Upstream's `2.2.96`
  release (2026-07-24) restructured the dependency tree and fixes it in
  practice, but the issue remains open — which is exactly why
  `:AgentScriptInstall` verifies every install instead of trusting a version
  number.

The full text for both submissions lives in `upstream/`.
