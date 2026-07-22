# PROGRESS — agentscript-nvim

Status: **MVP complete, hardened, cross-platform verified** (2026-07-22).
All local verification done — including the Windows tree-sitter build (below).
Remaining work is distribution only (repo push + upstream submissions).

## Phase 0 verification (all confirmed by direct fetch/run)

- salesforce/agentscript exists, Apache 2.0, 258★; LSP + tree-sitter + VS Code
  extension are real. Upstream registers **only `.agent`** (language id
  `agentscript`); `.ascript` from the brief does not exist upstream (kept as an
  optional extra in the plugin only).
- Real npm scope is **`@sf-agentscript/*`** — the brief's `@agentscript/lsp`
  does not exist. Server = `@sf-agentscript/lsp-server` (bin `agentscript-lsp`,
  usage `agentscript-lsp --stdio`; no `--version`/`--help` flags).
- **Upstream packaging bug found:** published `lsp-server@2.2.30` crashes at
  import (`variantMatch is not a function`) because `agentforce-dialect@2.13.4`
  pins `language@2.5.4` but needs ≥ 2.8.4. Verified fix: npm override
  `@sf-agentscript/language → 2.8.4`. Same publish-pipeline defect is already
  reported upstream for the `agentforce` SDK package (issue #71, plus earlier
  #35/#40 and CI-fix PR #72) — but NOT for lsp-server; our report is new.
- nvim-lspconfig now takes configs as **`lsp/<name>.lua`** (`vim.lsp.Config`,
  `root_markers`); `lua/lspconfig/configs/` + `tsserver.lua` from the brief are
  obsolete. **No agentscript PR/issue exists in nvim-lspconfig** (searched
  2026-07-22) — the niche is open.
- Launch dates verified: Agent Script GA + legacy Agentforce Builder retired
  the week of **July 13, 2026** (help.salesforce.com article 005232662).
- Local env: Neovim 0.12.2, Node 22.18, npm OK. No cost barriers.

## VERIFIED working (ran on this machine, real server, real data)

- `nvim -l tests/test_lsp.lua` → ALL PASS: `.agent`/`.ascript`/`# @dialect:`
  filetype rules, fallback syntax (group `agentscriptBlock` on `config`), LSP
  attach, 2 ERROR diagnostics on `broken.agent`, 0 errors + 1 INFO
  unused-variable lint on `sample.agent`, `:checkhealth agentscript-nvim`.
- `nvim -l tests/test_install.lua` → managed install into
  `C:/Users/cbosc/AppData/Local/nvim-data/agentscript-nvim/server` works
  (cmd.exe/npm on Windows) and wins cmd resolution.
- `nvim -l tests/test_upstream_config.lua` → **post-merge simulation**: real
  nvim-lspconfig clone on rtp (only), `agentscript-lsp` as npm-style `.cmd`
  shim on PATH, DEFAULT PR cmd attaches + publishes diagnostics, client shows
  in `:checkhealth vim.lsp` (`:LspInfo`'s alias; on Nvim 0.12+ lspconfig
  defers to the core `:lsp` command). Proves bare `.cmd` spawn works on
  Windows — no lspconfig#3704 workaround needed in the PR file (the plugin
  still exepath-resolves PATH installs as belt-and-braces).
- `lsp/agentscript.lua` passes `stylua --check` with nvim-lspconfig's own
  `.stylua.toml` (exit 0); all repo Lua formatted with the same config.
- Raw LSP smoke test (`scratch/lsp-smoke.mjs`) → initialize + publishDiagnostics
  over stdio confirmed independently of Neovim.
- **Linux, full suite (node:22-bookworm container, Neovim 0.12.4, gcc 12):**
  `LINUX SUITE: ALL PASSED` — tree-sitter grammar builds from the official
  `@sf-agentscript/parser-tree-sitter` sources and all 7 tree-sitter checks
  pass (parser loads, highlighter active, official highlights.scm yields
  captures, sample parses clean, broken has an ERROR node); managed install
  works against the live registry from Linux; all LSP checks pass; the
  post-merge nvim-lspconfig simulation passes with a unix shell shim (so both
  the Windows `.cmd` and unix script shim branches are now exercised).
  Runner: `scratch/linux/run-tests.sh` via
  `docker run --rm -v "<repo>:/work" node:22-bookworm bash /work/scratch/linux/run-tests.sh`.
- Tree-sitter is wired into the plugin: `:AgentScriptTSBuild` (npm pack →
  C compile → parser + official queries into stdpath('data')),
  auto `vim.treesitter.start()` on FileType when built, checkhealth reports it.
  Fixed a real bug found by the Linux run: nil-leading table literal made
  ipairs skip all compiler candidates in `find_compiler`.
- Naming risk closed with evidence: GitHub Linguist, Helix `languages.toml`
  and Neovim core `filetype.lua` all have NO entry for `.agent`/Agent Script
  (checked 2026-07-22), so upstream's language id `agentscript` is the only
  precedent; rationale section added to the PR description.

## Pending (none)

- **Windows tree-sitter build run — DONE (2026-07-22).** Built with portable
  zig 0.16.0 (`zig cc`) → `agentscript.dll` into `stdpath('data')`;
  `nvim -l tests/test_treesitter.lua` → `TREESITTER TEST PASSED`, and
  `nvim -l tests/test_lsp.lua` → `ALL TESTS PASSED` (tree-sitter section
  included). stylua check re-run clean (exit 0). Note: the staged
  `scratch/zig.zip` from the prior session was a truncated download; it was
  re-fetched (97 MB, `zig-x86_64-windows-0.16.0.zip`) and pre-extracted to
  `scratch/zig-extract/` (both gitignored). Test-harness caveat for future
  fresh-clone Windows runs with no system C compiler: the extraction step
  shells out to `tar`, which resolves to MSYS/GNU tar under Git Bash (can't
  read zip / mishandles `D:` paths) — run the test from PowerShell (native
  bsdtar) or pre-extract zig into `scratch/zig-extract/` first.

## Shipped (2026-07-22)

1. **Repo is live (public):** https://github.com/Booyaka101/agentscript-nvim
   (`main` pushed). `scratch/` is gitignored except `package.json` +
   `lsp-smoke.mjs` + `linux/run-tests.sh` (reproduce the test tooling with:
   `cd scratch && npm install`, clone nvim-lspconfig, download stylua/zig).
2. **lsp-server packaging bug filed:** salesforce/agentscript#73 —
   https://github.com/salesforce/agentscript/issues/73 . Written to the repo's
   `bug_report.md` template (Description / Steps / Expected / Actual /
   Environment / Minimal Reproduction / Additional Context); cross-references
   #71/#72 and #35/#40. Re-verified live on npm the same day (lsp-server still
   2.2.30 latest; dialect@2.13.4 still pins language@2.5.4; language@2.8.4
   exists, latest 2.19.3). `bug` label left to maintainer triage (external
   contributors can't set labels).
3. **nvim-lspconfig PR (draft):** neovim/nvim-lspconfig#4483 —
   https://github.com/neovim/nvim-lspconfig/pull/4483 . Commit `feat: agentscript`
   (their `feat: <server>` convention), single file `lsp/agentscript.lua` off
   latest `master`, stylua-clean, links the bug above. Opened as draft per
   CONTRIBUTING.

## Remaining

- Flip PR #4483 from draft to ready-for-review once you're happy with it.
- When Salesforce republishes fixed packages (watch #73): bump/drop `M.PINS` in
  `lua/agentscript-nvim/install.lua` and re-run all three tests.
- Optional later: nvim-treesitter parser entry for
  `@sf-agentscript/parser-tree-sitter` (would supersede the fallback syntax).
