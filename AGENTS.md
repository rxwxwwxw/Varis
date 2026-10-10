# AGENTS.md — Contributor & AI Agent Guide for dlua

Welcome to **dlua**! This document serves as the primary technical specification, architectural guide, and operational manual for AI agents and human contributors implementing and maintaining the codebase.

For declarative extensions, [LANGUAGE_EXTENSIONS.md](LANGUAGE_EXTENSIONS.md) defines the base v0.1 semantics, and [LANGUAGE_EXTENSIONS2.md](LANGUAGE_EXTENSIONS2.md) defines the stateful/narrative companion. Phase 6 milestones 0–8 and Phase 7 milestones 9–18 are implemented; [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md) records their interfaces and semantic decisions. [The companion conformance audit](tests/narrative/README.md) maps requirements and errors to executable evidence and reports support limits. Preserve separate coverage for core stateful behavior, aggregates, narrative behavior and optional authoring tools. The official Lua harness remains a separate Phase 5 gate. Phase 8 milestone 20's conformance gate is met (31 pass / 1 partial / 1 skipped / 0 fail on the official suite; see [tests/official/README.md](tests/official/README.md) for the remaining issues). Performance work is targeted and measured: the core-Lua benchmark workloads run at roughly 0.6–2.3× C Lua (see [benchmarks/PERFORMANCE_WORK.md](benchmarks/PERFORMANCE_WORK.md)); documented known costs remain (slow `error` unwinding through D exceptions, `errors.lua` ~25 s; recursion deeper than 150 Lua frames runs in `executeDeepFrame`, which must stay behaviourally identical to `executeFrame`).

---

## 1. Project Mission & North Star

1. **Idiomatic D Translation**: Translate the Lua 5.4 codebase from C (`c-implementation/src/`) into idiomatic, modern Dlang (D 2.100+ / LDC 1.43+), leveraging D's type safety, ranges, slices, and Phobos.
2. **Observable Behavior Fidelity**: Preserve observable Lua 5.4 semantics and pass language tests from `c-implementation/lua-5.4.9-tests/`.
3. **Declarative Programming Extensibility**: Extend the typed AST and VM with a separate finite Datalog engine implementing set semantics, least-fixed-point recursion, stratified negation, lexical local relations, independent worlds, and snapshot queries as defined in `LANGUAGE_EXTENSIONS.md`.
4. **Stateful and Narrative Extensibility**: Implement the companion in `LANGUAGE_EXTENSIONS2.md` through separate stateful and narrative conformance gates, preserving pure Datalog evaluation and transactional narrative effects.
5. **License Integrity**: Every source file derived from or porting Lua must include Lua's original MIT License header (PUC-Rio).

---

## 2. Architectural Blueprint & Invariants

### 2.1 Value Representation (`source/dlua/types.d`)
- `LuaValue` is a `struct` wrapping `std.sumtype.SumType!(Nil, bool, long, double, string, Symbol, LuaTable, LuaFunction, LuaUserData, LightUserData, LuaThread)`.
- **Primitives are stored inline**: Nil, bool, long, double, string, and raw pointers require no separate heap allocations.
- **Reference objects are D GC classes**: `LuaTable`, `LuaFunction`, `LuaUserData`, and `LuaThread` are managed by D's garbage collector.
- **Custom Equality & Hashing**:
  - `opEquals`: Follows Lua rules: integers and floats representing the same value are mathematically equal (`1L == 1.0`). `NaN == NaN` is false. Strings compare by value. Reference types compare by reference (`is`).
  - `toHash`: Guarantees that `1L` and `1.0` yield identical hash values, enabling seamless use of `LuaValue` as an associative array key (`LuaValue[LuaValue]`).
- **Matching Precedence**: In D, `long` implicitly converts to `double`. When writing sumtype handlers, **always list `long` before `double`** to avoid unwanted numeric conversion.
- **Symbols**: Use the inline symbol payload backed by a state-owned intern pool, shared across worlds. Audit exhaustive visitors/type switches. Keep logic variables in declarative AST/IR and binding environments, not in general `LuaValue`.
- **Numeric prerequisite**: Audit mixed integer/float equality and `floatToInteger` at large integer boundaries before using them for tuple sets. Converting both operands to `double` can lose precision above 2^53 and break equality/hash consistency.

### 2.2 Memory Management
- Direct delegation to D's garbage collector (`core.memory.GC`).
- No manual tri-color mark-and-sweep tracking or grey lists.
- `collectgarbage()` is mapped to D runtime GC equivalents (`GC.collect()`, `GC.stats()`, `GC.enable()`, `GC.disable()`).

### 2.3 Tables (`source/dlua/table.d`)
- **Dual-Storage**:
  - `arrayPart` (`LuaValue[]`): Fast path for 1-based positive integer indices `1 .. N`.
  - `hashPart` (`LuaValue[LuaValue]`): Storage for non-integer keys, strings, objects, negative/zero numbers, and sparse integer keys.
- **Key Normalization**: Float keys representing exact integers (e.g. `1.0`) are automatically converted to `long` (`1L`) via `normalizeKey()`.
- **Invalid Keys**: Setting a table index to `nil` or `NaN` throws a `LuaException`.
- **Length Operator (`#t`)**: Border search finding $n$ where $t[n] \neq \text{nil} \land t[n+1] = \text{nil}$.
- **Metatables**: `__index`, `__newindex`, `__len`, `__eq`, `__lt`, `__le`, etc.

### 2.4 Control Flow & Errors (`source/dlua/exception.d` & `state.d`)
- Lua runtime errors and `error()` throw `LuaException : Exception`.
- `pcall` and `xpcall` catch `LuaException` (and generic `Exception`), preserving native D stack unwinding and RAII cleanup (`scope(exit)` / `scope(failure)`).

### 2.5 Coroutines (`dlua.fiber`)
- Backed by D's `core.thread.Fiber`.
- Allows yielding across arbitrary native D boundaries without requiring continuation-passing boilerplate (`lua_yieldk`).
- Ordinary coroutines may mutate worlds and consume iterators between calls; each iterator retains its construction-time snapshot.
- Unprotected Lua coroutine errors retain frames and close handlers until explicit close; protected errors unwind at their handler. Closing must bypass protected calls, prohibit yielding/reentrant close, preserve error objects, and clear the error after the first close. Keep debug call stacks isolated per Fiber. Standard sort/gsub callbacks remain non-yieldable.
- Guards must not yield during inference, including through helper functions or native callbacks. Enforce this at the Fiber yield boundary with exception-safe restoration of yieldability.

### 2.6 Frontend: Typed AST Intermediate Representation
- Replaces Lua's intertwined single-pass parser/compiler with:
  `Source -> Lexer -> Parser -> Typed AST -> Compiler -> Bytecode -> VM`
- An explicit typed AST (`source/dlua/ast.d`) allows inserting AST transforms, syntax macros, and declarative rule definitions without disturbing bytecode generation.

### 2.7 Instructions & VM
- Strongly typed instruction representations (`struct Instruction`) rather than packed 32-bit bitfield macros.
- Clean, debuggable VM dispatch loop.

### 2.8 Standard Libraries & Pattern Matching
- Implemented using Phobos (`std.math`, `std.stdio`, `std.datetime`, `std.utf`, `std.process`).
- **Pattern Matching (`source/dlua/pattern.d`)**: Directly ports Lua's pattern matching engine from `lstrlib.c` to guarantee 100% fidelity for `%a`, `%b`, frontier `%f[]`, and numbered captures `%1`.

### 2.9 Declarative Engine (Phase 6)
- **Finite relations**: Fixed-arity tuple sets use raw Lua equality without `__eq`; `nil` is valid and NaN is prohibited. Preserve separate base and derived membership, including zero-arity tuples.
- **Validation and atomicity**: Check arity, variable safety, world/local ownership, and stratification before publishing a rule. Failed fact operations and rule registrations leave that operation's logical program changes uncommitted, including implicit declarations.
- **Evaluation**: Start with full recomputation of the query dependency closure from base facts, reaching a least fixed point within each stratum. Adding facts to negated relations and retracting facts must invalidate stale derivations. Publish only successfully completed caches, keyed by relevant world/local versions.
- **Worlds**: Each state owns `logic.global`. Inheritance snapshots facts/rules and rebinds inherited relation references to the child. Referenced Lua objects are shared by identity. Rules cannot depend on another world; world-owned rules cannot retain local relation dependencies.
- **Lexical context**: Use a separate relation namespace and hidden lexical slots/upvalues for local handles and world-block defaults. Local relations shadow named world relations; ordinary Lua locals do not shadow relations. Resolve rule/query references once so later shadowing does not retarget them.
- **Compilation**: Store immutable declarative templates on `Prototype` and lower to dedicated VM instructions calling engine APIs. Evaluate each syntactic relational constant argument once to exactly one value; do not expand the final Lua call or vararg.
- **Queries and records**: Freeze relational state at construction; defer inference until the first iterator call. Deduplicate returned named bindings, omit anonymous variables, and return one empty record for a successful ground query. Use opaque GC-managed world/record payloads with immutable field access and explicit binding presence for `nil`; retain local relations and snapshots by reachability. Evaluation errors invalidate the iterator.
- **Guards**: Capture ordinary Lua values by value at rule registration (reference objects retain identity), use the first result and Lua truthiness, and require grounded logic variables. Query guard capture timing and other semantic edges must follow the decisions recorded in milestone 0. Arbitrary external-state purity is a programmer obligation.
- **Compatibility**: Extension names remain contextual identifiers. Preserve ordinary calls, assignments, method colons, and labels. Compound terms, cuts, procedural backtracking, aggregation, and individual rule deletion are outside v0.1.

### 2.10 Stateful and Narrative Companion (Phase 7)
- **Schemas and updates**: Named columns are metadata, not types. Immutable keys constrain base tuples using raw equality, including `nil`; keyed relations are extensional and cannot be rule heads. `fact` conflicts error; `set`, key-only `delete`, and single-value `adjust` are atomic, with no-op updates preserving logical versions.
- **Transactions**: One selected world, entry snapshot plus prior writes, same-world nested savepoints, no tentative visibility to other coroutines. Commit on non-error exit; rollback on escaping errors or explicit `rollback`. Prohibit yields, cross-world mutations, schema/rule changes, and other-world nesting. Escaped committed iterators retain snapshots; rolled-back iterators become invalid. Arbitrary Lua mutations and I/O are not rolled back.
- **Optional aggregates**: Distinct local assignments, grounded correlated inputs, newly grounded results, strictly lower-stratum dependencies, and no aggregate recursion. Preserve empty-set/error semantics; aggregation is an implemented companion amendment to the base scope.
- **Content and sessions**: State-owned sealed/versioned content registry, separate from worlds. Sessions retain independent world references, turns, deck stacks/history, periods, events, and deterministic seeded RNG state. Canonical serializable scalar bindings identify instances independently of hash iteration.
- **Narrative compilation**: Bind exposed parameters as read-only Lua locals. Resolve narrative availability/effect references against the owning session world; preserve ordinary closure lexical-world semantics. Keep all new syntax contextual and constant fields frozen at registration.
- **Choices and actions**: Immutable presentation tokens; revalidate exact bindings and policies inside the effect transaction. Failed choices produce no turn advancement. Actions run outside inference in canonical priority order, reevaluating after each commit; enforce once-per policies and phase budgets, retaining prior successful commits on `ACTION_LIMIT`.
- **Decks and templates**: Canonical weighted draws with explicit seeding and versioned algorithms; per-entry no-replacement history. Render templates read-only from the presentation snapshot, with existence tests rather than iterator truthiness, and no RNG consumption during rendering.
- **Qualities and events**: Quality metadata constrains the keyed extensional relation across all mutation paths. Explicit initialization, no implicit defaults/clamping. Transactional events have commit-time sequence numbers and immutable read-only relation access; schedules run before actions with bounded immediate chains. Deferred external callbacks run only after commit.
- **Persistence and diagnostics**: Save only at quiescent boundaries; validate serializable values and schema/content versions, reconstruct authored rules, and reject unsupported closures/local relations absent a host protocol. Explanations are read-only; subscriptions/analysis are optional, post-commit/isolated facilities.
- **Recorded decisions**: Preserve the plan's control-flow, local-relation, token, event timing, handler, serialization and migration interfaces. Quality defaults inside effects follow lexical call-world metadata (including captured helper worlds); outside effects they use global. Nonyield scopes include synchronously resumed children. Do not claim broader Lua compatibility or analysis completeness than the audit supports.

---

## 3. Directory Layout & Module Ownership

| Module | Status | Role & Responsibilities |
|---|---|---|
| [`source/dlua/types.d`](source/dlua/types.d) | ✅ Phase 1 | `LuaValue` sumtype, value helpers, truthiness, equality, hashing |
| [`source/dlua/table.d`](source/dlua/table.d) | ✅ Phase 1 | `LuaTable` dual-storage, length border, rawget/rawset, iteration |
| [`source/dlua/exception.d`](source/dlua/exception.d) | ✅ Phase 1 | `LuaException`, error reporting, stack info |
| [`source/dlua/state.d`](source/dlua/state.d) | ✅ Phase 1 | `LuaState`, globals table (`_G`), registry, stack, `pcall` |
| [`source/dlua/package.d`](source/dlua/package.d) | ✅ Phase 1 | Public API re-exports |
| `source/dlua/ast.d` | ✅ Phase 2 | Typed AST node classes/structs (Statements, Expressions) |
| `source/dlua/lexer.d` | ✅ Phase 2 | Tokenizer, keywords, numbers, long brackets `[[...]]`, escapes |
| `source/dlua/parser.d` | ✅ Phase 2 | Recursive descent parser producing AST |
| `source/dlua/opcode.d` | ✅ Phase 3 | OpCode enums and `Instruction` struct definitions |
| `source/dlua/compiler.d` | ✅ Phase 3 | AST-to-bytecode compiler, scope analysis, register allocation |
| `source/dlua/vm.d` | ✅ Phase 3 | Bytecode execution loop, upvalues, closures |
| `source/dlua/fiber.d` | ✅ Phase 3 | Coroutine execution runner wrapping D `Fiber` |
| `source/dlua/pattern.d` | ✅ Phase 4 | Lua pattern matching engine ported from `lstrlib.c` |
| `source/dlua/lib/*.d` | ✅ Phase 4 | Standard libraries (`base`, `math`, `string`, `table`, etc.); `fastcall.d` holds allocation-free fast entry points for hot built-ins |
| `lua_api.exports` | ✅ Phase 5 | Symbols the dlua executable exports to `dlopen`ed C modules (replaces `-export_dynamic`, which cost ~8 ms startup) |
| `source/dlua/cli.d` | ✅ Phase 5 | Standalone `dlua` executable runner & REPL |
| `tests/unit/*.d` | ✅ Completed | Comprehensive unit tests (foundation, frontend, vm, libs) |
| `tests/runner.d` | ✅ Phase 5 | Automated runner for `c-implementation/lua-5.4.9-tests/` (`make test-official`) |
| `LANGUAGE_EXTENSIONS.md` | Proposed v0.1 | Declarative language semantics and grammar |
| `LANGUAGE_EXTENSIONS2.md` | Companion v0.1 | Core schemas/updates/transactions implemented; aggregates and narrative sessions/decks/choices/actions/events implemented; portable persistence/replay implemented; explanations/subscriptions implemented; bounded analysis implemented; custom formatters and weighted variants implemented; conformance evidence in tests/narrative/README.md |
| `LANGUAGE_EXTENSIONS_PLAN.md` | Plan | Base milestones 0–8 and companion milestones 9–18 (core and narrative runtime/persistence, formatters/variants, authoring implemented; conformance evidence in tests/narrative/README.md; runner baseline established) |
| [`source/dlua/logic/model.d`](source/dlua/logic/model.d) | ✅ Phase 6 | Tuple/term/goal/rule IR, identities, immutable snapshots |
| [`source/dlua/logic/world.d`](source/dlua/logic/world.d) | ✅ Phase 6 | Worlds, local relations, versions, atomic mutation, inheritance |
| [`source/dlua/logic/validate.d`](source/dlua/logic/validate.d) | ✅ Phase 6 | Safety, ownership, arity, signed dependencies, SCCs/strata |
| [`source/dlua/logic/evaluate.d`](source/dlua/logic/evaluate.d) | ✅ Phase 6 | Joins, constraints, guards, fixed-point evaluation |
| [`source/dlua/logic/query.d`](source/dlua/logic/query.d) | ✅ Phase 6 | Snapshot iterators, projection, immutable binding records |
| [`source/dlua/lib/logic.d`](source/dlua/lib/logic.d) | ✅ Phase 6 | Required `logic` library and global `symbol` |
| [`tests/unit/test_logic.d`](tests/unit/test_logic.d) | ✅ Phase 6 | Direct engine and integration tests |
| `lua54_datalog_tests/` | ✅ Phase 6 | 12 positive programs, 3 negative validation cases, shell runner |
| `tests/datalog/` | ✅ Phase 6 | 19 self-checking scenario programs (spec §2–§17) usable as benchmarks, golden output at two scales, `known_gaps/` for documented spec deviations; timed by `make benchmark-datalog` ("scenarios" suite) |

---

## 4. Phase-by-Phase Implementation Roadmap

### Phase 1: Foundation (Completed ✅)
- Core types, table dual storage, error handling, state, and foundation unit tests.

### Phase 2: Frontend (Completed ✅)
- Typed AST (`dlua.ast`), Tokenizer (`dlua.lexer`), and Recursive Descent Parser (`dlua.parser`). Unit tests in `tests/unit/test_parser.d`.

### Phase 3: Runtime & VM (Completed ✅)
- Opcode definitions (`dlua.opcode`), AST-to-bytecode compiler (`dlua.compiler`), VM execution loop (`dlua.vm`), and Fiber coroutines (`dlua.fiber`). Unit tests in `tests/unit/test_vm.d`.

### Phase 4: Standard Libraries (Completed ✅)
- Pattern matching engine (`dlua.pattern`) and standard libraries (`base`, `math`, `string`, `table`, `coroutine`, `os`, `io`, `utf8`, `package_lib`, `debug_lib`). Unit tests in `tests/unit/test_libs.d`.

### Phase 5: CLI, REPL & Conformance (Completed ✅; documented skips remain)
1. `source/dlua/cli.d`: Standalone executable supporting `-e`, `-v`, and script files. (Working).
2. `tests/runner.d` (conformance scope per the project owner: the suite as a stock binary runs it, `T == nil`, with `gc.lua` excluded; an ltests-style `T` is out of scope): Official Lua 5.4.9 runner via `make test-official`, with strict failure exits, combined output capture, process exit codes, PASS/PARTIAL/SKIP/FAIL statuses, `--reference` C Lua comparison and JSON reporting (default 120 s per file; use 240 s for the `all.lua` driver). It builds the suite's C test modules, provides a closed-pipe stdin and an `sh` wrapper for the nested-shell check, and runs `all.lua` in a scratch copy with `gc.lua` stubbed. Current October 9, 2026 release baseline: **31 passed, 1 partial (`all.lua` with `gc.lua` stubbed), 1 skipped (`gc.lua`, excluded by decision because exact reachability conflicts with D-accessible objects), 0 failed, 0 timed out.** [Recorded evidence and remaining issues](tests/official/README.md) supersede earlier baselines. A file PASS means the process exited successfully; `api`/`code` self-skip without the `T` library as under stock C Lua. Weak tables, ephemerons and finalizers are emulated on D's collector (`source/dlua/gc.d`, forked reachability probes); library ports live in `lib/*.d` with shared argument checking in `lib/auxlib.d`; C modules load through `dlopen` and the exported C API subset in `capi.d`; binary chunks are in `dump.d` (private body behind a standard header); the interpreter runs on a large-stack Fiber (`cli.d`).
3. Benchmarking against C Lua 5.4 exists (`make benchmark`), but the core-Lua runner reports minimum-of-three process timings without enforcing ratios. Phase 8 owns benchmark hardening and optimization.
4. Correctness takes priority over performance optimization. Goto execution/scope validation, precedence, floor arithmetic, shifts, lexical `_ENV`, debug upvalue APIs, const attributes and basic close cleanup are implemented with targeted tests. Proper tail calls, callable-table chains, reader loading, numeric-string parsing, function debug metadata, UTF-8 APIs and pattern-library fixes are implemented. Generic for loops retain the fourth closing value and evaluate all iterator expressions; each loop iteration closes its scoped values/upvalues. Register growth preserves captured-local aliases.  Debug fidelity, binary chunks, coroutine/library/CLI gaps and large-program failures remain. `make test-conformance-core` compares deterministic core behavior with C Lua. `make test` includes runner regression tests but excludes the official suite and differential target. Skipped files and unsupported D-GC semantics remain explicit barriers to full conformance claims.

### Phase 6: Declarative Datalog Extensions v0.1 (Completed ✅)

The base implementation is present for milestones 0–8 in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md); retain executable coverage for their requirements:
- **Milestone 0 & 1**: Interned symbols, relational value equality/hashing, NaN prohibition in tuples.
- **Milestone 2**: World and relation model, version tracking, atomic mutations, snapshot inheritance.
- **Milestone 3**: Rule/query validation, variable safety, stratification check, least-fixed-point evaluation.
- **Milestone 4**: Point-in-time snapshot query iterators, immutable `BindingRecord`, `logic` standard library.
- **Milestone 5**: Declarative AST nodes and parser integration (`fact`, `retract`, `rule`, `relation`, `local relation`, `logic (w) do`, `query`, symbols, logic variables).
- **Milestone 6**: Compiler and VM bytecode instructions (`LoadSymbol`, `NewLocalRel`, `DeclRel`, `AddFact`, `RetractFact`, `RegRule`, `MakeQuery`).
- **Milestone 7**: Value-captured guards and strict coroutine yield boundary enforcement.
- **Milestone 8**: `tests/unit/test_logic.d` (`make test-logic`), `make test-datalog` with per-test timeout runner, and integration into `make test`.

### Phase 7: Stateful Relations and Narrative Companion (Completed ✅)

Companion milestones 9–18 in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md) are implemented. Preserve these boundaries and their acceptance coverage:

1. **9–11, stateful relations**: Named/keyed schemas, atomic updates, per-coroutine transaction overlays/savepoints, exclusive world locks, cleanup and iterator validity in `logic/world.d`, compiler/VM and Fiber. No-yield scopes cover helpers and resumed child coroutines and restore on every exit.
2. **12, aggregates**: Scoped/correlated count/sum/min/max, distinct assignments, empty/error semantics and strict lower-stratum dependencies in the frontend, validator and evaluator.
3. **13–15, narrative runtime**: `narrative/{registry,templates,codec,fingerprint,session}.d` and `lib/{narrative,quality}.d` implement sealed content, immutable parameters/instances/tokens, deterministic decks, atomic choices, actions/periods, qualities/constraints, events/schedules and deferred callbacks. Deck/scheduler behavior lives in `session.d`; alternate proposed module splits are not missing features.
4. **16, persistence/replay**: `narrative/persistence.d` provides staged factory-world restoration, schema/content/code/capture checks, explicit authored reconstruction/migrations and immutable command logs. Preserve failed-load atomicity and unsupported-value diagnostics; hosts replay external inputs and reestablish subscriptions.
5. **17, authoring**: `diagnostics.d`, `observe.d` and `analysis.d` supply pure explanations, committed visible-set deltas with bounded queued commands, and isolated bounded choice exploration. Analysis reports its scope/incompleteness and blocks host/native external operations.
6. **18, conformance**: `make test-stateful`, `make test-narrative` (13 groups), and `make test-extensions` (54 cases) are included in `make test`. [tests/narrative/README.md](tests/narrative/README.md) contains the paragraph/grammar/error matrix, measured stress/replay coverage and limits. Keep all source modules listed explicitly in `Makefile`.

Custom display formatter registration and deterministic weighted text variants are implemented and verified. Existing compiler `goto` execution and the official Lua harness are outside the companion gate; do not conceal skips or imply complete Lua 5.4 conformance.

### Phase 8: Performance and Remaining Lua Conformance (Conformance gate met; performance planned)

Follow milestones 19–25 in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md#phase-8--performance-and-remaining-lua-conformance):

| Milestone | Planned deliverable |
| --- | --- |
| 19 | Reproducible core-Lua benchmarks, result assertions, metadata and regression enforcement |
| 20 | Conformance gate met: strict official runner, 31 pass / 1 partial / 1 skipped / 0 fail baseline, differential core fixture; skips and partials are documented, not hidden |
| 21 | CPU/allocation/GC profiles and measured optimization priorities |
| 22 | Reusable per-coroutine call frames and direct argument/result transfer |
| 23 | Lower VM/context overhead with debug, transaction and analysis semantics preserved |
| 24 | Profile-driven table iteration/access and bytecode improvements |
| 25 | Release performance gates, build tuning and documented final conformance evidence |

The goal is ≤2× C Lua time on each agreed representative core-Lua workload;
a geometric mean cannot hide a failing workload. Current ratios on the six
`bench.py` workloads are about 0.6–2.3× (recursive Fibonacci is the highest; see
README and `benchmarks/PERFORMANCE_WORK.md` for methodology limits). The CLI uses
`-O3 -release`; D unit tests default to `-g`, and C Lua defaults to `-O2`.
Record actual build settings rather than assuming optimization parity.
Datalog/narrative performance remains separately measured against calibrated
baselines; do not reset baselines to conceal regressions.

---

## 5. Development Invariants & Guidelines for Agents

1. **License Header**: Every new `.d` source file must include this header:
   ```d
   /*
   ** Lua - A Scripting Language
   ** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
   **
   ** dlua - D port of Lua 5.4
   ** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
   ** Copyright (C) 2026 dlua contributors.
   ** See LICENSE for license details.
   */
   ```
2. **Lua Truthiness**: Only `nil` and `false` are falsey. `0`, `0.0`, `""`, and empty tables are truthy. Never write `if (val)` in D without calling `val.isTruthy()`.
3. **Lua Indexing**: Lua tables and strings are 1-based by user contract. Internal D array slices are 0-based. Be vigilant with conversions (`index - 1`).
4. **Strings**: Lua strings can contain arbitrary binary bytes (including `\0`). While D `string` is UTF-8 immutable, treat strings as binary-safe byte slices when implementing standard library operations.
5. **No `cd` in tool commands**: Always set `Cwd` when running shell commands.
6. **Compiler**: Target `ldc2` (located at `/opt/homebrew/bin/ldc2` on Apple Silicon). Use `make test` or `make <target>`.
7. **Extension tests**: Treat `lua54_datalog_tests/` as base-language acceptance examples, not proof of full conformance or companion support. Compare unordered result sets. The shell runner now requires intended negative-case diagnostics and rejects crashes, timeouts and fallback errors; preserve and extend those checks. The examples permit compilation-time rejection, but implementation must still honor runtime registration, capture, and atomicity semantics from the specification.
8. **Conformance coverage**: Supplement the examples with tests for numeric boundaries, NaN, raw reference equality, binary symbol names, contextual syntax, qualified ownership failures, failed-operation rollback, lexical closure capture, guard errors/yields, coroutine snapshots, and invalid iterator reuse. Map all nine v0.1 conformance requirements to executable coverage and report unsupported official Lua harness tests as skips.

9. **Companion coverage**: Map `LANGUAGE_EXTENSIONS2.md` §16 to tests for key conflicts, transaction/savepoint/control-flow rollback, tentative snapshots, yields, stale choices, parameter binding, deterministic draws, action/event budgets, quality constraints, and save/version failures. Compare unordered relational sets and canonical narrative sequences. Keep optional aggregates/subscriptions/analysis separately identified; proposed tests and targets are not existing support.

10. **Performance changes**: Resolve the Lua conformance backlog before targeting optimizations. Profile before choosing optimizations. Land small changes with targeted semantic tests, full `make test`, optimized assertion-enabled validation, actual release CLI fixtures, and before/after timing and memory evidence. `make test-official` and `make test-conformance-core` exist; broader differential/release gates remain planned. Never trade correctness for benchmark scores or silently weaken failure/skip accounting. A file passing with protected errors or internally disabled tests is not proof of feature completeness.
11. **Runtime optimization boundaries**: Retain SumType, typed instructions and D GC initially. Frame reuse must preserve upvalue locations/lifetimes, GC roots, native reentry, suspended coroutines and exception cleanup. Context fast paths must preserve lexical worlds, aliases and Fiber isolation; combined instructions must preserve analysis budgets, debug attribution and transaction exit boundaries. Larger representation changes require measured justification and explicit architectural review.

---

## 6. Common Build Commands

```bash
# Run Foundation unit tests
make test-foundation

# Run Declarative Logic unit tests
make test-logic

# Run core stateful companion unit tests
make test-stateful

# Run Declarative Datalog acceptance suite with timeout
make test-datalog

# Run the 19 Datalog scenario programs (small + large scale, golden output, known gaps)
make test-scenarios

# Run additional extension corner cases and bounded stress tests (5 minutes per case)
make test-extensions

# Run the differential regression programs (output + checksum identical to C Lua)
make test-regression

# Run all test suites (foundation, frontend, VM, libraries, logic, stateful, datalog, extensions, benchmark runner)
make test

# Build CLI
make dlua

# Clean artifacts
make clean
```

The Datalog acceptance suite (`make test-datalog`) and unit tests (`make test-logic`) are integrated into `make test`, with per-test timeouts configured via `DATALOG_TIMEOUT` and runner timeouts via `TIMEOUT`.

The additional [extension regression and stress suite](tests/extensions/README.md)
(`make test-extensions`) is also included in `make test`. Each case has a hard
300-second maximum; `EXTENSIONS_TIMEOUT` may reduce it. Specification failures
remain visible as failures, with strict diagnostics for expected rejections.
