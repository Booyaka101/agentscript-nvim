# PROGRESS — agentscript-nvim

Status: **v0.2.0 — verified-install upgrade complete** (2026-08-07).
v0.1.0 (2026-07-22) shipped the MVP; see CHANGELOG.md. Repo is live at
https://github.com/Booyaka101/agentscript-nvim (published, has users).

## v0.2.0 (2026-08-07): pin → measurement

### Phase 0 re-verification (all confirmed by direct fetch on 2026-08-07)

- npm registry: `@sf-agentscript/lsp-server` latest = **2.2.96**, published
  2026-07-24T05:29:09Z; deps `{ vscode-languageserver ^9.0.1, lsp 2.5.24,
  types 0.2.3, parser 4.0.7 }`; `lsp@2.5.24` → `language@2.20.0` +
  `agentforce-dialect@2.37.0` (the crash pair bumped in lockstep).
- nvim-lspconfig **PR #4483 MERGED** 2026-07-23T10:42:40Z ("feat:
  agentscript"); upstream `lsp/agentscript.lua` is config-only.
- salesforce/agentscript#73 still **open, 0 comments** — upstream will not
  tell us when the packaging bug class recurs; hence verification.

### What changed

- `install.lua`: `resolve_latest()` (async `npm view`, 15s timeout),
  `verify()` (spawn `node dist/index.js --stdio`, framed LSP `initialize`,
  wait for `result.capabilities`, 15s timeout, always kills the child,
  captures the stderr Error line), `state()`, and a restructured `install()`:
  current-version-no-overrides → verify → only-on-failure fallback to
  `M.PINS` (2.2.30 + language@2.8.4 override) → verify; offline ⇒
  pinned-offline. Outcome written to `<dir>/agentscript-nvim-state.json`
  `{ version, path=current|fallback|pinned-offline, verified, reason,
  installedAt }`. Both-fail ⇒ reported as an error with both stderr details.
- `health.lua`: reports the state file (version/path/verified); the npx
  advice no longer asserts an unmeasured crash and cites #73 (not #71,
  which is a different package's bug).
- `init.lua`: npx hint rewritten — npx = "currently published, unverified".
- README: PR #4483 marked merged; "Why :AgentScriptInstall" rewritten
  around verification-not-pinning; CHANGELOG.md created (0.2.0 + 0.1.0).
- Tests: `tests/test_install.lua` Part 1 is network-free via
  `tests/fake_npm.js` + `stub_server_{ok,crash,hang}.js` — covers current
  adopted / fallback adopted / pinned-offline / both-fail (+ state file
  each time) and `verify()` crash + timeout; Part 2 is the real install.

## VERIFIED working (ran on this machine, 2026-08-07)

- `nvim -l tests/test_install.lua` → ALL PASS. Real end-to-end:
  **2.2.96 resolved from the live registry, installed with NO overrides,
  verified — "initialize answered in 538ms"**, state file
  `{ version="2.2.96", path="current", verified=true }`; managed install
  wins cmd resolution. Confirms the 0.1.0 crash is fixed upstream and the
  pin is correctly demoted to fallback.
- `nvim -l tests/test_lsp.lua` → ALL TESTS PASSED against the real 2.2.96
  server (2 ERROR diagnostics on broken.agent; sample.agent 0 errors — note
  2.2.96 adds a new WARN `default_agent_user is deprecated` lint, harmless).
- `nvim -l tests/test_upstream_config.lua` → PASSED (post-merge simulation).
- `nvim -l tests/test_treesitter.lua` → PASSED.
- `stylua --check` (nvim-lspconfig's `.stylua.toml`) → exit 0 on
  lua/ lsp/ plugin/ tests/.
- Acceptance greps: every remaining `2.2.30` is the documented fallback;
  README has no "draft" for #4483; no Lua text claims the published server
  currently crashes.

## Shipped history (v0.1.0, 2026-07-22)

1. Repo public: https://github.com/Booyaka101/agentscript-nvim
2. Bug filed: salesforce/agentscript#73 (lsp-server 2.2.30 startup crash).
3. nvim-lspconfig PR #4483 — **merged 2026-07-23**.

## Remaining / next steps

- Owner: push `main` + tag `v0.2.0` to GitHub from the phone
  (`git push origin main --tags`). Nothing else blocks release.
- Optional later: nvim-treesitter parser entry for
  `@sf-agentscript/parser-tree-sitter`; if #73 gets fixed/closed upstream,
  consider dropping `M.PINS` entirely in a future release (the verify
  machinery stays regardless — that is the moat).
- Windows fresh-clone tree-sitter caveat from v0.1.0 still applies (run
  tests from PowerShell or pre-extract zig into `scratch/zig-extract/`).
