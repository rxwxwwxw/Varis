# Extension regression and stress suite

This additional suite tests the [Varis Reference Manual](../../docs/README.md),
including relational, stateful, aggregate and narrative semantics
through the real lexer, parser, compiler, VM, and declarative engine. It runs
separately from the existing engine unit tests and 15 acceptance examples, and
is included in `make test`.

The suite contains 54 Lua cases and four runner checks. All language cases and
runner checks pass after fixing the seven failures found during initial validation.

```sh
make test-extensions DC=/opt/homebrew/bin/ldc2
# Run a subset using an already built interpreter:
python3 tests/extensions/run-tests.py ./bin/dlua --filter rollback
# A shorter timeout is useful when investigating a hang:
python3 tests/extensions/run-tests.py ./bin/dlua --timeout 10 --filter stress
```

Each Lua case gets a fresh interpreter process and a **300-second timeout**.
`EXTENSIONS_TIMEOUT` can reduce that limit; values above 300 are rejected.
Timeouts kill the process group, including subprocesses started by a guard.
The suite continues after failures and exits nonzero if any case fails. There
is no aggregate five-minute limit: each case gets its own budget.
The existing test executable timeout and Datalog acceptance timeout now both
default to 300 seconds as well.

The runner prepends `helpers.lua` to a temporary copy of each source. `count`
consumes unordered results; `reject` checks both rejection and the intended
error substring. Successful cases must reach a completion marker. The eight
standalone negative cases require a diagnostic matching their named validation
condition. A crash, timeout, unrelated error, zero exit, or fallback error does
not count as an expected rejection. Source line numbers in interpreter errors
include the prepended helper. Four Python runner tests check these protections,
including a deliberately hanging synthetic interpreter with a 0.1-second limit.

## Coverage of the nine v0.1 conformance requirements

| Requirement (§19.3) | Executable cases |
| --- | --- |
| 1. Grammar | `contextual_syntax`, `contextual_labels`, `constant_single_evaluation`, `zero_arity`, standalone `negative_*` cases |
| 2. Symbols and relational equality | `symbols_binary`, `numeric_boundaries`, `numeric_infinities`, `raw_identity`, `nan_atomicity`, `comparison_nan_constants` |
| 3. Runtime facts and rules | `runtime_registration`, `rule_capture_constants`, `arity_rollback`, `rule_rollback`, `rule_body_rollback`, `base_derived_overlap` |
| 4. Safety and stratified negation | Eight `negative_*` cases, `ownership`, `negation_cycle_rollback`, `query_safety_order`, `negation_mutation` |
| 5. Least fixed point | `recursive_graph_oracle`, `chain_retraction_stress`, `join_projection_stress`, `negation_mutation`, `unrelated_guard_dependency`, `mutation_snapshot_oracle` |
| 6. Independent snapshot worlds | `world_inheritance_stress`, `worlds_nested_closures`, `ownership`, `unknown_world_errors` |
| 7. Lexically scoped recursive locals | `local_gc_isolation`, `lexical_shadow_resolution` |
| 8. Snapshot iterators and sets | `projection_nil`, `zero_arity`, `coroutine_snapshot`, `chain_retraction_stress`, `mutation_snapshot_oracle`, `guard_errors_lazy` |
| 9. Lua scoping, calls, and errors | `constant_single_evaluation`, `guard_capture_truthiness`, `guard_yield_restore`, `guard_errors_lazy`, `contextual_syntax`, `worlds_nested_closures`, `rule_capture_constants` |

The bounded stress workloads include:

- Six deterministic generated graphs checked against independent Floyd–Warshall
  closure, including duplicates, cycles, self-reachability, and missing results.
- A 64-edge chain with a broken bridge, a retained old iterator, and a restored
  65-node cycle producing all 4,225 reachable pairs.
- Joins producing 4,800 bindings and anonymous-variable projections that collapse
  multiple derivations to 20 unique bindings.
- 24 generations of world inheritance, with independent retractions checked
  against exact expected sizes.
- 250 deterministic fact/retraction operations checked against a Lua set model,
  with 50 delayed snapshots consumed after all mutations.
- Repeated negated-input additions/retractions across multiple strata.

Guard tests use stable values during each inference; they do not assume defined
behavior for guards observing externally mutated table contents. Object identity
capture is checked by reassigning the captured variable instead.

## Regressions fixed after initial validation

These specification assertions remain in the suite to protect the fixes:

| Case | Corrected behavior |
| --- | --- |
| `contextual_labels` | Standalone Lua labels compile without runtime instructions. |
| `negative_anonymous_head` | Anonymous rule heads reach safety validation and are rejected. |
| `rule_rollback`, `rule_body_rollback` | Implicit declarations are staged until the complete rule passes validation. |
| `local_gc_isolation` | Rule references retain local dependencies after their declaring frame exits. |
| `worlds_nested_closures` | Captured world slots close before their registers are reused. |
| `unrelated_guard_dependency` | Query snapshots traverse only reachable relation dependencies. |

`local_gc_isolation` reports an explicit partial skip if the Lua library lacks
`collectgarbage`; escaping closures and isolation are still asserted. No official
Lua harness tests are claimed by this extension suite. Those remain outside its
scope; the current suite does not silently treat unsupported harness tests as
conformance passes.

## Core stateful companion coverage

`make test-stateful` supplements these integration cases with direct engine tests
for key-index consistency, no-op/failure versions, immutable schemas, integer
wrapping, inheritance, tentative snapshots, and commit/rollback cleanup.

| Companion requirement | Integration cases |
| --- | --- |
| Named schemas, keys, atomic replacement/deletion/adjustment | `keyed_relations` |
| Read-your-writes, nested savepoints, protected and escaping errors | `transactions` |
| World selection/isolation, return/break, lexical capture, external effects | `transaction_worlds_and_control` |
| Nonyieldable transactions, coroutine committed reads and mutation locking | `transaction_coroutines` |
| Snapshot retention/invalidation, rollback of negated inputs | `transaction_snapshot_stress` |

Companion rejection assertions inspect intended diagnostics with `reject`.
The stress case checks 100 transactions against a Lua value model and consumes
retained snapshots after subsequent updates. The additional `aggregates` case covers nested/correlated aggregate semantics, snapshots, errors and strict dependency cycles. `narrative_registry` checks definition registration/sealing, contextual fields, templates, and immutable sequences. Full companion evidence and implementation limits are mapped in [the narrative audit](../narrative/README.md).

`qualities.lua` covers companion quality metadata, explicit nil initialization,
exact numeric bounds, constraints through direct facts/updates and library calls,
nested savepoint rollback, inherited worlds and the owning session-world default.

`narrative_policies` checks cooldown, repeatability, priority tiers/zero weights
and deck-entry token lifetime. `narrative_effect_errors` checks contextual names,
indirect yield/reentrancy/registration/cross-world rejection, invalid scheduling,
reset and rollback. `narrative_scheduler_stress` runs 60 turns across opposite
fact insertion orders with six save/load checkpoints and recorded-input replay,
qualities, named periods, scheduled handlers and nested rollback.
