---@brief
---
--- https://github.com/salesforce/agentscript
---
--- Agent Script is Salesforce's open agent specification language for
--- configuring agent orchestration (open sourced under Apache 2.0, generally
--- available since July 2026 when it replaced the legacy Agentforce Builder).
---
--- `agentscript-lsp` is the official language server. It provides diagnostics,
--- completions, hover, go-to-definition, references, rename, document symbols,
--- code actions and semantic tokens for `*.agent` files. Install it via `npm`:
---
--- ```sh
--- npm install -g @sf-agentscript/lsp-server
--- ```
---
--- Neovim does not detect the `agentscript` filetype by default. Register it:
---
--- ```lua
--- vim.filetype.add({ extension = { agent = 'agentscript' } })
--- ```

---@type vim.lsp.Config
return {
  cmd = { 'agentscript-lsp', '--stdio' },
  filetypes = { 'agentscript' },
  root_markers = { 'package.json', '.git' },
}
