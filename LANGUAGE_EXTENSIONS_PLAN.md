# Implementation plan: language extensions, performance, and conformance

> **Reference authority:** [The Varis Reference Manual](docs/README.md) now defines
> current language semantics and supersedes the two former extension references.
> This file preserves implementation history, milestones, and performance plans.
> Completed-phase wording and historical baselines below are not independent
> language requirements. See [the migration map](docs/coverage.md) for former
> section numbers and decisions incorporated into the manual.


This plan records implementation of the relational and narrative facilities now defined in the [Varis reference](docs/README.md). Milestones 0–8 describe the existing Phase 6 implementation sequence; milestones 9–18 below track Phase 7. Milestones 9–18 are fully implemented, including aggregates, sessions/scheduling, portable persistence/replay, explanations, subscriptions, bounded analysis, custom display formatters, and deterministic weighted text variants in templates. The final requirement/error matrix and support limits are in [tests/narrative/README.md](tests/narrative/README.md).

[Phase 8](#phase-8--performance-and-remaining-lua-conformance), milestones 19–25, covers remaining Lua conformance work, benchmark hardening and measured optimization toward ≤2× C Lua. Milestone 20's conformance gate is met (31 pass / 1 partial / 1 skipped / 0 fail); remaining skips and partial exclusions are documented in [the official audit](tests/official/README.md), so performance optimization may now be targeted.

## Scope and current state

Future narrative localization work is proposed in
[NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md): permanent automatic
content labels, translation catalogs, locale-aware messages, RTL/LTR rendering
contracts, and save/replay compatibility. This is a proposal, not current support.

The base target is finite Datalog with set semantics, least-fixed-point recursion, stratified negation, lexical local relations, independent worlds, and snapshot queries. Its engine, typed declarative AST, compiler/VM integration, `logic` library, and tests now exist. `Makefile` explicitly includes the logic modules and runs foundation, frontend, VM, library, logic, stateful, narrative, Datalog, extension regression/stress, and benchmark-runner tests. The official Lua conformance runner is implemented (`tests/runner.d`, runnable via `make test-official`), establishing an automated pass/fail/skip baseline and failure backlog. Historical instructions in milestones 0–8 describe how the base was built; their presence alone is not a fresh claim that every conformance check has passed.

The companion adds named/keyed schemas, atomic updates, transactions, optional aggregates, and a separate narrative runtime. Named/keyed schemas, atomic updates, and world-scoped transactions are implemented and tested; aggregate goals are also implemented; the narrative runtime and authoring tools are implemented. Aggregation remains outside the base v0.1 scope and becomes available only through the companion aggregate work. Compound terms, Prolog backtracking, cuts, non-stratified negation, cross-world rule dependencies, and individual rule deletion remain outside scope. Fibers remain the coroutine substrate; inference does not require a search fiber.

## Architecture decisions

- Keep logic variables in declarative AST/IR and binding environments, rather than adding unbound variables to general `LuaValue`.
- Add an inline symbol value backed by a state-owned intern pool. Literal names live in prototypes and are interned in the executing state, rather than in the lexer or compiler.
- Represent worlds and binding records as opaque, GC-managed userdata payloads. Local relation handles stay in compiler-managed lexical slots. Extend VM field access for records and reject writes; do not implement records as mutable tables protected only by `__newindex`.
- Give every relation a stable identity distinct from its name and owning world. Resolve references when registering a rule or constructing a query; later name shadowing must not retarget existing rules.
- Compile declarative syntax to immutable plan templates attached to `Prototype`, plus dedicated VM operations that call a separate engine. These operations must not depend on mutable Lua globals such as `logic.add`.
- Start with complete recomputation of the required dependency closure at query evaluation, using naive fixed-point iteration within each stratum. Cache only completed materializations by program version. Optimize after correctness is established.
- Capture an immutable relational snapshot at query construction, then perform inference on the first iterator call. This preserves construction-time snapshots and delivers evaluation errors to the iterator caller. Iterators become permanently invalid after an evaluation error.
- Capture world-block defaults through hidden lexical locals/upvalues. Avoid a mutable default-world field that would accidentally introduce dynamic scoping across calls or coroutines.

Suggested module boundaries, subject to normal implementation refinement:

| Module | Responsibility |
| --- | --- |
| `source/varis/logic/model.d` | Relation identity, tuples, term/goal/rule IR, immutable program snapshots |
| `source/varis/logic/world.d` | World registries, local relations, versions, atomic mutations, inheritance |
| `source/varis/logic/validate.d` | Arity, variable safety, ownership, dependency graph, SCCs and strata |
| `source/varis/logic/evaluate.d` | Matching, joins, constraints, guards, fixed points, dependency materialization |
| `source/varis/logic/query.d` | Snapshot iterator state, projection, deduplication, immutable binding records |
| `source/varis/lib/logic.d` | Required public library functions and symbol helpers |

Keep engine modules independent of compiler internals. Pass a guard invocation interface into evaluation instead of embedding VM dispatch into the relation model. Preserve the prescribed Lua license header on every new D file.

## Milestone 0 — Establish compatibility and settle semantic edges

1. Run `make test` and build `make varis` with the configured LDC compiler. Record existing failures before changing the language.
2. Create a requirements-to-tests checklist covering specification sections 2–16 and all examples in section 18.
3. Document parser recognition rules for contextual keywords. Keep `fact`, `rule`, `query`, `relation`, `retract`, `where`, and `logic` as identifiers in the lexer. Ordinary assignments, calls, fields, method calls, and labels must retain their meanings.
4. Resolve or explicitly document underspecified edges before freezing tests:
   - Whether a braced query may join explicitly qualified relations from multiple worlds; the specification explicitly forbids cross-world *rules* but does not settle this query case. Do not extend the rule restriction silently.
   - Whether retracting from an entirely unknown relation errors or does nothing; implicit establishment is specified for facts and rules.
   - The exact diagnostic for calling an invalid iterator again, and guard capture timing for query guards, consistent with construction-time snapshots.
   - Interaction of the new globals `logic` and `symbol` with existing programs using those names.
5. Define snapshot closure for local computations: include reachable local relation versions, world facts/rules, captured constants, and guard functions. Local mutations must invalidate live-world evaluations without changing existing iterator snapshots.

**Exit criterion:** baseline results and semantic decisions are recorded; no unresolved issue is hidden inside an implementation default.

## Milestone 1 — Symbols and relational value correctness

**Files:** `types.d`, `state.d`, `table.d`, `vm.d`, `lib/base.d`, and symbol support in the new logic modules.

1. Extend `LuaSumType`, constructors, type tags, equality, hashing, and formatting for symbols. Audit exhaustive sumtype visitors and type switches throughout the interpreter and libraries. Always place `long` handlers before `double` handlers.
2. Implement byte-safe interning shared by all worlds in a state. Support dynamic names including empty strings and embedded NULs; quote nonidentifier names in `tostring`.
3. Reuse a single correct raw-equality/hash contract for tables and tuple sets. Audit mixed integer/float equality first: the current conversion of both operands to `double` can equate distinct values above 2^53 and violate equality/hash consistency. Check integer boundaries and `floatToInteger` at 2^63 as well.
4. Reject NaN in tuple elements and captured relational constants. Preserve `nil` as an ordinary tuple element, integer/float numerical equivalence, and reference identity. Relational matching must bypass `__eq`.
5. Define tuple keys with explicit length and owned value storage. A zero-arity tuple is a valid singleton fact; `nil` cannot serve as an absent-element sentinel.
6. Reject symbol ordering as specified while allowing symbols as table keys.

**Validation:** symbol identity across worlds, string/symbol distinction, binary names, table keys, boundary numeric equality/hash cases, reference identity despite `__eq`, NaN rejection, and tuples containing `nil`.

## Milestone 2 — World and relation storage

**Depends on:** milestone 1.

1. Give each `LuaState` a distinguished global world and a world-value wrapper. Maintain named relation registries, fixed arity, base tuple sets, registered rule instances, and monotonically changing logical versions.
2. Implement explicit declaration, implicit relation creation for facts/rules, insertion, and retraction. Duplicate insertions and absent-tuple removals are no-ops. Successful repeated rule registrations remain distinct rule instances.
3. Make mutations atomic: validate arity and values before publishing new relations or facts. Stage rule-related implicit declarations and dependency changes before committing them.
4. Implement empty worlds and parent snapshots. Clone relational membership and rule definitions; rebind every inherited relation reference, including qualified references, to the child's corresponding identity. Share referenced Lua objects and captured guard values without copying their contents.
5. Introduce local relation objects with fixed owning worlds, separate identities, reachability-based lifetime, and versioned rule/fact state.

**Validation:** independent parent/child changes, default parent always `logic.global`, inherited recursive rules, shared Lua-object identity, no-op version behavior, zero arity, arity conflicts, and failures leaving registries unchanged.

## Milestone 3 — Rule validation and the reference evaluator

**Depends on:** milestone 2. Exercise this layer directly from D before relying on syntax lowering.

1. Define resolved terms (constant, named variable ID, anonymous occurrence), positive/negative atoms, primitive comparisons, guard descriptors, and rule heads. Allocate variable IDs independently for each rule/query; every `?_` occurrence is distinct.
2. Validate rule/query safety across the entire body, independently of textual order. Reject anonymous variables in heads, comparisons, and guards, and logic-variable-dependent head computations.
3. Build signed dependencies over relation identities. Use strongly connected components to reject any negative dependency within a cycle and compute strata over the condensation graph.
4. Enforce ownership: local rules may depend on compatible local/world relations; world-owned rules cannot depend on locals; no rule may depend on another world. Validate against the proposed complete graph before registration commits.
5. Match positive tuples into bindings, enforcing repeated-variable equality. Evaluate grounded comparisons and negative atoms after the positive joins, consulting completed lower strata for negation.
6. Evaluate positive recursion to a least fixed point using tuple set insertion. Keep base and derived membership conceptually separate. Recompute from base facts after mutation so retraction and newly false negation cannot leave stale consequences.
7. Restrict materialization to the query's dependency closure; an unrelated failing guard should not be evaluated merely because it exists in the same world. Publish caches only after successful completion.

**Validation:** transitive closure with cycles, mutual recursion, multiple derivations, goal-order independence, repeated/anonymous variables, unsafe rules, negative cycles, grounded negation, comparisons without metamethods, and base retraction of a tuple still derivable through another route.

## Milestone 4 — Snapshot query API and required library

**Depends on:** milestone 3.

1. Create iterators that retain frozen program/local-relation snapshots and own their evaluation state. Ignore generic-for state/control arguments; return exactly one binding record per successful call and `nil` forever after exhaustion.
2. Deduplicate on all returned named variables, omitting anonymous variables. A successful ground query returns one empty record. Preserve presence independently of value so a `nil` binding is distinguishable from an absent name.
3. Add immutable record field reads to VM dispatch, and reject normal assignment and raw table mutation pathways. Avoid exposing backing tables through the library.
4. Implement `logic.global`, `logic.world`, `logic.emptyworld`, `logic.add`, `logic.retract`, `logic.symbol`, `logic.symbolname`, `logic.hasbinding`, `logic.binding`, and global `symbol`. Register the library through `openLibs` and `package.loaded`.
5. Propagate errors with source/relation context and invalidate the failing iterator. Preserve previous successful program mutations. Use D GC reachability to retain resources while needed.

**Validation:** construction-time snapshots followed by mutations before first use, partial iteration, exhaustion, invalid iterator reuse, `nil` presence, immutable records, ground queries, projection duplicates, and Lua `pcall`/`xpcall` handling.

## Milestone 5 — Lexer and typed declarative AST

**Depends on:** milestone 0; can proceed once the IR interfaces from milestone 3 are agreed.

1. Add `?` and `:-` punctuation while preserving `:` and `::`. Parse symbol literals from colon plus identifier in expression position so `object:method()` still works.
2. Add buffered lookahead/checkpoints to `Parser` for complete contextual construct recognition. Do not reserve extension names globally or consume ordinary calls such as `query(...)` and `logic(...)` as extensions without the required syntax.
3. Replace the placeholder `RuleStmt` with typed nodes for relation references, declarative terms/goals, facts, retractions, declarations, local declarations, rules, world blocks, symbols, and queries. Preserve `SourceLoc` on offending terms and goals.
4. Implement section 17's grammar, including static final relation names on qualified world paths, arbitrary Lua expressions as constants, comparisons, guards, and braced queries.
5. Allow logic-variable reads only inside declarative terms and guard expressions. Reject trailing commas, malformed heads, forbidden anonymous positions, and logic variables inside ordinary constant expressions.
6. Respect comma boundaries across Lua argument lists, declarative goals, and enclosing expression lists. Newlines must have no special termination role.

**Validation:** all grammar forms, adjacent same-line rules/statements, semicolons, multiline bodies, nested calls/tables in constants, contextual identifiers, method syntax, labels, qualified paths, and precise malformed-input diagnostics.

## Milestone 6 — Compiler and VM integration

**Depends on:** milestones 4 and 5.

1. Attach immutable rule/query templates to `Prototype`; add dedicated instructions for symbol loading, relation declaration, fact mutation, rule registration, and query construction. VM handlers call engine entry points using evaluated register values.
2. Compile every syntactic fact/constant argument to exactly one value, including the final call or vararg expression. Evaluate constants once when the statement or query executes; do not reuse Lua's final-argument multivalue expansion.
3. Maintain a separate lexical relation namespace with hidden registers/upvalues, including shadowing and closure capture. Ordinary Lua locals with the same spelling do not shadow relations.
4. Compile world blocks into one evaluated hidden world binding. Nested functions capture that binding. Functions defined outside a block retain their own lexical world when called inside it; closures defined inside retain the block world when called later.
5. Resolve qualified paths once per operation. A qualified rule head establishes the body's fallback world; local-name lookup still applies and ownership validation rejects invalid dependencies.
6. Ensure captured hidden handles remain correct across scope exit, loop register reuse, return, break, and error unwinding. Address any existing upvalue-closing defect exposed by these cases without introducing a dynamic world stack.

**Validation:** executable facts in loops/functions, registration timing, captured constant values, multireturn truncation, relation shadowing, qualified-head body resolution, nested lexical world blocks, escaped closures, and local recursive query iterators returned from functions.

## Milestone 7 — Guards and coroutine boundaries

**Depends on:** milestone 6.

1. Compile `where` expressions to guard prototypes with logic-variable reads from explicit binding parameters. Capture free Lua locals/upvalues/globals by value when registering rules; normal open upvalues must not track later assignments. Function and table captures retain object identity.
2. For query guards, capture their ordinary Lua environment at query construction, consistent with the snapshot decision recorded in milestone 0. Ordinary relational constant expressions are evaluated once; the guard predicate itself runs during inference.
3. Invoke guards through normal Lua call/error handling. Use only the first result and `isTruthy()`; guards do not create bindings.
4. Add an exception-safe nonyieldable execution guard for the active coroutine/call context. Enforce it at the Fiber yield boundary, including yields reached through helper functions or native callbacks, and reflect it in `coroutine.isyieldable()`.
5. Keep engine mutation/version handling exception-safe. Do not attempt to prove arbitrary guard purity; document the specification's external-state stability requirement.

**Validation:** captured locals/globals reassigned after registration, shallow table/function capture, false/nil versus 0/empty-string results, multireturn guards, guard errors invalidating iterators, nested yield attempts, restored yieldability after failure, and two coroutines mutating/consuming the same world between iterator calls.

## Milestone 8 — Conformance, integration, and documentation

**Depends on:** milestone 7.

1. Add `tests/unit/test_logic.d` and `make test-logic`, include it in `make test`, and add all new modules to `SRC_FILES` and appropriate public exports. Extend existing foundation/frontend/VM/library suites for their integration points.
2. Turn every section 18 example into an executable regression and map every section 19.3 conformance requirement to passing tests. Compare unordered result sets rather than iteration order.
3. Add a small independent evaluator in test code or exhaustive finite fixtures to cross-check generated safe programs, including insertion/retraction histories and stratified negation. Keep the oracle simple and independent of the production evaluator.
4. Run full unit tests and CLI smoke tests. The official Lua test-suite runner (`tests/runner.d`, executable via `make test-official`) is implemented, recording existing failures separately and reporting unsupported C test-harness facilities as skips, never successes (4 passed, 6 skipped, 23 failed baseline).
5. Document syntax, library APIs, captures, snapshots, guard purity, and known limits in `README.md`; update `AGENTS.md` architecture/module ownership and the Phase 6 roadmap.
6. Add measurements for closure, joins, recursive SCCs, snapshot creation, and retraction followed by querying. Record performance rather than making optimization a prerequisite for v0.1 correctness.

**Exit criterion:** all nine v0.1 conformance requirements have executable coverage, extension regressions pass, and ordinary Lua regressions introduce no new failures relative to the recorded baseline.

## Follow-on optimization work

After milestone 8, add argument-position indexes and grounded join planning, then semi-naive delta evaluation within positive SCCs. Reuse the reference evaluator as an oracle. Consider immutable structural sharing for worlds and query snapshots after measuring copy cost. Defer incremental deletion until evidence warrants its complexity; full recomputation remains a correct fallback for retractions and negation changes.

## Delivery order

Land milestones as reviewable changes with their tests. The recommended sequence is 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Frontend work can overlap engine work after interfaces are defined, but the complete syntax is not considered implemented until guards, local relations, worlds, and snapshot error behavior pass integration tests.

## Phase 7 — Stateful relations and narrative extensions

[The Varis narrative chapter](docs/narrative.md) is the current reference for these facilities; the companion terminology below is historical. Its amendments apply only to the added features; the base Datalog semantics remain in force elsewhere. Core schema/update/transaction/aggregate work is implemented. Narrative definitions, sealing, templates, sessions, deterministic presentations, choices, automatic actions, and transactional events/deferred callbacks are implemented. Quality metadata/API and direct-write constraints are also implemented. Portable session saves/restoration and replay input logging are implemented. Explanations, committed-set subscriptions and bounded state-space analysis are implemented. The final requirement-by-requirement audit is recorded in [tests/narrative/README.md](tests/narrative/README.md). Core stateful conformance and narrative conformance are separate delivery gates. Aggregates are optional; subscriptions and state-space analysis are optional authoring facilities. Do not advertise them as required core features or as available before their tests pass.

### Implementation status and core decisions

| Milestone | Status |
| --- | --- |
| 9 | Complete: baseline, core/session interfaces and authored reconstruction/migration decisions recorded |
| 10 | Implemented: named schemas, keys, atomic updates, contextual syntax, VM integration |
| 11 | Implemented: overlays/savepoints/isolation/cleanup/iterators plus session participants and after-commit callbacks |
| 12 | Implemented: aggregate syntax, scoped/correlated variables, strict dependency strata and evaluation |
| 13 | Implemented: registration/compiler, sealed registry, independent sessions and canonical instances |
| 14 | Implemented: snapshot templates, deterministic decks/presentation, opaque tokens, choice revalidation/atomic effects |
| 15 | Implemented: actions, periods, quality metadata/API/constraints, events/schedules and deferred callbacks |
| 16 | Implemented: canonical portable saves, staged restoration, version/fingerprint validation, explicit reconstruction/migration and replay logs |
| 17 | Implemented: explanations, committed-set subscriptions and isolated bounded choice analysis |
| 18 | Complete: requirement/error matrix, bounded integration/replay fixtures and full regression gate |

The initial `make test DC=/opt/homebrew/bin/ldc2` baseline passed foundation/frontend/VM/library/logic suites, 15 Datalog cases, 43 extension cases, and runner/benchmark tests. Core validation now adds `make test-stateful` and five companion cases to the existing extension runner. The official Lua harness remains outside this support claim.

Core decisions adopted for milestones 9–11:

- Named world schemas are immutable when established. Adding or changing named/key metadata on an implicitly or numerically established relation is rejected, rather than silently upgrading its schema. Numeric declarations of the same arity preserve an existing named schema. Empty named declarations are accepted for zero arity; `key(...)` requires at least one existing unique column. Local declarations retain their existing numeric-arity syntax.
- Key arguments follow the order listed in `key(...)`, including when it differs from tuple column order. Keys use relational equality, including `nil` and integer/float equivalence. Integer adjustments wrap as Lua integer arithmetic does; numeric strings are rejected for adjustment.
- Transactions use coroutine-specific overlays and hold an exclusive mutation lock on their world. A manually resumed coroutine may read committed facts but cannot write or start a conflicting transaction on that world. Transactions never retry. Within the owning coroutine, nested same-world transactions merge or discard savepoints.
- Schemas/rules cannot be registered even idempotently inside a transaction. Facts must target established relations; implicit creation is a prohibited schema change. Lexical local-relation mutations are rejected in transactions because they are outside the named world overlay. Reads of local relations remain allowed.
- `rollback` must be lexically inside a transaction in its own function; the compiler rejects other uses. It exits that innermost lexical block. Return and loop breaks commit transactions they leave; a break from a loop wholly inside a transaction does not exit the transaction. Ordinary `rollback` assignments, calls (including string/table sugar), fields and labels retain identifier behavior. Goto scope validation and execution are now implemented; the official goto file passes. Targeted stateful tests verify close-handler writes before commit, rollback, error cleanup, and goto exit.
- An escaping error rolls back every transaction owned by the unwinding frame. A protected error caught inside a transaction does not exit it: earlier successful writes remain tentative, and only the failed operation is unapplied. Lua object mutations and external effects remain outside rollback.
- Query iterators created in a rolled-back savepoint become permanently invalid, even after partial evaluation. A child savepoint's committed iterators are invalidated if the outer transaction later rolls back. An iterator created before a discarded nested savepoint remains valid; committed escaped iterators keep their construction-time tentative snapshot.
- World logical versions advance once per changed outer commit; relation versions track successful tentative mutations and are published with the fact/key-index state. Failed/no-op operations do not advance versions. Tentative inference snapshots never publish committed state.

The decisions below settle handler, token, event-turn, lexical-quality, authored reconstruction and explicit migration interfaces.

### Milestone 9 — Companion baseline, interfaces, and semantic decisions

**Depends on:** the base implementation in milestones 0–8. **Reference:** companion §§1–16.

1. Run `make test` and `make varis`; record failures and map each companion requirement to an executable acceptance case. Preserve the existing extension suites and official Lua skip policy.
2. Define relation-schema metadata, transaction overlays/savepoints, transaction-aware session participants, immutable content definitions, and session ownership interfaces before adding syntax. Reuse raw relational equality, snapshots, validation, and nonyieldable execution contexts.
3. Resolve ambiguities explicitly before freezing APIs: named/local/zero-column declarations and schema upgrades after implicit establishment; key-column argument order when key order differs from column order; transaction control transfers (`goto`, protected errors, return, break) and escaped closures; which rolled-back savepoints invalidate descendant iterators; local-relation writes in world transactions; and aggregate ordering versus the base rule body's order-independent safety.
4. Specify canonical scalar encoding (binary strings/symbol names, `nil`, numeric equality, signed zero, finite floats), schema/content version identifiers, choice-token lifetime/session ownership, cooldown turn boundaries, and seed validation. Identify the missing handler-registration, formatter/template-call, and migration interfaces rather than silently inventing public APIs.
5. Settle event turn assignment relative to choice commit/turn advancement, scheduled-handler/deferred-callback errors and ordering, presentation RNG/draw-history failure atomicity, observer reentrancy, and the ownership of the session event relation if sessions share a world. Clarify quality default-world resolution against the narrative session-world exception and how direct `fact`/`set`/`adjust` enforce quality constraints.

**Exit criterion:** requirements matrix, baseline, interfaces, and recorded decisions; examples and prose conflicts are resolved before implementation relies on them.

### Milestone 10 — Named schemas, keys, and atomic updates

**Depends on:** milestone 9. **Reference:** companion §2 and §15.

1. Extend `logic/model.d` and `logic/world.d` with unique column names, immutable key metadata, and a key-to-base-tuple index using raw relational equality, including `nil`. Copy schema/index state into inherited worlds; validate redeclarations and preserve numeric-arity declarations.
2. Reject rule heads targeting keyed relations in `logic/validate.d`. Keep keyed relations extensional while permitting body reads. Identical facts remain no-ops; conflicting same-key facts error without mutations or implicit-schema leakage.
3. Implement engine APIs for full-tuple `set`, key-only `delete`, and `adjust` on exactly one non-key column. Evaluate arguments once to one value, validate arity and ownership first, use Lua 5.4 arithmetic, and apply constraints before publishing an atomic replacement. Absent delete and identical set are no-ops; absent/nonnumeric adjust errors.
4. Add contextual parsing, typed AST nodes, immutable prototype descriptors, and VM instructions in `ast.d`, `parser.d`, `compiler.d`, `opcode.d`, and `vm.d`; preserve ordinary identifiers/calls/labels such as `set(...)` and `delete(...)`. Every mutation path, including library calls and exact-tuple `retract`, must maintain indexes and versions.

**Validation:** composite and reordered keys, `nil`, integer/float equality boundaries, binary symbols, duplicate columns/keys, conflicting redeclarations, inheritance isolation, no-op versions, keyed rule-head rejection, invalid update rollback, arithmetic errors, and unchanged ordinary Lua parsing.

### Milestone 11 — Transactions, savepoints, and iterator validity

**Depends on:** milestone 10. **Reference:** companion §3.

1. Add a transaction coordinator (suggested `logic/transaction.d`) with one selected world, entry snapshots, tentative fact overlays, nested same-world savepoints, and session-state participants. Reads and inference use entry state plus preceding writes; other coroutines see only committed state. Serialize transactions or reject conflicting commits without retries.
2. Validate all mutations through a shared coordinator, rejecting cross-world writes, other-world nesting, and schema/rule registration. Commit affected logical versions/caches and participant state together; discard tentative inference caches on rollback. Local-relation behavior follows milestone 9's recorded decision.
3. Compile `transaction [(world)] do ... end` and `rollback` with exception-safe VM cleanup. Evaluate world selection once, commit on normal/non-error control transfer, roll back on escaping errors, and make `rollback` exit only the innermost transaction. Check all scope/upvalue and control-transfer paths.
4. Attach transaction/savepoint validity to query snapshots. Escaped committed iterators retain their construction-time tentative snapshot; rollback invalidates affected iterators even if already evaluated. Enforce no yielding at the Fiber boundary and restore prior yieldability after every exit.
5. Provide commit hooks for events, deck/history changes, and deferred commands. Arbitrary Lua table changes and external I/O remain outside rollback.

**Validation:** read-your-writes including negation/retractions, coroutine isolation, nested commit/rollback, outer rollback after nested commit, return/break/error cleanup, caught errors, explicit rollback, escaped iterators, forbidden operations, conflict handling, and yieldability restoration.

### Milestone 12 — Optional aggregate goals

**Depends on:** milestones 9–11. **Reference:** companion §4.

1. Add typed aggregate goals for `count`, `sum`, `min`, and `max`, including braced subqueries, local variable scopes, correlated grounded inputs, and a newly grounded result. Document the agreed dependency-based execution ordering.
2. Extend safety validation and dependency analysis: aggregate subqueries must be safe/finite, dependencies strictly lower-stratum, and recursion through aggregates rejected before registration commits.
3. Evaluate distinct assignments of local variables rather than distinct expression values. Preserve multiple equal bonuses from distinct items. Empty `count`/`sum` return zero; empty `min`/`max` fail the goal. Propagate Lua arithmetic/comparison errors without publishing partial caches.

**Validation:** correlated grouping, variable shadowing/leakage, repeated values, empty inputs, ground subqueries, unsafe correlations, aggregate cycles, numeric/comparison errors, and snapshots after transaction updates. Ship separately if optional aggregates would delay core stateful conformance.

### Milestone 13 — Content registry, sessions, and narrative compilation

**Depends on:** milestones 10–11; milestone 12 only for aggregate-using content. **Reference:** companion §§5–8, §15.

1. Add suggested `narrative/model.d`, `narrative/registry.d`, `narrative/session.d`, and `lib/narrative.d`; register the library through `openLibs` and `package.loaded`. Content is state-owned and immutable after sealing, not copied by world inheritance. Sessions own world references, turn, deck stack, histories, periods, scheduled events, and RNG state.
2. Implement `narrative.registry`, sealing/versioning, `narrative.new(world)`, explicit host/session seeding before random draws, and read-only session accessors. Validate identifier uniqueness per kind, choices within storylets, references, options, and required fields; reject registration after sealing.
3. Parse contextual storylet/choice/action/deck forms into typed definitions and compile registration-time constant fields, availability query templates, and effect prototypes. Preserve source locations. Ground every exposed parameter; treat other availability variables existentially. Reject duplicate fields, invalid priorities/weights/cooldowns, and nonserializable instance keys.
4. Supply immutable parameter values as read-only lexical Lua locals in templates/effects, shadowing ordinary locals. Resolve narrative availability and unqualified effect relations against the owning session world at execution; preserve base lexical-world capture for ordinary closures. Prevent recursive session commands and forbidden content/rule registration from effects.

**Validation:** independent sessions sharing sealed content, kind-scoped IDs, sealing errors, field evaluation once, parameter scope/shadowing/read-only enforcement, session-world rebinding, scalar instance identity, invalid content diagnostics, and contextual-name compatibility.

### Milestone 14 — Storylet presentation, decks, templates, and choice execution

**Depends on:** milestone 13. **Reference:** companion §§6–7, §§9–10.

1. Implement canonical instance identity and ordering independent of tuple/hash iteration. Evaluate availability from a consistent presentation snapshot; track per-instance repeatability and cooldown. Present immutable bindings, stable ordered storylets/choices, and opaque session-owned tokens.
2. Implement default/configured decks, transaction-aware push/pop/replace/reset, per-entry draw history, and priority-tier weighted sampling without duplicates within a presentation. Exclude zero weights from draws; fill from lower tiers as needed; allow empty presentations. Require seeding and version the PRNG/sampling algorithm.
3. Parse templates at registration: parameter placeholders, escaped braces, nested relational-existence conditionals, unknown-name errors, `nil` as empty text, symbol display labels, and explicit formatters/templates once their APIs are settled. Render read-only against the same snapshot without consuming RNG. Optional weighted text variants are selected beforehand and recorded.
4. Begin choice resolution with a transaction; revalidate the exact storylet/choice bindings, deck, cooldown, and repeatability. Invalid or stale tokens produce `STALE_CHOICE` with no effects/turn increment. Atomically commit effect changes and instance completion, then advance one turn and start post-choice processing. Effect failures roll back transaction-aware state; effects cannot yield or recursively present/choose.

**Validation:** deterministic draws across insertion orders, zero weights, tier filling, replacement modes, stack/reset rollback, unknown placeholders, nested existence tests, stale/forged/other-session tokens, changed eligibility, cooldown boundaries, effect errors, read-only parameters, and turn advancement only on successful choices.

### Milestone 15 — Automatic actions, qualities, and transactional events

**Depends on:** milestone 14. **Reference:** companion §8, §§11–12.

1. Add suggested `narrative/scheduler.d` and `lib/quality.d`. Run pre-actions before presentation and post-actions after successful choices. Select highest priority with canonical ID/binding tie breaks, revalidate/execute one action transaction, record completion, then reevaluate committed state.
2. Implement per-instance `once_per :turn`, `:game`, named serializable periods, and `:always`; default phase is `:post`, priority zero, period `:turn`. Enforce the default 1,000-action phase budget and report `ACTION_LIMIT` while preserving earlier committed actions.
3. Register immutable quality metadata in the content registry; implement `quality.define`, initialize/get/set/add over keyed extensional `quality(entity, name, value)`. Initialization is explicit and idempotent, missing get returns `nil`, missing add errors, and constraints error without clamping. Enforce the same constraints through direct relational writes and keep derived qualities in separate relations.
4. Stage `narrative.emit` events transactionally, assigning sequence numbers at commit. Expose read-only `narrative_event(sequence, turn, kind, args)` with immutable serializable arguments; reject every user mutation path. Implement scheduled events with due-turn/insertion ordering, registered handlers in separate transactions, and an immediate-chain budget. Process due events before post-actions (or initialization pre-actions).
5. Run `narrative.defer` callbacks only after commit, never after rollback or inference. Implement/document the chosen handler/callback failure and ordering policy without claiming external effects can be undone.

**Validation:** action ordering/cycles/limits, period changes, effect rollback, quality constraints through every write path, event sequence/turn consistency, event-relation immutability, scheduled ordering and zero-delay chains, deferred callbacks after commit, and forbidden scheduler reentrancy/yields.

### Milestone 16 — Portable saves and deterministic replay

**Depends on:** milestone 15. **Reference:** companion §13.

1. Add suggested `narrative/persistence.d` and shared canonical serialization for scalar values and supported immutable sequences/records. Reject nonfinite floats and unsupported mutable objects/functions/threads/userdata with descriptive paths; never silently omit values.
2. Implement `session:save()` only at quiescent boundaries. Save base tuples, world/version/schema metadata, registry version, turn, deck entries/draw histories, completion/action histories, periods, schedules, committed events, and RNG state. Reconstruct derived tuples; exclude temporary iterators.
3. Implement `narrative.load(saved, world_factory)` by loading versioned authored registries/rule programs first, validating schema/content/runtime compatibility, then atomically restoring base/session state. Refuse non-reconstructible runtime rule closures/local relations absent an explicit host reconstruction protocol. Require explicit compatible migrations for mismatches.
4. Record replay inputs (seed, versions, choice instance keys, external inputs) and verify identical state and selections with the same runtime/content. Keep external I/O and impure Lua outside this guarantee.

**Validation:** round trips at turn/deck/event boundaries, binary values and `nil`, unsupported-value paths, active-operation save rejection, mismatched/reordered schemas, reconstruction failures, migration failures, unchanged destination on failed load, and replay determinism across hash enumeration orders.

### Milestone 17 — Authoring diagnostics and optional subscriptions/analysis

**Depends on:** milestones 15–16. **Reference:** companion §14.

1. Implement `narrative.explain` with structured goal outcomes and deck/cooldown/once-per exclusions; do not promise complete recursive failure proofs. Explanations must not mutate state or consume RNG.
2. Optionally implement `narrative.observe` by differencing committed visible sets, including derived changes from negation/retraction. Dispatch canonical relation/tuple deltas after commit, never inference. Callbacks may enqueue later commands but cannot synchronously mutate the notifying world; authored code reestablishes subscriptions on load.
3. Optionally implement bounded `narrative.analyze` over cloned world/session snapshots. Report unreachable content, dead ends, action cycles, depth, and completeness; isolate the original world, RNG, histories, and external effects.

**Validation:** explanation purity, rollback emits no notifications, derived enter/leave deltas, callback mutation rejection, nonserialized subscriptions, bounded analysis, and original-session preservation.

### Milestone 18 — Companion conformance and documentation

**Depends on:** milestones 10–11 for core stateful delivery; 13–16 and explanation support for narrative delivery. Optional features receive separate coverage when enabled. **Reference:** companion §16.

1. Add direct unit and end-to-end companion tests (suggested `tests/unit/test_stateful.d`, `tests/unit/test_narrative.d`, and `tests/narrative/`). Add implemented modules explicitly to `Makefile`, public exports, library initialization, and test aggregation. `make test-stateful` and `make test-narrative` exist and are included in `make test`; narrative tests cover registry/templates, sessions/scheduling/qualities, portable saves/replay, explanations, observers and bounded analysis. The paragraph/grammar/error audit and executable evidence are in `tests/narrative/README.md`.
2. Map every §16 error and requirement to a positive/negative case. Check intended diagnostics with source/content/relation context, not merely a nonzero process exit. Add bounded scheduler/transaction/save stress fixtures and deterministic replay fixtures; preserve existing Lua/Datalog regressions.
3. Publish separate support claims for core stateful updates/transactions, optional aggregates, narrative conformance, and optional authoring tools. Update README and AGENTS as each gate passes; record measured limits and unsupported official Lua harness tests as skips.

**Exit criterion:** required companion conformance tests pass with no new base regressions; pending/optional functionality remains explicitly identified.

## Companion delivery order and module ownership

Land 9 → 10 → 11 first as an independently testable stateful extension. Then 13 → 14 → 15 → 16 → 17 → 18 completes the narrative layer. Optional milestone 12 can land after 11 without blocking narrative content that does not use aggregates. Optional portions of 17 do not block narrative conformance. Keep each change reviewable with its own validation; performance work follows correctness.

| Implemented area | Companion responsibility |
| --- | --- |
| `logic/model.d`, `world.d`, `validate.d` | Schemas/keys, atomic updates, transactions/participants/observers, aggregate safety and strata |
| `logic/query.d`, `evaluate.d` | Snapshot validity, aggregate evaluation and bound diagnostic queries |
| `ast.d`, `parser.d`, `compiler.d`, `opcode.d`, `vm.d`, `fiber.d` | Contextual grammar, lowering, read-only parameters, session world, cleanup, yield boundaries and analysis VM budget |
| `narrative/registry.d`, `session.d` | Content/model, canonical identities, decks/presentation, tokens, choices, scheduling, periods and events |
| `narrative/templates.d`, `codec.d`, `fingerprint.d`, `persistence.d` | Rendering, immutable values, canonical saves/replay, authored reconstruction and version checks |
| `narrative/diagnostics.d`, `observe.d`, `analysis.d` | Explanations, committed-set subscriptions/queued work, isolated bounded search |
| `lib/narrative.d`, `lib/quality.d` | Public APIs and transaction-aware integration |

The transaction coordinator lives in `logic/world.d`; deck/scheduler behavior lives in `narrative/session.d`. Other splits originally suggested above are optional module boundaries, not missing deliverables. Preserve Lua's license header in every added D source file and keep scheduler effects separate from pure Datalog inference.

### Narrative foundation decisions and interfaces

- Aggregate outer positive atoms are joined before aggregate evaluation. Aggregate goals bind newly introduced results in textual order; comparisons/guards/negation run after those bindings. Inner-only named variables and anonymous occurrences are scoped and deduplicated by full satisfying assignment, not expression value. Aggregate dependencies use strict lower strata and reject recursive cycles.
- Narrative definitions lower through dedicated `DefineContent`/`DefineDeck` instructions; mutable Lua globals cannot redirect registration. Availability/effect prototypes receive an implicit world argument. Choice availability receives storylet parameters as grounded constants; exposed effect parameters are read-only lexical locals, including writes from nested closures. Unqualified narrative references bypass surrounding local relation handles in favor of the supplied session world.
- The state-owned registry supports registration, kind-scoped IDs, schema-independent content fingerprints, sealing, option/reference checks and parameter/template validation. `narrative.seal([authored_version])` may supply a host-authored version string; without it the registry hashes its canonical content manifest. Portable save validation will additionally check closure/rule reconstructibility.
- Added initialization helpers are `narrative.name(symbol, label)`, `narrative.display(value)`, `narrative.on(symbol, handler)` for named event-handler registration, and `narrative.sequence(...)` for explicit immutable serializable sequences. `narrative.template(text, bindings [, world])` renders an explicit template against a relational snapshot. Session creation and effect-only APIs are implemented through `narrative/session.d` and `lib/narrative.d`.
- `narrative/templates.d` uses the plural name because `template` is a D keyword. Rendering uses existence tests, nested conditionals, escaped braces, symbol labels and a read-only logical evaluation context. The portable codec preserves integer/float types and float bits, binary strings/symbols, nil presence, and immutable nested sequence/record values; canonical *instance* identity normalizes mathematically equal numeric scalars.
- Current executable evidence includes `tests/extensions/cases/aggregates.lua`, `narrative_registry.lua`, and `tests/unit/test_narrative.d`. The Phase 7 requirement and rejection matrix is published in `tests/narrative/README.md`, including implementation decisions and measured support limits.

### Session runtime decisions and executable evidence

- A mutable world belongs to at most one narrative session; separate sessions use independent worlds and share the sealed state registry. `narrative_event(sequence, turn, kind, args)` is reserved, protected against public facts/updates/retractions and rule heads, and contains only committed history. Session creation rejects a world with inherited event history unless an internal restoration protocol supplies the matching session state.
- Session state is a `TransactionParticipant` in the world coordinator. Each savepoint copies visible state on its first narrative write; child commit merges it, rollback discards it. Event tuples are prepared before the outer publication. Deferred callbacks merge with savepoints and run after publication and transaction cleanup. Callback errors propagate with the already committed choice turn/history and consumed token preserved.
- Choice tokens are opaque session-specific identities. An unconsumed token remains usable while its exact deck entry, policy, storylet bindings and choice bindings remain eligible; unrelated world mutations or additional presentations alone do not invalidate it. A successful commit consumes it atomically. Reusing a consumed, foreign, or stale token raises `STALE_CHOICE`.
- Draws use implementation-versioned SplitMix64 seed initialization, xorshift64* output (high 53 bits), canonical priority/ID/binding ordering, and weighted sampling without duplicate selection. Weights are normalized by the largest weight in the current tier. Seeded RNG, nonreplacement draw history and token issuance publish only after all rendering succeeds. Pre-phase actions already committed before a rendering error remain committed.
- Events emitted by a player effect carry the pre-advance turn. The same successful outer commit advances the turn and stores completion history at the new turn. Post-choice actions and due handlers therefore observe that new turn. Named handlers registered with `narrative.on(kind, function(world, kind, args) ... end)` receive an immutable argument sequence; `narrative.schedule` requires one made with `narrative.sequence(...)`.
- Due events run before each scheduler eligibility pass, ordered by due turn and insertion sequence. A failing handler leaves its event queued; earlier successful handlers/actions remain committed. `session:limits(action_count, event_count)` sets positive per-phase budgets (default 1,000 each), with `ACTION_LIMIT`/`EVENT_LIMIT` diagnostics. Once-per history keys include canonical instance and period identities; custom period values use the portable immutable-value codec.
- Read-only availability/template evaluation blocks world and session writes even through manually resumed coroutines, and the Fiber yield boundary also rejects yielding from this context. Session commands reject reentrancy during effects, presentations and callbacks; transaction-aware deck/event/period operations are permitted only through their specified effect interfaces.
- `make test-narrative` now checks choice rollback and retry, stale/foreign/consumed tokens, deck-stack and nonreplacement draws, event nil arguments and protected history, nested savepoint event/defer rollback, action scheduling and budgets, due-event ordering/chains, deterministic independent sessions, and post-commit callback errors. The companion conformance gate is documented in `tests/narrative/README.md`.

### Quality runtime decisions and evidence

- `quality` is an installed standard library (also `package.loaded.quality`), and each library-created world starts with the reserved `quality(entity, name, value) key(entity, name)` schema. Inherited worlds copy its metadata validator; transaction overlays preserve the same validator. `quality.define` registers metadata only and inserts no entity facts. Initial values and unbounded values must be portable scalars; bounds must be finite numbers in ascending order. A missing initial value is explicitly nil; visible defaults to true and label defaults to the identifier.
- Quality names must be declared symbols. Unknown names and invalid metadata fields/types are errors. Bounds reject invalid values before any existing tuple/key is removed, using exact Lua integer/float ordering. Constraints apply to direct `fact`, `set`, and `adjust`, `logic.add`, and the quality library, including inherited worlds and savepoints. Deletion/retraction removes membership; initializing again restores the declared initial value. An initialized nil remains a present tuple even though `quality.get` returns nil.
- With no explicit world argument, quality operations inside effects use the lexical call world: the owning session world for the effect body, a nested `logic` world in that block, or the captured lexical world of an ordinary helper closure. Outside effects they select `logic.global`. Call-site metadata applies equally to aliases, is scoped per Fiber, and restores after errors. Explicit world arguments resolve read access directly and mutation remains subject to the transaction's cross-world restriction. No clamping or absent-value arithmetic is performed.
- Evidence: `testQualities` in `make test-narrative` and `tests/extensions/cases/qualities.lua` cover explicit initialization/no implicit defaults, nil membership, nested rollback, helper and direct-write constraint paths, inherited/empty worlds, exact >2^53 boundary constraints, registry sealing, metadata errors, and session-world isolation. Portable restoration must retain and revalidate these constraints under milestone 16.

### Portable saves, authored reconstruction and replay

- `session:save()` returns canonical tagged JSON text (`varis-session-1`), available only at an idle boundary. It stores all base tuples and relation/world versions, persistent world identity, named column/key schemas and their fingerprint, content/program/runtime identities, turn, deck entries/draw history, completion/action histories, periods, schedules, event history, PRNG state/seed, execution limits, consumed-token IDs and replay inputs. Derived tuples and executable tokens/iterators are reconstructed or discarded. Restored worlds have fresh runtime identity and retain the saved persistent identity.
- `narrative.load(saved, world_factory [, migration])` calls the factory to rebuild an idle unowned authored world, stages a fresh snapshot, and validates every schema, key, tuple constraint, history/counter and content/program fingerprint before returning a session. The factory world remains unchanged on success and failure. The factory has the same external-side-effect obligations as authored code. Unsupported values fail with their saved relation/capture path; arbitrary Lua objects and local rule dependencies are not serialized.
- Pure rules with portable constants can be reconstructed structurally. Rule guards and aggregate-expression callbacks require `narrative.program(world, nonempty_version)` during authored initialization. This records the rule fingerprint; later rule/capture changes make a save non-reconstructible. The host must reproduce native callbacks/mutable captured environments under that explicit version. `narrative.seal(authored_version)` makes the corresponding explicit reconstruction assertion for content captures. Without an authored version, unsupported captured objects fail portable-save validation. Reinstalled globals and external impure code remain outside replay guarantees.
- Code/capture fingerprints supplement authored content versions. They include prototypes, query/rule templates, captured portable values and handler code; generated anonymous names and unordered aggregate-local sets are normalized. Schema checks compare column/key order and the complete relation set. The runtime identity versions PRNG/sampling behavior. Mismatches fail descriptively; an optional explicit migration callback receives saved text and immutable target runtime/content identities, returns one replacement saved-text string, and undergoes the same full validation. There is no silent migration.
- `session:replay_log()` returns immutable runtime/content/program/schema identities and command records. Seed, limits, external period changes, successful presentations (selected canonical keys) and committed choices are recorded; effect changes and choice records commit together. `session:record_input(symbol, portable_value)` records named host input without applying it. Presentation records expose read-only `instance_key` fields so a host can match logged keys to returned opaque tokens. Hosts replay recorded commands from the same authored initial state and apply their recorded external inputs; unrecorded external writes and failed commands with partial committed scheduler progress must be supplied by the host separately.
- Evidence in `testPortableSessions` and `testPersistenceRejections`: canonical roundtrips across states; restored subsequent draws and event/action state; replay from command records; malformed counters/history, reordered schema, content/runtime/program mismatches, quality violations and history disagreement; unchanged factory world on failed load; unsupported tuple/capture paths; active-save/load rejection; authored-guard and anonymous aggregate reconstruction; runtime program changes and explicit migration failures. The final requirement/error audit is recorded in `tests/narrative/README.md`.

### Explanations and relation-change subscriptions

- `narrative.explain(session, content_symbol [, bindings])` returns immutable goal outcomes and candidate instances with exclusion reasons. A storylet ID resolves first; an otherwise unique action ID can also be explained to inspect `once_per`. Bindings accept ordinary tables or immutable presentation/query records (the latter preserve explicit nil presence). Unknown parameters and nonportable parameter values are errors.
- Goal outcomes are computed against a frozen world in evaluator order: positives, aggregates, comparisons, guards, negation. Each result includes its authored goal index/kind/relation/terms, distinct-binding counts before/after, and `success`, `failure`, `error`, or `not_reached`. This is a conjunction-prefix diagnostic, not a complete recursive proof. It reruns pure inference without writes or RNG consumption and reports guard errors in place. Candidate exclusions identify deck, cooldown, completed/nonrepeatable instances, zero weight, nonreplacement draw history, once-per suppression or unset periods. Choice availability is included per bound storylet instance.
- `narrative.observe(world, relation_name, {on_enter=..., on_leave=...})` accepts a string or symbol relation name and returns a cancellation function. Registration snapshots the committed visible set; it does not deliver existing tuples. Each later logical commit (including single fact/update operations and rule registration) fully recomputes observed base/derived relations, then dispatches deltas after transaction and participant publication. Rollback/no-op membership changes produce no callbacks. Multiple subscriptions are delivered in registration order within each canonical relation/tuple delta.
- Callbacks receive one immutable tuple sequence, including exact nil slots and zero-arity length. Scalar tuple ordering uses canonical equality encodings; reference values use stable per-process addresses, because arbitrary Lua objects have no portable identity. Notifications are never emitted during inference. All baselines update before dispatch, and all applicable callbacks/deferred callbacks are attempted; the first error propagates after committed state remains published. No callback error retries the logical transaction or repeats an already delivered delta.
- Synchronous writes/transactions/session commands targeting the notifying world are rejected even through resumed coroutines. Notification callbacks cannot yield. `narrative.enqueue(function)` queues a later command from the current callback; the host calls `narrative.flush(world [, positive_limit])` at an idle boundary (default 1,000 commands). Recursive flushes are rejected; `OBSERVER_QUEUE_LIMIT` preserves earlier completed work and remaining queue entries. Failed queued commands are removed before invocation and propagate their error.
- Subscription state and queued closures are owned by the observed world, are not inherited by snapshots, and are not serialized. Authored code reestablishes them after load. Tests in `testObservers` cover base/derived negation/retraction deltas, canonical order, savepoint rollback, no-ops, cancellation, new rules, immutable nil tuples, foreign coroutine write rejection, callback errors after commit, queue bounds, and absent restored subscriptions. `testExplanations` verifies goal outcomes/exclusions, explicit nil bindings and byte-for-byte unchanged saves after diagnostic calls.

### Isolated bounded choice analysis

- `narrative.analyze(session [, options])` explores the session's deterministic seeded presentation tree. At each node it runs one pre-phase/presentation, branches across every returned choice, runs its atomic effect/post-phase, and continues until terminal states or configured bounds. It does not enumerate alternate random draws, repeated presentations without choices, future external inputs or observer queues; the report names this scope and records whether its tree was completely exhausted.
- Defaults are `depth=3`, `max_nodes=100`, `max_steps=1000000`, `max_objects=200000`. Depth is limited to 0..32 and nodes to 1..10000; positive VM-instruction and graph-copy budgets are shared across the entire run. Lua graph traversal also rejects nesting beyond 256 levels. Exhausted bounds, errors and blocked operations make `complete=false` and include diagnostic paths/frontiers rather than silently dropping branches.
- Each branch gets a fresh Lua state, cloned worlds/session/registry, tables, closure upvalues, periods, events and history. Copying preserves reference aliases, cycles and shared upvalues within the branch, but shares no mutable Lua object with the original. Prototypes and parsed templates are immutable engine data and may be shared. World/session identity aliases and opaque tokens are remapped; subscriptions/queued closures are not copied.
- Built-in function identities are recorded when standard libraries open. Clones reinstall those functions in the new state. Arbitrary host-native calls, I/O/process/debug/coroutine operations, dynamic external loading and the shared `math.random` generator are blocked and reported. `require` can access already loaded cloned modules only. Explicit context-free session-method factories can be copied; unknown native delegates are never invoked. Unsupported native calls caught by Lua still mark the analysis incomplete. Deferred pure Lua callbacks run only in the clone; external operations remain blocked.
- The immutable report includes limits/depth/nodes/transitions/instruction counts, reached content, content not reached within this scope, dead ends, potential automatic-action cycles/action-budget exhaustion, frontier paths, errors, blocked effects and completeness. A node/action budget error is not represented as a proof of an infinite cycle or of global unreachability.
- `testAnalysis` verifies all returned choices at a branching node, closed terminal trees, unreachable-within-scope content, depth/node/object/VM limits, cyclic table and shared capture aliases, deferred callbacks, action-loop candidates, blocked host callbacks/output/shared randomness, and byte-for-byte identical live saves plus unchanged mutable Lua captures after every run. The conformance audit and bounded-search limits are recorded in `tests/narrative/README.md`.

### Final companion audit and hardening

- The requirement/error matrix in `tests/narrative/README.md` maps §§2–16 and milestones 9–18 to implementation and intended-diagnostic assertions. The integrated suite includes 54 extension cases and 13 narrative test groups. `narrative_policies` covers per-instance cooldown boundaries, independent repeatability, zero-weight/tier filling and deck-entry token lifetime. `narrative_effect_errors` covers contextual identifiers, indirect yields, reentrancy, forbidden registration/cross-world effects, invalid scheduling, deck reset and rollback cleanup.
- Dynamic no-yield scopes now cover inference/transactions through resumed child coroutines; Fiber yield and `coroutine.isyieldable()` agree and restore on every exit. Ordinary coroutine committed reads remain permitted. Template scanning skips quoted/long-bracket strings and line/long comments before counting query braces, with nested existence/escape tests.
- `narrative_scheduler_stress` checks 60 turns, opposite insertion orders, six save/restore checkpoints and recorded-command replay, with qualities, named periods, canonical action order, scheduled events and nested rollback. Portable unit tests additionally compare original/restored sessions for 32 turns and load across Lua states.
- Core stateful, aggregate, narrative and optional authoring support are separately identified with bounds and existing Lua harness/control-flow limits. Optional weighted text variants and custom display formatter registration are implemented in `registry.d`, `templates.d`, `session.d`, and `lib/narrative.d` and verified in unit/extension tests.

## Phase 8 — Performance and remaining Lua conformance

**Status: conformance work in progress; performance optimization deferred.**
The differential regression programs in `tests/regression` (15 programs, byte-identical output and checksum against C Lua, run by `make test-regression` and timed by `make benchmark`) are part of the milestone 20 gate; the one known difference and the slow stack-overflow unwind are listed in `tests/official/README.md`. Conformance scope for milestone 20 (owner decision): the official suite as a stock Lua 5.4 binary runs it (`T == nil`) with `gc.lua` excluded; an ltests-style `T` for `api.lua`/`code.lua` is out of scope. Milestone 20 has strict official-suite reporting, runner regression tests, core
differential coverage and compiler/runtime fixes; every executable official file
now passes (31 pass, 1 partial, 1 skipped, 0 fail). The compatibility backlog and
unsupported coverage are documented in [the official audit](tests/official/README.md),
so performance work in milestones 19 and 21–25 may be targeted. Known costs to
profile first: ~5 KB native stack per Lua call frame, ~2.4 s deep-recursion error
unwinding, `errors.lua` (~30 s) and per-instruction bookkeeping. Skipped and
partial files, and the conservative-GC emulation of weak tables/finalizers, keep
an unqualified full Lua conformance claim out of scope.

**Target:** no more than 2× C Lua 5.4 execution time on each agreed representative
core-Lua workload. Report a geometric mean as a summary, never as a substitute
for individual limits. Separate startup/parse/compile and steady execution
measurements. Use independent regression budgets for Datalog and narrative work,
which stock Lua cannot execute. This is an engineering target, not a present
capability or a guarantee for every possible program.

### Current evidence and limitations

- The October 9, 2026 exploratory run of existing binaries reported ratios of
  17.21× for recursive Fibonacci, 7.56× for numeric loops, 7.14× for array access,
  3.44× for the hash workload, 3.52× for strings and 7.53× for the sieve. Binaries
  were not rebuilt for that run; these are not calibrated release baselines.
- `benchmarks/bench.py` takes the minimum of three process timings including
  startup and parsing. Several programs lack result assertions, and slow ratios
  do not fail the command. Its hash workload also mixes formatting/concatenation
  with writes, so it does not isolate lookup cost.
- `make varis` already uses `-O3 -release`; unit targets default to `-g`, and the
  C Makefile defaults to `-O2`. Record actual compiler versions/build flags.
- The Datalog runner already checks functional success and machine-specific
  median suite regressions (default 25% plus 0.1 seconds), but includes startup
  and runner overhead. Preserve this gate while adding engine-level measurements.
- Source candidates include fresh register storage and argument/result copies
  per call, Fiber/world-context map operations, per-instruction bookkeeping, and
  hash `next` rescanning from the beginning. Treat these as profiling hypotheses.
- The October 9, 2026 release run records 31 pass, 1 partial, 1 skip, 0 fail and 0 timeout
  across 33 files, with a 240-second per-file limit. See [the official audit](tests/official/README.md)
  and its JSON evidence for current blockers. This supersedes the initial
  4 pass / 6 skip / 23 unsuccessful baseline. The skip is `gc` (excluded by decision); `all` is the one partial
  (run with `gc.lua` stubbed); `api`/`code` self-skip without `T`.
  Preserve the companion audit's forced-GC skips, bounded analysis scope and host
  replay obligations. File-level passes and skipped C/GC files do not establish
  complete language or library conformance.

### Milestone 19 — Reproducible benchmarks and baseline enforcement

**Depends on:** existing test and benchmark runners.

1. Rebuild both interpreters; record source identity (revision when available),
   compiler versions, flags, machine/OS, workload parameters and binary identity.
   Keep compilation outside timings and use an otherwise idle machine.
2. Add result assertions to every workload, warmups, alternating interpreter
   order, configurable 7–10 measured runs, medians and variability. Lengthen
   short workloads; report process startup separately and use a load-once timing
   harness for execution measurements. Measure parse/compile costs separately.
3. Add isolated calls, native calls, varargs/multiple returns, closures, integer
   and float loops, hash lookup/iteration, metamethods, coroutines and allocation
   workloads, plus representative mixed Lua programs. Freeze the target corpus
   before optimizing; document changes rather than dropping difficult cases.
4. Emit machine-readable results and fail on functional errors, crashes,
   timeouts or calibrated regressions. Keep the eventual 2× target separate
   from initial regression thresholds, since current ratios exceed it. Test
   statistics, failure handling and explicit baseline recording in the runner.
5. Preserve existing Datalog suite checks; add separate narrative and focused
   engine measurements for joins, recursion, snapshots and update/query cycles.

**Exit criterion:** repeatable, correctness-checked reports with metadata,
per-workload ratios and tested regression enforcement; no automatic baseline
rewrites. Noise policy and machine-specific calibration are documented.

### Milestone 20 — Official Lua baseline and conformance gates

**Depends on:** existing unit/extension gates. Correctness fixes precede performance optimization.

**Progress (October 9, 2026):** runner deadlocks and missing stderr diagnostics
are fixed; strict Make target exits, process exit codes, empty-filter rejection
and five runner regression tests are implemented. `make test-conformance-core`
compares deterministic core behavior with C Lua. Goto, precedence/associativity,
parenthesized result adjustment, floor division/modulo, shifts and integral-float
bitwise operations, lexical `_ENV`/load environments, debug upvalue operations,
const validation and basic close cleanup have targeted tests. Stateful tests
cover close-handler writes at transaction exits and rollback when a returned callee fails.
Proper tail transfers preserve upvalues, world context, analysis budgets and native
reentry without reusing suspended frames; native recursion faults become Lua stack
errors. Reader loading/modes, numeral parsing, function debug metadata, UTF-8
strict/lax byte algorithms, gmatch and gsub semantics have regression coverage.
Binary packing/unpacking and size calculations cover Lua 5.4 formats, endian/alignment controls and integer bounds; binary reversal preserves bytes. The official UTF-8, pattern, bitwise and packing files now pass. Lua collector tuning remains
unsupported; debug metadata/error attribution, binary chunks, coroutine/library/CLI gaps and
large-program failures remain. Coroutine running identity, normal/running status, thread-aware yieldability and error-object propagation have targeted and differential coverage; coroutine close now unwinds suspended/protected frames, retains unprotected errors until close, preserves replacement errors and prevents reentrant close. Call/return/tail/line/count hooks, thread-aware getinfo, source truncation and stack-based traceback are implemented with focused tests. Active/suspended local and vararg get/set APIs, parameter-name queries and direct call-site names are implemented. Temporary-slot fidelity, computed caller names, hook transfer/line attribution and weak-table GC behavior still require broader conformance work.  Generic for loops retain the fourth closing value and evaluate all iterator expressions; each loop iteration closes its scoped values/upvalues. Register growth preserves captured-local aliases. Milestone status: the gate is met — 26 official files pass, 2 pass with documented partial exclusions, 0 fail — and the remaining skips are documented as environment/collector limits.

1. The official Lua 5.4.9 runner is implemented (`tests/runner.d`, executable
   via `make test-official`) with an explicit conformance target. It records
   pass, fail and skip per test with diagnostics, reasons and timeouts; unsupported
   C harness facilities are distinguished from actual interpreter failures.
   Current baseline: 31 passed, 1 partial, 1 skipped, 0 failed, 0 timed out (skip: `gc`; partial: `all` with `gc.lua` stubbed; see [the audit](tests/official/README.md)).
2. Record existing failures and maintain the tracked requirements-to-tests backlog,
   including remaining close/debug/coroutine behavior. Fix supported-language gaps
   incrementally; known failures remain visible and new failures block changes.
3. Add deterministic differential tests against C Lua for supported arithmetic,
   numeric loops, tables/metamethods, calls/returns, closures, errors and
   coroutines. Include integer overflow/boundaries, mixed values beyond 2^53,
   NaN, binary strings, nil result slots and error cleanup. Compare contractual
   behavior without requiring unspecified table iteration order.
4. Run existing suites in debug and optimized assertion-enabled configurations,
   and Lua fixtures against the actual `-release` CLI. Make build settings
   configurable as needed: current CLI flags are hardcoded independently of
   `DFLAGS`. A release build that removes assertions is not sufficient evidence.
5. Preserve separate base, stateful, aggregate, narrative and optional authoring
   evidence, intended negative diagnostics and documented support limits.

**Exit criterion:** executable official-suite reporting and differential gates,
a reviewed pass/fail/skip baseline and an explicit remaining-fix backlog. This
milestone's gate is met for every executable official file; skipped (C test library, exact GC reachability, non-standard stress) and partial files are documented and keep an unqualified full-conformance claim out of scope. Performance milestones 21–25 may proceed.

### Milestone 21 — Profiles and ranked experiments

**Depends on:** milestones 19 and 20 baselines.

1. Collect optimized CPU samples with symbols, allocation counts/bytes, GC time,
   peak memory and executed instruction counts for representative workloads.
   Account for profiling overhead; validate timing on the normal release build.
2. Attribute costs to calls, dispatch, arithmetic, table/string operations,
   allocation/GC and extension bookkeeping. Inspect generated code where needed
   rather than assuming SumType matching or dispatch is the dominant cost.
3. Rank bounded experiments by measured contribution, expected benefit and
   semantic risk; retain profiles and before/after reports with each change.

**Exit criterion:** reproducible hotspot evidence and an ordered experiment list.
Milestones 22–24 may be reordered using that evidence.

### Milestone 22 — Reusable frames and argument/result transfer

**Depends on:** milestones 20 and 21.

1. Introduce reusable per-coroutine register/frame storage incrementally, with
   direct Lua-to-Lua argument windows and fixed-result destination writes.
   Avoid temporary arrays for common zero/one/two-result calls; retain a native
   API adapter and explicit ownership rules for retained argument/result data.
2. Handle storage growth without invalidating open upvalue pointers; close
   escaped upvalues correctly and clear inactive storage to avoid GC retention.
   Preserve suspended coroutine frames, native reentry and GC roots.
3. If profiles justify it, execute Lua calls through explicit frames in one
   dispatch loop. Preserve traceback information, multiple returns, varargs,
   protected calls, lexical worlds and exception/transaction cleanup.
4. Test recursion, captured locals across growth/reuse, native callbacks,
   coroutine suspension/resumption, GC stress and failures during nested calls.

**Exit criterion:** measured reductions in call allocation and runtime, no
unexplained memory regression, and all relevant conformance gates passing.

### Milestone 23 — VM bookkeeping and numeric execution

**Depends on:** milestone 21; coordinate with frame changes in milestone 22.

1. Reduce repeated Fiber/world-context map operations with a per-coroutine
   mechanism that retains lexical call-world metadata, aliases, helper captures,
   reentry and exception-safe restoration. Never substitute dynamic scoping.
2. Evaluate storing current PC on frames and deriving line information when
   needed; preserve debug/traceback attribution and any supported hooks.
3. Move uncommon extension work to slow paths only with evidence that transaction
   exits and analysis limits remain enforced through nested/native calls and
   resumed children. Do not simply disable bookkeeping for ordinary prototypes.
4. Optimize numeric loops and arithmetic using guarded fast paths and generic
   fallback. Verify integer/float loops, overflow boundaries, coercion and
   metamethods before accepting speedups on integer-only benchmarks.

**Exit criterion:** lower measured instruction/context cost with unchanged error,
debug, numeric, transaction, yield and analysis-budget behavior.

### Milestone 24 — Tables and bytecode efficiency

**Depends on:** milestones 20 and 21; prioritize from updated profiles.

1. Evaluate integer-index fast paths and constructor capacity hints. Eliminate
   repeated hash rescanning during full iteration while preserving permitted
   mutations during traversal and existing raw equality/hash semantics.
2. Reduce redundant moves/register pressure; evaluate immediate arithmetic and a
   small set of combined instructions for measured frequent sequences. Retain
   typed instructions and explicit compiler/VM interfaces.
3. Consider lookup caches only with a tested invalidation design for writes,
   metatables and `_ENV` changes. Measure memory costs and mixed workloads.
4. Cover sparse-table borders, integer/float keys, nil/NaN, raw reference equality,
   binary strings, metamethod fallback, debug locations and transaction exits.
   Combined instructions must preserve the defined analysis step accounting.
5. Audit any changed prototype/instruction representation against narrative
   fingerprints, persistence/reconstruction and analysis cloning; version
   incompatible identities explicitly rather than silently accepting old saves.

**Exit criterion:** measured table/compiler improvements, correct invalidation
and persistence behavior, and no semantic or memory regressions.

### Milestone 25 — Release tuning and final performance acceptance

**Depends on:** milestones 19–24 and tracked compatibility fixes required for the
agreed supported corpus.

1. Evaluate supported inlining, LTO and PGO settings after algorithmic changes.
   Record training workloads, compiler support and portable build defaults;
   validate gains on held-out workloads and the full correctness gates.
2. Enforce ≤2× C Lua execution time for every agreed core workload on the
   calibrated machine, using the documented noise/retry policy. Report startup,
   compilation, memory and per-workload results alongside the geometric mean.
   Keep Datalog/narrative regression thresholds and functional gates independent.
3. Run the full unit/extension suite, differential corpus, optimized/release
   checks and official harness. Publish remaining failures/skips with reasons;
   Phase 5 remains incomplete while its compatibility obligations remain unmet.
4. Investigate missed targets through profiles. Keep SumType, typed instructions
   and D GC unless evidence supports a separately reviewed architectural change.
   A custom value representation, table backend or JIT is not implicitly
   authorized by this milestone and is not a substitute for reporting misses.
5. Update README, AGENTS and benchmark/conformance documentation with reproducible
   evidence. Never relax thresholds or remove workloads to claim completion.

**Exit criterion:** agreed performance targets and regression gates pass with
published correctness/support evidence. If any target is missed, record the gap
and keep this milestone open; do not claim general Lua conformance from extension
success or from performance results.

### Phase 8 delivery discipline

Start with 19 and 20, then 21; use measured priorities for 22–24 and finish with
25. Each optimization lands independently with targeted semantic regressions,
full `make test`, the established conformance gates, and timing/memory evidence.
Preserve small reviewable changes and a correct fallback where specialization
needs one. New tests must exercise observable behavior rather than mirror the
optimization's implementation. No new targets or capabilities in this phase
should be documented as existing until implemented and verified.
