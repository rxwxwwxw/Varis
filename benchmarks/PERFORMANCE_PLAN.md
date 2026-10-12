# Performance plan: turn latency on low-end hardware

Status: **plan**, October 11, 2026. Nothing below is implemented. This replaces the retired
Phase 8 optimization milestones (21–25) and details milestones 34, 35 and 37 of
[ROADMAP.md](../ROADMAP.md) Phase 11. [PERFORMANCE_WORK.md](PERFORMANCE_WORK.md) remains the record
of the earlier C-Lua-ratio work.

## 1. Constraints

1. **D-accessible objects on D's collector.** Values, tables, worlds, sessions and tokens stay
   ordinary D GC objects that host code can hold and use directly: no second collector, no
   reference counting, no handle wrappers.
2. **Semantics preserved.** Everything the manual defines for relations, state and narrative stays
   as is: construction-time query snapshots, transactions and savepoints, deterministic draws,
   portable saves and replay, explanations and bounded analysis.
3. **Lua compatibility is relaxed, the gates are not.** A Lua-only behaviour may be dropped when
   recorded (ROADMAP policy), but `make test` and `make bench-check` keep passing.
4. **The target is a graphical front end on a low-end machine**, so what counts is how long a
   turn takes, how much memory the engine holds, and that nothing stalls a frame.

## 2. What was measured

`benchmarks/experiments/synthetic_game.lua` generates a grid map with location-bound one-shot
storylets, parameterized `look`/`walk`/`take` storylets and, optionally, one storylet that reads a
recursive `reachable/2`. Release CLI at commit `15522b1`, Apple M1, CPU time from `os.clock`,
median `present()` over 3–200 turns. "E-cores" is the same binary under `taskpolicy -b`, used as a
rough stand-in for a slow machine (about 3.5× slower here; a real low-end machine may be slower).

| Game | `present()` | E-cores | Peak RSS |
| --- | ---: | ---: | ---: |
| 100 rooms, 200 storylets | 3.0 ms | 10.7 ms | 61 MB (200 turns) |
| 100 rooms, 1000 storylets | 16 ms | 55 ms | 94 MB |
| 400 rooms, 2000 storylets, 500 items | 201 ms | | |
| 16 rooms, 50 storylets, recursive `reachable` | 3.8 ms | | |
| 36 rooms, same | 33 ms | | |
| 64 rooms, same | 195 ms | 740 ms | |
| 100 rooms, 200 storylets, recursive `reachable` | **819 ms** | | 171 MB |

Other costs in the same runs: `choose()` 0.1–2.7 ms; content load 9 ms per 200 storylets and
44–59 ms per 1000; `save()` 14 ms at 200 storylets and 57 ms at 1000 (203 ms on E-cores).

A 5-second `sample` profile of the 400-room, 2000-storylet game (no recursion) attributes, by
top of stack: about **50 % to the garbage collector** (marking and allocation), about **33 % to
hashing and inserting tuples into associative arrays**, about 11 % to the evaluator's and query
constructor's own code (mostly the loops doing that copying), and 5 % to thread-local lookups.
Goal matching itself is a few percent. The bytecode interpreter does not appear.

### Why

- `Session.present` clones the world (`session.d`, `world.cloneSnapshot()`).
- Every storylet's `when` builds a `QueryIterator`, which copies the base facts of every relation
  in the query's dependency closure (`query.d`).
- `Evaluator.evaluateQuery` copies those facts again into a fresh `visibleFacts` map, recomputes
  stratification, then runs every rule of each stratum to a fixed point naively: each iteration
  re-joins all facts with nested loops, and each candidate binding is a string-keyed associative
  array duplicated per match (`evaluate.d`).
- Nothing is reused between the queries of one presentation, or between turns.
- `save()` recomputes the fingerprint of all registered content each time (`persistence.d`,
  `portableRegistryFingerprint`), so its cost follows content size rather than state size.

So a presentation costs roughly *storylets × facts their conditions depend on*, and one recursive
rule multiplies that by the size of its closure. Small games hide this; a 100-room map does not.

## 3. Targets

Reference game (stage 0 builds it): about 100 rooms, 1000 storylets, 50 items, at least one
recursive rule and one aggregate in use, a 500-turn scripted session.

| Measure | Low-end budget (provisional) | Stand-in on the development machine |
| --- | ---: | ---: |
| Turn: `choose()` plus the next `present()`, p95 | 50 ms | 5 ms |
| Content load | 1 s | 100 ms |
| `save()` | 50 ms | 5 ms |
| Peak RSS of the engine process | 64 MB | 64 MB |
| Collections inside a turn | 0 | 0 |

The development-machine column assumes a low-end machine is ten times slower than an M1
performance core. That factor is a guess until stage 7 puts a real machine in the loop; the
owner picks the reference machine (ROADMAP open decision 3).

Distance today: the recursive 100-room game is about 160× over the turn budget; the 1000-storylet
game without recursion is about 3× over; `save()` is about 11× over; RSS is 1.5–2.7× over.

## 4. Stages

Each stage is independently shippable and ordered by measured payoff per unit of risk. Stages 1–5
are inside the relational engine and the session; none depends on the authoring syntax of
ROADMAP Phase 9.

### Stage 0 — Measure (milestone 34)

- Turn the experiment script into a `narrative_scale` group in `benchmarks/manifest.toml` with a
  fixed reference game, reporting p50/p95/max turn time, load, save and peak RSS, with `gate.time`
  budgets in `targets.toml`. Record today's numbers first so every later stage shows its effect.
- Add engine counters, readable from tests and benchmarks: facts copied, tuples derived, queries
  and rule firings per presentation, collections per turn.
- Keep the E-core run as a second reported configuration until a real low-end machine exists.

### Stage 1 — Stop copying: shared immutable snapshots

Make a relation's fact set shareable: a snapshot holds a reference to the set and its version,
and a writer copies the set only when a snapshot still shares it. `cloneSnapshot`, query
construction and evaluation then share one set instead of copying it three times.

- Semantics: unchanged. A query still sees the state at its construction, because what it holds
  can no longer change. Transaction overlays stay as they are.
- Expected effect: removes most of the collector and hashing share in the profile above, so up to
  about 5× on games without recursion, and most of the peak-RSS excess.
- Exit: the "facts copied" counter is zero for read-only queries.

### Stage 2 — Evaluate once per world version

Cache, per dependency closure and keyed by the versions relations already carry (`version_`),
the stratification and the fully materialized derived relations. Every storylet, choice, template
condition and action in a presentation reuses them, and so does the next turn if nothing in the
closure changed.

- Publish a cache entry only after evaluation completes (existing invariant). Entries are
  immutable, so query iterators can keep them as their snapshot.
- Inside a transaction that has written to the closure, bypass the cache.
- Rule guards capture values at registration, so cached derivations stay valid; guard purity
  remains the author's obligation as today.
- Expected effect: in the measured game the exits never change, so `reachable` is computed once
  per session rather than once per storylet per turn.

### Stage 3 — Compiled plans, slot bindings, indexes (milestone 35)

- Compile each rule body and query once: number the variables into slots (an array, no
  associative array and no duplication per match), order positive goals by how bound they are,
  and apply comparisons, guards and negation as soon as their variables are bound.
- Give relations hash indexes on the argument positions those plans probe, built lazily per
  version and shared through the stage 2 cache. Keyed relations already have `keyIndex`.
- Expected effect: `when { at(:player, :room), not seen(:x), quality(:player, :resolve, ?r) }`
  becomes three probes. A thousand storylets should cost on the order of a millisecond.

### Stage 4 — Semi-naive evaluation of recursive strata (milestone 35)

Join only against the tuples derived in the previous iteration. With stage 3's indexes, closure
over a 100-room map is tens of thousands of probes rather than the current 0.8 s.

Not planned until measured: demand-driven evaluation for queries with bound arguments
(`reachable(:here, ?to)` needs one source's row, not all pairs).

### Stage 5 — Skip storylets whose inputs did not change

Each availability query's dependency closure is already known. Cache a definition's instance list
keyed by the versions of the relations it reads, so a turn that changes `seen` and one quality
re-evaluates only the storylets that read them. Instance enumeration consumes no random numbers
(draws happen afterwards), so replay is unaffected. Do this only if stages 1–4 leave the reference
game over budget.

### Stage 6 — Memory, pauses, saves, the host boundary (milestones 36, 37)

- Re-measure RSS after stages 1–3; most of today's heap is garbage produced by copying. Then
  revisit `heapSizeFactor:4` in `cli.d`, which was chosen for the C-Lua work and trades memory
  for fewer collections.
- D's collector stops the world. Offer the host an "idle now" call that collects after a
  presentation has been handed over, and keep per-turn allocation low enough that no collection
  starts inside a turn.
- The engine does no per-frame work: a presentation is an immutable value the front end can draw
  at any frame rate without calling back in. If a turn can still exceed a frame, the host runs
  turns off the render thread; a state is single-threaded, so the host must not touch it
  concurrently.
- Compute the content fingerprint once at `narrative.seal` and reuse it in `save()`.
- Leave content load alone unless stage 7 shows a problem.

### Stage 7 — Real low-end hardware (milestone 37)

Build for the platform the reference machine runs (the tree imports POSIX-only APIs today; see
ROADMAP milestone 37), run the reference game there, and replace the stand-in column in section 3
with measured budgets.

## 5. Validation

- Every existing gate: `make test` (unit `test_logic`/`test_stateful`/`test_narrative`,
  acceptance and rejection, the 19 scenarios with golden output, extension cases) and
  `make bench-check`.
- Keep the current evaluator as a **test oracle**: in test builds, every query is also answered
  by the naive evaluator and the result sets must be equal. Remove it only when stage 4 has
  shipped and soaked.
- New tests where the new machinery can go wrong: a snapshot taken before a write still sees the
  old facts; cache invalidation on fact, retract, `set`/`delete`/`adjust`, rule registration,
  rollback and world inheritance; negation and aggregates over cached strata; iterator
  invalidation after rollback; explanations and analysis on shared snapshots; saves and replay
  byte-identical before and after each stage.
- The `datalog`, `scenarios` and `narrative` benchmark groups must not regress and should improve;
  tighten their `gate.time` budgets after each stage.

## 6. Deliberately not planned

- **Interpreter restructuring** (flat call stack, compact instructions, error handling without D
  exceptions, new array opcodes). The interpreter is absent from the turn profile and `choose()`,
  which runs effect code, is already 0.1–2.7 ms. The flat call stack was built once and was not
  faster (see PERFORMANCE_WORK.md). Twelve `goal.clua` values in `targets.toml` were set to 1.2 in
  commit `15522b1`; they are reported, never enforced, and this plan does not work toward them.
- **A smaller `LuaValue`.** Tuples are arrays of values, so a 16-byte value would cut tuple
  memory by a third. Revisit only if stage 6 still misses the memory budget, with a profile, as
  an explicitly reviewed architectural change.
- **Incremental view maintenance.** With per-version caching and turns that touch a few relations,
  recomputing the affected strata should be enough. Revisit on evidence.
- **Parallel evaluation or a JIT.**

## 7. Reproducing the measurements

```sh
make varis
bin/varis benchmarks/experiments/synthetic_game.lua 10 1000 0 40      # 100 rooms, 1000 storylets
bin/varis benchmarks/experiments/synthetic_game.lua 10 200 1 3        # with recursive reachable
taskpolicy -b bin/varis benchmarks/experiments/synthetic_game.lua 8 50 1 4   # efficiency cores
```
