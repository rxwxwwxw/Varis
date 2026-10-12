# Editors

`varis lsp` is a Language Server (stdio) over the project index: diagnostics, completion,
definition, references, hover, outline and rename (which also rewrites `l10n/` catalog keys).
It never runs project code.

- **Highlighting:** `varis.tmLanguage.json` is a TextMate grammar (scope `source.varis`) and
  `language-configuration.json` the matching bracket and comment configuration. Varis files keep
  the `.lua` extension today (ROADMAP open decision 2), so an editor must be told to use this
  grammar for a project's files; it is a superset of Lua's highlighting.
- **Any LSP client:** start `varis lsp` with the project directory as the workspace root, for
  files of the project. For example in Neovim:

  ```lua
  vim.lsp.start({ name = "varis", cmd = { "varis", "lsp" }, root_dir = vim.fn.getcwd() })
  ```

- **VS Code:** use a generic LSP client extension with command `varis` and arguments `["lsp"]`,
  and associate the grammar with the project's files.

The workbench (`varis serve`) uses static diagnostics and indexed definitions in process;
its completion still reads live state and its UI has no hover/rename. The LSP exposes
the fuller static service set, including literal scenes/characters. See
[workbench status](../WORKBENCH_PLAN.md#1a-what-exists-today).
