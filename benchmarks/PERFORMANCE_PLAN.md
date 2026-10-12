# Performance plan: a fast Lua core and a fast world model

Status: **plan**, revised October 11, 2026. Nothing below is implemented. This replaces the
earlier plan of the same date (which covered only turn latency and ruled out interpreter work)
and details milestones 34, 35, 37, 45, 46 and 47 of [ROADMAP.md](../ROADMAP.md) Phase 11.
[PERFORMANCE_WORK.md](PERFORMANCE_WORK.md) remains the record of the Phase 8 tuning work.

Decisions this plan implements are cited as D1–D14; they are in the ROADMAP decision record.

## 1. Two targets

Varis has two engines with different jobs, so it has two performance targets.

| Engine | What it runs | Target | Measured by |
| --- | --- | --- | --- |
| **World model** (`logic/`, `narrative/`) | Deciding which storylets, choices and actions are available; effects; saves | A turn inside a budget on low-end hardware (D5) | The reference game, §3 |
| **Lua core** (values, tables, compiler, virtual machine, standard libraries) | Engine scripts, mods, effect bodies, guards | Never slower than C Lua, then faster (D4) | `core`, `programs`, `regression`, `startup` benchmark groups against C Lua |

Why both: the world model is what a player waits for, and the Lua core is what a modder writes
against. Why separately: they share almost no hot code, and today they are tangled in a way that
slows the core (§2.3).

## 2. What was measured

Release CLI (`make varis`, `-O3 -release`) at commit `cad1d5b`, Apple M1, October 11, 2026. Core
ratios are paired interleaved samples from `python3 tools/suite bench`. Profiles are 3–4 second
runs of the macOS `sample` tool, read by top of stack.

### 2.1 World model

`benchmarks/experiments/synthetic_game.lua` generates a grid map with location-bound one-shot
storylets, parameterized `look`/`walk`/`take` storylets and, optionally, one storylet that reads a
recursive `reachable/2`. Times are CPU time from `os.clock`, median `present()`.

| Game | `present()` | `choose()` | `save()` | Content load | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 rooms, 200 storylets | 3.1 ms | 0.6 ms | 15.6 ms | 15 ms | 58 MB |
| 100 rooms, 1000 storylets | 14.6 ms | 0.6 ms | 61 ms | 47 ms | 94 MB |
| 100 rooms, 200 storylets, recursive `reachable` | **836 ms** | 0.6 ms | 14 ms | 9 ms | 171 MB |
| 100 rooms, 1000 storylets, recursive `reachable` | **840 ms** | 0.6 ms | 58 ms | 45 ms | 239 MB |

Under `taskpolicy -b` (efficiency cores, a rough stand-in for a slow machine) the same binary was
about 3.5× slower in the earlier measurement.

Where the time goes:

| Profile | Collector (marking, allocation) | Hashing, associative arrays, `memcmp` | Thread-local lookups | Engine's own code |
| --- | ---: | ---: | ---: | ---: |
| 1000 storylets, no recursion | 55 % | 20 % | 8 % | 9 % |
| 200 storylets, recursive `reachable` | 17 % | 46 % | 2 % | 31 % |

The bytecode interpreter does not appear in either profile.

Why:

- `Session.present` clones the world (`session.d`, `world.cloneSnapshot()`).
- Every storylet's `when` builds a `QueryIterator`, which copies the base facts of every relation
  in the query's dependency closure (`query.d`).
- `Evaluator.evaluateQuery` copies those facts again into a fresh `visibleFacts` map
  (`bool[RelTuple][size_t]`), recomputes stratification, then runs every rule of each stratum to a
  fixed point naively: each iteration re-joins all facts with nested loops (`evaluate.d`,
  `matchGoals`).
- Each candidate binding is a `LuaValue[string]`, an associative array keyed by the variable's
  **name**, duplicated per match (`env.dup`). In the recursive profile `memcmp` alone is 30 % of
  the time: it is comparing variable names.
- Nothing is reused between the queries of one presentation, or between turns.
- `save()` recomputes the fingerprint of all registered content each time (`persistence.d`,
  `portableRegistryFingerprint`), so its cost follows content size rather than state size.

So a presentation costs roughly *storylets × facts their conditions depend on*, and one recursive
rule multiplies that by the size of its closure.

### 2.2 Lua core

| Workload | Varis / C Lua | Where the time goes |
| --- | ---: | --- |
| `core.fib` | 2.41× | 94 % inside `executeFrame` itself; no collector time. The cost is the call path. |
| `core.closures` | 1.98× | 85 % inside `executeFrame`. |
| `core.method_dispatch` | 1.82× | 43 % `executeFrame`; about 27 % string-keyed table lookup, including 7 % `memcmp` because equal string constants in different functions are different pointers. |
| `core.array_access`, `core.numeric_loop`, `core.sieve` | 1.91×, 1.57×, 1.33× | Dispatch and operand decoding. |
| `core.coroutine_switch` | 2.05× | druntime's `fiber_switchContext` and thread-local lookups. |
| `core.pcall_error` | **37.1×** | Essentially all in `libunwind` and `dyld` under `_d_throw_exception`: the platform unwinder. |
| `core.deep_recursion` | **8.3×** | Over half in the collector: `executeDeepFrame` allocates arrays per frame. |
| `core.hash_access`, `core.gc_churn`, `core.table_insert_remove` | 1.29×, 1.03×, 1.09× | Near parity. |
| `core.string_manip`, `core.table_sort`, `programs.sort`, `programs.pairs` | 0.60×, 0.95×, 0.21×, 0.62× | Already faster than C Lua. |

Structural facts behind those numbers:

| Fact | Varis today | C Lua 5.4 |
| --- | --- | --- |
| Size of a value | 24 bytes (`std.sumtype`, string slice stored inline) | 16 bytes |
| Size of an instruction | 32 bytes (`struct Instruction` with separate `a`, `b`, `c`, `sBx`, `line` and three "is constant" flags) | 4 bytes |
| Machine instructions per Lua-to-Lua call | about 400 (PERFORMANCE_WORK.md) | about 150 |
| Error propagation | D exception through the platform unwinder | `longjmp` |
| Hash-table node | 56 bytes | 32 bytes |
| Exception and Phobos idioms in `source/varis` | about 570 `throw` sites, 66 `catch`, 65 scope guards, 281 `match!`, 4 uses of `@nogc` | |

Checked and ruled out: compiler flags. A build with `-boundscheck=off -mcpu=apple-m1` was within
noise of the normal build on every core workload and on the synthetic game. Link-time
optimization was not tested (the LTO runtime libraries are not installed here). `pragma(musttail)`
is silently ignored by LDC 1.43 (no `musttail` in the generated IR, stack overflow at `-O0`), so
tail-call threaded dispatch is not available and dispatch stays a `switch`.

### 2.3 The two engines are tangled

- Every Lua-to-Lua `Call` looks up the call site's lexical world (`proto.callSites[pc].world`) and
  may swap `state.callWorld`, then restores it (`vm.d`, `case OpCode.Call`). The only reader of
  `state.callWorld` outside the virtual machine is `lib/quality.d` (one line).
- Transactions opened by a frame are tracked inside `executeFrame` (`frameTransactions`) and
  checked through the per-instruction `vmAttention` flag while one is open.
- `vm.d` mentions worlds, transactions, relations or narrative about 200 times and imports the
  logic and narrative modules.
- The opcode handlers of `executeFrame` and `executeDeepFrame` are copied by hand (they differ only
  in how the program counter is spelled), so every interpreter change must be made twice and "the
  two must stay identical" is a manual obligation.

## 3. Targets

### 3.1 World model

Reference game (stage S0 builds it): about 100 rooms, 1000 storylets, 50 items, at least one
recursive rule and one aggregate in use, a 500-turn scripted session.

| Measure | Low-end budget (provisional) | Stand-in on the development machine |
| --- | ---: | ---: |
| Turn: `choose()` plus the next `present()`, p95 | 50 ms | 5 ms |
| Content load | 1 s | 100 ms |
| `save()` | 50 ms | 5 ms |
| Peak RSS of the engine process | 64 MB | 64 MB |
| Collections inside a turn | 0 | 0 |

The stand-in column assumes a low-end machine is ten times slower than an M1 performance core.
That factor is a guess until stage M puts a real machine in the loop; the owner picks the
reference machine (ROADMAP open decision 3).

Distance today: the recursive 100-room game is about 170× over the turn budget; the
1000-storylet game without recursion is about 3× over; `save()` is about 12× over; RSS is 1.5–3.7×
over.

### 3.2 Lua core

| Step | Target | Enforced how |
| --- | --- | --- |
| Parity (milestone 46) | Every workload that has a C Lua comparator at or below 1.0× | `goal.clua = 1.0` in `targets.toml` (reported); `gate.clua` ratchets tightened as stages land (enforced) |
| Beyond (milestone 47) | Below 1.0×; the number is ROADMAP open decision 10 | Set a new `goal.clua` when parity is measured |

Estimates, to be replaced by measurement: stage L1 should bring `core.pcall_error` from 37× to
under 2×; stages L2–L4 should bring loops and table access to about 1.2–1.5× and calls to about
1.5–1.8×; reaching 1.0× on calls and going below it needs the X stages. Do not report an estimate
as a result.

## 4. Design rules for all stages

These follow from D6, D7 and D8. A stage that cannot follow one must say so in its change and
explain why.

1. **Hot kernels are `@nogc nothrow`.** A kernel is a loop that runs per instruction, per tuple or
   per table probe. Put `@nogc nothrow:` at the top of a kernel module so the compiler enforces
   it.
2. **Allocation happens at named grow points, outside kernels.** Objects still come from D's
   collector (D8). A kernel works on buffers that were sized before it started; when a buffer is
   full it returns a "need more room" status and its caller grows the buffer (with the collector)
   and calls again. Buffers that hold values must be allocated as scanned memory so the collector
   sees the references in them.
3. **Errors are values.** A function that can fail returns a status (or a count with a negative
   value meaning failure). The error object is stored in a slot on the thread, where the collector
   can see it. No `throw` in new code. Programmer errors that cannot be handled (failed
   assertions, out of memory) stay fatal D `Error`s.
4. **Cleanup is explicit and ordered.** Where today a `scope(exit)` runs, the error path must do
   the same things in the same order: close to-be-closed values, finish open transactions
   (rollback on error), close upvalues, pop the call record, clear the registers.
5. **No second collector, no reference counts, no handle tables** (D8).
6. **Templates remove duplication; they do not add layers.** Generating two executors from one
   handler source is the intended use. A template whose only purpose is abstraction is not.
7. **The canonical bytecode `proto.code` is never changed for speed.** Content fingerprints
   (`narrative/fingerprint.d`) and binary chunks (`dump.d`) read `proto.code` and
   `proto.callWorlds`. Changing what the compiler emits there changes fingerprints and invalidates
   saves. Speed work happens in `proto.execCode` and other data derived at
   `VM.prepareForExecution`, which nothing persists.
8. **Behaviour is defined by the manual and the tests, not by the old code's structure.** A
   restructuring that passes every gate in §7 is correct even if nothing of the old code remains.

## 5. Stages

Order: S0, S1, then W1–W5, then L1–L4, then X1–X4, then M (ROADMAP D14). W, L and X stages are
independent of each other once S1 is done, so the owner may reorder the tracks; do not reorder
stages inside a track.

Each stage lists what to do, what can go wrong, and the exit test. A stage is done only when its
exit test and all of §7 pass.

### Stage S0 — Safety net and measurement (milestone 34)

**Status: done October 11, 2026, except item 4.** The `sample-game` test suite (fast tier) runs
`tools/check.lua` and compares `tools/golden.lua` with `tests/sample_game/golden.expected`; the
`narrative_scale` benchmark group has `reference_game` (4.3 s for load, five turns and a save)
and `wide_game` (0.75 s for forty turns without recursion) with `gate.time` budgets; the baseline
is `benchmarks/baselines/2026-10-11-pre-restructure.json`. The reference game does not yet use an
aggregate, and engine counters (item 4) are left to the first W stage that needs them.

Do this before changing any runtime code. It is what makes the later stages safe.

1. **Sample game in the test tiers.** Today `sample-game/tools/check.lua` runs only as the
   `narrative_e2e.sample_game_check` benchmark, not in `make test`. Add it to
   `tests/manifest.toml` in the fast tier (working directory `sample-game`).
2. **Golden transcript and golden save.** Add a script that plays a fixed, seeded walkthrough of
   the sample game and writes every presentation (titles, text, choice titles) and the final
   `session:save()` text. Commit the output. The test compares byte for byte. This is the check
   that a restructuring did not change behaviour, fingerprints or the save format.
3. **Reference game as a benchmark group.** Turn `benchmarks/experiments/synthetic_game.lua` into a
   `narrative_scale` group in `benchmarks/manifest.toml` with the fixed reference game of §3.1,
   reporting p50/p95/max turn time, load, save and peak RSS, with `gate.time` budgets in
   `targets.toml`. Record today's numbers first (they will be far over budget; the gate starts at
   today's value and ratchets down).
4. **Engine counters**, readable from tests and benchmarks: facts copied, tuples derived, queries
   and rule firings per presentation, allocations and collections per turn.
5. **Record a baseline**: `make bench-record LABEL=<date>-pre-restructure`.

Exit: `make test` runs the sample game and the golden comparison; `make bench` reports the
`narrative_scale` group; the baseline file is committed.

### Stage S1 — The seam (milestone 45)

**Measured October 11, 2026:** a build with the world swap removed from the Lua-to-Lua `Call`
handler ran `core.fib` at 2.37× against 2.42× (within noise). The swap reads a global, not
thread-local storage, so it is cheap. The seam is therefore an **architectural** stage (layering,
one executor source, a home for the debugger), not a speed-up, and tracks W and L do not depend
on it. It may be done after track W.

Goal: the Lua core stops knowing about the world model, with **no behaviour change**. Saves and
fingerprints stay byte-identical (the S0 golden test proves it).

1. **One executor source.** *(First step done October 11, 2026: the 40 handlers that were
   identical in both executors are now `sharedOpcodeCases*` string mixins in `vm.d`; `Call`,
   `TailCall`, `Return` and frame entry/exit remain per executor. No measurable speed change.)*
   Generate `executeFrame` and `executeDeepFrame` from one set of opcode
   handlers (a mixin template or a compile-time loop over a handler table). Add a compile-time
   parameter for an **instrumented** variant; in this stage it only needs to carry what the
   `vmSlowMode` path carries today (debug hooks, the analysis instruction budget). The workbench
   debugger (ROADMAP milestone 44) will add breakpoints and stepping to the instrumented variant
   later; the fast variant must contain none of that code.
2. **World context off the plain call path.** First find out exactly what depends on the swap of
   `state.callWorld` at a Lua-to-Lua call. The known reader is `lib/quality.d` (quality defaults
   "follow lexical call-world metadata, including captured helper worlds", AGENTS §4.11). Then
   make only world-aware natives pay: for example, flag such natives and have their call resolve
   the world from the call site. Plain Lua-to-Lua calls must do no world work. Do not change the
   contents of `proto.callWorlds` (rule 7).
3. **Transactions out of the per-instruction check.** Today an open frame transaction keeps
   `vmAttention` set and every instruction checks whether the program counter left the
   transaction's range. Derive, at `prepareForExecution`, the exits of each transaction region
   from the `BeginTransaction` operands, and commit or roll back at those exits. The canonical
   code stays as it is (rule 7).
4. **Relational and narrative opcodes out of line.** Each one is a single `case` that calls a
   non-inlined function reached through an extension table registered by the world model at state
   creation.
5. **Module boundary.** After this stage no core module (the list is in AGENTS §4.1) imports
   `varis.logic` or `varis.narrative`. Today these do: `vm.d` (6 imports), `state.d` (3),
   `fiber.d` (2), `compiler.d`, `opcode.d`, `ast.d`, `parser.d` and `lib/coroutine.d` (1 each).
   State that belongs to the upper layers (the global world, the content registry) hangs off the
   state through an opaque extension slot. The small enums the frontend and `opcode.d` take from
   `varis.logic.model` (`CompareOp`, `TermKind`, `GoalKind`) move down into the frontend, because
   syntax is part of the core. Add the import check to `make check-sources` so the boundary stays
   true. `Symbol` stays a core value type.

What can go wrong: the captured-helper-world rule (test it first, in `test_narrative` and
`test_stateful`); commit-on-`break`/`goto`/`return` exits of a transaction block; coroutines that
are resumed inside a no-yield scope; `executeDeepFrame` behaviour past 150 frames
(`tests/regression/deepframes.lua`).

Exit: all gates; golden transcript and save identical; the import check passes; no core workload
slower, and `core.fib` measurably faster (the call path lost the world lookup).

### Track W — World model (milestone 35)

**Status: W0–W4 done October 11, 2026; W5 not started.** Measured on the same machine, release
build, median `present()`:

| Game | Before | After |
| --- | ---: | ---: |
| 100 rooms, 200 storylets | 3.1 ms | 0.7 ms |
| 100 rooms, 1000 storylets | 14.6 ms | 3.1 ms |
| 100 rooms, 200 storylets, recursive `reachable` | 836 ms | 0.7 ms |
| 100 rooms, 1000 storylets, recursive `reachable` | 840 ms | 3.2 ms |

`choose()` went from 0.6 ms to 0.1 ms. Benchmark groups: `datalog.transitive_closure` 0.524 s →
0.004 s, `scenarios.03_transitive_closure` 1.4 s → 0.012 s, `narrative_scale.reference_game`
4.3 s → 0.09 s; the `datalog_comp` programs now run in 0.10–0.18× of Soufflé's time (process
start-up included on both sides). Gates were re-derived from these numbers.

What was built, and where:

- `logic/store.d`: `FactTable` (append-only rows, lazily built hash indexes per set of bound
  columns). `Relation.factTable()` returns an immutable table that is rebuilt only after a write;
  snapshots, queries and cloned worlds share it. `World.cloneSnapshot` shares the fact set itself
  and copies on the first write (`Relation.ownFacts`). Every write to `baseFacts` or `keyIndex`
  must go through `ownFacts`, `adoptFacts` or `clearFacts`.
- `logic/evaluate.d`: conjunctions compile to slot-based `Plan`s; positive atoms probe indexes;
  recursive strata run semi-naively; derived relations are cached per closure, keyed by the
  identity of the rules (`Rule.origin`) and base tables (`DerivedCache`, on `LuaState.logicCache`).
  Closures whose rules call Lua (guards, aggregate expressions) are not cached, so author code
  runs as often as before. A query template keeps its plan (`QueryTemplate.planHolder`) and is
  safety-checked once.
- `logic/naive.d`: the previous evaluator, unchanged in behaviour, as the oracle. With
  `VARIS_LOGIC_ORACLE=1` every query is answered by both and the result sets must be equal; the
  `logic-oracle` test suite runs the scenarios, the acceptance programs and the sample game that
  way.
- The order of goal kinds inside a conjunction is unchanged (positive atoms, aggregates,
  comparisons, guards, negated atoms, each over all candidates), so errors and guard calls
  happen for the same candidates. Result order and the number of guard calls in recursive rules
  may differ; both were already unspecified.

Still open: peak RSS on the 1000-storylet game rose from 94 MB to about 125 MB (index and
candidate buffers; stage M), and a presentation still builds, validates and runs one query per
storylet (about 3 µs each), which is what W5 removes.

The new evaluator was written next to the old one, which stays as a **test oracle** (§7). `logic/` is about 2,100
lines, so this track is also where the kernel conventions (status type, growable buffers, hash
sets over value rows) are settled before they are used in the much larger `vm.d`.

**W0 — Cheaper saves (done October 11, 2026).** The content fingerprint cannot simply be computed
once at `narrative.seal`: it includes the **current values captured by content closures**, which
can change, and a save must reflect them. What is cached instead: each prototype's fingerprint
text (on `Prototype.fingerprintCache`; prototypes are immutable), the fingerprint each definition
already receives at registration, and the last digest together with the entries it came from
(`ContentRegistry.fingerprintEntries`), reused when the entries are unchanged. Measured on the
1000-storylet game: first `save()` 57 ms → 22 ms (one SHA-256 over the whole text), every later
`save()` 4.9 ms. The saved text is byte-identical (golden test).

**W1 — Shared immutable fact storage.** Store a relation's facts as flat rows of values with an
open-addressing hash index, not as `bool[RelTuple]`. A snapshot holds a reference to the storage
and its version; a writer copies the storage only when a snapshot still shares it.
`cloneSnapshot`, query construction and evaluation then share one set instead of copying it three
times. Semantics are unchanged: a query still sees the state at its construction, because what it
holds can no longer change. Transaction overlays stay as they are. Exit: the "facts copied"
counter is zero for read-only queries; expected effect is most of the collector and hashing share
of the non-recursive profile and most of the peak-RSS excess.

**W2 — Compiled plans, slot bindings, indexes.** Compile each rule body and query once: number
the variables into slots (an array; no associative array, no duplication per match), order
positive goals by how bound they are, and apply comparisons, guards and negation as soon as their
variables are bound. Give relations hash indexes on the argument positions those plans probe,
built lazily per version. Keyed relations already have `keyIndex`. Exit:
`when { at(:player, :room), not seen(:x), quality(:player, :resolve, ?r) }` is three probes; the
variable-name `memcmp` is gone from the profile.

**W3 — Semi-naive evaluation of recursive strata.** Join only against the tuples derived in the
previous iteration. Exit: closure over the 100-room map is tens of thousands of probes, and the
recursive reference game is inside the turn budget on first evaluation.

**W4 — Evaluate once per world version.** Cache, per dependency closure and keyed by the versions
relations already carry (`version_`), the stratification and the materialized derived relations.
Every storylet, choice, template condition and action in a presentation reuses them, and so does
the next turn if nothing in the closure changed. Publish a cache entry only after evaluation
completes. Entries are immutable, so query iterators can keep them as their snapshot. Inside a
transaction that has written to the closure, bypass the cache. Rule guards capture values at
registration, so cached derivations stay valid; guard purity remains the author's obligation as
today.

**W5 — Do not look at storylets that cannot apply.** Two parts. (a) Index storylet definitions by
the constant arguments of their conditions, so a presentation considers only storylets whose
ground goals can match the current state (in the reference game almost every storylet starts with
`at(:player, <room>)`). (b) Cache a definition's instance list keyed by the versions of the
relations it reads, so a turn that changes `seen` and one quality re-evaluates only the storylets
that read them. Instance enumeration consumes no random numbers (draws happen afterwards), so
replay is unaffected.

Exit for the track: the reference game meets the §3.1 stand-in budgets for turn, save and RSS.

Not planned until measured: demand-driven evaluation for queries with bound arguments
(`reachable(:here, ?to)` needs one source's row, not all pairs); incremental view maintenance.

### Track L — Lua core to parity (milestone 46)

**L1 — Errors as values (D7).**

*First step done October 11, 2026:* inside `executeFrame`, an error raised by `error` or
returned by a Lua callee now reaches the frame's handler without a throw (the handler code moved
out of the `catch` block and runs once per frame as before; Lua-to-Lua calls set
`TailRequest.returnErrors`), and `pcall(error, …)` produces its result directly. Errors thrown
by natives and by out-of-line helpers still use one D throw to reach the nearest Lua frame.
`core.pcall_error` 37× → 1.36× C Lua; an error raised three Lua frames below a `pcall` costs
0.5 µs (C Lua 0.37 µs). The rest of this stage (natives returning statuses, no exceptions in the
core) is still to do.

- The executor and every native return a status; the error object lives in a slot on the thread.
  `pcall`/`xpcall` become a status check. `error`, runtime errors, `CoroutineClose` and
  `ExitRequest` become status codes.
- Natives move to a signature that reads arguments from, and writes results to, the value stack,
  instead of receiving and returning freshly allocated arrays (`LuaNativeFunction.NativeDelegate`
  today is `LuaValue[] delegate(void* state, LuaValue[] args)`). `lib/fastcall.d` already works
  this way for hot built-ins.
- Migration is incremental: an adapter at the native-call boundary catches `LuaException` from
  natives that have not been converted and turns it into a status. Convert module by module
  (about 570 `throw` sites). Remove the adapter when the last one is converted.
- The executor loop then has no `try`/`catch` and no scope guards; cleanup follows rule 4.
- Transaction rollback on an escaping error, upvalue closing, to-be-closed values and the
  no-yield scopes must behave exactly as before; each has tests in `test_stateful`, `test_vm` and
  the official `errors.lua`/`locals.lua`/`coroutine.lua`.
- Once frames no longer need native unwinding, measure a single executor that keeps frames as
  records (what `executeDeepFrame` does) against native recursion, keep the faster one and delete
  the other. An earlier attempt (PERFORMANCE_WORK.md) was not faster, but it still paid for
  exception cleanup.

Exit: `core.pcall_error` and `core.deep_recursion` at or below their new gates (set after
measuring; expected under 2×); `errors.lua` in the official suite, about 25 s today, runs in a
few seconds; no `throw` in core modules.

**L2 — Value representation.**

*Main step done October 11, 2026:* `LuaValue` is 16 bytes. Instead of introducing string objects,
a string value packs the slice's pointer into the payload word and its length into a 32-bit
field beside the tag (`LuaPayload` in `types.d`), so no string code changed and creating a string
value still allocates nothing; strings are limited to 4 GiB. `match!` keeps working by converting
to `std.sumtype` on demand. Measured against C Lua: `core.array_access` 1.83× → 1.51×,
`core.sieve` 1.35× → 1.16×, `core.table_sort` 0.95× → 0.76×, `programs.bintrees` 1.84× → 1.59×,
`core.fib` 2.45× → 2.28×; nothing slower. Remaining: convert the 281 `match!` uses and drop the
`std.sumtype` import; string objects with a cached hash only if a profile asks for them.

- Replace `std.sumtype` with a hand-written tagged union. The hot paths already bypass `SumType`
  (`getVal`, `typeIndex`, `memcpy` assignment), so this mostly converts the 281 `match!` uses to
  switches on the tag. Keep the public accessors (`isString`, `asTable`, …) so host code and the
  rest of the runtime keep compiling.
- Make a string a pointer to a collector-allocated string object holding the length, a cached
  hash and the bytes. That makes a value 16 bytes, a hash node 40 bytes and a tuple a third
  smaller.
- Intern only **compile-time string constants**, in a pool owned by the state. Do not intern
  strings created at run time: an intern pool on D's collector would keep every string alive for
  ever. Run-time strings compare by pointer, then length, then cached hash, then bytes.
- Rules that must survive: `1 == 1.0`, equal hashes for `1` and `1.0`, `NaN ~= NaN`, binary-safe
  strings, large-integer boundaries (AGENTS §4.2).

Exit: `LuaValue.sizeof == 16`; `std.sumtype` no longer imported by `types.d`; no workload slower;
peak RSS of the reference game lower.

**L3 — Execution encoding.**

- At `prepareForExecution`, lower `proto.code` into a compact private `execCode` (8 bytes per
  instruction is the aim) with opcodes specialized by operand kind (register or constant), fused
  compare-and-jump, and line numbers moved to a side table. `proto.code` is untouched (rule 7).
- The per-pc side tables that exist today (`lookupHints`, `callSites`, `newTableSizes`) become
  operands of the lowered instructions where that removes a load.
- Error messages, tracebacks and the instrumented executor map a lowered instruction back to its
  canonical pc and line.

Exit: `core.numeric_loop`, `core.array_access`, `core.sieve` at or below 1.2×.

**L4 — Call path.**

- Remove per-call work that exists only for rare cases: build call records lazily (only when an
  error, a traceback or the debugger needs them), merge the two stack-limit counters into one
  comparison, clear only the registers that were live.
- Fixed-arity call and return instructions for the common shapes.

Exit: every C-Lua-comparable core workload at or below 1.0×, or a written account of which ones
are not and why, with the next stage that addresses each.

### Track X — Lua core beyond C Lua (milestone 47)

These are things C Lua's design does not do. Each is its own change with its own measurement.

- **X1 — Inline caches.** Field reads and writes with constant string keys remember the slot they
  hit; method calls remember the result of the `__index` chain walk, guarded by a version on the
  metatable; global reads remember their node. `findStringHinted` is the existing start of this.
- **X2 — Specialized and fused instructions.** After an instruction has seen integers (or floats)
  it is rewritten in `execCode` to a version that checks once and falls back if the guess fails.
  Fuse the commonest pairs.
- **X3 — Compiler passes on the typed AST.** Constant folding, direct opcodes for well-known
  built-ins when the global has not been reassigned, no upvalue bookkeeping for locals that are
  never captured. C Lua compiles in one pass and cannot do these.
- **X4 — Build.** Try profile-guided optimization again (it was mixed in Phase 8 because the
  interpreter loop was one large function), and link-time optimization once the LTO runtime
  libraries are available.

A just-in-time compiler is not planned: it complicates saves, portability (Android, consoles) and
the single-collector rule.

### Stage M — Memory, pauses, the host boundary, real hardware (milestones 36, 37)

**Measured October 11, 2026 (after track W):** the reference-scale game peaks at about 150 MB
RSS with `heapSizeFactor:4` and at 70–95 MB with the collector's default factor 2, with the same
`present()` time. Factor 2 cannot simply be adopted: it fails the `regression.limits` gate (2.33×
against 2.3) and slows `programs.bintrees` and `regression.deepframes` by about 10–40 %. Live heap
after a collection is about 45 MB, of which roughly 8 MB is fingerprint text kept for fast saves
(W0). The memory budget therefore needs both a smaller live heap and a host-driven collection
policy, not just a different factor.

**Done October 11, 2026:** `Session.present` collects between turns once the heap has grown past
1.5× the size that survived the previous collection plus 4 MB (`collectAtTurnBoundary` in
`narrative/session.d`; skipped during bounded analysis). The interpreter's factor stays 4, so core
workloads are unaffected. Peak RSS on the reference-scale game: 150 MB → 53 MB (before the whole
restructuring: 76–94 MB; budget 64 MB); the 200-storylet game peaks at 21 MB. Pauses stay under
5 ms and now fall at the start of a presentation instead of at arbitrary points. A host-facing
"idle now" call remains to be added with the host interface (milestone 36).

- Re-measure RSS after W1–W2 and L2; most of today's heap is garbage produced by copying. Then
  revisit `heapSizeFactor:4` in `cli.d`, which was chosen for the Phase 8 work and trades memory
  for fewer collections.
- D's collector stops the world. Offer the host an "idle now" call that collects after a
  presentation has been handed over, and keep per-turn allocation low enough that no collection
  starts inside a turn.
- The engine does no per-frame work: a presentation is an immutable value the front end can draw
  at any frame rate without calling back in. If a turn can still exceed a frame, the host runs
  turns off the render thread; a state is single-threaded, so the host must not touch it
  concurrently.
- Build for the platform the reference machine runs (the tree imports POSIX-only APIs today),
  run the reference game there, and replace the stand-in column in §3.1 with measured budgets.
- Leave content load alone unless this stage shows a problem.

## 6. Deliberately not planned

- **A second collector, reference counting, or arenas that hide references from D's collector**
  (D8).
- **Faster coroutines.** Content will not use coroutines (scenes compile to resumable positions,
  ROADMAP milestone 29). They keep working on druntime fibers. Revisit only if mods make them hot.
- **A just-in-time compiler or parallel evaluation.**
- **Changing the canonical bytecode for speed** (rule 7).
- **Closing Lua conformance gaps** (D3). Speed work must not break what passes today, but it does
  not have to make more of the official suite pass.

## 7. Validation

Every change in every stage:

- `make test` (unit groups, acceptance and rejection, the 19 scenarios with golden output,
  extension cases, official suite, core differential fixture, regression programs) and
  `make bench-check`.
- The sample-game golden transcript and golden save from S0, byte for byte.
- An optimized build with assertions (`make varis-checked`) for interpreter changes.
- Before/after timing and memory evidence in the change description, from the same session.
- Gates only tighten. After a stage lands, re-derive and commit tighter `gate.*` values.
  Loosening one needs a `Perf-Regression-Accepted:` trailer. Never reset a baseline to hide a
  regression.

World-model track in addition:

- **Test oracle.** In test builds every query is also answered by the old naive evaluator and the
  result sets must be equal (as unordered sets).
- New tests where the new machinery can go wrong: a snapshot taken before a write still sees the
  old facts; cache invalidation on `fact`, `retract`, `set`/`delete`/`adjust`, rule registration,
  rollback and world inheritance; negation and aggregates over cached strata; iterator
  invalidation after rollback; explanations and analysis on shared snapshots.

Lua-core track in addition:

- The differential fixture and regression programs compare against C Lua's output; they are the
  proof that a faster path did not change results.
- Error text, tracebacks and line numbers are tested by the official suite; a status-based error
  path must produce the same messages.

## 8. Reproducing the measurements

```sh
make varis
python3 tools/suite bench --group core --group programs --group startup
bin/varis benchmarks/experiments/synthetic_game.lua 10 1000 0 20      # 100 rooms, 1000 storylets
bin/varis benchmarks/experiments/synthetic_game.lua 10 200 1 3        # with recursive reachable
taskpolicy -b bin/varis benchmarks/experiments/synthetic_game.lua 8 50 1 4   # efficiency cores
```

Profiles: start a long run in the background and attach `sample <pid> 4 -file out.txt`; read the
"Sort by top of stack" section. For a core workload, loop it with a small driver script
(`loadfile` the workload and call it until `os.clock` passes a few seconds).

Run benchmarks on an idle machine. In `zsh`, a variable holding several arguments is passed as one
argument unless written `${=var}`; the synthetic game then silently uses its defaults.
