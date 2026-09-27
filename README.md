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
- **`:AgentScriptTSBuild`**: builds the published tree-sitter grammar into
  `stdpath('data')` and verifies it parses current syntax before using it
  (below).
- **`:AgentScriptValidate`** and **`:AgentScriptPreview`**: compile the
  bundle on your org with its errors shown inline, and chat with it in a
  split, through the Salesforce CLI (below).
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
  target_org = nil,        -- org for :AgentScriptValidate/Preview; nil = sf's default
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
`:AgentScriptTSBuild` builds one in the background, the same way
`:AgentScriptInstall` handles the server:

1. `npm view` resolves the published grammar version (3.2.1 as of
   September 2026).
2. `npm pack` downloads it and any C compiler on PATH (`cc`/`gcc`/`clang`/`zig`,
   or `$CC`) compiles it.
3. The new parser is loaded under a scratch name, its highlights query must
   compile against it, and an `escalate` statement (3.x syntax) must parse
   without an ERROR node.
4. Only then is it moved to
   `stdpath('data')/agentscript-nvim/ts/parser/agentscript-<version>.so`
   (`.dll` on Windows), with its queries next to it.

If the published version fails any step (download, compile or verify), the
parser you already have stays in place and `:checkhealth` shows what was
rejected and why. The pinned 2.7.2 is built only when there is nothing to
keep, and `:checkhealth` then warns that you're on the `fallback` path. 2.7.2
predates `escalate`, `render` and `show_and_return`, so those show up as parse
errors under it. The same goes for an unreachable registry: an existing parser
is kept, and with none, 2.7.2 is built from npm's cache (`pinned-offline`).

Running it again when the published version is already built does nothing;
`:AgentScriptTSBuild!` rebuilds anyway. `:AgentScriptTSBuild 2.7.2` builds
that exact version. It skips resolution and never falls back: the version
verifies, or the current parser stays.

Upstream's `highlights.scm` has no captures for `escalate`, `render`,
`show_and_return`, `when`, `is`, `is not` and `not`, so the installed query
appends keyword captures for whichever of those the built grammar defines.

Neovim loads a parser once per session. When a build replaces the version
this session loaded, the message tells you to restart; until then the session
keeps the old parser and its queries. The outcome is recorded in
`ts-state.json` and shown by `:checkhealth agentscript-nvim`:

```
- ✅ OK tree-sitter grammar: 3.2.1 via current path, verification passed (highlights compile, escalate snippet parses clean)
```

Once built, `.agent` buffers use tree-sitter highlighting automatically.
Without a parser, the fallback regex syntax keeps files readable.

## Validate and preview on the org

Both commands run the [Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm)
(`sf`, with the agent plugin that ships in core) in the background, and both
need an authenticated org. `sf agent validate authoring-bundle` doesn't
compile locally: it sends the bundle to the org's Agentforce authoring API.
Log in once with `sf org login web --set-default`, or set `target_org` in
`setup()` to an alias or username.

The `.agent` file has to be in an authoring bundle,
`aiAuthoringBundles/<Name>/<Name>.agent` next to `<Name>.bundle-meta.xml`,
inside a Salesforce DX project (`sfdx-project.json` somewhere above it). The
directory name is the bundle's api name. sf runs from the project root.

`:AgentScriptValidate` compiles the current buffer's bundle.
`:AgentScriptValidate <Name>` compiles another one in the project (`<Tab>`
completes the names). sf reads
the file from disk, so save first. The command warns if the buffer has unsaved
changes. Errors land
as diagnostics (source `sf agent validate`) on the right line and column, and
in the quickfix list. A clean compile clears both. sf reports 0-based lines
and counts columns in characters, so a line with non-ASCII text before the
error still gets the right column.

`:AgentScriptPreview` starts a preview session with simulated actions and
opens a split. Type after the `> ` prompt and press `<CR>` to send; the
agent's reply lands above the prompt. `<CR>` sends in insert mode too, so
add the lines of a longer prompt with `o` from normal mode.
`:AgentScriptPreview!` uses live actions instead. Running the command again
while the session is open jumps to its split, and either command run in the
chat acts on its bundle. Closing the split (or quitting Neovim) ends the
session, and the message says where sf saved the traces
(`.sfdx/agents/<Name>/sessions/<id>` in the project). Preview needs Agentforce turned on in the org (Setup,
Agentforce Agents). Without it `sf agent preview start` never answers, and
the command gives up after two minutes and asks whether Agentforce is on.

`:checkhealth agentscript-nvim` shows the sf version and whether
`sf agent validate authoring-bundle` exists in it.

## Tests

Headless end-to-end tests (they run the real server against real fixtures):

```sh
nvim -l tests/test_lsp.lua              # filetype rules (.agent, .ascript,
                                        # "# @dialect:" header), highlighting,
                                        # attach, diagnostics, checkhealth,
                                        # + the tree-sitter section
nvim -l tests/test_install.lua          # stubbed install paths (current /
                                        # fallback / pinned-offline / both-fail,
                                        # verify crash + timeout, npm view
                                        # against a fake npm; no network), then
                                        # the real verified install into
                                        # stdpath('data')
nvim -l tests/test_upstream_config.lua  # post-merge nvim-lspconfig simulation:
                                        # real clone on rtp, npm-style shim on
                                        # PATH, default PR cmd, :checkhealth
nvim -l tests/test_treesitter.lua       # real 3.2.1 and 2.7.2 builds with
                                        # resolution stubbed: current / fallback
                                        # / pinned-offline / requested paths,
                                        # failed updates keeping the parser,
                                        # verify rejecting a broken query, the
                                        # 3.x keywords parsing and highlighted,
                                        # :AgentScriptTSBuild!, 0.2.0 installs
nvim -l tests/test_sf.lua               # :AgentScriptValidate/Preview against
                                        # a stub sf (tests/fake_sf.js) that
                                        # replays output captured from a real
                                        # org: pass, two errors (diagnostics +
                                        # quickfix), the [Ln X, Col Y] fallback,
                                        # CRLF and non-ASCII columns, sf missing,
                                        # no org, timeout kill, a three-turn
                                        # preview ending on wipeout
```

`test_treesitter` fetches the two grammar packages with `npm pack` on its
first run (into `scratch/ts/`) and needs a C compiler. CI runs it with
`test_install`, `test_lsp` and `test_sf`.

Verified passing (2026-09-27) with all five suites on Linux and Windows, same
setup as below. `:AgentScriptValidate` and a three-turn `:AgentScriptPreview`
were also run against a real Developer Edition org with sf 2.151.7.

Verified passing (2026-09-25) on **Linux**, all four suites, tree-sitter
built with gcc 12 (node:22-bookworm container, Neovim 0.12.4, Node 22.23; run
`docker run --rm -v "<repo>:/work" node:22-bookworm bash
/work/scratch/linux/run-tests.sh`), and on **Windows 11** (Neovim 0.12.2,
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
                           org validate and preview (sf), :checkhealth (health)
plugin/agentscript-nvim.lua auto-setup, :AgentScriptInstall, :AgentScriptTSBuild,
                           :AgentScriptValidate, :AgentScriptPreview
syntax/agentscript.vim     fallback highlighting (used when no parser built)
ftplugin/agentscript.vim   indent/comment settings
tests/                     headless e2e tests + real fixtures (fixtures/sf:
                           sf output captured from a real org, replayed by
                           fake_sf.js)
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
