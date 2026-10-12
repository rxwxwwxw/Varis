# Varis

A narrative engine: a language and runtime for authoring visual novels and story games,
written in D.

Varis combines quality-based narrative (storylets, qualities, decks, choices) with a
relational world model: facts and Datalog rules describe what is true, transactional
effects change it, and sessions save and replay deterministically. Its procedural core
is a full language derived from Lua 5.4, so ordinary Lua syntax and semantics carry over
and a game can be modded with all of Lua.

**Direction** (revised October 11, 2026). Varis began as a D port of Lua 5.4. The goals now
are:

- easy, safe authoring by writers who are not programmers;
- a world model that answers a turn within a budget on low-end hardware;
- a complete Lua-derived language for engine scripts and mods, whose core is never slower
  than C Lua (passing more of the official Lua suite is not a goal);
- tools as part of the language: a project checker, language services, and a workbench in
  a web browser served by the Varis executable, laid out like MATLAB (command window,
  editor, workspace), with debugging at the level of the source and the story;
- an implementation in C-like D: return values instead of exceptions, `@nogc nothrow` hot
  paths, little Phobos, and one garbage collector (D's).

[ROADMAP.md](ROADMAP.md) states the goals, records who decided what and why, and defines
the planned phases. [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md) is the
staged performance plan and [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) the tool design.
**The planned work is not implemented yet**; the sections below describe the code as it is.

The [Varis Reference Manual](docs/README.md) is the single source of truth for the
current language: procedural programming, symbols, finite relations, keyed state,
transactions, aggregates, and the narrative runtime and authoring libraries.
[Conformance evidence and limits](tests/narrative/README.md) are recorded separately;
[the implementation plan](LANGUAGE_EXTENSIONS_PLAN.md) is engineering history, not
another language reference. [`sample-game/`](sample-game/README.md) is a small complete
game written against the current manual.

---

## Implementation Highlights

This is the implementation **as it stands**. Several of these points are planned to change
(value representation, error handling, the split between the Lua core and the world model);
[AGENTS.md](AGENTS.md) §5 lists today's state against the target.

- **Relational and Narrative Runtime**: A finite Datalog engine (worlds, stratified negation, snapshot queries, aggregates), keyed state with transactions, and a narrative runtime (storylets, choices, actions, decks, templates, qualities, events, portable saves and replay) in `source/varis/logic/` and `source/varis/narrative/`.
- **D Implementation**: Written in D for LDC. Existing code leans on Phobos; the project's style is now C-like D (return values, `@nogc nothrow` hot paths, plain structs), and the code is being moved to it by planned stages, not piecemeal.
- **Value Representation**: `LuaValue` wraps `std.sumtype` today (24 bytes), with customized equality and hashing adhering to Lua 5.4 semantics (e.g. `1 == 1.0`, NaN handling, reference equality for objects). A 16-byte hand-written tagged union is planned.
- **One Garbage Collector**: All objects live on D's garbage collector (`core.memory.GC`), so host D code can hold tables, worlds and sessions as ordinary references. This is permanent.
- **Errors**: Lua errors are D exceptions today (`class LuaException : Exception`), caught by `pcall` and `xpcall`. Errors as return values are planned, because unwinding is the largest single cost in the core (`pcall` round trips are 37× C Lua).
- **Fiber-Backed Coroutines**: Coroutines and Lua threads are backed by D's `core.thread.Fiber`, enabling yields across native boundaries. The declarative engine evaluates finite relations to a fixed point; guards cannot yield during inference.
- **Typed AST Intermediate Representation**: Replaces Lua's single-pass intertwined parser/compiler with a modular pipeline (`Lexer -> AST -> Compiler -> VM`), making AST transforms and grammar modifications straightforward.
- **Lua Pattern Engine**: Ports Lua's pattern matching engine to D, targeting compatibility with Lua string patterns (`%a`, `%b`, frontier patterns `%f[]`, and captures).
- **License Integrity**: Preserves original Lua 5.4 MIT licensing (PUC-Rio) and attributes all derived work.

---

## Architecture Overview

```
                      +-------------------+
                      | Lua Source Script |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |    varis.lexer     | Tokenizer
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |    varis.parser    |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |     varis.ast      | Typed AST (Extensibility Hook)
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |   varis.compiler   | AST -> Bytecode
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |      varis.vm      | VM Dispatcher
                      +---------+---------+
                                |
      +-------------------------+-------------------------+
      |                         |                         |
      v                         v                         v
+-----------+            +-------------+           +--------------+
| varis.types|            | varis.table  |           |  varis.fiber  |
|  SumType  |            | Dual-Storage|           | D Lang Fiber |
+-----------+            +-------------+           +--------------+
```

---

## Directory Structure

```
varis/
├── Makefile                     # Build and test orchestration using ldc2
├── README.md                    # Project overview and quick start
├── AGENTS.md                    # Architecture guide and instructions for AI agents
├── ROADMAP.md                   # Direction, decision record, order of work, planned phases
├── WORKBENCH_PLAN.md            # Proposal: web workbench (editor, command window, workspace, debugger)
├── NARRATIVE_LOCALIZATION_PLAN.md # Proposal: localization pipeline
├── benchmarks/                  # Workloads, targets.toml, PERFORMANCE_PLAN.md (current plan), history
├── docs/                        # Varis language reference, libraries, grammar, examples
├── LANGUAGE_EXTENSIONS.md       # Redirect to the Varis reference
├── LANGUAGE_EXTENSIONS2.md      # Redirect to the Varis reference
├── LANGUAGE_EXTENSIONS_PLAN.md  # Engineering history: base, companion and Phase 8 milestones
├── sample-game/                 # Saltmarsh Light sample game and proposed extensions
├── LICENSE                      # MIT License (Lua 5.4 PUC-Rio + varis)
├── tests/datalog/acceptance/          # Base declarative extension acceptance tests
│   ├── README.md                # Coverage and runner limitations
│   ├── run-tests.sh             # Runs an extended interpreter against the suite
│   ├── positive/                # 12 programs expected to succeed
│   └── negative/                # 3 programs expected to be rejected
├── c-implementation/            # Original C source & reference tests
│   ├── src/                     # Lua 5.4.9 C source code
│   └── lua-5.4.9-tests/         # Official Lua 5.4.9 test suite
├── source/
│   └── varis/
│       ├── package.d            # Public API exports
│       ├── types.d              # LuaValue sumtype, value helpers, raw equality
│       ├── exception.d          # LuaException, error reporting
│       ├── table.d              # Dual-storage LuaTable (array + hash)
│       ├── state.d              # LuaState runtime, globals (_G), pcall
│       ├── ast.d                # Abstract Syntax Tree nodes (Phase 2)
│       ├── lexer.d              # Lexer & Tokenizer (Phase 2)
│       ├── parser.d             # Recursive descent parser -> AST (Phase 2)
│       ├── opcode.d             # Bytecode instruction definitions (Phase 3)
│       ├── compiler.d           # AST -> Bytecode compiler (Phase 3)
│       ├── vm.d                 # Bytecode VM dispatch engine (Phase 3)
│       ├── fiber.d              # Coroutine fiber runner (Phase 3)
│       ├── pattern.d            # Ported Lua pattern matching engine (Phase 4)
│       ├── logic/               # Datalog model, worlds, validation, evaluation, queries
│       ├── narrative/           # Registry, sessions, templates, persistence, analysis
│       ├── lib/                 # Standard libraries, including logic
│       └── cli.d                # Standalone varis CLI / REPL (Phase 5)
└── tests/
    ├── unit/                    # D unit tests
    │   ├── test_foundation.d    # Value, table, state, and pcall tests
    │   ├── test_parser.d        # Lexer and parser tests
    │   ├── test_vm.d            # Compiler and VM tests
    │   ├── test_libs.d          # Standard library tests
    │   └── test_logic.d         # Declarative engine and integration tests
    └── runner.d                 # Automated official Lua 5.4.9 test runner (python3 tools/suite test --suite official)
```

---

## Build & Test

### Prerequisites

- **LDC**: LLVM D Compiler (`ldc2`), targeting LDC 1.43+ / D 2.100+.
- **Make**: Standard GNU Make.
- **Python 3.11+**: Runs the test/benchmark driver in `tools/suite`.
- **dfmt** 0.15.2 (`brew install dfmt`): formatting and the pre-commit hook.

### Running Tests

One driver (`python3 tools/suite`) runs every suite from one manifest, [tests/manifest.toml](tests/manifest.toml).
Tiers are cumulative:

| Command | Tier | Contents | Time |
| --- | --- | --- | --- |
| `make test-smoke` | smoke | parser/VM/foundation unit groups, Datalog acceptance, five regression programs | seconds |
| `make test-fast` | fast | + all unit groups, extension cases, regression programs, small-scale scenarios | ~10 s |
| `make test` | full | + official Lua 5.4.9 suite, large-scale scenarios, core differential, runner self-tests | ~20 s |
| `make release` | release | `make test` + enforced benchmark gates (`make bench-check`) and the gate-enforcement checks | ~3 min |

```bash
make test                                         # full tier
python3 tools/suite test --tier fast --filter keyed   # subset by case-id substring
python3 tools/suite test --list                   # enumerate cases
python3 tools/suite trace --verify                # requirement -> evidence map
```

Every skip, partial and known gap must be listed in the manifest's ledger (and a ledger entry
whose case starts passing is a failure). Results are also written as JSON with `--json`.
Individual suites: `python3 tools/suite test --suite <id>`; one D unit group:
`make unit-test UNIT=test_vm`. [tests/TRACEABILITY.md](tests/TRACEABILITY.md) maps the spec
requirements to cases.

### Declarative Extension Acceptance Tests

Run the base extension suite from the repository root:

```bash
python3 tools/suite test --suite acceptance --suite rejection
```

The standalone shell runner `tests/datalog/acceptance/run-tests.sh` runs the same programs against any interpreter given as its argument or in `LUA_BIN`; its default is `lua`, and stock Lua cannot parse the extension syntax.

The suite covers symbols, facts, recursion, stratified negation, retraction, conjunctive queries, guards and captures, world inheritance, lexical world blocks, local relations, snapshot iterators, immutable records, zero arity, and `nil` bindings. Positive programs assert their results without requiring a particular iteration order. Negative programs exercise unsafe negation, a negation cycle, and an arity mismatch.

Negative cases require the intended validation diagnostic and reject crashes, timeouts, and the `UNEXPECTED SUCCESS` fallback marker. Preserve those checks when adding or changing rejection cases. These examples complement the existing engine unit tests and broader conformance coverage; they do not establish full v0.1 conformance on their own.

### Building the Varis CLI Executable

```bash
# Build optimized release binary
make varis

# Run the CLI / REPL
./bin/varis -v
./bin/varis -e 'print("Hello from varis!")'
```

### Running Benchmarks

```bash
make bench          # report ratios against C Lua and absolute time budgets
make bench-check    # enforce gates and floors from benchmarks/targets.toml
make status         # regenerate docs/STATUS.md (full tests + all benchmarks; idle machine)
```

Current counts and ratios: [docs/STATUS.md](docs/STATUS.md) (generated, not hand-edited).

Core-language workloads are compared, in the same session, against stock C Lua 5.4.9 (`-O2`);
Datalog and narrative workloads have absolute time budgets. See [benchmarks/README.md](benchmarks/README.md).

### Repository Workflow

```bash
make hooks      # once: enable .githooks (dfmt check, header check, source list, size guard)
make fmt        # format all D sources with dfmt (settings in .editorconfig)
make check      # what pre-push runs: format + source checks + fast tier
```

### Cleaning Artifacts

```bash
make clean
```

---

## Performance Benchmarks

Varis has two performance targets, because it has two engines
([benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md) has the measurements and the
staged plan and what has landed; the first target is met on the development-machine stand-in, the
second is not yet):

1. **World model: a turn within a budget on low-end hardware.** Provisional budgets
   ([ROADMAP.md](ROADMAP.md), milestone 34): 50 ms per turn, 1 s content load, 50 ms per save,
   64 MB. Measured on a synthetic game (Apple M1, October 11, 2026) after the world-model
   rewrite: 0.7 ms per presentation with 100 rooms and 200 storylets and 3.2 ms with 1000
   storylets, with or without a recursive rule over the map (before: 3 ms, 15 ms, and 0.84 s with
   the recursive rule). Facts are shared instead of copied, joins use indexes, recursion is
   semi-naive and derived relations are cached. Peak memory (about 150 MB) is still over budget.
2. **Lua core: never slower than C Lua 5.4, then faster.** Measured against stock C Lua 5.4.9
   (`-O2`) in the same session, the core workloads are at 0.6–2.3× today (function calls and
   string operations are the slowest; caught errors went from 37× to 1.3× and deep recursion from
   8× to 2.7×).
   Every workload with a C Lua comparator has `goal.clua = 1.0` in `benchmarks/targets.toml`.

Current per-workload ratios are in the generated [docs/STATUS.md](docs/STATUS.md).
`make bench-check` enforces a per-workload regression gate against C Lua and absolute time
budgets, including for the Datalog and narrative groups (stock Lua cannot execute their syntax,
so they have no comparator).

History: Phase 8 pursued "no more than 2× C Lua" by tuning the existing design and was closed on
October 11, 2026 with most workloads inside that bound.
[benchmarks/PERFORMANCE_WORK.md](benchmarks/PERFORMANCE_WORK.md) records its methodology, changes
and remaining costs. The current target is stricter (1.0×) and the method is restructuring:
errors as values, a smaller value, a compact execution encoding, and separating the Lua core
from the world model.

### Lua compatibility status

The procedural core stays a complete Lua-derived language, because mods use all of it.
The official Lua suite, a differential fixture and the regression programs stay in
`make test` as a regression net for it. Passing more of the official suite is not a goal:
no work is planned on the remaining differences, and deliberate divergences are allowed
when recorded (see the policy in [ROADMAP.md](ROADMAP.md)). The record as it stands:

- Conformance scope (owner decision): the official suite as a stock Lua 5.4 binary runs it (no internal `T` library), with `gc.lua` excluded; an ltests-style `T` for `api.lua`/`code.lua` is out of scope. The official Lua 5.4.9 suite runs clean: the October 9, 2026 release-build run reports **31 pass, 1 partial, 1 skipped, 0 fail, 0 timeout** across 33 files (240 seconds per file, C Lua as reference). `gc.lua` is the one skip, excluded by decision because exact collector reachability conflicts with keeping Varis objects directly accessible from D. The one partial is the suite driver `all.lua`, which the runner executes with `gc.lua` stubbed (it ends with `final OK !!!` and also pushes each file through `string.dump`/`load`). The suite's C test modules are compiled and loaded through the exported C API subset (`source/varis/capi.d`), and `files.lua` runs against an `sh` wrapper because macOS `sh` reports a signal for the nested-shell check where the suite expects an exit status. `api` and `code` pass because, as with stock C Lua, they return immediately when the internal `T` library is absent. See the [recorded results and remaining issues](tests/official/README.md); a file pass means the process exited successfully.
- `python3 tools/suite test --suite official` fails on interpreter failures or timeouts. The runner captures both output streams without pipe deadlocks and retains exit codes and diagnostics. Weak tables and `__gc`/`__close` finalizers are emulated on D's conservative GC (`source/varis/gc.d`), so `collectgarbage` modes/step are bookkeeping-level rather than a Lua collector. Native stack use (~5 KB per Lua call frame) and slow deep-recursion unwinding (D exceptions through the platform unwinder) remain known performance issues.
- Implemented conformance work includes luac-style compiler output (RK operands, condition jumps, line attribution, strip semantics), lvm.c-style loops and error messages with variable info, ports of lstrlib/ltablib/lmathlib/loslib/liolib/loadlib/lcorolib/lua.c, binary chunks (`string.dump`/`load`, private body behind a standard header), debug hooks/getinfo/locals/upvalues, coroutine close/wrap semantics, tracebacks and C-call depth limits. The explicit skips and partial exclusions above are the only recorded gaps.
- `python3 tools/suite test --suite core` compares a deterministic core fixture against bundled C Lua. `make test` includes runner regression tests, while the official suite and differential target remain separate gates.
- Preserve the base and companion requirement mappings, intended rejection
  diagnostics, and separately identified aggregate/authoring coverage. Report
  forced-GC skips and bounded analysis/replay limits from the
  [companion audit](tests/narrative/README.md).

Performance changes must pass existing gates and targeted semantic regressions;
known unsupported cases remain visible rather than being counted as successes.

---

## Roadmap

- [x] **Phase 1: Foundation**: Core values (`LuaValue` sumtype), dual-storage table (`LuaTable`), state management (`LuaState`), exceptions (`LuaException`), build system, and unit tests.
- [x] **Phase 2: Frontend**: Lexer, typed AST, and recursive descent parser.
- [x] **Phase 3: VM & Execution**: Typed instruction set, AST-to-bytecode compiler, VM execution engine, upvalues/closures, and fiber coroutines.
- [x] **Phase 4: Standard Libraries**: Base, math, string (with Lua pattern engine), table, coroutine, io, os, utf8, package, and debug libraries.
- [x] **Phase 5: CLI & Conformance**: CLI and runner implemented; the official suite reports 31 pass / 1 partial / 1 skipped / 0 fail (skip and partial documented in [tests/official/README.md](tests/official/README.md)).
- [x] **Phase 6: Declarative Extensions v0.1**: Finite Datalog relations, symbols, runtime facts/rules, stratified negation, lexical local relations, independent worlds, and snapshot query iterators.
- [x] **Phase 7: Stateful and Narrative Extensions**: Named/keyed relations, atomic updates, transactions, storylets and choices, automatic actions, decks, templates, qualities, events, deterministic saves/replay, authoring diagnostics, custom display formatters, and deterministic weighted text variants. Optional aggregates, subscriptions, and bounded state-space analysis are implemented.
- [x] **Phase 8: Core-Lua Performance & Conformance (closed)**: The conformance gate is met for all executable official files and most core workloads run within about 2× of C Lua (see Performance Benchmarks). Closed October 11, 2026; milestones 21–25 are retired. Core performance continues under a stricter target in Phase 11.
- [ ] **Phase 9: Authoring Language v1**: Content/engine file tiers, syntax triage and freeze, the authoring gaps found by the sample game, declared symbols, scenes and beats.
- [ ] **Phase 10: Authoring Tools and the Workbench**: `varis check` with source-ranged diagnostics, parser error recovery, language services and a language server built on the Varis frontend, writer playtest and CI workflow, and a web workbench served by `varis serve` (command window, editor, workspace, story panel) with debugging at source and story level.
- [ ] **Phase 11: Fast Runtime & Host Interface**: The sample game and a reference game as enforced checks, the seam between the Lua core and the world model, indexed semi-naive cached inference, the Lua core at parity with C Lua and then beyond, a documented D host API and a standard SDL3 presentation layer, builds for Windows, macOS and Linux (Android as a stretch).
- [ ] **Phase 12: Ergonomics**: Undo and persistent data, localization tooling and a publisher handoff kit, Twine-class conveniences, writer documentation.

Phases 9–12 are defined in [ROADMAP.md](ROADMAP.md) and are planned, not implemented.

Phase 6 follows the milestones in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md):

| Milestone | Deliverable |
| --- | --- |
| 0 | Record Lua compatibility baseline and resolve semantic edges |
| 1 | Symbols and correct relational equality/hashing |
| 2 | Worlds, relation storage, atomic mutations, and inheritance |
| 3 | Safety/stratification validation and fixed-point evaluation |
| 4 | Snapshot iterators, immutable bindings, and the `logic` library |
| 5 | Contextual syntax, lexer additions, and typed declarative AST |
| 6 | Compiler/VM integration and lexical relation/world capture |
| 7 | Guard captures, errors, and coroutine yield restrictions |
| 8 | Acceptance tests, full conformance coverage, and documentation |

The engine keeps logic variables separate from Lua values, uses raw equality for tuple sets, and initially recomputes derived results from base facts after mutations. Query snapshots capture relational state at construction, with evaluation deferred until the first iterator call. World defaults follow lexical closure capture, and rule guards capture ordinary Lua values by value at registration.

Compound terms, Prolog cuts/backtracking, aggregation, non-stratified negation, cross-world rule dependencies, and individual rule deletion are outside the base v0.1. Optional aggregates are implemented under the companion reference. Indexing, semi-naive evaluation, and structural sharing follow correctness and measurement.

### Companion implementation status

[The narrative chapter](docs/narrative.md) defines effects separately from Datalog inference. Milestones 9–18 in the [implementation plan](LANGUAGE_EXTENSIONS_PLAN.md#phase-7--stateful-relations-and-narrative-extensions) cover:

| Milestone | Deliverable/status |
| --- | --- |
| 9 | Complete: baseline, interfaces and semantic decisions |
| 10 | Implemented: named columns, extensional keyed relations, atomic `set`/`delete`/`adjust` |
| 11 | Implemented: world-scoped transactions, nested savepoints, rollback and iterator validity |
| 12 | Implemented: safe, lower-stratum `count`/`sum`/`min`/`max` goals |
| 13 | Implemented: definitions/registry/compiler, independent sessions and canonical instances |
| 14 | Implemented: templates, deterministic decks, presentation, tokens, atomic choices, custom display formatters, and weighted text variants |
| 15 | Implemented: actions, qualities/constraints, events/schedules and deferred callbacks |
| 16 | Implemented: portable saves/restoration, authored-rule validation, migrations and replay input logs |
| 17 | Implemented: explanations, committed-set subscriptions and isolated bounded choice analysis |
| 18 | Complete: separate conformance gates, requirement/error matrix, bounded replay/stress and documentation |

The implemented stateful syntax can be used now:

```lua
relation balance(entity, value) key(entity)
fact balance(:player, 10)
transaction do
    adjust balance(:player) by -2
    transaction do
        set balance(:player, 100)
        rollback
    end
end
assert((query balance(:player, ?value))().value == 8)
delete balance(:player)
```

Keys constrain base facts; conflicting facts error and keyed relations cannot be rule heads. Transactions prohibit yields, cross-world/local-relation mutations, and schema/rule registration. They commit on return/break exits and roll back on escaping errors or lexical `rollback`; caught errors preserve earlier tentative writes. Rolled-back iterators become invalid. Named schema upgrades are rejected after establishment; local declarations remain numeric-arity only. Lua object mutations and I/O remain outside rollback. See the plan's core decisions for details and current control-flow limits.

Core updates and transactions come first; narrative facilities build on that commit boundary. Choices revalidate eligibility against the current transaction snapshot, and failed effects leave transaction-aware state and turn unchanged. Transaction blocks prohibit yielding and cross-world mutation; arbitrary Lua table changes and external I/O are outside rollback. Content is shared through a sealed state-owned registry while sessions retain independent worlds, histories, deck entries, and seeded RNG state. Save files validate schema/content versions and serializable values rather than persisting arbitrary Lua closures. Aggregate goals, storylets, choices, actions, decks, templates, events, and session scheduling are available. `narrative.new(world)` creates a session; seed it with `session:seed(integer)`, obtain immutable presentations with `session:present()`, and pass an exact returned token to `session:choose(token)`. Session participants commit alongside facts, and deferred callbacks run after commit. The `quality` library provides explicit initialization, keyed access/updates, and metadata bounds enforced on direct relation writes. `session:save()` and `narrative.load(saved, world_factory)` support canonical portable saves with schema/content/program validation. Guard-bearing programs declare an authored reconstruction version with `narrative.program(world, version)`. `session:replay_log()` records commands and canonical instance keys. `narrative.explain` reports goal and policy outcomes without consuming RNG. `narrative.observe` delivers committed base/derived tuple changes, with deferred observer commands through `narrative.enqueue`/`narrative.flush`. `narrative.analyze(session, {depth=3, max_nodes=100})` explores an isolated seeded choice tree and reports its bounds/completeness. The [conformance audit](tests/narrative/README.md) records coverage, bounded analysis scope, authored reconstruction/replay obligations and existing Lua harness limits.

---

## License

`varis` is a derived work of Lua 5.4. It is licensed under the MIT License, preserving all original copyright notices from Lua.org, PUC-Rio. See [LICENSE](LICENSE) for the full text.

Portable narrative checkpoints use a versioned authored world factory:

```lua
function make_world()
    local world = logic.emptyworld()
    logic (world) do
        relation person(1)
        fact person(:player)
        rule eligible(?p) :- person(?p)
    end
    narrative.program(world, "my-rules-v1")
    return world
end
local session = narrative.new(make_world())
session:seed(42)
local saved = session:save()
local restored = narrative.load(saved, make_world)
```

The factory world is cloned before saved facts are restored. Saves reject
unsupported mutable values and incompatible schema/content/program versions.
Hosts can explicitly migrate saved text through the optional third argument to
`narrative.load`; the migrated result receives the same validation.
