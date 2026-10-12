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

`bin/varis check [--json] [files...]` compiles files without running them. Without
file arguments it checks the files listed by the project manifest, or every `.lua`
file under the current directory when there is no manifest.

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
symbol written once in the whole project and never as a plain name) and
`computed-text` (a label or name whose text is not a string literal, so it cannot
be extracted for translation), `duplicate-id` (error: two storylets, actions or
decks of one name, or two choices of one storylet), `unknown-deck` (error: `deck :x`
with no `deck :x {...}`), `unknown-placeholder` (error: `{name}` that is not a
parameter of the storylet or choice), `relation-arity` (error: a use that disagrees
with the declared columns), `unknown-relation` and `unknown-quality` (warnings: a
relation read that nothing declares, asserts or derives; a quality no
`quality.define` names). A finding that carries a near name has a `suggestion`. `varis check --index` prints the project index:
the declarations, references and display messages read from the source files.


### 8.4 — Message catalogs: `varis l10n`

`bin/varis l10n` reads the project like `varis check` (the manifest, else every
`.lua` file) and runs nothing. Every display text that is a string literal has a
**message key** built from authored names: a storylet's `title` is `lamp.title`,
a choice's is `lamp.light.title`, a quality's label `quality.oil.label`, a
`narrative.name` label `name.keeper`. Text built by code has no key and is
reported as `computed-text`; empty text is not extracted.

| Command | Does |
| --- | --- |
| `l10n extract [--check] [--carry-renames]` | Writes `l10n/source.json`, the messages of the package sorted by key with source text, revision, arguments and context, and prints what changed. With `--check` it writes nothing and fails when the file is out of date. |
| `l10n status` | Per locale of the manifest: reviewed, draft, stale and untranslated messages, and the definitions with work left. |
| `l10n export [--locale L] [--format csv] [--out FILE]` | The catalog as CSV (UTF-8 with a byte order mark): `key,source,translation,status,revision,context,arguments`. |
| `l10n import FILE --locale L [--apply]` | Proposes `draft` translations and rejects unknown keys and placeholders the source does not have; writes `l10n/L.json` only with `--apply`. |

A message's **revision** is a hash of its text with case, spacing and punctuation
outside template tags removed. A source edit that leaves the revision equal is
*cosmetic*: translations keep their status. Any other edit is *substantive* and
marks translations of that message `stale` (their text is kept). A removed key
and an added key with the same words are reported as a probable rename;
`--carry-renames` moves the translation to the new key.

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
  exist. Planned authoring tools debug at the level of source lines and story
  turns and are not built on the `debug` library.
- A restricted tier for content files is planned, excluding coroutines, function
  values that capture mutable state, and the `io`, `os`, `debug`, `package`, and
  `load` facilities and metatables from authored content. Engine scripts and
  script mods keep the full language. The tier is not implemented; every file is
  currently compiled as the full language.
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
platform shell shim. These are recorded results, not a fresh run of every suite
for this documentation change or a claim of complete Lua conformance.

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
- `STALE_CHOICE`, reentrant commands, `ACTION_LIMIT`, `EVENT_LIMIT`, and
  `OBSERVER_QUEUE_LIMIT`, with the commit boundaries specified in section 6.
- Unsupported saved values/captures, non-reconstructible programs, malformed
  histories, incompatible versions/schemas, and invalid migrations.

Errors should identify the relevant relation/content/variable and source location
where available. Except for documented diagnostic identifiers, programs should
not depend on exact human-readable error text.
