# Performance plan

Updated October 13, 2026. **Next: finish the authorized L1 error-as-values conversion,
then measure the remaining call/frame and parity gaps.** Completed stages are summarized
below; their implementation narrative and experiments are in
[PERFORMANCE_HISTORY.md](PERFORMANCE_HISTORY.md).

| Need | Document |
| --- | --- |
| What to work on and what must stay true | This plan |
| Commands, sampling, comparators and gate policy | [Benchmark guide](README.md) |
| Recorded workload ratios and test results | [Generated status](../docs/STATUS.md) |
| Restructuring measurements and original stage designs | [October 11–13 history](PERFORMANCE_HISTORY.md) |
| Earlier tuning toward the retired 2× goal | [Phase 8 history](PERFORMANCE_WORK.md) |

## 1. Two targets

- **World model (D5):** reference-game turns, load, saves and memory fit low-end
  budgets (§3.1). The development-machine stand-in passes in the recorded runs;
  real low-end validation remains open.
- **Lua core (D4):** every C-Lua-comparable workload reaches `goal.clua = 1.0`, then
  improves beyond parity. Parity is not reached. Passing regression gates does not
  mean meeting the goal; use the generated report rather than copied ratio tables.

[ROADMAP.md](../ROADMAP.md) owns priorities and owner decisions. Default remaining
order: L1/parity (46), X (47), then M (37). The owner may reorder tracks; preserve
within-track dependencies. Presentation/localization work (36/39) can proceed
independently and is specified in its own plans.

## 2. Delivered stages

These are prerequisites already in place, not work to restart.

| Stage | Delivered scope / disposition |
| --- | --- |
| S0 (34) | Sample-game golden transcript/save, full reference workload, counters and per-measure budgets. |
| S1 (45) | Enforced layer seam, shared opcode handlers, no Lua-call world bookkeeping, execution-only transaction exits, fast/instrumented loops. |
| W0–W4, W5(a) (35) | Fingerprint caching, shared fact storage, indexed slot plans, semi-naive evaluation, eligible derived caches and required-fact storylet prefilter. Stand-in budget met. |
| L2 | 16-byte tagged values, string slices retained, `std.sumtype` removed. Cached-hash string objects were not required for delivery. |
| L3 | Recorded loop exit met through S1's fast loop; fused compare/jump exists. Compact encoding was not built. This is a dated stage exit, not a permanent claim about every later ratio. |
| L4 | Closed by the measured account of parity misses, an allowed stage exit. Milestone 46 remains open. |
| Partial L1 / X / M | Lua-frame error returns and native error channel; math/table/base native conversions; initial caches/fast paths; turn-boundary and host-idle collection, D host contract and macOS footprint audit. |

See the [history index](PERFORMANCE_HISTORY.md#evidence-index) for evidence and
substitutions. Runtime architecture and invariants are in [AGENTS.md](../AGENTS.md)
§4–5; do not reconstruct current behavior from historical implementation sketches.

## 3. Budgets and exits

### 3.1 World model

`narrative_scale.reference_game` runs 100 rooms, 1,000 storylets, 50 items, a recursive
rule, an aggregate and 500 turns. The script checks per-measure limits; the benchmark
runner checks peak RSS and overall CPU time.

| Measure | Provisional low-end budget | Development-machine stand-in |
| --- | ---: | ---: |
| Turn (`choose` plus next `present`), p95 | 50 ms | 5 ms |
| Content load | 1 s | 100 ms |
| First `save()` after the run | 50 ms | 5 ms |
| Peak engine-process RSS | 64 MB | 64 MB |
| Collections inside a turn | 0 | 0 |

The time scaling assumes a low-end machine ten times slower than an M1 performance
core. That is provisional until the owner selects the reference machine and M records
measurements. Budget definitions live in the
[workload](workloads/narrative_scale/reference_game.lua) and [targets.toml](targets.toml);
keep documentation consistent with them. Do not relax a budget to make a change pass.

### 3.2 Lua core

Milestone 46 exits only when **every workload with a C Lua comparator is at or below
1.0×**, with semantics and gates preserved. L1 also has its own no-throw exit (§5).
Milestone 47's below-parity number remains an owner decision after parity is measured.
`goal.*` reports progress; `gate.*` and any `floor.*` enforce regressions. Their
meaning and ratchet policy are in the [benchmark guide](README.md#targets).

## 4. Design rules for all stages

1. **C-like D:** hot kernels are `@nogc nothrow`; use explicit loops, plain data and
   generated variants instead of duplicated handlers. New failure paths return
   statuses, with the error object rooted on the thread. Fatal D errors remain fatal.
2. **One collector:** use D's GC. Grow buffers at named points outside kernels;
   kernels return "need room" to the caller. Memory holding references must be scanned.
   No second collector, reference counting, handle tables or hidden GC roots.
3. **Exact behavior and cleanup:** preserve numeric equality/hashing, binary strings,
   upvalue lifetime, native reentry, Fiber isolation, lexical worlds, transactions,
   analysis budgets and debug attribution. Preserve cleanup order: close values,
   finish/rollback transactions, close upvalues, pop call records, clear registers.
4. **Execution-only optimization:** never change canonical `proto.code` or
   `proto.callWorlds` for speed. Derive `execCode` and side tables during preparation;
   map optimized execution back to canonical locations for errors and debugging.
   Saves, fingerprints and replay must stay byte-identical.
5. **Safepoints and layers:** keep the fast loop free of per-instruction instrumentation;
   preserve attention checks after call-outs and backward jumps. Lower layers never
   import higher ones. Follow the detailed rules in AGENTS §4.1/§4.8.
6. **Measurement decides:** profile before choosing a change, measure a small slice
   before a broad rewrite, and compare the same build settings in the same session.
   Estimates and old ratios are not new evidence. Never weaken tests or gates.

## 5. Remaining work

### Track L — Lua core to parity (milestone 46)

**L1 is authorized; its runtime part is done (October 13, 2026).** A Lua error travels
by value everywhere the interpreter and the libraries handle one. `raise(state, error)` /
`state.raisedError` provide the channel. Done:

- every native library in `lib/` (no `throw`; `os.exit(code, true)` reports an `ExitSignal`
  that `takeRaised` turns into the `ExitRequest` unwind);
- the pattern engine (`MatchState.error`, `-1` unwinds the match);
- table access and metamethods (`VM.tryGetTable`/`trySetTable`, `LuaTable.nextEntry`,
  `LuaTable.keyProblem`), the operators and `forprep` (`opAdd`…`opLe` leave the error in
  `state.raisedError` and return nil/false), call checks, `__call` resolution and the
  generic `for` call;
- the dispatch loops' own errors (instruction budget, interrupt, unknown opcode, closing a
  non-closable value, transaction misuse) and deep-frame stack-limit errors, through
  `reportedFailure` (a per-executor mixin: `break interpret` / `break deepInterpret`);
- close handlers (`closeValuesFrom` returns a status) and both executors:
  `executeFrame`/`executeDeepFrame` return a Lua error in `TailRequest.error` and never throw
  it; `callValue(..., statusReturn: true)` runs a Lua function the same way, so a
  metamethod, iterator or comparator that fails reaches its caller through the slot.

What still throws, and why it stays for now:

- **Host adapters** (the "thin throwing wrapper" of open decision 8): `VM.execute`,
  `VM.getTable`/`setTable`, `callValue` without `statusReturn`, `checkStackLimits` at a frame
  entry that is itself a boundary, `LuaNativeFunction.call`, `LuaTable.rawset`/`next`.
  Hundreds of D callers rely on them; each is one throw at the outermost edge.
- **Unwinding that is control flow, not an error**: `CoroutineClose` (closing a suspended
  coroutine), `ExitRequest`. Both cross native frames of a Fiber; converting them means
  threading a "closing" status through yields and `pcall`, which needs its own design.
- **The frontend and loaders**: lexer, parser, compiler (syntax and compile errors), `dump.d`
  (binary chunks), `capi.d`, `cli.d`. They run at load time, not per instruction; `loadChunk`
  already turns their exception into a status at its boundary. Converting them is a separate
  change (a latched error with a sticky end-of-input token) and was not part of the
  authorization; the owner decides whether it belongs to L1's exit.
- The world-model and narrative layers throw `LuaException` from natives; the executor's
  frame handler still catches those (the adapter).

Continue in this dependency order:

1. Convert remaining native libraries and their helpers. Prioritize using profiles
   and conversion boundaries, not the historical count of throw sites.
2. Convert runtime helpers and executor/coroutine boundaries, including the existing
   `CoroutineClose` and `ExitRequest` control paths. Preserve protected-call behavior,
   error attribution and cleanup before removing exception adapters and frame guards.
3. Move generic native arguments/results to stack-based access where planned,
   avoiding allocated arrays; `lib/fastcall.d` is the existing model for hot built-ins.
4. After native unwinding is no longer required, measure a lean frame and a single
   record-based executor against native recursion. Keep a replacement only if it is
   at least as fast and preserves the constraints in §5a.

**Conversion recipe.** In native bodies, use `return raise(state, error)`; replace
throwing argument checks with `argNumber`, `argInteger`, `argAny`, `argFail` and the
other status helpers in `lib/auxlib.d`, returning immediately on failure. Helpers
return a status with results in out parameters. Never continue with `raisedError`
set, or assign partially validated results into live state. Throwing callers remain
supported through the adapters until their conversion. Audit both executors and
native reentry; do not remove an adapter while callers still rely on it.

**L1 exit:** no language-error `throw` in core modules, no exception-driven executor
cleanup, preserved messages/tracebacks/close behavior, and measured caught-error and
deep-recursion gates. Status October 13, 2026: executor cleanup and every runtime
language error are by value; the remaining throws are the adapters, control-flow unwinds
and frontend listed above. The original target was below 2× for those workloads; use the
current stricter gates where applicable. This does not substitute for milestone 46's
all-workload parity exit.

**Remaining parity work:** reprofile call-heavy and deep-recursion workloads after
L1; inspect string construction, hash/method probes and dispatch where still behind.
L3 compact encoding and cached-hash string objects remain conditional experiments:
measure one handler group or representation change from the current fast-loop
baseline before committing to a rewrite. Do not reopen delivered L2–L4 merely to
implement their original suggested techniques.

### Track X — Lua core beyond C Lua (milestone 47)

Initial constant-key hints, cached hashes, arithmetic and string fast paths exist.
Remaining candidates, each with separate measurements and semantic validation:

| Stage | Remaining candidate |
| --- | --- |
| X1 | Guarded method `__index` chain/global caches and computed-key probes where profiles justify them. |
| X2 | Operand-kind specialization and further fused instructions in execution data, with correct fallback. |
| X3 | Constant folding, guarded built-in specialization and reduced upvalue bookkeeping **only in derived execution data**. The original AST proposal does not authorize changed canonical bytecode or fingerprints. |
| X4 | PGO/LTO experiments after confirming the required profile tools and runtime libraries are available; do not assume an old toolchain limitation still holds. |

### Stage M — Memory, pauses, the host boundary, real hardware (milestones 36, 37)

Turn-boundary collection, `session:idle()` / `GameHost.idle()` and the documented D
host contract already exist. Keep `heapSizeFactor:4`: the recorded factor-2 experiment
failed gates without improving reference-game memory.

Remaining work:

- Build/test/package for Windows and Linux. Recheck the
  [POSIX audit](PERFORMANCE_HISTORY.md#stage-m--memory-pauses-the-host-boundary-real-hardware-milestones-36-37)
  against current code; it is a starting point, not proof that other modules are portable.
- On the chosen reference hardware, measure turn/load/save time, RSS, allocations,
  collector pauses, startup and binary size; replace assumed scaling with evidence.
- Reduce allocation if the measurements require it. Keep collections outside turns
  and engine work off the narrative render path. A host must not touch one state
  concurrently, even if it moves turn processing off the render thread.
- Android remains a stretch goal. Removing a frozen Lua feature to enable a port
  requires its own owner decision; this stage does not grant that authorization.

Full SDL rendering/typography belongs to milestone 36 and the localization plan,
not another performance-stage implementation checklist.

### Conditional world-model work

W5(b) instance-list caching is not needed for the recorded budget. Revisit only on
measured demand, preserving snapshot/cache invalidation and guard semantics. The same
applies to demand-driven inference and incremental view maintenance. Keep the naive
oracle; do not optimize it.

## 5a. Decision constraints

| Topic | Current constraint |
| --- | --- |
| L1 remainder | Authorized October 13, 2026. The earlier deferral no longer applies. |
| Call records/register clearing | Production remains exact. The owner permitted a lazy-record experiment; its measured ceiling did not establish parity or authorize weaker traceback/GC semantics. Preserve those semantics in a lean frame. |
| Executor replacement | Measure after L1. The existing record-based executor lost to native recursion in the recorded experiments; merging executors is not an assumed win. |
| Fiber-free coroutines | Deferred. Any future design must keep yielding from Lua and across `pcall`, plus transaction, no-yield and debug isolation. Consider only with a record-based executor at least as fast as native recursion. |
| Compact encoding / string objects | Conditional on fresh evidence; the delivered stage exits do not require them. Never intern runtime strings in a pool that keeps them alive. |
| Low-end machine / below-parity target | Owner decisions still open (ROADMAP 3 and 10); retain provisional budgets and the 1.0× goal meanwhile. |

Evidence: [L4 experiments and account](PERFORMANCE_HISTORY.md#track-l--lua-core-to-parity-milestone-46)
and [October 13 decisions](PERFORMANCE_HISTORY.md#5a-what-the-measurements-and-the-owners-decisions-leave-open-updated-october-13-2026).

## 6. Deliberately not planned

No JIT, parallel evaluation, separate collector or canonical-bytecode speed changes.
Faster coroutines are not a content-performance target. Closing frozen Lua conformance
gaps remains out of scope (D3); their existing regression tests must keep passing.

## 7. Validation

For each runtime performance change:

- Run `make test`, the sample's `tools/check.lua` from `sample-game/`, and
  `make bench-check`; retain byte-identical golden transcripts and saves.
- Build optimized with assertions (`make varis-checked`) and exercise the changed
  paths as well as release CLI fixtures. Preserve C Lua differential results,
  error messages, line numbers, tracebacks and both executor paths.
- Record same-session before/after timing and memory evidence, with build, machine,
  workload and comparator identified. Run benchmarks without competing heavy jobs.
- Ratchet gates only from measurements. Never reset baselines to hide regressions;
  loosening a gate requires the existing `Perf-Regression-Accepted:` policy.
- For evaluator/storage/cache changes, run `logic-oracle` (`VARIS_LOGIC_ORACLE=1`)
  and cover unordered-result equivalence, snapshots, writes, rule registration,
  negation/aggregates, rollback, inheritance and escaped iterators. The oracle runs
  when enabled, not automatically for every ordinary query.

Documentation-only changes still run `make test` and documentation link checks;
they do not require new benchmark measurements or fabricated current ratios.

## 8. Running measurements

Use the [benchmark guide](README.md#commands) for commands and interpretation.
Record raw runs in `build/` or labeled baselines as appropriate; regenerate
`docs/STATUS.md` with the suite's report workflow, never by editing ratios in prose.
Completed experiments belong in history, with a date and evidence link. Update
this plan only when the remaining work, stage disposition or constraints change.
