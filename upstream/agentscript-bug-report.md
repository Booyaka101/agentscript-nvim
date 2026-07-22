# Bug report for salesforce/agentscript

**Where to post (checked 2026-07-22):** this exact bug is unreported, but the
same broken publish pipeline is already on file for the `agentforce` SDK
package as [issue #71](https://github.com/salesforce/agentscript/issues/71)
(stale `language` pin, missing `nullLiteralValidationPass`; earlier incident
[#35](https://github.com/salesforce/agentscript/issues/35) /
[PR #40](https://github.com/salesforce/agentscript/pull/40); proposed CI fix
[PR #72](https://github.com/salesforce/agentscript/pull/72)). Post the text
below either as a comment on #71 ("also affects the LSP server") or as a new
issue cross-referencing #71 — new issue preferred, since the affected package,
error, and minimum working `language` version (2.8.4 vs 2.18.0) all differ.

**Title:** `@sf-agentscript/lsp-server@2.2.30` crashes at startup: `variantMatch is not a function` (stale `@sf-agentscript/language` pin)

**Body:**

Running the published LSP server crashes immediately, before the LSP
connection is established:

```
npx --yes @sf-agentscript/lsp-server --stdio
```

```
.../@sf-agentscript/agentforce-dialect/dist/schema.js:217
    .variantMatch('byon', (value) => value.startsWith(BYON_SCHEMA_PREFIX), byonSubagentVariant);
     ^
TypeError: NamedBlock(...).describe(...).discriminant(...).variant(...).variantMatch is not a function
```

**Cause:** `@sf-agentscript/agentforce-dialect@2.13.4` (published 2026-06-10)
uses the `variantMatch` schema-builder API, but pins
`@sf-agentscript/language@2.5.4` (2026-06-01), which predates that API —
`variantMatch` first shipped in `@sf-agentscript/language@2.8.4`
(published 2026-06-11, one day *after* the dialect). It looks like the dialect
was built against the unreleased workspace version of `language` and published
with a stale exact pin. Because every `@sf-agentscript/*` dependency is an
exact pin, no fresh install of `@sf-agentscript/lsp-server@2.2.30` (or
`@sf-agentscript/lsp@2.3.8`) can currently work.

**Workaround (verified):** install with an npm override:

```json
{
  "dependencies": { "@sf-agentscript/lsp-server": "2.2.30" },
  "overrides": { "@sf-agentscript/language": "2.8.4" }
}
```

With that override the server initializes and publishes diagnostics normally
(verified against Neovim's LSP client on Node 22).

**Fix:** republish `agentforce-dialect` / `lsp` / `lsp-server` with
`@sf-agentscript/language >= 2.8.4` (or the current 2.19.3 train).

**Related:** same publish-pipeline defect as #71 (`@sf-agentscript/agentforce`
unusable for the same reason, different missing symbol) and the earlier
#35 / #40 scope-rewrite incident; the post-publish import smoke test proposed
in #72 would have caught this too.

**Environment:** Node.js 22.18.0, npm registry state as of 2026-07-22.
