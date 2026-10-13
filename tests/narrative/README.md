# Phase 7 conformance evidence

The current definition is the [Varis Reference Manual](../../docs/README.md),
particularly [state/transactions](../../docs/relations.md#5--state-and-transactions)
and [narrative facilities](../../docs/narrative.md). Milestones 9–18 are
implemented, including aggregates, subscriptions and bounded analysis. The audit
below retains historical companion section numbers; [the migration map](../../docs/coverage.md)
connects them to current reference sections. The implementation plan records
engineering history; language semantics are maintained in `docs/`.

Run `make test DC=/opt/homebrew/bin/ldc2`. Stateful and narrative unit executables,
the extension cases, the 15 base Datalog cases and existing base unit suites
are included. Current counts/results are in [generated status](../../docs/STATUS.md);
timeouts are defined per suite in `tests/manifest.toml`. Lua rejection
assertions inspect the intended diagnostic, and successful cases must reach the
runner's completion marker. Official Lua harness coverage is a separate Phase 5
gate. Forced-GC coverage reports a partial skip when `collectgarbage` is absent.

| Companion requirement | Implementation | Executable evidence |
| --- | --- | --- |
| §§2.1–2.2 column uniqueness, immutable schemas, raw-equality keys, extensional heads, inheritance | `logic/world.d`, validation, frontend/VM | `testKeyIndexes`; `keyed_relations` |
| §§2.3–2.5 atomic set/delete/adjust, key order, arity, constraints, no-ops and snapshots | world/key indexes/overlays | `testKeyIndexes`; `keyed_relations`, `qualities` |
| §§3.1–3.2 selected world once, rollback, savepoints, errors and non-error exits, external Lua effects | transaction coordinator and compiler/VM cleanup | `testCleanup`; `transactions`, `transaction_worlds_and_control` |
| §§3.3–3.5 tentative reads/inference, committed coroutine reads, locks, iterator validity, forbidden operations and yields | coordinator, snapshots, Fiber boundary | `testTentativeSnapshots`; `transaction_coroutines`, `transaction_snapshot_stress`, `narrative_effect_errors` |
| §§4.1–4.3 count/sum/min/max, local assignments/correlation, empty/error semantics, strict aggregate strata | frontend, validator and evaluator | `aggregates`; anonymous aggregate reconstruction in `testPersistenceRejections` |
| §5 sealed state registry, kind-scoped IDs, independent worlds/sessions, accessors and reentrancy | registry/session/library | `testRegistryFailures`, `testCompanionErrors`, `testSessions`, `testDeterminismAndBudgets`; `narrative_registry`, `narrative_effect_errors` |
| §6 frozen fields, scalar canonical instances, existential projection, per-instance cooldown/repeatability | compiler/registry/session/codec | `testCompanionErrors`, `testCompiledContexts`, `testDeterminismAndBudgets`; `narrative_policies`, `narrative_registry` |
| §7 immutable lexical parameters, correlated choice queries, session-world binding, token identity, revalidation and atomic effects | compiler/VM/session transactions | `testCompiledContexts`, `testSessions`, `testQualities`; `narrative_effect_errors`, `narrative_policies` |
| §8 phases, canonical priority ordering, reevaluation, turn/game/named/always policies, action budgets | session scheduler | `testActionsAndEvents`, `testDeterminismAndBudgets`, `testExplanations`; `narrative_scheduler_stress` |
| §9 tier filling/weights, stable order, seeded draws, independent stack histories, reset and replacement | session deck/RNG state | `testSessions`, `testDeterminismAndBudgets`; `narrative_policies`, `narrative_effect_errors`, `narrative_scheduler_stress` |
| §10 placeholders/labels/escaping, conditional existence/nesting, readonly frozen rendering, Lua lexical forms | templates/registry/context compiler | `testCompiledContexts`, `testExplanations`; `narrative_registry` |
| §11 metadata, initialization and nil membership, bounds on direct/library writes, lexical effect defaults and explicit worlds | quality library, tuple validators, lexical call metadata | `testQualities`; `qualities`, `narrative_scheduler_stress` |
| §12 sequence/turn/immutable arguments, protected history, due ordering/chains, handler budgets, transactional deferral | session participants and scheduler | `testSessions`, `testActionsAndEvents`, `testDeterminismAndBudgets`; `narrative_scheduler_stress` |
| §13 idle saves, tagged portable values, complete world/session state, authored reconstruction, version/schema validation, migrations, atomic failed loads and replay | codec/fingerprint/persistence/session | `testCodec`, `testPortableSessions`, `testPersistenceRejections`; `narrative_scheduler_stress` |
| §14.1 committed visible-set deltas including derived negation, canonical dispatch, callback restrictions, queued work and nonserialized subscriptions | observer hub/world commit hooks | `testObservers` |
| §14.2 pure structured goal and policy explanations, explicit nil bindings | diagnostics/bound evaluator | `testExplanations` |
| §14.3 isolated bounded choice tree, dead ends, unreachable-within-scope content and cycle candidates, explicit completeness | analysis graph copying and shared budgets | `testAnalysis` |
| §15 all added forms and contextual identifiers, ordinary calls/methods/fields/labels | parser/compiler/VM | above cases; `keyed_relations`, `narrative_effect_errors`, `contextual_syntax`, `contextual_labels` |

## Required rejection evidence (§16)

Each row checks the intended reason, rather than accepting arbitrary failures.

| Error | Assertions |
| --- | --- |
| Conflicting key declaration, duplicate columns, keyed rule head | `keyed_relations`: `conflicting schema`, `duplicate column`, `cannot be a rule head`; `testKeyIndexes`: duplicate/unknown key/schema consistency |
| Conflicting fact insertion | `keyed_relations`, `testKeyIndexes`: `conflicting fact`, with unchanged facts/indexes/versions |
| Invalid update arity/relation/key/value | `keyed_relations`: `not keyed`, `one non-key column`, `expects 1 key arguments`, `expects arity 3`, `NaN is prohibited`; quality tests: bound failures |
| Absent or nonnumeric adjustment | `keyed_relations`: `adjust key is absent`, `requires numeric values` |
| Cross-world/nested/registration/yield errors | `transaction_worlds_and_control`, `transactions`, `transaction_coroutines`, `guard_yield_restore`, `narrative_effect_errors`; cleanup and later yieldability asserted |
| Unbound parameters and nonportable instance keys | `testRegistryFailures`, `testCompanionErrors`: storylet/choice/action parameter diagnostics and mutable-table instance-key failure |
| Duplicate content, unknown deck/placeholder and invalid options | `testRegistryFailures`, `testCompanionErrors`, `narrative_registry`: identifier, field, priority/weight/cooldown/repeatability/deck-option, sealed-registry diagnostics |
| Stale tokens, action limit and invalid effects | `testSessions`, `testDeterminismAndBudgets`, `testActionsAndEvents`; `narrative_policies`, `narrative_effect_errors`: consumed/foreign/deck-entry/policy/eligibility invalidation, budgets, reentrancy and full rollback |
| Unsupported saves, runtime-rule reconstruction, version/schema mismatch | `testCodec`, `testPortableSessions`, `testPersistenceRejections`: paths, authored programs/captures, reordered schemas, runtime/content/program versions, malformed histories/counters, migration failure and unchanged factory worlds |

## Bounds and support limits

- The integrated stress fixture runs 60 turns with identical seeded selections
  across opposite fact insertion orders, six canonical save/restore checkpoints,
  full recorded-command replay, scheduled deliveries, period changes, action
  ordering and rolled-back nested effects. Its release execution was about 0.14
  seconds on the development host. Unit persistence coverage also advances two
  original/restored sessions together for 32 turns and checks cross-state loads.
- Transactions, inference, readonly evaluation and observer notification prohibit
  yields through helpers and synchronously resumed coroutines. Coroutine reads
  of another transaction's committed state remain permitted; its tentative
  writes remain private. Yieldability is restored after commit, rollback/error
  and completed inference.
- Quality calls without an explicit world use the lexical call world's captured
  slot inside effects, defaulting to the session world in the effect body.
  Ordinary standalone helpers retain their own lexical world. Outside effects,
  omitted worlds use `logic.global`. Aliasing the library function preserves this
  behavior; foreign-world writes still fail transaction validation.
- Cooldown N counts completed turns after the successful choice's committed
  turn. A presentation does not advance cooldown. Nonreplacement draws are
  per deck entry; reset clears draws, push/pop preserves the underlying entry,
  and replacement creates a fresh entry and invalidates its predecessor's tokens.
- Replay uses the same authored initial state, engine/content versions and logged
  commands. Hosts apply logged external inputs. Unrecorded external writes,
  impure code and failed commands with partial scheduler commits require the host
  to reproduce those inputs separately. Arbitrary Lua mutations/I/O are outside
  transaction rollback and replay guarantees.
- Analysis explores one seeded presentation per node and all its returned choices,
  excluding alternate random draws, future host inputs and observer queues. It
  reports scope/completeness, bounds, errors and blocked native operations. Default
  depth/nodes/VM steps/graph objects are 3/100/1,000,000/200,000; depth is at most
  32, nodes at most 10,000, graph nesting at most 256. An action-budget failure is
  a potential cycle, not a proof. Native host/I/O/shared-random calls are blocked.
- Explanations are conjunction-prefix and policy diagnostics, not full recursive
  proof trees. Full recomputation remains the correctness baseline for inference
  and subscription differencing. Default per-phase action/event budgets and
  observer flush budgets are 1,000. Custom display formatter registration
  (`narrative.formatter`) and deterministic weighted text variants in templates
  (`{#variant ...}` / `{#variants}`) are implemented and verified in `testFormattersAndVariants`.
- Existing compiler `goto` execution and the official Lua harness are outside the
  companion gate; `tests/runner.d` provides the dedicated official runner (`python3 tools/suite test --suite official`).
  Standalone labels and existing supported Lua behavior remain covered by regression tests.


Scene coverage (manual §6.11): `extensions.narrative_scenes` covers frozen programs,
portable locals, menu control, stale/foreign/load tokens, immutable stage, failed
control-loop atomicity, translations and repeat presentation. `narrative_scene_rollback`
proves effect launch/rollback and scene/hub interoperation. The `sample-game` suite's
`linear-vn` and `scene-save` cases prove mid-dialogue and mid-call save/load, fresh-process
restoration, wording compatibility, structural/corrupt-save rejection and static
unknown-character/attribute diagnostics. Readable scene branches and errors are covered
by `phase9_readable_scene` and `phase9_readable_scene_errors`; beat undo is implemented
(see the undo cases in `tests/extensions/cases/`). Exhaustive scene-branch analysis
is not implemented; the RPG Maker/Ren'Py rendering parity list remains milestone 36 work.

The status-returning `SceneHost` is covered by `tests/unit/test_presentation.d`.
Optional `make test-sdl` checks rendering, input/menu flow, assets and scene saves;
it requires the SDL development packages and is separate from `make test`.
The [presentation guide](../../docs/presentation.md) records supported directives and limits.
