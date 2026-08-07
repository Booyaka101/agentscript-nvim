# Changelog

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
