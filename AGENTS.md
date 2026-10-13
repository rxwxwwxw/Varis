# AGENTS.md — Contributor & AI Agent Guide for Varis

Varis is a **narrative engine**: a language and runtime for authoring visual novels and story
games. It combines a relational world model (facts, Datalog rules, transactions, deterministic
saves and replay) with a full programming language derived from Lua 5.4. This document is the
operating manual for AI agents and human contributors. Language semantics are defined by the
Varis Reference Manual linked below, not here.

---

## 1. Start here

### 1.1 Which document answers which question

| Question | Document |
| --- | --- |
| What does the language do **today**? | [Varis Reference Manual](docs/README.md) (`docs/`). The only definition of current behaviour. |
| What is the project trying to become, and who decided what? | [ROADMAP.md](ROADMAP.md): direction, decision record (D1–D14), order of work, milestones, open decisions. |
| How do we make it fast, and in what order? | [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md): measurements, design rules, stages S0, S1, W, L, X, M. |
| What is the web workbench and its debugger? | [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md). |
| How will the checker, the language services and the writer's playtest and test tools work? | [AUTHORING_TOOLS_PLAN.md](AUTHORING_TOOLS_PLAN.md): project manifest, project index, stages A0–A6. |
| How will localization work? | [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md): workflows by role, stages T0–T5. |
| What do the tests prove, and what is skipped? | [tests/narrative/README.md](tests/narrative/README.md), [tests/official/README.md](tests/official/README.md), [docs/STATUS.md](docs/STATUS.md) (generated). |
| How does a writer learn the language? | [docs/writers/](docs/writers/README.md): tutorial and cookbook; their programs are run by suite `writers-docs`, so a change that breaks one is a failure to fix, not a doc to edit away. |
| How do the benchmarks and gates work? | [benchmarks/README.md](benchmarks/README.md). |
| What is the planned second sample game (`sample-rpg/`) and its SDL3 host work? | [SAMPLE_RPG_PLAN.md](SAMPLE_RPG_PLAN.md): plan only; nothing implemented until its stages land. |
| What is the combined tower-defense / visual-novel sample (`sample-td/`, *Lanternfall*) that tests the battle engine? | [SAMPLE_TD_PLAN.md](SAMPLE_TD_PLAN.md) (outline and stages) and [sample-td/README.md](sample-td/README.md) (what was built). |
| How does the hex tower-defense battle (native simulation, 2.5D view, story bridge) work? | [docs/battle.md](docs/battle.md) is the manual; [TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md) the design and decisions (B1–B12), with measurements from `benchmarks/experiments/td_tick.lua` and `td_native.d`; stages TD0–TD8, mostly landed with the sample. |
| How did we get here? | [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md), [benchmarks/PERFORMANCE_WORK.md](benchmarks/PERFORMANCE_WORK.md), [CONSOLIDATION_PLAN.md](CONSOLIDATION_PLAN.md). History only. |

`LANGUAGE_EXTENSIONS.md` and `LANGUAGE_EXTENSIONS2.md` are redirects to the manual.
[docs/coverage.md](docs/coverage.md) preserves historical section and requirement identifiers.

### 1.2 When documents disagree

1. For what the language does: the manual wins, then the tests.
2. For what to build and why: the ROADMAP decision record wins.
3. History documents never override the above. They describe earlier goals (for example "no more
   than 2× C Lua", or "retain `SumType`") that have been replaced.
4. If you find a disagreement, fix the losing document in the same change.

### 1.3 The rules that matter most

1. **Planned is not implemented.** The roadmap and plans mix completed stages with future work. §5 of
   this file and each plan's status notes say what is true today. Do not write code against a design that has not landed.
2. **Never change behaviour by accident.** Every change passes `make test`; interpreter and engine
   changes also pass `make bench-check` and the sample-game check (§8, guideline 15).
3. **Never weaken a test, a gate or a ledger entry to make a change pass.**
4. **Do not change the canonical bytecode (`proto.code`) for speed.** Fingerprints and saves read
   it (§4.8).
5. **One garbage collector: D's.** Never add a second collector, reference counting or handle
   tables (§4.3).
6. **New code follows the style in §3**: return values, not exceptions; `@nogc nothrow` in hot
   paths; little Phobos.
7. **Respect the layers** (§4.1): a lower layer never imports a higher one.
8. **Work in the planned order** (ROADMAP "Order of work"). Do not start a later stage because it
   looks more interesting.
9. **When something is undecided, use the documented default** (ROADMAP "Open decisions",
   WORKBENCH_PLAN §9) and say in your change that you did.
10. **If you are unsure whether a change is allowed, it is not.** Ask the owner.

---

## 2. Project Mission & North Star

1. **Authoring first.** Varis exists so that writers, including contracted writers who are not
   programmers, can author visual novels and story games. Judge syntax, diagnostics and defaults
   by whether such a writer can use them from examples.
2. **Saveable and replayable by construction.** Preserve transactional effects, deterministic
   sessions and portable saves. Where a language feature cannot be saved or replayed (coroutines,
   closures over mutable state, unrestricted I/O), restrict it in **content files** and in what
   may be stored in saved state. Do not remove it from the language (item 4).
3. **Relational world model.** Maintain the finite Datalog engine: set semantics,
   least-fixed-point recursion, stratified negation, lexical local relations, independent worlds
   and snapshot queries, as defined in [the Varis relational reference](docs/relations.md). This
   is the product's distinguishing part and the owner's main concern (ROADMAP D5).
4. **A full language, which is Lua.** The procedural core stays a complete Lua-derived language,
   because people must be able to mod a game however they like (ROADMAP D2). Keep Lua 5.4's syntax
   and semantics. Passing more of the official Lua suite is **not** a goal (D3); the Lua suites
   are a regression net that protects modders.
5. **Fast in two ways.** The world model answers a turn within a budget on low-end hardware (D5).
   The Lua core must become no slower than C Lua and then faster (D4); parity has not been
   reached. Stand-in world-model budgets have recorded passing measurements; real low-end
   validation remains. See the performance plan.
6. **Tooling is part of the language.** A project checker, language services built on the Varis
   frontend, and a web workbench served by the Varis executable (command window, editor,
   workspace, in the manner of MATLAB) are deliverables (D10). Debugging is offered at the level
   of the source and the story, not of Lua's debug hooks (D11). Keep the frontend usable for
   tools: accurate source locations, validation separable from execution.
7. **C-like D.** The implementation is D (D 2.100+ / LDC 1.43+) written as "C plus sane templates
   and some classes": see §3. Varis objects stay directly accessible from D host code through the
   D garbage collector (D6, D8).
8. **Licence integrity.** Every source file derived from or porting Lua must include Lua's
   original MIT licence header (PUC-Rio).

---

## 3. Coding style (owner decision D6)

The owner's preferred D is close to C: betterC-style blocks, `@nogc`, return values instead of
exceptions. Treat D as C with good templates and a few classes. The contributor who favoured
Phobos-heavy code has left the project.

### 3.1 Rules for new and restructured code

| Do | Do not |
| --- | --- |
| Return a status or a count; put the error object in a slot on the thread. | `throw` in new code. |
| Mark hot kernels `@nogc nothrow` (ideally `@nogc nothrow:` at the top of the module). | Allocate inside a per-instruction, per-tuple or per-probe loop. |
| Use plain structs, tagged unions, fixed arrays, slices and pointers. | Add `std.sumtype`, `std.variant`, `std.typecons` wrappers. |
| Write the container you need (open-addressing hash set, growable buffer). | Use built-in associative arrays (`V[K]`) or `~=` on hot paths. |
| Use a template or `mixin` to generate variants from one source. | Copy a block of code and edit the copy. |
| Use a class when the object needs identity and lives on the collector (tables, closures, worlds, sessions). | Wrap values in classes to get polymorphism. |
| Write explicit loops. | Chain Phobos ranges (`map`, `filter`, `array`) in runtime code. |
| Use `core.stdc` and small local helpers. | Import `std.conv`, `std.format`, `std.string`, `std.algorithm`, `std.array` in hot modules. |

### 3.2 What "betterC style" means here

A whole-program `-betterC` build is impossible: betterC has no garbage collector, and all Varis
objects must live on D's collector (D8). "betterC style" means: the body of a kernel would compile
under `-betterC`, and the only things outside that subset are the named points where a buffer is
grown or an object is created with the collector. `@nogc` code cannot call the collector, so:

- size or grow buffers **before** entering a kernel;
- when a kernel runs out of room it returns a "need more room" status; its caller grows the
  buffer and calls again;
- buffers that hold values must be scanned memory, so the collector sees the references in them.

### 3.3 Existing code

Much existing code does not follow §3.1 yet: it still uses exceptions, `match!` and
associative arrays. Counts change as stages land; inspect the source rather than treating
historical profile counts as current. Rules:

- **Do not convert code opportunistically.** Conversion is planned work with its own stages
  (performance plan, tracks W and L). A drive-by conversion in an unrelated change is unwanted.
- When you fix a bug in old-style code, match the surrounding code.
- When a stage tells you to rewrite a module, the result follows §3.1 completely.
- Tests, the test runner and tools (`tests/`, `tools/`) may keep using Phobos and exceptions.

### 3.4 Formatting and headers

Formatting is `dfmt` with the settings in `.editorconfig` (`make fmt`). Every new `.d` file starts
with the licence header in guideline 1 (§8).

---

## 4. Architecture and invariants

Each subsection says what is true **today**. Where a planned stage will change it, a "Planned"
note names the stage. Until that stage lands, today's description is the one to code against.

### 4.1 Layers (ROADMAP D9)

```
  tools        cli.d, services/*.d, workbench/*.d, optional tools/sdl host
     |
  narrative    narrative/*.d, lib/narrative.d, lib/quality.d
     |
  world model  logic/*.d, lib/logic.d
     |
  Lua core     types, table, state, exception, opcode, ast, lexer, parser, compiler, vm, fiber,
               pattern, gc, dump, capi, lib/{base,math,string,table,coroutine,os,io,utf8,
               package_lib,debug_lib,auxlib,fastcall,pack}

  game         game/*.d: hex, terrain, fog, route, kinds, types, battle (a leaf beside the
               layers: it imports nothing from Varis; TOWER_DEFENSE_PLAN B9)
```

Rule: a module may import modules of its own layer and of layers below it, never above. The
`game/` leaf may import only other `game/` modules.

The rule holds and is **enforced**: `make check-sources` (part of `make check` and the pre-push
hook) fails when a module imports a higher layer. `source/varis/package.d` and `lib/package.d`,
which open every library for a state, are the only exemptions.

How the core reaches the layers above it without importing them (the seam, stage S1):

- **Syntax vocabulary** (`TermKind`, `CompareOp`, `GoalKind`) lives in the core module
  `varis.relterms`; the frontend and the compiler know the relational and narrative **syntax**,
  because syntax is part of the language.
- **Per-state objects**: `LuaState` holds the global world, the call world and the content
  registry as opaque `Object` slots. Their typed accessors are free functions found by UFCS
  (`state.globalWorld`, `state.callWorld` in `varis.logic.world`; `state.narrativeRegistry` in
  `varis.narrative.registry`), so import the accessor where you use it. The global world is
  created by a hook the world model adds to `stateCreatedHooks`.
- **Instructions**: the executor passes relational and narrative opcodes to
  `declarativeOpHook`, resolves a world value through `worldOfValueHook`, and opens a
  `transaction` block through `beginFrameScopeHook`, which returns the core interface
  `FrameScope`. `varis.narrative.vmops` implements and installs all three.
- **Execution scopes** (no-yield, read-only, notification) are core concepts in `varis.fiber`.

### 4.2 Value representation (`source/varis/types.d`)

- `LuaValue` is a 16-byte `struct` holding a `LuaPayload`: one 8-byte word (integer, float, boolean or pointer), a 32-bit length and a one-byte tag (`TagNil` … `TagThread`). The value kinds are Nil, bool, long, double, string, Symbol, LuaTable, LuaFunction, LuaUserData, LightUserData and LuaThread. Nil is all zero bytes (`LuaValue.init`; registers are cleared with `memset`).
- **Strings stay D slices**: a string value stores the slice's pointer in the word and its length in the 32-bit field, so creating a string value allocates nothing and `asString` returns the same slice. Strings (and symbol names) are therefore limited to 4 GiB.
- **Reference objects are D GC classes**: `LuaTable`, `LuaFunction`, `LuaUserData`, and `LuaThread` are managed by D's garbage collector.
- **Custom Equality & Hashing**:
  - `opEquals`: Follows Lua rules: integers and floats representing the same value are mathematically equal (`1L == 1.0`). `NaN == NaN` is false. Strings compare by value. Reference types compare by reference (`is`).
  - `toHash`: Guarantees that `1L` and `1.0` yield identical hash values, enabling use of `LuaValue` as a hash key.
- **Matching Precedence**: In D, `long` implicitly converts to `double`. When writing handlers over the value's type, **always handle `long` before `double`** to avoid unwanted numeric conversion.
- **Symbols**: Use the inline symbol payload backed by a state-owned intern pool, shared across worlds. Audit exhaustive visitors/type switches. Keep logic variables in declarative AST/IR and binding environments, not in general `LuaValue`.
- **Numeric prerequisite**: Audit mixed integer/float equality and `floatToInteger` at large integer boundaries before using them for tuple sets. Converting both operands to `double` can lose precision above 2^53 and break equality/hash consistency.
- **`match` is a tag switch** (`types.d`): the first handler that accepts the value's kind runs, `std.sumtype` is no longer imported anywhere. Still convenient and slower than the accessors; runtime code uses the accessors.
- **Still planned (rest of stage L2):** decide on measurement whether strings should become objects with a cached hash. Compile-time string constants are interned (`VM.prepareForExecution`); run-time strings are not, and must not be (an intern pool on D's collector would keep every string alive).

### 4.3 Memory management

- Direct delegation to D's garbage collector (`core.memory.GC`). This is permanent (ROADMAP D8): host D code holds tables, worlds and sessions as ordinary references.
- No manual tri-color mark-and-sweep tracking or grey lists. No second collector, no reference counting, no handle tables.
- `collectgarbage()` is mapped to D runtime GC equivalents (`GC.collect()`, `GC.stats()`, `GC.enable()`, `GC.disable()`).
- Weak tables, ephemerons and finalizers are emulated (`gc.d`); this is a frozen Lua feature.
- Performance comes from allocating less, not from replacing the collector: see §3.2.

### 4.4 Tables (`source/varis/table.d`)

- **Dual-Storage**:
  - `arrayPart` (`LuaValue[]`): Fast path for 1-based positive integer indices `1 .. N`, nil-padded to a power of two with Lua's rehash policy.
  - Hash part: nodes with cached hashes; small tables (≤ 8 nodes) have no bucket array.
- **Key Normalization**: Float keys representing exact integers (e.g. `1.0`) are automatically converted to `long` (`1L`) via `normalizeKey()`.
- **Invalid Keys**: Setting a table index to `nil` or `NaN` raises a Lua error.
- **Length Operator (`#t`)**: Border search finding $n$ where $t[n] \neq \text{nil} \land t[n+1] = \text{nil}$.
- **Metatables**: `__index`, `__newindex`, `__len`, `__eq`, `__lt`, `__le`, etc.
- String-key lookups compare pointer first, then length and bytes (`findStringHinted`, `findStringHashed`). `VM.prepareForExecution` interns compile-time string constants across functions; runtime strings remain uninterned.

### 4.5 Control flow & errors (`source/varis/exception.d` & `state.d`)

- **Today:** a Lua error is a `LuaException` object. Natives and the VM's out-of-line helpers `throw` it; `executeFrame` catches it once and from there it travels **by return**: a Lua callee hands it back in `TailRequest.error`, the caller runs its frame handler (the block after the `try` in `executeFrame`) and returns it in turn, up to `VM.callProtected`. The `error` builtin called from Lua raises without any throw, and `pcall(error, …)` computes its result directly. `executeDeepFrame` and coroutine boundaries still rethrow. A D throw costs about 5 µs on macOS, so new code must not add throws on paths that can be hot.
- **Planned (stage L1, ROADMAP D7):** errors as values. The executor and natives return a status; the error object sits in a slot on the thread; cleanup is explicit and in the same order the scope guards run today. An adapter keeps unconverted natives working during the migration.
- Until L1 lands, existing code keeps throwing `LuaException`, and code that calls it must stay exception-safe. New modules written in the §3 style return statuses and convert at their boundary with old code.

### 4.6 Coroutines (`varis.fiber`)

- Backed by D's `core.thread.Fiber`.
- Allows yielding across arbitrary native D boundaries without requiring continuation-passing boilerplate (`lua_yieldk`).
- Ordinary coroutines may mutate worlds and consume iterators between calls; each iterator retains its construction-time snapshot.
- Unprotected Lua coroutine errors retain frames and close handlers until explicit close; protected errors unwind at their handler. Closing must bypass protected calls, prohibit yielding/reentrant close, preserve error objects, and clear the error after the first close. Keep debug call stacks isolated per Fiber. Standard sort/gsub callbacks remain non-yieldable.
- Guards must not yield during inference, including through helper functions or native callbacks. Enforce this at the Fiber yield boundary with restoration of yieldability on every exit.
- Coroutines are part of the full language (D2) and must keep working. They are not a performance target: content does not use them, and implemented declarative scenes retain resumable positions instead (ROADMAP milestone 29).

### 4.7 Frontend: typed AST intermediate representation

- Replaces Lua's intertwined single-pass parser/compiler with:
  `Source -> Lexer -> Parser -> Typed AST -> Compiler -> Bytecode -> VM`
- An explicit typed AST (`source/varis/ast.d`) allows AST transforms, declarative rule definitions, tools (checker, language services) and, later, optimizing compiler passes (stage X3) without disturbing bytecode generation.
- AST nodes carry line and column. Keep them accurate: diagnostics, the workbench editor and breakpoints depend on them.

### 4.8 Instructions & VM

- **Canonical bytecode:** `Prototype.code` is an array of `struct Instruction` (32 bytes: `op`, `a`, `b`, `c`, `sBx`, `line`, three "operand is a constant" flags). Content fingerprints (`narrative/fingerprint.d`) and binary chunks (`dump.d`) read `proto.code` and `proto.callWorlds`. **Changing what the compiler emits there changes fingerprints and invalidates saves.** Never do it for speed.
- **Execution data:** `VM.prepareForExecution` derives `proto.execCode` (today: `code` plus a final `Return`) and per-pc side tables (`callSites`, `lookupHints`, `newTableSizes`, `constantHashes`). Nothing persists these. Speed work belongs here. Do not mutate `proto.code` after compilation.
- **Two executors:** `executeFrame` (native recursion per Lua call) and, past 150 nested Lua frames, `executeDeepFrame` (frames as saved records in one native frame). They **must stay behaviourally identical**; `tests/regression/deepframes.lua` pins this. Forty of the 43 opcode handlers are written once, in the `sharedOpcodeCases*` strings at the top of `vm.d`, and mixed into both dispatch switches: change a handler there. Only `Call`, `TailCall` and `Return` (and the frame entry, exit and error code) are still written per executor; a change to one of those must be made in both.
- **Rare duties** (instruction budget for analysis, open frame transactions, pending collection, interrupts, debug hooks) are behind one flag, `vmAttention`, with `vmSlowMode` for the per-instruction ones.
- **Planned:** S1 generates a fast and an instrumented executor from one handler source and removes world and transaction bookkeeping from the plain call path; L3 lowers `code` into a compact specialized `execCode`; L4 slims the call path; X1–X2 add inline caches and specialized instructions.

### 4.9 Standard libraries & pattern matching

- Standard libraries live in `lib/*.d`, ported from the corresponding C Lua libraries, with shared argument checking in `lib/auxlib.d`. `lib/fastcall.d` holds allocation-free entry points for hot built-ins that decline (return -1) on any unusual case so the generic implementation produces the diagnostics.
- Today they use Phobos (`std.math`, `std.stdio`, `std.datetime`, `std.utf`, `std.process`, `std.conv`, `std.format`). New library code follows §3; existing code is converted in stage L1.
- **Pattern Matching (`source/varis/pattern.d`)**: Directly ports Lua's pattern matching engine from `lstrlib.c` to guarantee fidelity for `%a`, `%b`, frontier `%f[]`, and numbered captures `%1`.

### 4.10 Declarative engine (Phase 6)

- **Finite relations**: Fixed-arity tuple sets use raw Lua equality without `__eq`; `nil` is valid and NaN is prohibited. Preserve separate base and derived membership, including zero-arity tuples.
- **Validation and atomicity**: Check arity, variable safety, world/local ownership, and stratification before publishing a rule. Failed fact operations and rule registrations leave that operation's logical program changes uncommitted, including implicit declarations.
- **Evaluation** (`logic/evaluate.d`, `logic/store.d`): facts are read from shared immutable `FactTable`s; a conjunction compiles to a slot-based plan whose positive atoms probe hash indexes; recursive strata are evaluated semi-naively; derived relations are cached per closure, keyed by the identity of the rules and of the base tables. Only successfully completed results are published, and closures whose rules call Lua (guards, aggregate expressions) are never cached. Adding facts to negated relations and retracting facts replace the relation's table, which invalidates every cache entry that read it.
- **Order inside a conjunction is part of the behaviour**: positive atoms are joined first, then aggregates, comparisons, guards and negated atoms are applied, each to all surviving candidates before the next kind. Do not push a comparison or guard into the join: it would change which candidates raise errors or run author code.
- **Writes**: every write to `Relation.baseFacts` or `keyIndex` goes through `ownFacts`, `adoptFacts` or `clearFacts` (the fact set may be shared with a cloned world, and the cached table must be dropped).
- **Oracle** (`logic/naive.d`): the original naive evaluator is the correctness reference. `VARIS_LOGIC_ORACLE=1` makes the runtime answer every query with both and fail on a difference; the `logic-oracle` suite runs that way. Do not optimize the oracle. A change to evaluation is not done until the oracle suite passes.
- **Worlds**: Each state owns `logic.global`. Inheritance snapshots facts/rules and rebinds inherited relation references to the child. Referenced Lua objects are shared by identity. Rules cannot depend on another world; world-owned rules cannot retain local relation dependencies.
- **Lexical context**: Use a separate relation namespace and hidden lexical slots/upvalues for local handles and world-block defaults. Local relations shadow named world relations; ordinary Lua locals do not shadow relations. Resolve rule/query references once so later shadowing does not retarget them.
- **Compilation**: Store immutable declarative templates on `Prototype` and lower to dedicated VM instructions calling engine APIs. Evaluate each syntactic relational constant argument once to exactly one value; do not expand the final Lua call or vararg.
- **Queries and records**: Freeze relational state at construction; defer inference until the first iterator call. Deduplicate returned named bindings, omit anonymous variables, and return one empty record for a successful ground query. Use opaque GC-managed world/record payloads with immutable field access and explicit binding presence for `nil`; retain local relations and snapshots by reachability. Evaluation errors invalidate the iterator.
- **Guards**: Capture ordinary Lua values by value at rule registration (reference objects retain identity), use the first result and Lua truthiness, and require grounded logic variables. Query guard capture timing and other semantic edges follow the Varis reference; milestone 0 records their engineering history. Arbitrary external-state purity is a programmer obligation.
- **Compatibility**: Extension names remain contextual identifiers. Preserve ordinary calls, assignments, method colons, and labels. Compound terms, cuts, procedural backtracking and individual rule deletion remain outside scope. Aggregates are implemented and documented in Varis reference §4.6.

### 4.11 Stateful and narrative companion (Phase 7)

- **Schemas and updates**: Named columns are metadata, not types. Immutable keys constrain base tuples using raw equality, including `nil`; keyed relations are extensional and cannot be rule heads. `fact` conflicts error; `set`, key-only `delete`, and single-value `adjust` are atomic, with no-op updates preserving logical versions.
- **Transactions**: One selected world, entry snapshot plus prior writes, same-world nested savepoints, no tentative visibility to other coroutines. Commit on non-error exit; rollback on escaping errors or explicit `rollback`. Prohibit yields, cross-world mutations, schema/rule changes, and other-world nesting. Escaped committed iterators retain snapshots; rolled-back iterators become invalid. Arbitrary Lua mutations and I/O are not rolled back.
- **Optional aggregates**: Distinct local assignments, grounded correlated inputs, newly grounded results, strictly lower-stratum dependencies, and no aggregate recursion. Preserve empty-set/error semantics; aggregation is an implemented companion amendment to the base scope.
- **Content and sessions**: State-owned sealed/versioned content registry, separate from worlds. Sessions retain independent world references, turns, deck stacks/history, periods, events, and deterministic seeded RNG state. Canonical serializable scalar bindings identify instances independently of hash iteration.
- **Narrative compilation**: Bind exposed parameters as read-only Lua locals. Resolve narrative availability/effect references against the owning session world; preserve ordinary closure lexical-world semantics. Keep all new syntax contextual and constant fields frozen at registration.
- **Requirements and procedures**: A choice may carry `require { goals } because "…"`; when it fails the choice is still presented, `enabled = false`, with a rendered reason and no token, and choosing re-checks it. A `procedure` is content that a scene `effect` beat names: its effect runs in the session world, and the effect beats of one command run in one transaction. Procedures cannot start scenes. `because` wording is outside content identity; `require` goals and procedure code are inside it.
- **Choices and actions**: Immutable presentation tokens; revalidate exact bindings and policies inside the effect transaction. Failed choices produce no turn advancement. Actions run outside inference in canonical priority order, reevaluating after each commit; enforce once-per policies and phase budgets, retaining prior successful commits on `ACTION_LIMIT`.
- **Decks and templates**: Canonical weighted draws with explicit seeding and versioned algorithms; per-entry no-replacement history. Render templates read-only from the presentation snapshot, with existence tests rather than iterator truthiness, and no RNG consumption during rendering.
- **Qualities and events**: Quality metadata constrains the keyed extensional relation across all mutation paths. Explicit initialization, no implicit defaults/clamping. Transactional events have commit-time sequence numbers and immutable read-only relation access; schedules run before actions with bounded immediate chains. Deferred external callbacks run only after commit.
- **Save format and wording**: formats 2/3 (`varis-session-2` and scene-aware `varis-session-3`, October 12, 2026) keep wording (titles, texts, names, quality labels) out of the content identity: `contentFingerprint` includes only the structure of a template (conditions, variant weights and names, plural/select parameters). Format 1 is read with `legacyContentFingerprint` / `legacyContentVersion` and written back as 2. Translations (`narrative.translate`, `varis l10n build` packs) are presentation data: never fingerprinted, never saved. Do not put wording back into the identity.
- **Persistence and diagnostics**: Save only at quiescent boundaries; validate serializable values and schema/content versions, reconstruct authored rules, and reject unsupported closures/local relations absent a host protocol. Explanations are read-only; subscriptions/analysis are optional, post-commit/isolated facilities.
- **Recorded decisions**: Preserve the plan's control-flow, local-relation, token, event timing, handler, serialization and migration interfaces. Quality defaults inside effects follow lexical call-world metadata (including captured helper worlds); outside effects they use global. Nonyield scopes include synchronously resumed children. Do not claim broader Lua compatibility or analysis completeness than the audit supports.
- The lexical call world is carried in `state.callWorld`, set at call sites from `proto.callSites[pc].world`. Its only reader outside the VM is `lib/quality.d`. Stage S1 moves this off the plain Lua call path; the rule above must still hold afterwards.

### Phase 9 additions (milestones 26–29, October 13, 2026)

- **Menu labels** are catalog messages `scene.<label_id>.label`; `label_id` is a choice field
  (`<scene>.<option id>` from readable scenes, else `<scene>.<choice id>`), unique per registry.
- **Readable scenes** are lowered by the parser (`parseReadableScene` in `parser.d`) to
  `narrative.scene(:name, {beats})` calls, plus generated scenes (`<scene>__<what><n>`) for menu
  options, `if` branches and their join points and generated procedures for `effect using`. The
  only engine addition is the `branch` beat (`narrative/scenes.d`: validated at seal, resolved in
  `seekBeat`, rejected as a restore position). Parsed statements queue extra statements in
  `pendingStmts`, which `parseBlock` flushes after the scene. Do not add statements that need
  state the beat model cannot hold (loops, expressions over several locals) without the owner.

- **Computed bindings** are the aggregate goal with operator `"value"` and no goals (`?x := expr`);
  both evaluators (`logic/evaluate.d` and the oracle `logic/naive.d`) handle it, and a rule that
  has one gets strict dependencies on its body relations so it cannot recurse. A parenthesized
  `or` group is parsed into one guard. Do not teach either evaluator a second meaning for them.
- **`AdjustClamp`** was appended to the opcode enum (the last value, so existing numbering and
  fingerprints are unchanged); `Relation.clampTuple` is set only for `quality`.
- **Saves**: `ending` and `event_cursor` are optional fields written only when they carry
  something (the cursor only when events are waiting), so saves that never used them are
  byte-identical. `expose` names and `leads` are part of the content identity; the exposed
  *values* are not part of an instance key.
- **Handlers and `narrative.defer` callbacks** run through `callInSessionWorld`, which swaps
  `state.globalWorldObject` for the call. Do not read `state.globalWorld` in new code on those
  paths expecting the process-wide world; `logic.global` is that.
- **Tiers at load time**: `LuaState.fileTierHook` (core, a delegate) is installed by
  `services/tier.d` from the manifest; the core only calls it from `loadSourceFile`. The
  restricted environment is built per file from `contentEnvironment`; add a name there only when
  content may call it without breaking saves and replay.
- **Source extension**: `.varis` and `.lua` are both source (`isSourceName`); `package.path`
  keeps its Lua spelling and the `.lua` searcher falls back to `.varis`.

### Undo, profile and conveniences (milestones 38, 40)

- `session:undo()` restores facts through `World.captureFacts` / `restoreFacts` (copy-on-write
  sharing, versions only move forward) and `SessionData.copy()`; scene objects are replaced,
  never mutated, which is what keeps beat tokens valid. Token, deck and schedule counters keep
  running and tokens issued after the restored point are voided. The ring is off by default and
  not saved. Do not make scene or session state mutable in place without revisiting this.
- The profile (`narrative/profile.d`, `narrative.profile_*`) is deliberately outside saves,
  fingerprints and replay; reads are refused in transactions and read-only evaluation. Keep it
  that way: content must not be able to depend on it.
- `narrative.meta` data, save `label`/`meta` and rich-text markup are presentation data: never
  in a fingerprint (same rule as wording).
- `visited`/`last_chosen` are derived from `replayInputs` and `completed`; adding a counter to
  the save would change the format, which needs the owner.

### SDL3 presentation (initial milestone 36 slice)

`make varis-sdl` builds the optional `bin/varis-sdl` scene player in `tools/sdl/`.
`varis.services.presentation` is the status-returning scene-host adapter. Media paths,
fonts and slot layout live in a JSON manifest, outside engine stage and save identity.
See [docs/presentation.md](docs/presentation.md) for the implemented surface and limits.
The CLI has no SDL dependency; `make test-sdl` runs optional headless rendering checks.

### 4.12 Debugging and the workbench (partial; ROADMAP D10, D11)

A first version exists (`varis serve` and `varis check`, `source/varis/workbench/`; WORKBENCH_PLAN §1a lists what works), including story-level debugging and a source-level debugger with line breakpoints, stepping, stack and locals. Language services, LSP and the editor's static diagnostics exist; the editor embeds vendored CodeMirror with inline diagnostics, breakpoint gutters and retained undo. Panels resize and command history persists in browser storage. Pushed events and the complete debugger do not. The design is in [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md).

- The tool is a web workbench served by `varis serve`: command window on the left, editor on the right, a workspace browser (MATLAB's model). The engine runs natively; the browser is only the user interface. No WebAssembly.
- Debugging is at two levels. **Story level** (step a turn, rewind by replay, what changed, why a choice is missing) is built on the existing `narrative.explain`, `narrative.observe`, `narrative.analyze` and replay logs. **Source level** (line breakpoints, stepping, call stack, locals) is built on the instrumented executor from stage S1.
- The fast executor must never contain debugging code. A function runs on the instrumented executor only while a debugger is attached, a debug hook is set, or an analysis budget is active.
- Lua's `debug` library is a frozen feature. It keeps working; it is not the interface tools are built on.
- Inspection is read-only and goes through snapshots. Looking at state must never change it or consume random numbers.
- What you can do today to keep this possible: keep source positions accurate, keep validation separable from execution, keep diagnostics structured (a code, a location, names) rather than only formatted strings.

---

## 5. Today versus target

Use this table to avoid coding against a design that has not landed.

| Aspect | Today (code against this) | Target | Changes in |
| --- | --- | --- | --- |
| Errors | `LuaException` objects. Between Lua frames they are **returned** (`TailRequest.returnErrors`), and `error` raises without a throw; natives and out-of-line helpers still `throw`, and `pcall` still catches those | Status returns everywhere; error object on the thread | L1 (first step done) |
| Value | 16-byte tagged payload; strings are slices packed as pointer + 32-bit length; `match!` is a tag switch (no `std.sumtype`) | Same; cached string hashes if measurement supports it | L2 (done except string objects) |
| Instructions executed | `execCode` = canonical 32-byte instructions plus a final `Return` | Compact specialized encoding derived from `code` | L3 |
| Executors | `executeFrame` and `executeDeepFrame`; 40 of 43 handlers shared through `sharedOpcodeCases*` mixins, calls and returns still per executor | One executor with frames as records; fast and instrumented variants | S1 (first step done) |
| Core and world model | No core module imports `logic` or `narrative` (enforced by `make check-sources`); the world model plugs in through hooks (`narrative/vmops.d`). The executor still carries an opaque call world on every Lua call | Same, with the call world resolved only for natives that ask | S1 (boundary done) |
| Fact storage | `bool[RelTuple]` per relation for writes, plus a shared immutable `FactTable` with indexes for reads (`logic/store.d`); cloned worlds share fact sets copy-on-write | Same | W1 (done) |
| Query evaluation | Compiled slot plans, index probes, semi-naive recursion, derived relations cached per closure; naive oracle; required-constant-fact storylet prefilter | Remaining W5 indexing only if measurements justify it | W2–W4 and W5(a) done |
| Scenes and stage | Declarative scene/character declarations and the readable `scene name() … end` form (say/narrate/show/menu/if/input/effect, explicit text ids; manual 6.11a), scalar locals, jump/call/return, beat tokens and engine-owned stage; format 3 mid-scene saves; `sample-vn/` (`content.varis`) | Arbitrary Lua between beats (deferred), full presentation parity (milestone 36) | 29 (done) |
| SDL3 presentation | Optional `varis-sdl` scene player: backgrounds, expression sprites, portraits, dialogue/menu/input, audio, quicksave/load, recent history, auto/skip; asset manifest and status-returning scene host. A manifest with a `project` runs a whole game through `GameHost`: title, storylet hub, status panel, toasts, character sheet, journal, map, pause/settings, language switch, ending screen (*The Hollowbrook Summer*) | Full stage parity and typography; general embedding API | 36 (initial slice and game host done) |
| Sample game | In `make test` (suite `sample-game`: its check plus a golden transcript and save, `tests/sample_game/`) | Same | S0 (done) |
| Tower-defense battle | Native fixed-step integer simulation in `source/varis/game/` (all ten ability primitives, heroes with obedience, modifiers, replay, digest; a step allocates nothing); the `battle` library (`lib/battle.d`); the four project hooks run by `GameHost` (build, silent raid, night, moments as scenes, sync, result, retry, abandon, no save during a battle); a static check of battle data in `varis check`; the 2.5D SDL battle view (`tools/sdl/battleview.d`: terrace prisms, billboards, camera, picking, four zoom bands, fog, minimap, HUD, moment overlay). Measured: about 15–21 ns per live enemy per step natively, about 3 µs in relations | Travelling projectiles, Dijkstra costs, `varis battle`, overview texture and caches for the 435,600-tile map, benchmark budgets | [TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md) TD0, TD5 remainder |
| Third sample game | `sample-td/` (*Lanternfall*): four nights of dusk hub, build and real-time night on a terraced map, three heroes with trust and bonds, eleven moments with choices, ruins, injuries and deaths, judge and forecast, four endings, a French pack; suite `sample-td` plus an SDL smoke in `make test-sdl` | Real art and audio; a human review of the French draft; balance by play | [SAMPLE_TD_PLAN.md](SAMPLE_TD_PLAN.md) |
| Second sample game | `sample-rpg/` (*The Hollowbrook Summer*): character creation, a nine-place town, stat-gated choices with reasons, scene outcomes, a three-contest finale, six endings, a French pack; suite `sample-rpg` plus an SDL smoke in `make test-sdl` | Real art and audio; a human review of the French draft | [SAMPLE_RPG_PLAN.md](SAMPLE_RPG_PLAN.md) |
| Undo, profile, conveniences | `session:undo` (turn and beat), `GameHost.back`/`SceneHost.back` and the SDL B key; `narrative.profile_*` (host-owned; the SDL player keeps `profile.json`); save headers, autosave hook and slots; `var`, `{$name}`, `{>fragment}`, `{#if lua}`; `visited`/`last_chosen`, `narrative.meta`, `narrative.spans`, validated `input` beats; the writer's guide in `docs/writers/` | Nothing open for milestones 38, 40, 41 | Milestones 38, 40, 41 done |
| Debugging | Workbench line breakpoints and stepping for Run/commands and story effects, selectable frame locals and read-only frame expressions; asynchronous Pause and Stop; story explanations/deltas and seeded replay/rewind; Lua `debug` library remains frozen | Error stops and separate fast/instrumented executors | Milestone 44 incomplete |
| Tools | CLI and REPL (`cli.d`); project manifest (`project.lua` or `project.varis`), project index, `varis check` (every syntax error, static checks including battle data, load and analysis passes, `--locale`), `varis lsp` language server, static content-tier and declared-symbol checks, load-time content-tier enforcement (`services/tier.d`: restricted environment, `narrative.helper`), the `.varis` source extension, `varis play`, `varis test`, `varis l10n` (extract, status, kits, XLIFF/CSV, review, packs); `varis serve` first version (command window, workspace, story panel with why/changes and a language switch, editor with shared source services, retained drafts and rename preview, project problems, breakpoints and stepping) | Complete debugger and workbench | Milestones 42–44 |
| Core speed | 0.62–2.67× C Lua on core workloads in the October 12 run (`fib` 2.28×, `string_ops` 1.72×, `closures` 1.93×, loops 1.1–1.5×); `pcall_error` 1.22× (was 37×), `deep_recursion` 2.67× (was 8×); see generated `docs/STATUS.md` for the latest full run | ≤ 1.0×, then below | L, X |
| Turn latency (reference-scale game, M1) | 0.3 ms with or without a recursive rule (was 15 ms and 840 ms); peak memory 53 MB | 5 ms and 64 MB on the stand-in; real hardware unmeasured | W, M |

---

## 6. Directory Layout & Module Ownership

| Module | Layer | Status | Role & Responsibilities |
|---|---|---|---|
| [`source/varis/types.d`](source/varis/types.d) | core | ✅ Phase 1 | `LuaValue`, value helpers, truthiness, equality, hashing |
| [`source/varis/table.d`](source/varis/table.d) | core | ✅ Phase 1 | `LuaTable` dual-storage, length border, rawget/rawset, iteration |
| [`source/varis/exception.d`](source/varis/exception.d) | core | ✅ Phase 1 | `LuaException`, error reporting, stack info |
| [`source/varis/state.d`](source/varis/state.d) | core | ✅ Phase 1 | `LuaState`, globals table (`_G`), registry, stack, `pcall`, `vmAttention` flags |
| [`source/varis/package.d`](source/varis/package.d) | core | ✅ Phase 1 | Public API re-exports |
| `source/varis/ast.d` | core (frontend) | ✅ Phase 2 | Typed AST node classes/structs (Statements, Expressions), with source positions |
| `source/varis/lexer.d` | core (frontend) | ✅ Phase 2 | Tokenizer, keywords, numbers, long brackets `[[...]]`, escapes |
| `source/varis/parser.d` | core (frontend) | ✅ Phase 2 | Recursive descent parser producing AST |
| `source/varis/opcode.d` | core | ✅ Phase 3 | OpCode enums, `Instruction` struct, `Prototype` (canonical `code`, derived `execCode` and side tables) |
| `source/varis/compiler.d` | core | ✅ Phase 3 | AST-to-bytecode compiler, scope analysis, register allocation |
| `source/varis/vm.d` | core | ✅ Phase 3 | Bytecode execution loops (`executeFrame`, `executeDeepFrame`), upvalues, closures |
| `source/varis/fiber.d` | core | ✅ Phase 3 | Coroutine execution runner wrapping D `Fiber` |
| `source/varis/pattern.d` | core | ✅ Phase 4 | Lua pattern matching engine ported from `lstrlib.c` |
| `source/varis/lib/*.d` | core, except as listed below | ✅ Phase 4 | Standard libraries (`base`, `math`, `string`, `table`, etc.); `fastcall.d` holds allocation-free fast entry points for hot built-ins |
| `source/varis/gc.d`, `dump.d`, `capi.d`, `lua_api.exports` | core (frozen features) | ✅ Phase 5 | Weak-table/finalizer emulation, binary chunks, exported C API subset for `dlopen`ed modules |
| `source/varis/cli.d` | tools | ✅ Phase 5 | Standalone `varis` executable runner & REPL |
| [`source/varis/logic/model.d`](source/varis/logic/model.d) | world model | ✅ Phase 6 | Tuple/term/goal/rule IR, identities, immutable snapshots |
| [`source/varis/logic/world.d`](source/varis/logic/world.d) | world model | ✅ Phase 6 | Worlds, local relations, versions, atomic mutation, inheritance, transactions |
| [`source/varis/logic/validate.d`](source/varis/logic/validate.d) | world model | ✅ Phase 6 | Safety, ownership, arity, signed dependencies, SCCs/strata |
| [`source/varis/logic/evaluate.d`](source/varis/logic/evaluate.d) | world model | ✅ Phase 6, rewritten in stage W | Compiled plans, index joins, semi-naive fixed point, derived-relation cache |
| [`source/varis/logic/store.d`](source/varis/logic/store.d) | world model | ✅ stage W | `FactTable`: shared immutable fact rows with hash indexes |
| [`source/varis/logic/naive.d`](source/varis/logic/naive.d) | world model | ✅ Phase 6 | The original naive evaluator, kept as the test oracle |
| [`source/varis/logic/query.d`](source/varis/logic/query.d) | world model | ✅ Phase 6 | Snapshot iterators, projection, immutable binding records |
| [`source/varis/lib/logic.d`](source/varis/lib/logic.d) | world model | ✅ Phase 6 | `logic` library and global `symbol` |
| `source/varis/narrative/{registry,templates,codec,fingerprint,session,persistence,observe,diagnostics,analysis}.d` | narrative | ✅ Phase 7 | Sealed content, sessions, decks, choices, actions, saves and replay, explanations, subscriptions, bounded analysis |
| `source/varis/lib/{narrative,quality}.d` | narrative | ✅ Phase 7 | `narrative` and `quality` libraries |
| `source/varis/narrative/vmops.d` | narrative | ✅ stage S1 | Implementation of the relational and narrative instructions; installs the executor's hooks |
| `source/varis/relterms.d` | core (frontend) | ✅ stage S1 | Relational syntax vocabulary shared by the frontend and the world model |
| `tests/unit/*.d` | | ✅ | Unit tests (foundation, frontend, vm, libs, logic, stateful, narrative) |
| `tests/runner.d` | | ✅ Phase 5 | Runner for `c-implementation/lua-5.4.9-tests/` (`python3 tools/suite test --suite official`) |
| `tests/datalog/` | | ✅ Phase 6 | 12 positive and 3 negative acceptance programs; 19 self-checking scenario programs with golden output at two scales; `known_gaps/` |
| `tests/manifest.toml`, `tools/suite` | | ✅ | One manifest and one driver for every test suite and benchmark |
| `sample-game/` | | ✅ | *Saltmarsh Light*, the complete sample game; must keep working (D12) |
| `benchmarks/` | | ✅ | Workloads, `targets.toml` (goals and gates), plans and history |
| `docs/` | | Current reference | The Varis language definition, libraries, grammar, compatibility, runnable examples |
| `source/varis/workbench/server.d`, `page.d`, `inspect.d` | tools | ✅ first version (milestone 42) | `varis serve`: loopback HTTP server owning the project state, and the workbench page |
| `source/varis/services/{diagnostic,manifest,index,checks,check,loadpass,lang,lsp,play,json,catalog,xliff,l10n}.d` | tools | ✅ authoring plan A0–A6, localization plan T1/T3/T4 | Diagnostic record, manifest reader, project index, static checks, `varis check`, language services and server, playtest and author tests, catalogs and the `l10n` commands. Read the AST; never run content to understand it (§4.12). |
| `source/varis/narrative/translation.d` | narrative | ✅ localization plan T3 | Translated message templates, render traces; translations are presentation data, never fingerprinted or saved |
| The debugger | tools | ✅ initial slice, milestone 44 incomplete | Line breakpoints, stack/locals and stepping for command-window/Run code; story explanations and turn changes. See WORKBENCH_PLAN §1a for remaining limits. |
| `source/varis/narrative/{scenes,plural,text}.d` | narrative | ✅ initial scenes and text support | Portable beat programs, stage state, plural rules and Unicode/text helpers |
| `source/varis/services/{tier,presentation}.d`, `tools/sdl/` | tools | ✅ initial slices | Static content restrictions, status-returning scene adapter and optional SDL3 player |
| `sample-vn/` | | ✅ | *Harbour Window*: scene saves and graphical presentation sample |
| `source/varis/services/gamehost.d`, `tools/sdl/{gameplayer,ui}.d` | tools | ✅ | `GameHost`: the status-returning host of a project or of scene-only content (hub, scenes, stage, status, toasts, journal, map, saves, language); the SDL3 player; `ui.d` is its widget toolkit (one root owns the screen, text owned by boxes with overflow policies, size classes, theme as data) |
| `source/varis/game/{hex,terrain,fog,route,kinds,types,battle}.d` | game (leaf) | ✅ TD1–TD2, extended | Tower-defense battle core: axial hex maths, seeded terrain with edits and terrace heights, sector fog, flow fields, tower/enemy kinds (ten primitives), setup/command/outcome types, the fixed-step simulation, hero orders, modifiers and its digest. No Lua. |
| `source/varis/lib/battle.d` | world model (bridge) | ✅ TD3 | The `battle` library: converts the Lua setup (1-based) to the simulation's structs with field-named problems, drives a battle, reads it (snapshot, tile, route, log), forks and replays it, applies `battle_sync` tables, `BattleHost` for `GameHost`. |
| `tools/sdl/battleview.d` | tools | ✅ TD4–TD5 slice | The battle view widget: projection and painter's order, prisms, billboards, effects, camera, picking, minimap; read-only over the simulation. |
| `sample-td/` | | ✅ | *Lanternfall*: tower-defense / visual-novel sample and integration test of the battle engine; see its README |
| `sample-rpg/` | | ✅ | *The Hollowbrook Summer*: Twine-style RPG sample for the SDL3 player; see its README |

Keep all source modules listed explicitly in the `Makefile` (`make check-sources`).

---

## 7. Phase status

### Phases 1–5: Lua core (completed ✅)

1. **Phase 1, foundation**: core types, table dual storage, error handling, state.
2. **Phase 2, frontend**: typed AST (`varis.ast`), tokenizer (`varis.lexer`), recursive descent parser (`varis.parser`). Unit tests in `tests/unit/test_parser.d`.
3. **Phase 3, runtime**: opcodes (`varis.opcode`), compiler (`varis.compiler`), VM (`varis.vm`), Fiber coroutines (`varis.fiber`). Unit tests in `tests/unit/test_vm.d`.
4. **Phase 4, standard libraries**: pattern engine and `base`, `math`, `string`, `table`, `coroutine`, `os`, `io`, `utf8`, `package_lib`, `debug_lib`. Unit tests in `tests/unit/test_libs.d`.
5. **Phase 5, CLI and conformance evidence**:
   - `source/varis/cli.d`: standalone executable supporting `-e`, `-v`, `-i`, script files and a REPL.
   - `tests/runner.d` runs the official Lua 5.4.9 suite as a stock binary runs it (`T == nil`, `gc.lua` excluded by owner decision; an ltests-style `T` is out of scope), with strict failure exits, combined output capture, PASS/PARTIAL/SKIP/FAIL statuses, `--reference` C Lua comparison and JSON reporting (default 120 s per file; 240 s for the `all.lua` driver). It builds the suite's C test modules, provides a closed-pipe stdin and an `sh` wrapper for the nested-shell check, and runs `all.lua` in a scratch copy with `gc.lua` stubbed. Baseline (October 9, 2026 release build): **31 passed, 1 partial (`all.lua` with `gc.lua` stubbed), 1 skipped (`gc.lua`, because exact reachability conflicts with D-accessible objects), 0 failed, 0 timed out.** [Recorded evidence and remaining issues](tests/official/README.md) supersede earlier baselines. A file PASS means the process exited successfully; `api`/`code` self-skip without the `T` library as under stock C Lua.
   - Weak tables, ephemerons and finalizers are emulated on D's collector (`source/varis/gc.d`, forked reachability probes); C modules load through `dlopen` and the exported C API subset in `capi.d`; binary chunks are in `dump.d` (private body behind a standard header); the interpreter runs on a large-stack Fiber (`cli.d`). These are frozen features.
   - `python3 tools/suite test --suite core` compares deterministic core behaviour with C Lua.
   - This is a **regression net**, not a goal (D3). No work is planned on the remaining gaps. Skipped files and unsupported D-GC semantics remain explicit barriers to any full-conformance claim.

### Phase 6: Declarative Datalog extensions v0.1 (completed ✅)

Milestones 0–8 in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md); retain executable coverage for their requirements:
- **Milestone 0 & 1**: Interned symbols, relational value equality/hashing, NaN prohibition in tuples.
- **Milestone 2**: World and relation model, version tracking, atomic mutations, snapshot inheritance.
- **Milestone 3**: Rule/query validation, variable safety, stratification check, least-fixed-point evaluation.
- **Milestone 4**: Point-in-time snapshot query iterators, immutable `BindingRecord`, `logic` standard library.
- **Milestone 5**: Declarative AST nodes and parser integration (`fact`, `retract`, `rule`, `relation`, `local relation`, `logic (w) do`, `query`, symbols, logic variables).
- **Milestone 6**: Compiler and VM bytecode instructions (`LoadSymbol`, `NewLocalRel`, `DeclRel`, `AddFact`, `RetractFact`, `RegRule`, `MakeQuery`).
- **Milestone 7**: Value-captured guards and strict coroutine yield boundary enforcement.
- **Milestone 8**: `tests/unit/test_logic.d` (`make unit-test UNIT=test_logic`), `python3 tools/suite test --suite acceptance --suite rejection` with per-test timeout runner, and integration into `make test`.

### Phase 7: Stateful relations and narrative companion (completed ✅)

Companion milestones 9–18 in [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md) are implemented. Preserve these boundaries and their acceptance coverage:

1. **9–11, stateful relations**: Named/keyed schemas, atomic updates, per-coroutine transaction overlays/savepoints, exclusive world locks, cleanup and iterator validity in `logic/world.d`, compiler/VM and Fiber. No-yield scopes cover helpers and resumed child coroutines and restore on every exit.
2. **12, aggregates**: Scoped/correlated count/sum/min/max, distinct assignments, empty/error semantics and strict lower-stratum dependencies in the frontend, validator and evaluator.
3. **13–15, narrative runtime**: `narrative/{registry,templates,codec,fingerprint,session}.d` and `lib/{narrative,quality}.d` implement sealed content, immutable parameters/instances/tokens, deterministic decks, atomic choices, actions/periods, qualities/constraints, events/schedules and deferred callbacks. Deck/scheduler behavior lives in `session.d`; alternate proposed module splits are not missing features.
4. **16, persistence/replay**: `narrative/persistence.d` provides staged factory-world restoration, schema/content/code/capture checks, explicit authored reconstruction/migrations and immutable command logs. Preserve failed-load atomicity and unsupported-value diagnostics; hosts replay external inputs and reestablish subscriptions.
5. **17, authoring**: `diagnostics.d`, `observe.d` and `analysis.d` supply pure explanations, committed visible-set deltas with bounded queued commands, and isolated bounded choice exploration. Analysis reports its scope/incompleteness and blocks host/native external operations.
6. **18, conformance**: `make unit-test UNIT=test_stateful`, `make unit-test UNIT=test_narrative` (13 groups), and `python3 tools/suite test --suite extensions` are included in `make test`. [tests/narrative/README.md](tests/narrative/README.md) contains the paragraph/grammar/error matrix, measured stress/replay coverage and limits.

Custom display formatter registration and deterministic weighted text variants are implemented and verified.

### Phase 8: Core-Lua performance and conformance (closed)

Closed October 11, 2026 by owner decision; see [ROADMAP.md](ROADMAP.md#closed-phase-8--core-lua-performance-and-conformance). Milestones 19 (benchmark suite with enforced gates) and 20 (official-suite gate: 31 pass / 1 partial / 1 skipped / 0 fail) are done. Milestones 21–25 are retired, not completed: their method was tuning the existing design toward "no more than 2× C Lua".

State at closure: core workloads at about 0.6–2.4× C Lua, with `core.pcall_error` (~37×) and `core.deep_recursion` (~8×) as outliers; see `docs/STATUS.md` and `benchmarks/PERFORMANCE_WORK.md`. The CLI uses `-O3 -release`; D unit tests default to `-g`, and C Lua defaults to `-O2`.

Core performance is a goal again with a stricter target (≤ 1.0×, ROADMAP D4) and a different method (restructuring). That work is Phase 11, milestones 45–47. Phase 8 is not reopened, and its conformance half stays closed (D3).

### Phases 9–12 (partially implemented)

Defined in [ROADMAP.md](ROADMAP.md). Implemented slices include static content-tier/manifest-symbol checks, declarative
scenes/stage (29), authoring A0–A6, localization T1–T4, the workbench/debugger,
world-model restructuring and the SDL3 scene player; the remaining proposals are not language semantics. Milestone numbers are identifiers, not an order; the order is in ROADMAP "Order of work".

| Phase | Milestones | Planned deliverable |
| --- | --- | --- |
| 9 | 26–29 | Authoring language v1: content/engine tiers and a distinct file identity, syntax triage and freeze (including the localization-ready decisions), the core authoring gaps from `sample-game/needed_extensions.md`, declared entities/symbols, scenes, beats and engine-owned stage state (characters with attributes, slots, audio channels) |
| 10 | 30–33, 42–44 | Authoring tools and the workbench: `varis check` with source-ranged diagnostics, parser error recovery, language services and a language server on the Varis frontend, writer playtest/test/CI workflow, the workbench server (`varis serve`), the MATLAB-style web user interface, debugging at source and story level |
| 11 | 34–37, 45–47 | Fast runtime and host interface: safety net and reference game with enforced budgets, the seam between Lua core and world model, the world-model engine (shared storage, slot plans, indexes, semi-naive, caches), Lua core to parity with C Lua and then beyond, a documented D host interface and a standard SDL3 presentation layer, builds for Windows/macOS/Linux with Android as a stretch |
| 12 | 38–41 | Ergonomics: undo and persistent data, localization pipeline and publisher handoff (Chinese, Japanese, Korean; French and Russian as in-house test languages), Twine-class conveniences, writer documentation |

---

## 8. Development Invariants & Guidelines for Agents

1. **Licence header**: Every new `.d` source file must include this header:
   ```d
   /*
   ** Lua - A Scripting Language
   ** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
   **
   ** Varis - a Lua 5.4 derivative, written in D
   ** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
   ** Copyright (C) 2026 Varis contributors.
   ** See LICENSE for license details.
   */
   ```
2. **Lua truthiness**: Only `nil` and `false` are falsey. `0`, `0.0`, `""`, and empty tables are truthy. Never write `if (val)` in D without calling `val.isTruthy()`.
3. **Lua indexing**: Lua tables and strings are 1-based by user contract. Internal D array slices are 0-based. Be vigilant with conversions (`index - 1`).
4. **Strings**: Lua strings can contain arbitrary binary bytes (including `\0`). While D `string` is UTF-8 immutable, treat strings as binary-safe byte slices when implementing standard library operations.
5. **No `cd` in tool commands**: Always set `Cwd` when running shell commands.
6. **Compiler**: Target `ldc2` (located at `/opt/homebrew/bin/ldc2` on Apple Silicon). Use `make test` or `make <target>`.
7. **Extension tests**: Treat `tests/datalog/acceptance/` as base-language acceptance examples, not proof of full conformance or companion support. Compare unordered result sets. The shell runner requires intended negative-case diagnostics and rejects crashes, timeouts and fallback errors; preserve and extend those checks. The examples permit compilation-time rejection, but implementation must still honor runtime registration, capture, and atomicity semantics from the specification.
8. **Conformance coverage**: Supplement the examples with tests for numeric boundaries, NaN, raw reference equality, binary symbol names, contextual syntax, qualified ownership failures, failed-operation rollback, lexical closure capture, guard errors/yields, coroutine snapshots, and invalid iterator reuse. Map all nine v0.1 conformance requirements to executable coverage and report unsupported official Lua harness tests as skips.
9. **Companion coverage**: Map [Varis rejection requirements](docs/compatibility.md#95--error-categories) (historical companion §16; see docs/coverage.md) to tests for key conflicts, transaction/savepoint/control-flow rollback, tentative snapshots, yields, stale choices, parameter binding, deterministic draws, action/event budgets, quality constraints, and save/version failures. Compare unordered relational sets and canonical narrative sequences. Keep optional aggregates/subscriptions/analysis separately identified; proposed tests and targets are not existing support.
10. **Performance changes**: There are two targets (performance plan §1): turn latency, load time and memory on the reference game for the world model, and the ratio against C Lua for the Lua core. Follow the stage order in [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md); do not skip ahead. Profile before choosing an optimization inside a stage. Land small changes with targeted semantic tests, full `make test`, optimized assertion-enabled validation (`make varis-checked`), actual release CLI fixtures, and before/after timing and memory evidence from the same session. Report measurements, not estimates. Never trade correctness for benchmark scores or silently weaken failure/skip accounting. A file passing with protected errors or internally disabled tests is not proof of feature completeness.
11. **Runtime restructuring boundaries**: The value representation, the execution encoding, error handling and the executor structure are planned to change (stages L1–L4), each in its own stage with its own exit test. Outside those stages, do not change them. Inside them, preserve: upvalue locations and lifetimes, GC roots, native reentry, suspended coroutines, cleanup order on errors, lexical worlds, aliases and Fiber isolation, analysis budgets, debug attribution, transaction exit boundaries. The canonical bytecode `proto.code` is not changed for speed, because fingerprints and saves read it (§4.8). The single D collector is permanent (§4.3).
12. **Lua compatibility policy**: The full language stays (D2). The official suite, the core differential fixture and the regression programs are a regression net: a new failure there is still a failure, and is never fixed by weakening a test. Do not spend effort closing the remaining Lua-fidelity gaps (D3). A deliberate divergence (for authoring, saves/replay, portability or performance) is allowed with a `[[ledger]]` entry, a `Skip-Accepted:` trailer and a line in `docs/compatibility.md` §9. The frozen features listed in ROADMAP (C API subset and `dlopen` modules, binary chunks, weak-table/finalizer emulation, `debug.sethook` fidelity, exact PUC-Rio error text) get no new work but must keep passing while they exist; removing one is the owner's decision, so ask first.
13. **Planned is not implemented**: The full content/engine tier split, procedural scene bodies, declared-symbol syntax and unfinished performance stages remain plans. Declarative scenes/stage, the checker, language services, the workbench and the seam have implemented slices described above. The manual in `docs/` describes only implemented behaviour; proposals live in `ROADMAP.md`, the plan documents and `sample-game/needed_extensions.md`. Move a construct into the manual in the same change that implements and tests it, and update §5 of this file when a stage lands.
14. **Writer-facing quality**: New content syntax must not require understanding closures, coroutines, iterators or metatables. Diagnostics for content name the storylet, choice or field and carry a source location; prefer rejecting a likely mistake (an unknown symbol, a storylet that can never appear) over accepting it silently.
15. **The sample game keeps working** (D12): `sample-game/tools/check.lua` must pass after every change. Run it with the working directory set to `sample-game` (§9); it prints `checks passed`. `make test-fast` runs it together with a golden transcript and save comparison (`python3 tools/suite test --suite sample-game`). If the golden comparison fails, the change altered behaviour, fingerprints or the save format: fix the change. Regenerate `tests/sample_game/golden.expected` (`check_golden.py <binary> --update`) only for an intended, reviewed change, in its own commit.
16. **Style** (D6): new and restructured code follows §3. Do not convert old code outside a planned stage.
17. **Layers** (D9): do not add an import from a lower layer to a higher one (§4.1).
18. **Tools are built on the frontend and on read-only services**: diagnostics, completion, the workspace and the debugger must not mutate game state or consume random numbers, and must not be built on Lua's `debug` library (§4.12).

### 8.1 How to decide when the documents do not say

Work through these in order and stop at the first that answers the question.

1. Does the manual define the behaviour? Then keep it.
2. Does a test pin it? Then keep it.
3. Does the ROADMAP decision record cover it? Follow the decision.
4. Is it an open decision with a default? Use the default and say so.
5. Would the change alter saves, fingerprints, replay results or random draws? Then do not make it without asking.
6. Would it make content harder for a non-programmer to write, or a mod impossible to write? Then do not make it.
7. Otherwise choose the smaller, more reversible option, describe the choice in the change, and continue.

---

## 9. Common Build Commands

```bash
# Build the CLI (release, -O3 -release); `make varis-checked` builds optimized with assertions
make varis

# Tests: one driver, one manifest (tests/manifest.toml); tiers smoke < fast < full
make test-smoke
make test-fast
make test            # full tier incl. official Lua suite (~20 s; all.lua runs concurrently with the rest)
python3 tools/suite test --filter <case-id substring>

# Performance: ratios vs C Lua plus absolute time budgets (benchmarks/targets.toml), ~2 min
make bench
make bench-check     # fails on gate/floor regressions

# The sample game's own check (working directory: sample-game)
../bin/varis tools/check.lua

# Repository hygiene
make hooks           # enable .githooks once per clone
make fmt             # dfmt; `make fmt-check` verifies
make check           # pre-push gate

# One suite / one D unit group:
python3 tools/suite test --suite acceptance
make unit-test UNIT=test_vm
make clean
```

### Git workflow

The project is a git repository (`main`). History begins with two reconstructed import commits,
tagged `baseline/v0-snapshot` (the 2026-10-09 pre-optimization tree) and `baseline/v1-perf-final`;
the tags are reference points (ad-hoc `ref =` comparators build from them), so never move or delete them.
They are no longer part of the default benchmark run.

- Run `make hooks` once per clone. Pre-commit rejects non-dfmt-clean `.d` files, missing license
  headers, source modules absent from the Makefile list, build outputs and blobs over 1 MiB;
  commit-msg demands a `Perf-Regression-Accepted:` / `Skip-Accepted:` trailer when targets or the
  ledger are loosened; pre-push runs `make check` (format, source list, fast tier).
- Formatting is dfmt (`.editorconfig`); `make fmt` is idempotent. Mechanical sweeps (formatting,
  renames) go in their own commit and are added to `.git-blame-ignore-revs`.
- Keep commits focused: behaviour changes with their tests; do not mix them with reformatting or
  with style conversion.
- Build outputs live in `bin/`, `build/` and `.cache/` and are ignored. Comparator builds are
  created by `tools/suite bench` in `.cache/src/<sha>` worktrees; remove them with
  `git worktree remove` rather than `rm -rf`.
- Never run the benchmarks alongside other heavy jobs; ratios are only meaningful on an idle machine.

Skips, partial results and known gaps are accounted in the `[[ledger]]` of `tests/manifest.toml`;
loosening a performance target or adding a ledger entry requires a `Perf-Regression-Accepted:` /
`Skip-Accepted:` commit trailer (enforced by the commit-msg hook). Do not reset baselines to conceal
regressions. Keep all source modules listed explicitly in the Makefile (`make check-sources`).
