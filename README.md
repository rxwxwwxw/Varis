# Varis

A language and runtime for authoring visual novels and story games, written in D.

Varis combines quality-based narrative (storylets, qualities, decks, choices) with a
relational world model: facts and Datalog rules describe what is true, transactional
effects change it, and sessions save and replay deterministically. Its procedural core
is derived from Lua 5.4, so ordinary Lua syntax and semantics carry over.

**Direction.** Varis began as a D port of Lua 5.4. Lua conformance is no longer a goal;
the goals are easy, safe authoring by writers who are not programmers, authoring tools
(a project checker and a language server), and good behaviour under a graphical front
end on low-end hardware. [ROADMAP.md](ROADMAP.md) states the goals, the Lua compatibility
policy and the planned phases. The planned work is not implemented yet.

The [Varis Reference Manual](docs/README.md) is the single source of truth for the
current language: procedural programming, symbols, finite relations, keyed state,
transactions, aggregates, and the narrative runtime and authoring libraries.
[Conformance evidence and limits](tests/narrative/README.md) are recorded separately;
[the implementation plan](LANGUAGE_EXTENSIONS_PLAN.md) is engineering history, not
another language reference. [`sample-game/`](sample-game/README.md) is a small complete
game written against the current manual.

---

## Implementation Highlights

- **Relational and Narrative Runtime**: A finite Datalog engine (worlds, stratified negation, snapshot queries, aggregates), keyed state with transactions, and a narrative runtime (storylets, choices, actions, decks, templates, qualities, events, portable saves and replay) in `source/varis/logic/` and `source/varis/narrative/`.
- **Idiomatic D Architecture**: Implemented in modern D (targeting LDC / DMD) utilizing D's strong typing, ranges, slices, and Phobos standard library.
- **Robust Value Representation**: Uses `std.sumtype` for values (`LuaValue`), with customized equality and hashing adhering to Lua 5.4 semantics (e.g. `1 == 1.0`, NaN handling, reference equality for objects).
- **Automated Memory Management**: Leverages D's garbage collector (`core.memory.GC`) for memory safety and simplified reference tracking.
- **Exception-Driven Control Flow**: Translates Lua errors into native D exceptions (`class LuaException : Exception`), allowing `pcall` and `xpcall` to naturally integrate with D's RAII and `scope(exit)` unwinding.
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
├── ROADMAP.md                   # Current goals, Lua compatibility policy, planned phases
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

The performance that matters for Varis is how a game behaves under a graphical front
end on low-end hardware: turn latency, content load time and memory on a reference game.
Budgets for those are provisional ([ROADMAP.md](ROADMAP.md), Phase 11) and not yet enforced.
First measurements on a synthetic game (Apple M1): 3 ms per presentation with 100 rooms and
200 storylets, 16 ms with 1000 storylets, and about 0.8 s once a storylet depends on a recursive
rule over the 100-room map. The cost is inference, which copies the facts each query depends on
and recomputes without caches, indexes or semi-naive evaluation.
[benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md) has the measurements and the
staged plan.

The numbers below are the record of the earlier goal of **no more than 2× C Lua 5.4
execution time on each core-Lua workload**. That goal is closed and no longer pursued.
The ratios remain as regression gates (`make bench-check`), and Datalog and narrative
workloads keep separate absolute budgets because stock Lua cannot execute their syntax.

Measured on October 9, 2026 with the former `benchmarks/bench.py` script, since replaced by
`tools/suite bench` (release CLI built
with `-O3 -release`, C Lua with `-O2`; execution only, one warmup, median of seven
runs of five repetitions; assertion-checked workloads):

| Workload | Varis / C Lua |
| --- | ---: |
| Recursive Fibonacci | 2.0–2.3× |
| Numeric loop | 1.6× |
| Array inserts and reads | 1.6× |
| Hash-table workload | 1.4–1.5× |
| String manipulation | 0.6× |
| Sieve | 1.3× |

The numbers move by roughly ±10% between builds because the interpreter loop is one
large function (code layout effects); `benchmarks/PERFORMANCE_WORK.md` records the
methodology, the changes and the remaining costs. Calls and returns, object
creation, closures and coroutines (≈2.3–2.5×) and caught errors (≈4.5 µs each; macOS's unwinder
is slow for D exceptions) are the known remaining gaps; deep recursion past 150 frames runs in a
flat-stack executor (stack overflow ≈2.6× C Lua).
`make bench-check` enforces a per-workload ratio gate against C Lua and absolute time
budgets, including for the Datalog and narrative groups.

Current per-workload ratios are in the generated [docs/STATUS.md](docs/STATUS.md).
[Phase 8](LANGUAGE_EXTENSIONS_PLAN.md#phase-8--performance-and-remaining-lua-conformance)
records the original plan; its milestones 21–25 are retired.

### Lua compatibility status

The official Lua suite, a differential fixture and the regression programs stay in
`make test` as a regression net for the procedural core. They are no longer a goal: no
work is planned on the remaining differences, and deliberate divergences are allowed
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
- [x] **Phase 8: Core-Lua Performance & Conformance (closed)**: The conformance gate is met for all executable official files and most core workloads run within about 2× of C Lua (see Performance Benchmarks). Closed October 11, 2026; the ≤2× target is no longer pursued and milestones 21–25 are retired.
- [ ] **Phase 9: Authoring Language v1**: Content/engine file tiers, syntax triage and freeze, the authoring gaps found by the sample game, declared symbols, scenes and beats.
- [ ] **Phase 10: Authoring Tools**: `varis check` with source-ranged diagnostics, parser error recovery, syntax highlighting, a language server built on the Varis frontend, writer playtest and CI workflow.
- [ ] **Phase 11: Low-End Runtime & Host Interface**: Reference game with enforced latency and memory budgets, indexed semi-naive cached inference, a documented D host API and reference graphical host, portability.
- [ ] **Phase 12: Ergonomics**: Undo and persistent data, localization, Twine-class conveniences, writer documentation.

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
