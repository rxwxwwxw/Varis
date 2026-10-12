# Workbench browser assets

The executable embeds `editor.bundle.js`. Ordinary `make varis`, `make test` and
release builds require no Node, package download or browser build step.

`editor/main.js` adapts CodeMirror 6 to the workbench. Syntax colours are visual;
all semantic services use the Varis frontend through the workbench protocol. The
editor retains document states (including undo), shows source-ranged diagnostics
and breakpoint markers, and requests indexed completion and hover. Breakpoints
move with edits and are synchronized to the server before Run.

To maintain the bundle, install Node and pnpm, then run these commands with
`workbench/editor/` as the working directory:

```sh
pnpm install --frozen-lockfile --ignore-scripts
node build.mjs
```

The lockfile pins CodeMirror, its dependencies and esbuild. The maintenance build
writes `../editor.bundle.js` and `../THIRD_PARTY_NOTICES.txt`; review both together
with changes to `main.js`. Third-party MIT notices are also embedded in the bundle
so they accompany the standalone executable. Keep the prebuilt bundle checked in.

The optional browser test uses Node/Playwright and a Chromium browser:

```sh
node tests/workbench/ui_test.cjs bin/varis
```

`VARIS_BROWSER` can name an existing Chromium executable, and
`VARIS_UI_SCREENSHOT` can name a screenshot output path. Normal protocol tests
need only Python and the executable, and run as part of `make test`.
