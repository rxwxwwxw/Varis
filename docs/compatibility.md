# Varis Reference Manual — Interpreter and Compatibility

[Contents](README.md) · [Libraries](libraries.md) · [Syntax](syntax.md)

## 8 — The interpreter and host interfaces

### 8.1 — Standalone execution

Build with `make dlua` and run `bin/dlua [options] [script [args]]`. Varis is the
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
make dlua
bin/dlua docs/examples/relations.lua
bin/dlua docs/examples/narrative.lua
bin/dlua -e 'print(type(:room), logic.symbolname(:room))'
```

### 8.2 — Embedding and native modules

The D API is exported through `source/dlua/package.d` and the `dlua` modules.
Hosts construct a `LuaState`, open desired libraries with `openLibs`, and execute
source with `doString` (or compile/load through the frontend and VM APIs). `LuaValue` holds primitive and reference values;
`LuaException` carries language errors. Embedded hosts remain responsible for
native callbacks, external side effects, and any authored reconstruction protocol.

The executable also exports a **subset** of the Lua C API for loading simple
native modules with `package.loadlib`/C searchers. `lua_api.exports` and
`source/dlua/capi.d` describe the actual exported symbols. This is not a complete
Lua ABI: native error/yield continuations, arbitrary callbacks into the VM, and
internal Lua structures must not be assumed compatible. No new Varis native ABI
or public programmatic Lua rule/query builder is defined by this manual.

## 9 — Compatibility and implementation limits

### 9.1 — Relationship to Lua

Varis retains the implemented procedural syntax, values, libraries, lexical
closures, multivalue behavior, and coroutine model inherited from Lua 5.4, while
adding symbols, relations, transactions, and narrative facilities. New construct
words are contextual, preserving ordinary identifier uses. Opening libraries adds
`logic`, `symbol`, `narrative`, and `quality` globals; an older program assigning
those names can replace the library values. Dedicated language operations do not
work by calling these replaceable globals.

Future divergence will be documented here as language changes. This edition does
not rename syntax or claim support for proposed story/game features absent from
the current runtime. Compound logical terms, procedural backtracking, cuts,
non-stratified negation, cross-world rule dependencies, individual rule deletion,
and statement-based guards are not defined. Aggregates, weighted text variants,
and custom display formatters **are** implemented.

### 9.2 — Current compatibility evidence

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
