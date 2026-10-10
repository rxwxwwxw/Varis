# dlua

A modern, idiomatic D (Dlang) port and translation of the Lua 5.4 interpreter and runtime.

`dlua` translates Lua from C into modern D, aiming to preserve observable Lua 5.4 behavior and provide a foundation for finite Datalog-style declarative programming.

The base declarative extension is defined in [LANGUAGE_EXTENSIONS.md](LANGUAGE_EXTENSIONS.md). Phase 7 implements the stateful/narrative companion in [LANGUAGE_EXTENSIONS2.md](LANGUAGE_EXTENSIONS2.md): keyed relations and transactions, aggregates, storylets/choices, automatic actions, decks, templates, qualities, events, portable saves and replay. Explanations, committed-change subscriptions and isolated bounded choice analysis are also implemented. [The conformance evidence and limits](tests/narrative/README.md) map the specification to executable tests; [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md) records the implementation and semantic decisions.

---

## Key Highlights

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
                      |    dlua.lexer     | Tokenizer
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |    dlua.parser    |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |     dlua.ast      | Typed AST (Extensibility Hook)
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |   dlua.compiler   | AST -> Bytecode
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |      dlua.vm      | VM Dispatcher
                      +---------+---------+
                                |
      +-------------------------+-------------------------+
      |                         |                         |
      v                         v                         v
+-----------+            +-------------+           +--------------+
| dlua.types|            | dlua.table  |           |  dlua.fiber  |
|  SumType  |            | Dual-Storage|           | D Lang Fiber |
+-----------+            +-------------+           +--------------+
```

---

## Directory Structure

```
dlua/
├── Makefile                     # Build and test orchestration using ldc2
├── README.md                    # Project overview and quick start
├── AGENTS.md                    # Architecture guide and instructions for AI agents
├── LANGUAGE_EXTENSIONS.md       # Proposed declarative language reference v0.1
├── LANGUAGE_EXTENSIONS2.md      # Proposed stateful/narrative companion reference
├── LANGUAGE_EXTENSIONS_PLAN.md  # Base and companion milestones and validation criteria
├── LICENSE                      # MIT License (Lua 5.4 PUC-Rio + dlua)
├── lua54_datalog_tests/          # Base declarative extension acceptance tests
│   ├── README.md                # Coverage and runner limitations
│   ├── run-tests.sh             # Runs an extended interpreter against the suite
│   ├── positive/                # 12 programs expected to succeed
│   └── negative/                # 3 programs expected to be rejected
├── c-implementation/            # Original C source & reference tests
│   ├── src/                     # Lua 5.4.9 C source code
│   └── lua-5.4.9-tests/         # Official Lua 5.4.9 test suite
├── source/
│   └── dlua/
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
│       ├── lib/                 # Standard libraries, including logic
│       └── cli.d                # Standalone dlua CLI / REPL (Phase 5)
└── tests/
    ├── unit/                    # D unit tests
    │   ├── test_foundation.d    # Value, table, state, and pcall tests
    │   ├── test_parser.d        # Lexer and parser tests
    │   ├── test_vm.d            # Compiler and VM tests
    │   ├── test_libs.d          # Standard library tests
    │   └── test_logic.d         # Declarative engine and integration tests
    └── runner.d                 # Automated official Lua 5.4.9 test runner (make test-official)
```

---

## Build & Test

### Prerequisites

- **LDC**: LLVM D Compiler (`ldc2`), targeting LDC 1.43+ / D 2.100+.
- **Make**: Standard GNU Make.
- **Python 3**: Used by the unit-test timeout wrapper and benchmark runner.

### Running Tests

To build and run the unit test suite:

```bash
make test
```

Or target the foundation tests directly:

```bash
make test-foundation
```

Other existing targets are `make test-frontend`, `make test-vm`, `make test-libs`, `make test-logic`, `make test-stateful`, `make test-datalog`, and `make test-extensions`. `make test` includes all of these plus benchmark-runner tests. `make test-regression` runs the [differential regression programs](tests/regression/README.md) (15 deterministic Lua programs, including csmith-style expression fuzzing, whose output and FNV-1a checksum must be byte-identical to C Lua); `make benchmark` also times them with a per-program budget. The official Lua conformance suite is not included in `make test`; run it separately via `make test-official` (`tests/runner.d`), which classifies all 33 official Lua 5.4.9 test files, executes the non-skipped files, and reports individual pass/fail/skip results with strict failure exits. `make test-stateful` runs the core companion unit tests and is included in `make test`. `make test-narrative` runs 13 narrative test groups. Companion acceptance/stress fixtures run through `make test-extensions`; see [the conformance audit](tests/narrative/README.md).

### Declarative Extension Acceptance Tests

Run the base extension suite from the repository root:

```bash
make test-datalog
```

The runner also accepts `LUA_BIN` instead of a binary argument. Supply the extended interpreter explicitly: its default is `lua`, and stock Lua cannot parse the extension syntax.

The suite covers symbols, facts, recursion, stratified negation, retraction, conjunctive queries, guards and captures, world inheritance, lexical world blocks, local relations, snapshot iterators, immutable records, zero arity, and `nil` bindings. Positive programs assert their results without requiring a particular iteration order. Negative programs exercise unsafe negation, a negation cycle, and an arity mismatch.

Negative cases require the intended validation diagnostic and reject crashes, timeouts, and the `UNEXPECTED SUCCESS` fallback marker. Preserve those checks when adding or changing rejection cases. These examples complement the existing engine unit tests and broader conformance coverage; they do not establish full v0.1 conformance on their own.

### Building the dlua CLI Executable

```bash
# Build optimized release binary
make dlua

# Run the CLI / REPL
./bin/dlua -v
./bin/dlua -e 'print("Hello from dlua!")'
```

### Running Benchmarks

Compare `dlua` performance against the original C Lua 5.4 implementation. The current Makefiles build dlua with `-O3 -release` and C Lua with `-O2`; record the actual compiler versions and flags for comparisons:

```bash
make benchmark
```

This also runs the Datalog performance regression check. To run it alone:

```bash
make benchmark-datalog
```

It measures the complete acceptance suite and the extension regression/stress
suite separately, excluding compilation. Three runs produce a median for each
suite. A runtime above its saved baseline by **25% plus 0.1 seconds** fails the
command and is treated as a performance bug. `BENCHMARK_RUNS`,
`DATALOG_REGRESSION`, and `DATALOG_SLACK` override these defaults.
The checked-in baseline was measured on Apple Silicon; for a different machine,
use `make benchmark-datalog-record DATALOG_BASELINE=/tmp/dlua-baseline.json`
and pass that same `DATALOG_BASELINE` to subsequent checks. Normal checks never
update the baseline. See [benchmark details](benchmarks/README.md).

### Cleaning Artifacts

```bash
make clean
```

---

## Performance Benchmarks

The target is **no more than 2× C Lua 5.4 execution time on each agreed
representative core-Lua workload**, with a geometric mean reported only as a
summary. Datalog and narrative workloads have separate regression budgets because
stock Lua cannot execute their syntax.

Measured on October 9, 2026 with `python3 benchmarks/bench.py` (release CLI built
with `-O3 -release`, C Lua with `-O2`; execution only, one warmup, median of seven
runs of five repetitions; assertion-checked workloads):

| Workload | dlua / C Lua |
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
The ratios are printed without a failure threshold. The Datalog check enforces
machine-specific suite medians and functional success, but includes
process/runner overhead and does not isolate engine costs.

[Phase 8, milestones 19–25](LANGUAGE_EXTENSIONS_PLAN.md#phase-8--performance-and-remaining-lua-conformance)
plans reproducible benchmarks, official-suite reporting, profiling, reusable call
frames, lower VM overhead, table/bytecode improvements, and enforced performance
gates.

### Remaining conformance work

- Conformance scope (owner decision): the official suite as a stock Lua 5.4 binary runs it (no internal `T` library), with `gc.lua` excluded; an ltests-style `T` for `api.lua`/`code.lua` is out of scope. The official Lua 5.4.9 suite runs clean: the October 9, 2026 release-build run reports **31 pass, 1 partial, 1 skipped, 0 fail, 0 timeout** across 33 files (240 seconds per file, C Lua as reference). `gc.lua` is the one skip, excluded by decision because exact collector reachability conflicts with keeping dlua objects directly accessible from D. The one partial is the suite driver `all.lua`, which the runner executes with `gc.lua` stubbed (it ends with `final OK !!!` and also pushes each file through `string.dump`/`load`). The suite's C test modules are compiled and loaded through the exported C API subset (`source/dlua/capi.d`), and `files.lua` runs against an `sh` wrapper because macOS `sh` reports a signal for the nested-shell check where the suite expects an exit status. `api` and `code` pass because, as with stock C Lua, they return immediately when the internal `T` library is absent. See the [recorded results and remaining issues](tests/official/README.md); a file pass means the process exited successfully.
- `make test-official` fails on interpreter failures or timeouts. The runner captures both output streams without pipe deadlocks and retains exit codes and diagnostics. Weak tables and `__gc`/`__close` finalizers are emulated on D's conservative GC (`source/dlua/gc.d`), so `collectgarbage` modes/step are bookkeeping-level rather than a Lua collector. Native stack use (~5 KB per Lua call frame) and slow deep-recursion unwinding (D exceptions through the platform unwinder) remain known performance issues.
- Implemented conformance work includes luac-style compiler output (RK operands, condition jumps, line attribution, strip semantics), lvm.c-style loops and error messages with variable info, ports of lstrlib/ltablib/lmathlib/loslib/liolib/loadlib/lcorolib/lua.c, binary chunks (`string.dump`/`load`, private body behind a standard header), debug hooks/getinfo/locals/upvalues, coroutine close/wrap semantics, tracebacks and C-call depth limits. Remaining work before performance optimization is only the explicit skips and partial exclusions above.
- `make test-conformance-core` compares a deterministic core fixture against bundled C Lua. `make test` includes runner regression tests, while the official suite and differential target remain separate gates.
- Add differential coverage against C Lua for supported numeric behavior,
  calls/returns, closures, tables/metamethods, errors and coroutines. Test the
  optimized runtime as well as assertion-enabled builds.
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
- [ ] **Phase 8: Performance & Remaining Lua Conformance**: Milestone 20 conformance gate is met for all executable official files; core-Lua execution is now within about 2× of C Lua on the benchmark workloads (see Performance Benchmarks); enforcement gates (milestones 19, 25) remain planned.

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

[LANGUAGE_EXTENSIONS2.md](LANGUAGE_EXTENSIONS2.md) extends the base semantics without making narrative effects part of Datalog inference. Milestones 9–18 in the [implementation plan](LANGUAGE_EXTENSIONS_PLAN.md#phase-7--stateful-relations-and-narrative-extensions) cover:

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

`dlua` is a derived work of Lua 5.4. It is licensed under the MIT License, preserving all original copyright notices from Lua.org, PUC-Rio. See [LICENSE](LICENSE) for the full text.

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
