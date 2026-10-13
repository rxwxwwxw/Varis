# Varis Reference Manual — Interpreter and Compatibility

[Contents](README.md) · [Libraries](libraries.md) · [Syntax](syntax.md)

## 8 — The interpreter and host interfaces

### 8.1 — Standalone execution

Build with `make varis` and run `bin/varis [options] [script [args]]`. Varis is the
language name used in this manual; executable, module paths, version strings,
source suffixes, and save-format identifiers retain their existing names until
an explicit implementation migration.

| Option | Meaning |
| --- | --- |
| `-e code` | Execute code; may be repeated. |
| `-l module` | Require a module into the global with its name. |
| `-l name=module` | Require into a selected global. |
| `-i` | Enter interactive mode after commands/script. |
| `-v` | Print current Lua compatibility version information. |
| `-E` | Ignore environment initialization/path overrides. |
| `-W` | Enable warnings. |
| `--` | End option processing. |
| `-` | End option processing and execute stdin. |

Script arguments are available through `arg` and chunk varargs. Without a script,
commands, or explicit version-only request, terminal input enters the REPL;
nonterminal input is executed as a chunk. Interactive input supports expressions
and continuation of incomplete chunks. Initialization uses `LUA_INIT_5_4`, then
`LUA_INIT`, unless `-E`; leading `@` loads a file. Package search uses Lua-named
path environment variables. SIGINT requests an interrupt error in active execution.

```sh
make varis
bin/varis docs/examples/relations.lua
bin/varis docs/examples/narrative.lua
bin/varis -e 'print(type(:room), logic.symbolname(:room))'
```

### 8.2 — Embedding and native modules

The D API is exported through `source/varis/package.d` and the `varis` modules.
Hosts construct a `LuaState`, open desired libraries with `openLibs`, and execute
source with `doString` (or compile/load through the frontend and VM APIs). `LuaValue` holds primitive and reference values;
`LuaException` carries language errors. Embedded hosts remain responsible for
native callbacks, external side effects, and any authored reconstruction protocol.

The executable also exports a **subset** of the Lua C API for loading simple
native modules with `package.loadlib`/C searchers. `lua_api.exports` and
`source/varis/capi.d` describe the actual exported symbols. This is not a complete
Lua ABI: native error/yield continuations, arbitrary callbacks into the VM, and
internal Lua structures must not be assumed compatible. No new Varis native ABI
or public programmatic Lua rule/query builder is defined by this manual.

### 8.3 — The project manifest and `varis check`

`bin/varis check [--json] [files...]` parses, compiles and statically checks files.
With a manifest entry it also runs the load pass described below; use `--no-load`
for static checking only. Without file arguments it checks the files listed by the project manifest, or every `.varis`
and `.lua` file under the current directory when there is no manifest.

**Source files.** Varis source files use the extension `.varis` and the editor language
name **Varis** (owner decision of October 13, 2026); the extension identifies the
language and the manifest decides each file's tier. Existing `.lua` files load and check
exactly as before, a project can mix both, and `require("a.b")` finds `a/b.varis` when
no `a/b.lua` exists on `package.path` (`package.path` itself keeps its Lua spelling).
A manifest pattern written with `.lua` also matches the same name with `.varis`, so
renaming a file needs no manifest edit. The manifest may itself be `project.varis`; it
wins when both exist.

The **project manifest** is the file `project.lua` at the project root: one
`return { ... }` of literals. It is parsed and **never executed**. Fields:

| Field | Value | Meaning |
| --- | --- | --- |
| `id` | string | Package id. |
| `language` | string | Language tag of the display text in the source. |
| `entry` | string | Module that loads and seals the content. |
| `session` | string | `"module.function"`: function of a seed that returns a session. |
| `content` | list of patterns | Files that hold content. |
| `scripts` | list of patterns | Engine scripts. |
| `tests` | list of patterns | Author tests. |
| `symbols` | list of strings | Opt-in strictness: symbols (entities, flags, event kinds) that no declaration names. With it, any symbol neither listed nor named by a storylet, action, deck, scene, character, relation, quality or choice is an `undeclared-symbol` error, and `symbol-once` is not reported. `varis check --symbols` prints the symbols that need listing. The same strictness starts when any file contains a `symbols a, b, c` statement (below). |
| `locales` | list of strings | Translations kept in the repository. |

In a pattern `*` matches within one path segment, `**` across segments and `?` one
character. An unknown field is a warning (`manifest-key`); a manifest that does not
have this shape is an error (`manifest`).

`varis check` reports every syntax error of a file, not only the first: the
parser skips to the next statement or definition and goes on. Loading code
(`load`, `require`, running a script) is unchanged and stops at the first error.

Every diagnostic has a stable `code`, a `severity` (`error`, `warning`, `note`), a
`file`, a start `line` and `column` and an end `endLine` and `endColumn` (1-based
byte columns; the end is just past the last byte; 0 when unknown), and a `message`.
`--json` prints `{"files": N, "problems": [...]}`; the text form is
`file:line:column: severity: message [code]`. Only errors give exit status 1.
Codes in use: `syntax`, `io`, `manifest`, `manifest-key`, `symbol-once` (a
symbol written once in the whole project and never as a plain name),
`undeclared-symbol` (error under the manifest's optional `symbols` list), `tier`
(content-file policy violation), `unknown-scene`, `unknown-character`, and
`unknown-character-attribute` (errors for unresolved literal scene references),
`computed-text` (a label or name whose text is not a string literal, so it cannot
be extracted for translation), `duplicate-id` (error: two storylets, actions or
decks, scenes or characters of one name, or two choices of one storylet), `unknown-deck` (error: `deck :x`
with no `deck :x {...}`), `unknown-placeholder` (error: `{name}` that is not a
parameter of the storylet or choice), `relation-arity` (error: a use that disagrees
with the declared columns), `unknown-relation` and `unknown-quality` (warnings: a
relation read that nothing declares, asserts or derives; a quality no
`quality.define` names). A finding that carries a near name has a `suggestion`.

**The content tier.** Files matching `content` in the manifest are held to the content
tier: error `tier` for the globals `coroutine`, `io`, `os`, `debug`, `package`, `load`,
`loadstring`, `loadfile`, `dofile`, `setmetatable` and `getmetatable`; for a function
value or declaration, except a callback passed directly to `narrative.defer`,
`narrative.formatter` or `narrative.on`; and for a callback that uses a local of the
code around it. Engine scripts (`scripts`, `tests`) are unrestricted. The list is the
roadmap's default for open decision 1.

**Enforcement at load time (milestone 26).** The same restriction holds when the project
runs. A host that has read the manifest (`varis play`, `varis test`, `varis serve`, the
game host, the load pass of `varis check`) installs a policy on the state: each file loaded
from disk with `require`, `dofile` or `loadfile` that matches `content` is vetted by the
static check (a violation refuses the file, naming `file:line`), must be source text and
not a binary chunk, and runs in a **restricted environment** instead of the globals:
`assert error ipairs next pairs pcall print require select tonumber tostring type xpcall`,
copies of `math string table utf8`, the interfaces `narrative quality logic battle` and
`symbol`, and the helpers engine scripts exposed with `narrative.helper(name, value)`.
There is no `io`, `os`, `debug`, `package`, `load`, `coroutine` or metatable function to
alias, and reading any other global is an error that names `narrative.helper`, so a
mistyped or unexposed name is not a silent nil. Each file has its own environment, so
content files cannot talk to each other through globals; they use the world. Helpers are
trusted engine code responsible for respecting the saves and replay rules. A plain
`varis script.varis` run has no manifest policy and keeps the full language.

**Declared symbols.** `symbols player, keeper, lamp_room` (contextual, a declaration
that runs nothing) declares symbols for the whole project, in any file and in any order;
references keep the `:keeper` spelling. Named definitions (storylets, actions, choices,
decks, scenes, characters, relations, qualities, names) declare their own symbol, so
they need no second declaration. Once a project declares symbols, by this statement or
the manifest's `symbols` list, an undeclared symbol in content is an `undeclared-symbol`
error in `varis check` and refuses the file when it loads; engine scripts keep creating
symbols dynamically with `symbol(name)`.

When the manifest names an `entry` module and nothing else failed, `varis check`
also runs that module in a fresh state, up to the seal of the content, and reports
what the engine's validation says as `load` errors at the line of the storylet,
choice, action or rule that was rejected (it creates no session; `--no-load` skips
this pass). Running the entry module runs the project's own code with your
permissions, as `varis serve` does. With `--analyze [--depth N] [--nodes N]` it
also creates a session through the manifest's `session` function and runs
`narrative.analyze` on it: each storylet that bounded exploration never reached is
an `unreachable` warning (a hint, not a proof) and an exhausted bound is an
`analysis-incomplete` note. `varis check --index` prints the project index:
the declarations, references and display messages read from the source files.


### 8.4 — Message catalogs: `varis l10n`

`bin/varis l10n` reads the project like `varis check` (the manifest, else every
`.lua` file) and runs nothing. Every display text that is a string literal has a
**message key** built from authored names: a storylet's `title` is `lamp.title`,
a choice's is `lamp.light.title`, a quality's label `quality.oil.label`, a
`narrative.name` label `name.keeper`, a scene line `scene.<line-id>.text`,
and a character name `character.<id>.name`. Scene menu labels are not yet extracted.
Text built by code has no key and is reported as `computed-text`; empty text is not extracted.

| Command | Does |
| --- | --- |
| `l10n extract [--check] [--carry-renames]` | Writes `l10n/source.json`, the messages of the package sorted by key with source text, revision, arguments and context, and prints what changed. With `--check` it writes nothing and fails when the file is out of date. |
| `l10n status` | Per locale of the manifest: reviewed, draft, stale and untranslated messages, and the definitions with work left. |
| `l10n export [--locale L] [--format csv] [--out FILE]` | The catalog as CSV (UTF-8 with a byte order mark): `key,source,translation,status,revision,context,arguments`. |
| `l10n export --locale L[,L...] --format csv\|xliff\|json --kit DIR [--changed-since ID]` | A handoff kit: the messages of each locale in the chosen format (XLIFF 1.2 carries the owner, arguments and `when` clause as notes), the source catalog, a glossary (`l10n/glossary.json` or one made from the labels and names), the character set each language uses, and a kit id (a hash of the source catalog). The source of each kit is kept in `l10n/kits/ID.json`; with `--changed-since` only new and substantively changed messages are sent, each with the previous English. |
| `l10n import FILE(.csv\|.xlf\|.json) --locale L [--kit DIR] [--apply]` | Proposes `draft` translations and rejects unknown keys, text that does not parse and placeholders the source does not have; an entry made from an older revision (taken from the kit) arrives `stale`. Writes `l10n/L.json` only with `--apply`. Never deletes. |
| `l10n check --kit DIR FILE` | What a publisher runs with no source tree: the checks of `check --locale` against the kit's source catalog. |
| `l10n review --locale L [KEY...]` | The only way a translation becomes `reviewed` (stale ones cannot be). |
| `l10n build [--out DIR]` | Language packs: `DIR/L/pack.json` (`messages`, `charset`) for each locale of the manifest that passes the checks; stale translations are left out. |

A message's **revision** is a hash of its text with case, spacing and punctuation
outside template tags removed. A source edit that leaves the revision equal is
*cosmetic*: translations keep their status. Any other edit is *substantive* and
marks translations of that message `stale` (their text is kept). A removed key
and an added key with the same words are reported as a probable rename;
`--carry-renames` moves the translation to the new key.

### 8.5 — Language server: `varis lsp`

`bin/varis lsp` speaks the Language Server Protocol on standard input and output
for the project in the workspace root. It is built on the same project index as
`varis check` and never runs project code. It provides diagnostics (every syntax
error and the checks of 8.3, pushed as documents change), completion (symbols,
decks after `deck`, qualities inside `quality(...)`, relations in goals, declared
names and content words), definition, references, hover (a relation's columns and
keys, a quality's bounds, a storylet's parameters, `when` and title), document
symbols, and rename. Rename covers relations, symbols, qualities, decks, storylets,
actions and choices; it refuses a name that is taken or reserved, and when it renames
a storylet, choice or quality it also edits the message keys in `l10n/` catalogs. The
load and analysis passes of 8.3 run project code and are only in `varis check`.
`editors/` holds a TextMate grammar and setup notes.

### 8.6 — Playtest and author tests: `varis play`, `varis test`

Both commands run the project's `entry` module and the `session` function named in
the manifest (8.3), in a fresh state. Three more optional manifest fields name the
host's own steps, each `"module.function"`: `after_choose` (called with the session
after every choice, as `main.lua` of the sample game calls `sync_periods`), `finished`
(returns true when the game is over) and `load` (builds a session from saved text).

`varis play [--seed N] [--record FILE] [--replay FILE]` is a text front end: it
prints each presentation with numbered choices and reads commands from standard
input: a number chooses, `why NAME` explains why a storylet or action is not
available (the failing goal and the exclusions), `save [FILE]` and `load [FILE]`
write and read a save, `quit` leaves. `--record` writes the choices made as lines
`storylet choice param=value,...` and `--replay` plays such a file back with the
same seed, for bug reports.

`varis test [--json] [files...]` runs the files matching `tests` in the manifest
(or the named files), each in a fresh state, with the global `test` available:
`test.play{seed=N}` returns a session wrapper `t` with `t:choose(storylet, choice
[, bindings])`, `t:expect_shown(storylet [, bindings])`, `t:expect_hidden(...)`,
`t:expect_fact("told(:lamp)")`, `t:expect_no_fact(...)`, `t:expect_quality(entity,
name, value)`, `t:save()`, `t:load(text)`, `t:why(storylet)`, `t:world()` and
`t:session`. `test.case(name, function() ... end)` groups checks. A failure is a
`test` diagnostic at the line of the failing call; a missing storylet's message
includes `t:why`. Exit status is 1 when a test fails. A script run with plain `varis script.lua` in a project directory can `local test = require("varis.test")`, register cases and end with `test.run()`, which prints `checks passed` or fails; `sample-game/tools/check.lua` is written this way. `tools/project_ci.sh` runs
`check`, `test` and `l10n extract --check` as a CI recipe.

### 8.7 — Translations at run time and in tools

`bin/varis check --locale L|all` also checks the catalogs under `l10n/` against the
source text (`translation-syntax`, `translation-placeholder`,
`translation-condition`, `translation-variants` are errors; `stale` and
`unknown-key` warnings), and `varis l10n check --locale L|all [--require reviewed]`
prints the coverage and fails the release gate when a message is not reviewed.
`varis play --locale L [--keys]` and `varis test --locale L` load `l10n/L.json` as a
language pack and play in it; `--keys` shows the message key before each text, so
that a line can be reported by key. The locale `x-pseudo` needs no catalog: it
accents and lengthens the source text (`[Lóók áróúñd~~~]`) to show clipped text
boxes and hard-coded strings. `varis play --pack DIR` loads a built pack, as a released
game does with `narrative.load_pack(DIR)`: the pack is accepted or rejected as a whole, and
the error names the language and each bad key. Packs are registered with
`narrative.translate` (section 7). In the workbench the story panel has a language
selector (a switch renders the current presentation again) and a panel to edit a
translation, which is saved to `l10n/L.json` as a draft; for a message with `{#plural}` or `{#select}` it lists every branch rendered with sample values, in the language's plural rules, as the translation is typed. The editor highlights comments, strings and their template tags, symbols, logic variables, numbers and the content words.

### 8.8 — Web workbench: `varis serve`

`bin/varis serve [--port N] [project directory]` starts a native loopback HTTP
server and prints a browser URL with an access token. The browser provides the
command window, editor, workspace, relation tables and story panel; code runs
in the native interpreter. The server supports ordinary project scripts with
the user's permissions, rather than a content sandbox.

Storylets can be played through the manifest-backed Start button or after binding
a session with `story(session)` in the command window. The panel shows turn changes,
explains availability, and supports language switching and draft translations (8.7).

The source debugger supports file/line breakpoints and step over/into/out for code
started by commands, Run and story-panel operations. Effects stop with their transaction
open; inspection shows tentative facts, and continuation preserves normal commit/rollback.
Selecting a stack frame shows its locals. While paused, the command prompt evaluates
read-only expressions in that frame: literals, locals, captured values, raw table fields,
Boolean operations and basic numeric arithmetic/comparisons. It rejects calls, queries,
assignments and unsupported operators; it never invokes metamethods. Pause stops a running command or
story operation at its next line (never inside the workbench's own code); Stop aborts it
with `interrupted!`, also while stopped. Stop-on-error and pushed events remain unfinished.

In projects with manifest entry/session fields, Start creates a seeded playtest (`s` and
`w` in the workspace). Reload and Run rebuild in a fresh state and replay story-panel
commands by stable instance keys; Rewind reconstructs an earlier turn. Failed reloads
retain the current state. Replay covers panel commands and the manifest's `after_choose`
callback, not arbitrary command-window writes or external inputs. History lists recorded
panel commands. Workspace inspection supports raw paged Lua tables, session periods/decks/
completed instances, and snapshot-derived relation facts.

The editor uses the shared language services for source completion, definition, hover,
rename preview and project diagnostics over unsaved buffers. File switching retains drafts
and undo; rename applies to drafts and Save all writes them. Vendored CodeMirror provides
syntax highlighting, inline diagnostics and clickable breakpoint gutters that follow edits.
Pane sizes and selectable command history persist in browser storage. No Node installation
or network access is needed to build or use the editor.

## 9 — Compatibility and implementation limits

### 9.1 — Relationship to Lua

Varis is derived from Lua 5.4 and is not a Lua implementation: conformance to
Lua 5.4 is not a goal. Lua supplied the procedural core, and that core is kept as
a complete language, because existing knowledge and examples carry over and
because games are meant to be modded with all of it.

Varis currently retains the implemented procedural syntax, values, libraries, lexical
closures, multivalue behavior, and coroutine model inherited from Lua 5.4, while
adding symbols, relations, transactions, and narrative facilities. New construct
words are contextual, preserving ordinary identifier uses. Opening libraries adds
`logic`, `symbol`, `narrative`, and `quality` globals; an older program assigning
those names can replace the library values. Dedicated language operations do not
work by calling these replaceable globals.

One deliberate divergence from Lua 5.4 has been made (owner decision, October 12,
2026): the depth at which a runaway recursion raises `stack overflow` is
approximate. Frames of up to 16 stack slots are charged a flat 6 slots each
against the 1,000,000-slot limit instead of their exact size, so ordinary calls
do no accounting; larger frames are counted exactly. The error, its message and
its recoverability are unchanged, and no test result changed. The policy
for further ones (owner decisions, October 11, 2026; see the decision record in the
[roadmap](../ROADMAP.md)):

- The official Lua suite, the core differential fixture, and the regression
  programs remain executable regression evidence for the procedural core. No work
  is planned on the differences they still record.
- A Lua behavior may be changed or removed when that serves authoring, saves and
  replay, portability, or performance. Each such change is listed in this section
  and in the test ledger when it is made.
- These inherited facilities are frozen and are candidates for removal: the C API
  subset and native module loading (8.2), binary chunks, weak-table and finalizer
  emulation with collector tuning modes, debug-hook and line-attribution
  fidelity (9.3), and exact upstream error text. They keep working while they
  exist. The workbench's initial debugger works at source lines and story
  turns; the complete interface remains planned and is not built on the `debug` library.
- The manifest content tier is checked statically by `varis check` and LSP,
  including restricted globals and function captures, and enforced when a project
  loads (restricted environment, 8.3). Engine scripts and script mods keep the full
  language. Source files may use the `.varis` extension; `.lua` still loads (8.3).
- The internal representation of values, instructions and errors is planned to
  change for performance. Such changes are not divergences: they must leave every
  behavior defined in this manual, and saved games, unchanged.

This edition does
not rename syntax or claim support for proposed story/game features absent from
the current runtime. Compound logical terms, procedural backtracking, cuts,
non-stratified negation, cross-world rule dependencies, individual rule deletion,
and statement-based guards are not defined. Aggregates, weighted text variants,
and custom display formatters **are** implemented.

### 9.2 — Current compatibility evidence

This evidence describes how much inherited Lua behavior currently works. It is a
regression record, not progress toward a conformance target.

The recorded October 9, 2026 Lua 5.4.9 release-CLI baseline is **31 pass, 1 partial,
1 skipped, 0 fail, 0 timeout** across 33 files. The official runner targets the
suite as a stock binary with `T == nil`, excluding `gc.lua` by owner decision.
`all.lua` is partial because it runs with that file stubbed. `api.lua` and
`code.lua` self-skip internal `T` assertions as under stock C Lua; their process
passes do not validate a complete C API or upstream instruction representation.
The harness also supplies native modules, a closed-pipe stdin, and a documented
platform shell shim. These baseline results do not claim complete Lua conformance.
The generated [project status](STATUS.md) records the most recent full test and benchmark run.

[The official audit](../tests/official/README.md) records exact scope, environment,
remaining diagnostics, baseline JSON, and test commands. Separate
[stateful/narrative evidence](../tests/narrative/README.md) and
[requirement traceability](../tests/TRACEABILITY.md) cover relational and narrative
contracts. Core stateful behavior, aggregates, narrative behavior, and optional
authoring facilities remain separate coverage categories.

### 9.3 — Collection, chunks, and diagnostics

D collection does not reproduce exact Lua reachability, collection timing,
memory accounting, or incremental/generational tuning. Weak tables, ephemerons,
and finalizers are emulated. Unreachable self-referencing suspended coroutine
stacks may remain roots. The official `gc.lua` exclusion is explicit; deterministic
`<close>` cleanup is the appropriate contract for scope-bound resources.

Binary chunks use a standard-looking Lua header with a private implementation
body. `string.dump`/`load` roundtrips within the runtime do not establish C Lua
bytecode interchange. Persist authored source/versioned content rather than
assuming a cross-runtime binary format.

Debug hooks, stack inspection, local/upvalue APIs, and tracebacks are implemented,
but temporary-register names, computed caller names, some line/hook attribution,
and rare variable-info diagnostic suffixes can differ from upstream. Consult the
audit for the maintained backlog. Resource limits and error unwinding costs are
implementation properties, not promises of unbounded recursion or allocation.

### 9.4 — Transaction, inference, and authoring boundaries

Transactions roll back logical and registered narrative participants only.
External objects, I/O, and globals remain changed. Callbacks invoked after commit
can fail while leaving the commit published. Scheduler limits preserve earlier
commits, so a command failure does not imply the whole session command was undone.

Query snapshots freeze membership and rules, not arbitrary mutable objects.
Guard purity beyond runtime mutation/yield checks is an author obligation.
Snapshots and cache invalidation cannot track arbitrary external-state changes.

Portable saves require reconstructible authored code, portable values, and
matching validated identities. Logs require host replay of external inputs;
they are not a general external-world recorder. Subscription queues and closures
are not inherited or saved. Explanations show conjunction prefixes; analysis
explores a bounded seeded choice tree, not all possible future behavior. Its
scope and completeness must accompany any interpretation of its results.

### 9.5 — Error categories

Syntax and static binding errors may be rejected during parsing/compilation.
Rule/query structure is checked at its compilation/registration/construction
boundary. Registration/content sealing validates required fields, grounded
parameters, known references, and immutable options. Updates validate at execution.
Lazy inference errors reach the iterator caller. Errors include:

- Arity/schema/key conflicts; duplicate columns; keyed or protected rule heads.
- Unsafe variables, invalid anonymous positions, negative/aggregate cycles,
  cross-world rules, or persistent rules retaining local dependencies.
- Unknown query relations, invalid world values, NaN constants/tuples,
  unsupported comparisons, guard errors, and invalid iterator reuse.
- Unsuitable keyed updates, missing/nonnumeric adjustments, quality constraints,
  prohibited transaction declarations/local mutations/cross-world writes/yields.
- Duplicate/sealed content, unknown decks/placeholders, invalid frozen options,
  ungrounded parameters, and nonportable scalar instance keys.
- `STALE_BEAT`, invalid scene input/control flow, unknown characters/attributes,
  duplicate line ids, and malformed saved scene positions/stage (§6.11).
- `STALE_CHOICE`, reentrant commands, `ACTION_LIMIT`, `EVENT_LIMIT`, and
  `OBSERVER_QUEUE_LIMIT`, with the commit boundaries specified in section 6.
- Unsupported saved values/captures, non-reconstructible programs, malformed
  histories, incompatible versions/schemas, and invalid migrations.

Errors should identify the relevant relation/content/variable and source location
where available. Except for documented diagnostic identifiers, programs should
not depend on exact human-readable error text.
