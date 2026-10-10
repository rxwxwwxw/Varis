# Saltmarsh Light — Review and Proposed Amendments to the Narrative Extensions

**Status:** proposed changes to *Lua 5.4 — Narrative and Stateful Relational Extensions*, v0.1. This document is a delta, not a replacement. It assumes the earlier untyped declarative specification also applies. The reviewed sample is `sample-game.zip` (files rooted at `sample-game/`).

## 1. Conformance target

The immediate target is to run `sample-game/main.lua` interactively and `sample-game/tools/check.lua` as an author test. **No scenes, passage system, multimedia renderer, text input, or general type system is necessary for that target.** The game is source-only; no compatible `varis` executable was included in the archive, so these findings are from static review, not a successful playthrough.

The existing spec already provides most important concepts: world snapshots, transactions, keyed relations, query-driven storylets, choices, automatic actions, decks, template conditions, events, and save/load. The amendments below clarify or add missing observable behavior.

## 2. Required specification amendments

### 2.1 — Bind content to a session's world when the session is created (§5, §6, §7)

Content modules register before `G.build_world()` creates schemas and rules (`game.lua:20–35`, `world.lua:13–136`). Therefore `narrative.seal()` **must not require named relations in content queries to exist in the global world at registration time**. Content query plans may be stored as relocatable, symbolic references with checked arities. When `narrative.new(world)` or `narrative.load(...)` attaches the registry to a concrete world, the runtime must resolve and validate required relation names, arities, and schemas in that world. Failure is a deterministic schema-compatibility error. The compiler must preserve the distinction between registration-time Lua captures and execution-time session-world resolution. The content registry remains independent of the world.

### 2.2 — Install or require the `quality` schema (§11)

The standard quality library operates on `quality(entity, name, value) key(entity, name)`. The spec must say **who creates this keyed relation in each world**. Prefer explicit declaration in authored world construction:

```lua
relation quality(entity, name, value) key(entity, name)
```

Alternatively, the runtime may install exactly this relation in `narrative.new(world)` and make conflicting definitions errors. It must not silently treat an implicitly established, unkeyed `quality/3` relation as keyed. `world.lua` currently references `quality/3` in rules and initializes qualities but does not explicitly declare its keyed schema.

### 2.3 — Define the complete API surface actually used (§5, §10–§14)

The following calls exist in the sample but have no complete normative contract (some are mentioned only narratively):

| Call | Suggested contract |
| --- | --- |
| `narrative.seal(version)` | Optional stable authored version string; validate/freeze registry, also store a deterministic content fingerprint. |
| `narrative.program(world, version)` | Associate a deterministic authored rule-program identifier with a world, validated at load. |
| `session:seed(integer)` | Allowed before first random use, reproducible PRNG initialization; changing mid-session either prohibited or explicitly logged. |
| `session:limits(actions, events)` | Set positive integer scheduler budgets, with documented ordering and errors. |
| `narrative.on(kind, handler)` | Register a handler at initialization, using `handler(world, kind, immutable_args)` and a transaction around invocation. Emitting events inside that handler is permitted. |
| `narrative.sequence(...)` | Construct an immutable, portable sequence; define indexing, serialization, equality/hash semantics. |
| `narrative.formatter(type_name, fn)` | Register a pure, deterministic template display formatter, including one for `nil`. |
| `narrative.observe(world, name, callbacks)` | Return an unsubscribe function; define tuple form and dispatch ordering. |
| `narrative.flush(world)` | Dispatch queued post-commit notifications exactly once, or explicitly make it unnecessary if notifications dispatch automatically. |
| `session:replay_log()` | Return a canonical input log with a documented `inputs` collection and version metadata. |
| `narrative.load(encoded, world_factory)` | Reconstruct authored program, verify versions/schema, restore saved state, and return a session. |
| `session:save()` | Return portable encoded bytes (e.g., a string), rather than an unspecified Lua object. |

Document the shape of `session:present()` and `narrative.explain()` / `narrative.analyze()` results at least to the extent that `main.lua` and `tools/check.lua` access them (`storylets`, `id`, `bindings`, `choices`, `token`, `instances`, `nodes`, `complete`, and `dead_ends`). Analysis may report incomplete searches; it must not invoke real-world deferred callbacks or mutate the live session.

### 2.4 — Establish an active narrative context without dynamic Lua scoping (§7.2, §11.2, §12)

While a choice effect, automatic-action effect, or registered scheduled-event handler runs, there is an **active narrative context** containing `(session, world, transaction)`. The unqualified `fact`, `query`, `set`, `delete`, and `adjust` constructs compiled inside dedicated effect blocks use this world, and `quality.get/set/add/initialize` default to this active transaction world within effects and event handlers. Outside such a context, normal lexical-world rules continue to apply. Ordinary Lua closures must not have their lexical environments silently rewritten. Handlers can use the explicit `world` argument or context-aware library calls. Deferred callbacks execute after commit, outside the transaction and with no implied authority to mutate the session.

### 2.5 — Transaction-aware periods and the scheduler (§8.3, §12.2)

Add `narrative.set_period(period_symbol, serializable_value)` within an active narrative transaction. The updated value commits or rolls back with the transaction, is included in saves and replay, and becomes visible to automatic-action suppression before choosing the next action instance. `session:set_period` remains a host-only operation at idle boundaries. Do not infer period values automatically from `quality(:world, :day, ...)` without an explicit configuration.

This removes the stale `:day` period caused by `G.sync_periods()` running after `session:choose()` has already processed post actions (`content/events.lua:29–38`, `game.lua:43–47`, `main.lua:106–109`).

### 2.6 — Pinned storylets and independent display ordering (§9)

Allow a storylet to specify:

```lua
sticky true
order 100
```

A sticky eligible storylet must be included on every presentation of its active deck, does not consume a `draw` slot, and is not suppressed by non-replacement draw history. It remains subject to its declared eligibility, repeatability and cooldown unless those are deliberately changed. `priority` controls candidate selection; `order` is a separate integer controlling rendered order after selection. Sort ties canonically. Sticky entries must not consume RNG.

This is essential for `leave_market` (`content/market.lua:54–63`). Under the v0.1 rules, priority 100 ensures its first draw but does **not** stop non-replacement history from excluding it on the next presentation. Merely raising priority is not sufficient. `end_talk` may use the same feature for consistency.

Additionally `session:present()` should cache the stable presentation within an unchanged decision boundary. Repeated requests for that presentation must not advance the RNG or consume another non-replacement draw. Invalidate it on committed world/session changes or successful choice resolution.

### 2.7 — Stable action instance identity distinct from all variable bindings (§8)

An automatic action with header parameters currently uses those parameters as part of the once-per instance key. Add a supported way to define a *coarser* suppression key (e.g., `once_per :game key()`), or require authors to encode a one-shot flag in the availability rule.

`storm_brews(?h)` (`content/events.lua:85–93`) is otherwise eligible at different hours and can schedule the same storm repeatedly despite `once_per :game`. The existing specification is internally consistent; this is a game-authoring problem, not a reason to silently redefine the meaning of `once_per :game`. A v0.1-compatible game fix is:

```lua
when {
    quality(:world, :day, ?d), ?d >= 2,
    quality(:world, :hour, ?h), ?h >= 12, ?h < 20,
    not flag(:storm_scheduled)
}
-- effect:
fact flag(:storm_scheduled)
```

A formal keyed-suppression feature is preferable for larger games, but not needed merely to run this sample.

### 2.8 — Portable saves and canonical replay (§13)

`narrative.load(encoded, world_factory)` must reconstruct schemas and rules from the authored factory, then **replace** the factory's seed base tuples with the saved base tuples before constructing the restored session state. It must not merge a save into newly initialized starting facts. The host must not invoke ordinary fresh-game initializers after loading.

Version checks must distinguish authored rule program version, content registry version, and serialized-state schema version. Closure instances and D pointers are not portable save data. Event sequence counters, action-history keys, deck-entry identities, RNG state, periods, and choice presentation state must restore consistently.

The sample asserts byte-identical `restored:save() == saved` (`tools/check.lua:77–79`). This is *stronger* than the v0.1 requirement for a portable save. Either make the encoding canonical (stable tuple order, key order, integer/float normalization, no volatile serialization timestamp, canonical history order) or change the test to compare normalized decoded state and replay. Explicitly choose one contract.

### 2.9 — Committed event delivery (§12, §14)

Provide `session:events_since(sequence)` as an ordered read-only cursor or array over committed narrative events. It must be indexed by event sequence and must not scan the full history. `session:present()` may include the events since the preceding delivery cursor; the API must document whether delivery advances that cursor. `narrative_event` remains available for Datalog queries.

Define the exact ordering between transaction commit, derived-relation refresh, scheduled-event handling, automatic actions, observer notification, deferred callbacks, and presentation. Prefer post-commit event dispatch after all state updates are visible, with observers prohibited from synchronously mutating the notifying world. Queued callbacks must not be replayed from loaded history unless explicitly requested.

### 2.10 — Complete template syntax and RNG policy (§10)

The sample uses `{#variant N}...{/variant}` in `content/explore.lua`, `content/market.lua`, and `content/keeper.lua`. Define its grammar: a collection of adjacent weighted variants in one block, positive finite weights, optional nesting restrictions, deterministic selection exactly once per presentation/instance/field, and no RNG consumption by diagnostic or exploratory reads. Register display formatters and symbol labels before registry sealing; formatter calls must be read-only and stable for the presentation snapshot.

## 3. Corrections needed in the sample game even with amended semantics

1. **`world.lua`**: explicitly declare keyed `quality/3`, unless the runtime guarantees it by construction.
2. **`content/market.lua:54–63`**: mark `leave_market` sticky; otherwise the player may be trapped on the market deck after making the first selection.
3. **`content/events.lua:85–93`**: add a `:storm_scheduled` flag or stable per-definition once-per key to prevent repeated storm scheduling.
4. **`content/keeper.lua:21–41`**: `topic_key` has `repeatable false`, so choosing `refuse` permanently removes the opportunity to obtain the key, even if the player later changes their mind. Remove storylet-level repeat suppression and rely on `not told(:key)`, or introduce choice-specific history.
5. **`content/market.lua:30–37`**: `haggle` can be offered at resolve 0; the effect decrements a bounded quality to -1 and fails. Add a resolve prerequisite or opt into explicit clamp semantics.
6. **`content/events.lua:85–90`**: the `after_turns` calculation uses game turns as a proxy for clock hours. `rest` advances the hour itself (`content/explore.lua:112–116`) and the clock action also advances it. Either schedule against canonical in-game time or clarify that the storm intentionally depends on choice count.
7. **`main.lua` / `game.lua`**: replace the manual period synchronization and linear scan of `narrative_event` once the new APIs exist. The existing host's quit/save/load loop can otherwise remain a simple console UI.
8. **`tools/check.lua`**: if byte-identical saves are not guaranteed, compare parsed/canonical state instead; consider matching choice-specific parameter bindings in `pick`, not just storylet bindings.

## 4. Useful optional extensions, not blockers for this game

- `adjust ... by ... clamp` and `quality.add(..., {clamp=true})`, with bounds still enforced by default.
- `expose ?variable` in storylets with uniqueness validation and a clear choice about whether changing an exposed value invalidates previously issued tokens.
- `?result := pure_expression` as a range-restricted **nonrecursive** binding goal. Do not allow unrestricted recursively computed values: `n(?y) :- n(?x), ?y := ?x + 1` has an infinite ascending domain even though `?x` is bound. A simple disjunction such as `night` can already be written using `where (?h >= 20 or ?h < 6)` without extending goal grammar.
- `exists relation(...)`, disabled choices with authored reasons, `session:choose_by`, content metadata, and an explicit terminal session state via `narrative.finish(:ending_id)`.
- Indexed, semi-naive, version-cached derived relations. Cache queries across one presentation snapshot, but invalidate dependency-affected caches after committed writes. This is a major scalability requirement, not a prerequisite for the tiny sample.
- Optional `passage`/`scene`/beat-stream facilities, undo, media commands, inline links, text input, localization, and a D-side embedding API for Twine/Ren'Py-class games. **These are distinct future targets, not necessary to play Saltmarsh Light.**

## 5. Acceptance tests to add

1. Registry seals successfully before a world exists; constructing a session binds content queries against that world's schemas.
2. A fresh quality world can initialize, set, adjust and query keyed `quality/3` without accidental unkeyed substitution.
3. Consecutive `present()` calls for an unchanged decision give the same options/tokens and do not consume draws or RNG.
4. `leave_market` remains available after purchase/rumour while the deck has `replacement=false`.
5. A post-phase midnight action updates `:day` before once-per-day wage scheduling is evaluated.
6. One storm is scheduled even as the clock visits several eligible hour values.
7. Refusing the key leaves a route to later acceptance (if that is the intended game design).
8. A failed `haggle` effect does not advance a turn or partially change state.
9. Event handlers can query the current session world and emit new committed events; event callbacks and deferred side effects do not fire during dry-run analysis.
10. Save/load round-trip restores base facts, decks, RNG state, periods, event sequences, and scheduler suppression; no starting facts are accidentally reintroduced.
11. Observation and event cursors deliver each committed notification once in a documented order, and can be detached after a load.
12. The scripted walkthrough in `tools/check.lua` completes; a real terminal session can reach each ending without being stranded by deck selection.

## 6. Recommended implementation sequence

First specify registry-to-world binding and the quality-schema contract. Then stabilize transactional period updates, immutable presentation caching, pinned storylets, and event/handler APIs. Afterward implement canonical saves, snapshots, and replay, followed by authoring tools. The other proposed DSL syntax is best added after this executable core is tested with the sample game.
