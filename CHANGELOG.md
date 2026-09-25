# Changelog

## 0.3.0 — 2026-09-25

The grammar gets the same treatment the server got in 0.2.0.
`:AgentScriptTSBuild` always built `@sf-agentscript/parser-tree-sitter@2.7.2`
(2026-07-21), while upstream moved on to 3.2.1 (2026-08-20), which parses
`escalate`, `render`, `show_and_return` and slice expressions. Under 2.7.2 a
plain `escalate` parses as an ERROR node and highlights as a variable.

### Added

- `:AgentScriptTSBuild` resolves the currently published grammar
  (`npm view`), builds it and verifies it before moving it into place: the
  parser loads under a scratch language name, its `highlights.scm` compiles
  against it, and an `escalate` snippet from upstream's corpus parses without
  an ERROR node. The build runs in the background.
- If the published grammar fails to download, compile or verify, a parser
  that is already built is kept and the rejection is recorded for
  `:checkhealth`. The pinned 2.7.2 is built only when there is nothing to
  keep (`fallback`). With the registry unreachable the same rule applies, and
  2.7.2 comes from npm's cache (`npm pack --offline`, `pinned-offline`).
- `:AgentScriptTSBuild <version>` builds one exact version, skipping
  resolution. It never falls back: if the version does not build or verify,
  the working parser stays in place.
- `:AgentScriptTSBuild` is a no-op when the published version is already
  built; `:AgentScriptTSBuild!` rebuilds it.
- Build outcome recorded in `ts-state.json` (`version`,
  `path = current|fallback|pinned-offline|requested`, `verified`, `reason`,
  `builtAt`, and `rejected` after a failed update); `:checkhealth
  agentscript-nvim` reports it, e.g.
  `tree-sitter grammar: 3.2.1 via current path, verification passed`, and
  warns on `fallback`, `pinned-offline` and a rejected update. Parsers built
  by 0.2.0 still load and are reported as version unknown.
- Keyword captures for `escalate`, `render`, `show_and_return`, `when`, `is`,
  `is not` and `not`, which upstream's `highlights.scm` leaves uncaptured.
  Each is appended only if the built grammar defines the node, so older
  grammars still get a query that compiles.
- `escalate`, `render` and `show_and_return` in the fallback regex syntax.
- `tests/fixtures/v3.agent` and `v3-keywords.agent`, and a rewritten
  `test_treesitter.lua` that builds the real 3.2.1 and 2.7.2 grammars with
  resolution stubbed out. CI now runs it and `test_lsp`.

### Changed

- Parsers are written to `parser/agentscript-<version>.<so|dll>` and their
  queries to `runtime/<version>/`. Windows won't overwrite or delete a loaded
  library, and a session keeps the queries of the parser it loaded, so a
  rebuild never changes what a running Neovim is using. The build message
  asks for a restart when the session already loaded a different parser.
  Old files are removed by a later `:AgentScriptTSBuild`, including one
  with nothing to rebuild, once nothing holds them.
- Build failures show one line: npm's relevant error, or the compiler's
  first `error:` line, instead of the full output.
- `:AgentScriptTSBuild` no longer blocks the editor. Downloads and the
  compiler have timeouts, and only one build runs per session.

### Fixed

- The 15s `npm view` timeout did not hold on Windows: it killed `cmd.exe`,
  and the result then waited for npm's own node process to give up (about
  70s with no network). It now settles on time and kills the whole process
  tree. This also affected `:AgentScriptInstall`.
- Unpacking the grammar with Git Bash's GNU `tar` on PATH failed, because it
  reads `D:/...` as a remote host.
- The state files are written atomically.

## 0.2.0 — 2026-08-07

The pin becomes a measurement. `@sf-agentscript/lsp-server@2.2.96`
(2026-07-24) restructured the dependency tree that caused the launch-week
startup crash ([salesforce/agentscript#73](https://github.com/salesforce/agentscript/issues/73),
still open, so upstream will never tell us), and 0.1.0's hard pin on
`2.2.30 + language@2.8.4` was silently freezing users weeks behind a fix.

### Added

- **Verified managed install.** `:AgentScriptInstall` now resolves the
  currently published server version from the npm registry (`npm view`),
  installs it with no overrides, and **verifies** it by spawning it and
  completing a real LSP `initialize` round-trip before trusting it. Only on
  verification failure does it fall back to the historically verified
  `2.2.30 + @sf-agentscript/language@2.8.4` override recipe (applying that
  override to a current release would downgrade `language` by many minor
  versions, so it is strictly a fallback). If the registry is unreachable the
  pinned recipe is installed directly and reported as `pinned-offline`.
- `install.resolve_latest()`, `install.verify()` (15s timeout, kills the
  child, surfaces the server's stderr error line) and `install.state()`.
- Install outcome recorded in `agentscript-nvim-state.json`
  (`version`, `path = current|fallback|pinned-offline`, `verified`, `reason`,
  `installedAt`); `:checkhealth agentscript-nvim` reports it.
- Network-free install tests: stub servers under `tests/` exercise the
  current / fallback / pinned-offline / both-fail paths plus the verify
  crash and timeout cases.

### Changed

- **README: nvim-lspconfig PR
  [#4483](https://github.com/neovim/nvim-lspconfig/pull/4483) is merged**
  (2026-07-23), not a draft — the base config now ships in nvim-lspconfig,
  and this plugin documents what it layers on top.
- If both install attempts fail verification, the failure is reported with
  both servers' stderr details — never a silent success.

### Removed

- The false "the published @sf-agentscript/lsp-server currently crashes"
  warning from the npx-fallback hint and `:checkhealth` (it also cited the
  wrong issue — #71 is a different package's bug; ours is #73). The npx path
  is now described accurately as *unverified*, not broken.

## 0.1.0 — 2026-07-22

Initial release: filetype detection (`*.agent`, `*.ascript`, `# @dialect:`
header), LSP integration (config also merged upstream as
nvim-lspconfig#4483), `:AgentScriptInstall` with the pinned
`2.2.30 + language@2.8.4` workaround for the then-current startup crash,
`:AgentScriptTSBuild` tree-sitter grammar build, fallback regex syntax,
`:checkhealth`, and four headless end-to-end test suites (verified on
Windows 11 and Linux).
