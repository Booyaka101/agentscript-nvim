# nvim-lspconfig PR: add `agentscript` (Salesforce Agent Script)

The file to submit is this repo's [`lsp/agentscript.lua`](../lsp/agentscript.lua) —
it drops into nvim-lspconfig's `lsp/` directory unchanged. (nvim-lspconfig
migrated from `lua/lspconfig/configs/*.lua` to `lsp/*.lua` `vim.lsp.Config`
files; `tsserver.lua` no longer exists, so the file is modeled on current
configs such as `lsp/aiken.lua` and `lsp/air.lua`.)

## Suggested PR title

```
feat: add agentscript language server config
```

## Suggested PR body

---

Adds support for **Agent Script**, Salesforce's open agent specification
language ([salesforce/agentscript](https://github.com/salesforce/agentscript),
Apache 2.0).

**Why now:** Salesforce open sourced the complete Agent Script toolchain —
parser, compiler, LSP server, VS Code extension — and made the language
generally available in July 2026. As of the week of **July 13, 2026** the
legacy Agentforce Builder was retired: the "New Agent" button in Setup only
opens the new Agent Script-based Agentforce Builder
([release note](https://help.salesforce.com/s/articleView?id=005232662&language=en_US&type=1)).
Every Agentforce customer authoring agents going forward is writing `.agent`
files, and the Salesforce + Neovim community already maintains dedicated
tooling (e.g. [sf.nvim](https://github.com/xixiaofinland/sf.nvim)).

**Server:** [`@sf-agentscript/lsp-server`](https://www.npmjs.com/package/@sf-agentscript/lsp-server)
(`npm install -g @sf-agentscript/lsp-server`) ships the `agentscript-lsp`
executable; `agentscript-lsp --stdio` provides diagnostics, completions,
hover, go-to-definition, references, rename, document symbols, code actions
and semantic tokens.

**Popularity criteria:** the server repository has 250+ stars within a week of
launch, and Agent Script is the mandated authoring format for Salesforce
Agentforce (see above).

**Filetype:** Neovim core does not yet detect `.agent`; the docstring shows the
`vim.filetype.add` one-liner (upstream registers only the `.agent` extension,
language id `agentscript`).

**Naming:** the config, server and filetype are all named `agentscript` — the
exact language id upstream's VS Code extension registers. No competing
convention exists anywhere as of 2026-07-22: GitHub Linguist has no entry for
`.agent`/Agent Script, and neither Helix's `languages.toml` nor Neovim core's
`filetype.lua` mention it, so upstream's own id is the only precedent. This
also fits CONTRIBUTING's guidance (unique server name, nothing to
dash-convert).

Verified locally on Neovim 0.12.2 (Windows): server attaches on `.agent`
buffers, publishes parse errors and semantic lints (e.g. unused-variable).

---

## Submission checklist (per nvim-lspconfig CONTRIBUTING.md)

1. Fork `neovim/nvim-lspconfig`, branch, copy `lsp/agentscript.lua` in.
2. `make lint` (stylua + luals) — the file follows existing config style.
3. Commit as `feat: add agentscript language server config` (rebase workflow,
   open as draft first).
4. Known caveat to disclose if asked: the currently published
   `@sf-agentscript/lsp-server@2.2.30` crashes at import due to an upstream
   dependency-pin mistake (`agentforce-dialect@2.13.4` needs
   `@sf-agentscript/language` ≥ 2.8.4 but pins 2.5.4) — the same publish-
   pipeline defect already reported for a sibling package as
   salesforce/agentscript#71. Installing with an npm override works today, and
   the config itself is correct regardless — it runs whatever `agentscript-lsp`
   resolves on `$PATH`. File the lsp-server report first
   (`upstream/agentscript-bug-report.md`) so this PR can link to it.

## Verification already done (2026-07-22 — Windows 11: Neovim 0.12.2 + Node 22; Linux: node:22-bookworm container, Neovim 0.12.4)

- `lsp/agentscript.lua` passes nvim-lspconfig's own stylua check
  (`stylua --check` with the repo's `.stylua.toml`, exit 0).
- Post-merge simulation (`tests/test_upstream_config.lua`): with only the
  nvim-lspconfig checkout on `runtimepath` and `agentscript-lsp` on `$PATH`
  (npm-style `.cmd` shim), the DEFAULT config attaches, publishes diagnostics
  on a malformed file, and the client appears in `:checkhealth vim.lsp`
  (`:LspInfo`'s alias; on Nvim 0.12+ lspconfig defers to the core `:lsp`
  command and defines no alias).
- Bare `agentscript-lsp` (a `.cmd` shim) spawns fine on Windows via the native
  `vim.lsp` client — no lspconfig#3704-style `exepath()` workaround needed in
  the config file.
- The same simulation passes on Linux (shell-script shim on `$PATH`), so both
  npm shim styles are covered.
