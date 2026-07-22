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
  actions, semantic tokens. Ships the same `lsp/agentscript.lua` config file
  prepared for upstream [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
  (see `upstream/PR_DESCRIPTION.md`).
- **`:AgentScriptInstall`** — one-command managed server install into
  `stdpath('data')` that works around a real upstream packaging bug (below).
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

The currently published `@sf-agentscript/lsp-server@2.2.30` **crashes on
startup** (`variantMatch is not a function`): `agentforce-dialect@2.13.4` was
published with a stale exact pin on `@sf-agentscript/language@2.5.4`, one day
before the `language@2.8.4` release that actually contains the API it uses.
`:AgentScriptInstall` installs the server with a verified npm `overrides` fix
(`@sf-agentscript/language` → `2.8.4`). The same publish-pipeline defect is
already reported upstream for a sibling package
([salesforce/agentscript#71](https://github.com/salesforce/agentscript/issues/71));
ready-to-file text for the lsp-server case is in
`upstream/agentscript-bug-report.md`. Once Salesforce republishes, the plain
`agentscript-lsp` / npx paths (which the plugin also supports) heal on their
own.

## Server resolution order

1. `opts.cmd` if you set it
2. the managed `:AgentScriptInstall` install
3. `agentscript-lsp` on `$PATH`
4. `npx --yes @sf-agentscript/lsp-server --stdio` (currently broken upstream,
   see above)

`:checkhealth agentscript-nvim` reports Node/npm availability, which server
the plugin resolved, and tree-sitter status.

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
nvim -l tests/test_install.lua          # managed install into stdpath('data')
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

- **nvim-lspconfig config PR (draft):**
  [neovim/nvim-lspconfig#4483](https://github.com/neovim/nvim-lspconfig/pull/4483)
  adds `lsp/agentscript.lua` upstream (`feat: agentscript`).
- **Launch-week packaging bug:**
  [salesforce/agentscript#73](https://github.com/salesforce/agentscript/issues/73)
  reports the `@sf-agentscript/lsp-server@2.2.30` startup crash and the verified
  npm-`overrides` workaround that `:AgentScriptInstall` applies. Once Salesforce
  republishes with `@sf-agentscript/language >= 2.8.4`, the plain
  `agentscript-lsp` / npx paths heal on their own.

The full text for both submissions lives in `upstream/`.
