# Editors

`varis lsp` is a Language Server (stdio) over the project index: diagnostics, completion,
definition, references, hover, outline and rename (which also rewrites `l10n/` catalog keys).
It never runs project code.

- **Highlighting:** `varis.tmLanguage.json` is a TextMate grammar (scope `source.varis`) and
  `language-configuration.json` the matching bracket and comment configuration. Varis source
  files use the `.varis` extension (owner decision of October 13, 2026; the language is shown as
  **Varis**, not Lua), and an editor picks this grammar from the extension. Existing `.lua`
  files keep loading, and an editor must be told to use this grammar for those; it is a superset
  of Lua's highlighting.
- **Any LSP client:** start `varis lsp` with the project directory as the workspace root, for
  files of the project. For example in Neovim:

  ```lua
  vim.lsp.start({ name = "varis", cmd = { "varis", "lsp" }, root_dir = vim.fn.getcwd() })
  ```

- **VS Code:** use a generic LSP client extension with command `varis` and arguments `["lsp"]`,
  and associate the grammar with the project's files.

The workbench (`varis serve`) uses the same static diagnostics, source completion,
definitions, hover and rename services in process, including unsaved drafts and
literal scenes/characters. Command-window completion reads live state. Rename
previews edits in drafts and writes them only on Save all. See
[workbench status](../WORKBENCH_PLAN.md#1a-what-exists-today).
