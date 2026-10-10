# Lua 5.4 — Narrative and Stateful Relational Extensions

**Proposed Companion Reference — Version 0.1**  
**Suggested file:** `lua54_narrative_extensions_spec.md`

## 1 — Status and Scope

This document extends *Lua 5.4 — Declarative Programming Extensions*, assumed to be distributed alongside it (hereafter, **the base specification**). It defines only additional syntax, changed requirements, and the `narrative` and `quality` libraries. All base-language rules remain in force unless explicitly amended here.

The words **must**, **must not**, **should**, and **may** indicate normative requirements, recommendations, and implementation freedoms respectively. The examples use the untyped dialect; names in relation declarations are column names, not types.

The additions fall into two groups:

1. **Stateful relational extensions:** named columns and keys, atomic updates, transactions, and optional aggregate goals.
2. **Narrative facilities:** content definitions, instantiated storylets and choices, automatic actions, decks, templates, event history, deterministic selection, persistence, and authoring diagnostics.

Narrative definitions do not alter Datalog's declarative semantics. Rule evaluation remains side-effect-free. A narrative effect is an ordinary Lua block run by the narrative scheduler inside a state transaction.

## 2 — Named Columns and Keyed Relations

### 2.1 — Named, untyped declarations

A relation declaration may name its columns:

```lua
relation location(entity, room)
relation quality(entity, name, value)
```

The declaration above is equivalent to an arity declaration of two or three, respectively, except that it also supplies column metadata. It does not impose types. Column names must be unique within a relation. Existing numeric-arity declarations remain valid.

### 2.2 — Keys

A relation may designate one or more columns as a key:

```lua
relation location(entity, room) key(entity)
relation quality(entity, name, value) key(entity, name)
```

For a keyed relation, no two **base tuples** may agree on all key columns while differing in any other column. Keys are checked using relational equality defined by the base specification, including support for `nil` as a key value. A key does not establish an ordering or a type.

A keyed relation is **extensional**: it may appear in rule bodies, but may not be the head of a rule. This restriction keeps functional updates distinct from inferred tuples. The key declaration is part of the relation schema and is copied into child-world snapshots. It is immutable once the relation is established. A conflicting redeclaration is an error.

A `fact` insertion of an identical tuple remains a no-op. Insertion of a different tuple with an existing key is an error, rather than an implicit overwrite.

### 2.3 — Replacement and deletion

The statement `set` atomically replaces the base tuple at a key:

```lua
set location(:player, :library)
set quality(:player, :coins, 15)
```

The last relation argument list must supply the complete tuple. If the key exists, the previous base tuple is removed and the supplied tuple inserted as one logical operation; otherwise the tuple is inserted. `set` requires a keyed relation. Identical replacement changes nothing.

The statement `delete` removes the base tuple identified by its key columns, in **declaration order**:

```lua
delete location(:player)
delete quality(:player, :coins)
```

Deleting an absent key has no effect. `retract` continues to remove an exactly specified base tuple as defined in the base specification.

### 2.4 — Numeric adjustment

The statement `adjust` performs a read–modify–write on a keyed relation's **single non-key value column**:

```lua
adjust quality(:player, :coins) by -10
```

The arguments preceding `by` specify all key values in key-declaration order. The existing value and adjustment must both be Lua numbers. The resulting value is computed with Lua 5.4 arithmetic and must satisfy the relation's runtime constraints, if any. The existing tuple must be present; an absent key is an error. `adjust` does not create a default value. All reads and updates are one logical operation.

For relations with more than one non-key column, the program must use `set` or a library update function instead. No relational or procedural operation may modify a derived tuple directly.

### 2.5 — Update visibility

Outside a transaction, each successful update is immediately observable by subsequent queries. Within a transaction, the visibility rules in §3 apply. Key-violation and arithmetic errors leave the attempted update unapplied.

## 3 — Transactions

### 3.1 — Syntax and world selection

```lua
transaction do
    adjust quality(:player, :coins) by -10
    fact owns(:player, :silver_key)
end

transaction (another_world) do
    set location(:player, :garden)
end
```

The optional world expression is evaluated once upon entry. Without it, the transaction uses the lexically selected default world. All mutations inside the transaction must target that world. Mutating a different world is an error.

### 3.2 — Atomicity

A transaction groups changes to base facts, keyed relations, and transaction-aware narrative state into a single atomic commit. On normal exit, changes are committed together. If an uncaught error exits the block, the transaction is rolled back before the error propagates. A `return`, `break`, or other non-error exit commits before control transfers.

The statement `rollback` exits the innermost transaction without committing and without raising an error. It is invalid outside a transaction.

Mutations of arbitrary Lua tables, file I/O, printing, and other external side effects are **not** rolled back. Programs requiring effects upon successful commit should use transaction-aware narrative APIs or defer external effects until the commit has succeeded.

### 3.3 — Read consistency

Reads in a transaction observe its entry snapshot plus all preceding writes by that transaction. Rules and derived relations queried inside a transaction are evaluated against that tentative state. No other coroutine may observe tentative changes.

A query iterator created inside a transaction captures the tentative state at the time of query construction. An iterator that escapes a committed transaction retains that snapshot. An iterator that escapes a rolled-back transaction becomes invalid and raises an error when used.

### 3.4 — Nesting and concurrency

A nested transaction on the same world is a savepoint: successful exit merges its writes into the enclosing transaction, and `rollback` discards only the nested writes. Starting a nested transaction on another world is an error.

The reference execution model serializes transactions on a world. Implementations supporting concurrent execution must provide equivalent serializable behavior or reject a conflicting commit. Transactions are not automatically re-executed following a conflict. Yielding from inside a transaction is prohibited.

### 3.5 — Permitted operations

Fact insertion/retraction, `set`, `delete`, `adjust`, and transaction-aware narrative commands are permitted. Registration or removal of relation schemas and rules inside a transaction is prohibited in this version. Transaction commit invalidates affected derived relations as required by the base specification.

## 4 — Aggregation Goals

### 4.1 — Forms

An aggregate goal binds a result variable from a finite subquery:

```lua
rule total_bonus(?person, ?total) :-
    person(?person),
    ?total = sum { ?bonus :
        equipped(?person, ?item),
        equipment_bonus(?item, ?bonus)
    }
```

The supported aggregate operators are `count`, `sum`, `min`, and `max`. The syntax is `?result = aggregate { expression : goal, ... }`; for `count`, the expression is omitted: `?count = count { goal, ... }`.

### 4.2 — Scope and grouping

Variables grounded by the surrounding positive goals and referenced inside an aggregate are **correlated inputs**. Variables introduced only inside the aggregate are local to it. The result variable is newly bound by the aggregate goal and may be used in a rule head or a subsequent constraint.

The aggregate ranges over distinct satisfying assignments of its local variables, not merely distinct expression values. Two different items carrying the same bonus each contribute to `sum`. `count` counts these distinct assignments.

`count` over an empty set yields zero and `sum` yields numeric zero. `min` and `max` over an empty set fail to bind a result, causing the aggregate goal to fail. `sum`, `min`, and `max` require suitable values and propagate arithmetic or comparison errors.

### 4.3 — Restrictions

Every correlated input must be grounded outside the aggregate. The aggregate's subquery must be safe and finite. Aggregate dependencies must point to lower strata; recursion through aggregates is disallowed in this version. An aggregate result counts as grounded for subsequent constraints and for the rule head, amending the base specification's rule-safety condition.

## 5 — Narrative Runtime Model

### 5.1 — Content and sessions

A **content definition** is an immutable registered storylet, choice, action, deck, template, or quality definition. Content definitions are stored in a registry associated with the Lua state, not in a logical world. World snapshots therefore do not copy content definitions.

A **session** contains a mutable logical world, a reference to the sealed content registry, a game-turn counter, a deck stack, choice and action history, scheduled events, a deterministic pseudorandom generator, and narrative event history. Multiple sessions may share the same registry while maintaining independent state.

A default registry is available as `narrative.registry`. Content registration is allowed during initialization. Calling `narrative.seal()` validates references, freezes the registry, and assigns a content-version identifier. Creating a session seals the registry if it has not already been sealed. Registration after sealing is an error.

Content identifiers are symbols and must be unique within their kind; `:walk` denotes the storylet declared by `storylet walk(...)`. A storylet, deck, and action may have the same symbol without colliding. Choice identifiers must be unique within their enclosing storylet.

### 5.2 — Session interface

`narrative.new(world)` constructs a session with `world`, the sealed default registry, turn zero, initial deck stack `[:default]`, and a deterministically initialized RNG whose seed must be supplied by the host or explicitly set via `session:seed(integer)` before random selection.

`session:present()` completes the pre-choice action phase and returns a presentation containing zero or more rendered storylet instances and their eligible choices.

`session:choose(choice_token)` revalidates the referenced storylet and choice, executes its effect transaction, advances the turn on success, and completes the post-choice action phase. A stale or invalid choice produces a defined `STALE_CHOICE` error without effects or turn advancement.

`session:world()`, `session:turn()`, and `session:active_deck()` expose the corresponding session state. These accessors do not mutate state.

No session command may be called recursively from an active choice or automatic-action effect, except for explicitly permitted transaction-aware operations described below.

## 6 — Storylets

### 6.1 — Definition

A storylet defines a set of potential narrative instances by means of an availability query. For example:

```lua
storylet travel(?from, ?to)
    when {
        location(:player, ?from),
        traversable(?from, ?to)
    }

    deck :exploration
    priority 10
    weight 2
    title "Walk to {to}"
    text [[You take the road from {from} to {to}.]]

    choice proceed
        title "Continue"
        effect do
            set location(:player, to)
            narrative.emit(:travelled, from, to)
        end
    end
end
```

At least one choice is required. The storylet's header variables are **parameters**. All parameters must be grounded by its `when` query. Each distinct parameter assignment is a different storylet instance; additional query variables are existential and are not exposed to content or effects unless declared as parameters.

### 6.2 — Content fields

A storylet may specify `deck`, `priority`, `weight`, `cooldown`, `repeatable`, `title`, and `text`, at most once each, before its choices. Defaults are `deck :default`, `priority 0`, `weight 1`, `cooldown 0`, and `repeatable true`. `title` is required; `text` defaults to the empty template.

Numeric and Boolean field expressions are evaluated once when the definition is registered and then frozen. `priority` must be an integer, `weight` must be a finite nonnegative number, and `cooldown` must be a nonnegative integer number of turns. A zero weight excludes the instance from random draws but does not make its `when` query false.

`repeatable false` prevents an instance from appearing after a choice from it has successfully committed. `cooldown N` prevents its selection while fewer than `N` completed turns have elapsed since its last successful choice. These policies are applied to each bound instance, not to the storylet definition as a whole.

### 6.3 — Instance identity

An instance is identified by its content identifier and a canonical encoding of its parameter bindings. Bindings used as instance keys must be serializable scalars: `nil`, booleans, integers, finite floats, strings, and symbols. Mutable tables, functions, threads, and userdata are not permitted as instance-key values.

Instance identity does not depend on query enumeration or hash-table iteration order. Instantiated bindings are immutable. Instances carry the world version from which their availability was evaluated.

## 7 — Choices and Effects

### 7.1 — Choice definitions

A choice belongs to a storylet. A choice may have its own parameters and `when` query:

```lua
choice buy(?item, ?cost)
    when {
        for_sale(?item, ?cost),
        quality(:player, :coins, ?balance),
        ?balance >= ?cost
    }
    title "Buy {item}"
    effect do
        adjust quality(:player, :coins) by -cost
        fact owns(:player, item)
    end
end
```

The storylet's parameter bindings are available to the choice's query as grounded inputs. New choice parameters must be grounded by the choice's query. A choice without `when` is unconditionally available when its storylet is available.

Each combination of choice ID and choice-parameter bindings yields a distinct choice instance. A choice may specify a `title` and an optional `text` template. Its `effect do ... end` block is required.

### 7.2 — Binding into Lua

Storylet and choice parameters become read-only lexical Lua locals, **without** their `?` prefixes, inside title/template interpolation and choice-effect blocks. A parameter shadows any ordinary Lua local of the same name in that nested context. Unexposed existential query variables do not become Lua locals.

All unqualified relational references in a narrative availability query or effect are resolved against the **owning session world**, regardless of the lexical default world at content registration. The compiler supplies this session world as an implicit captured context for the content definition; explicit cross-world effects remain prohibited. This is an intentional exception to the base specification's rule that ordinary standalone closures retain their lexical default world.

Values in templates and effects are those from the selected instance, not values re-evaluated by re-running the original expression syntax. The syntax `?name` remains restricted to declarative goals and guards.

### 7.3 — Execution and revalidation

A presentation is not an authorization to apply effects indefinitely. `session:choose(token)` begins a transaction, reruns the chosen storylet and choice eligibility checks against the current transaction snapshot using the **same parameter bindings**, and verifies deck, cooldown, and repeatability conditions. If any condition fails, it raises `STALE_CHOICE` and commits nothing.

Otherwise the effect block runs as ordinary Lua in that transaction. Its fact and narrative-state changes commit atomically. The instance-completion record commits atomically with the effect changes. Upon successful commit the engine advances the turn by one and starts post-choice actions.

Errors from the effect roll back all transaction-aware changes and leave the turn unchanged. External Lua side effects are not undone. Effects may not yield, register content, register rules, or initiate presentation or choice resolution.

## 8 — Automatic Actions

### 8.1 — Definition

An automatic action is an effectful command selected by the narrative scheduler, not a Datalog inference rule:

```lua
action poison_warning(?player)
    when {
        quality(?player, :poison, ?n),
        ?n >= 10,
        not warned(?player)
    }
    phase :post
    priority 100
    once_per :game
    effect do
        fact warned(player)
        narrative.emit(:poison_warning, player)
    end
end
```

Action parameters follow the same binding and instance-identity rules as storylets. The default phase is `:post`, the default priority is zero, and the default execution limit is `once_per :turn` per action instance.

### 8.2 — Scheduling

The **pre-choice phase** runs immediately before producing a presentation. The **post-choice phase** runs after a successfully committed player choice and before the next presentation. In each phase, the scheduler:

1. Evaluates eligible instances from a consistent current world state.
2. Excludes instances blocked by their once-per policies.
3. Selects the instance with highest priority, breaking ties by canonical content ID and then canonical bindings.
4. Revalidates and executes that instance in an atomic transaction.
5. Records its execution and reevaluates eligibility from the new committed state.

This repeats until no instance is eligible. A configurable maximum number of actions per phase (default 1,000) prevents unbounded loops; reaching it raises `ACTION_LIMIT`, preserves already committed earlier actions, and does not silently continue.

### 8.3 — Once-per periods

`once_per :turn` permits at most one execution of an instance during a numbered turn. `once_per :game` permits one execution during a session. Other period symbols require a value registered through `session:set_period(period_symbol, serializable_value)`; an action may execute once for each distinct current period value. Period values are saved with the session. `once_per :always` removes suppression and should be used only for actions that make themselves ineligible.

Action eligibility and effects must not rely on the order or number of Datalog goal evaluations. Randomness and mutations belong solely in effects and the scheduler.

## 9 — Decks and Presentation

### 9.1 — Declaration

```lua
deck :exploration { draw = 3, replacement = false }
```

A deck is a named collection of storylet definitions declaring that deck. The implicit `:default` deck has `draw = 1` and `replacement = true` unless explicitly configured. `draw` must be a positive integer; `replacement` is a Boolean.

### 9.2 — Deck stack

Every session maintains a deck stack, initially containing `:default`. The active deck is the top entry. Inside a transaction-aware effect:

```lua
narrative.push_deck(:conversation)
narrative.pop_deck()
narrative.replace_deck(:combat)
```

`pop_deck` cannot remove the last stack entry. Deck changes take effect on the next presentation, are included in the transaction, and are saved. Each push creates a fresh deck-entry instance with independent draw history.

### 9.3 — Selection

At presentation, the engine enumerates eligible storylet instances in the active deck, filtering cooldown and repeatability. Instances with greater priority are considered before those with lower priority. Up to `draw` instances are sampled without duplication from the highest available priority tier; additional tiers fill any remaining slots. Within a tier, weights determine selection probabilities.

With `replacement = false`, instances already drawn during the current deck-stack entry are excluded until that entry is popped or explicitly reset with `narrative.reset_deck()`. With `replacement = true`, previously drawn instances may be selected on subsequent presentations, but not twice within one presentation. A deck may produce an empty presentation.

A presentation's storylet instances and choice instances have stable order and opaque choice tokens. The host must pass back the exact token; it must not construct tokens or infer identity from display text.

### 9.4 — Determinism

Before weighted selection, candidates are put in a canonical order by priority, content ID, and binding encoding. Only the session's deterministic RNG is used for draws. Random state updates are part of session state and are saved. The specific PRNG and sampling algorithm are implementation-versioned so that replay with the same runtime version and seed can reproduce selections.

## 10 — Narrative Templates

### 10.1 — Template fields

`title` and `text` fields contain template strings. A template is parsed when its content definition is registered. Lua strings themselves are unchanged; interpolation occurs only in declared template fields and explicit template-library calls.

`{name}` inserts the display form of a bound storylet or choice parameter. `{{` and `}}` produce literal braces. An unknown placeholder is a content-validation error. Nil values render as the empty string unless an explicit formatter is registered.

Symbols render through `narrative.display(value)`; initially this uses `logic.symbolname(value)` for symbols and `tostring(value)` for other primitive values. Authors may register stable display labels with `narrative.name(:library, "the Library")`.

### 10.2 — Conditional templates

```lua
text [[
    The guard examines your papers.
    {#if query trusted_by(:guard, :player)}
        "Welcome back."
    {#else}
        "What is your business?"
    {/if}
]]
```

The condition is a relational existence test, **not** the Lua truthiness of the query iterator. It is true if the query has at least one result. Conditions may reference the current immutable parameter bindings and read only the same presentation snapshot. Nested conditionals are allowed. All template queries obey the base specification's safety and purity rules.

Template rendering is read-only. It may not change the world or advance the session RNG. Optional weighted text variants are selected by the narrative runtime before rendering and their selection is recorded in the session's deterministic sequence.

## 11 — Qualities

### 11.1 — Library model

A quality is a named piece of narrative metadata associated with the base tuple relation `quality(entity, name, value) key(entity, name)`. Qualities are not a separate logical truth model.

```lua
quality.define(:coins, {
    initial = 0,
    minimum = 0,
    maximum = 1000,
    visible = true,
    label = "Coins"
})
```

`quality.define` registers immutable metadata with the narrative content registry. It does **not** silently insert initial facts for every entity, since that would make the set of entities ambiguous.

### 11.2 — Initialization and access

`quality.initialize(entity, name [, world])` inserts the declared initial value if that quality tuple is absent; if already present, it has no effect. The world defaults to the lexically current world when called from an effect, otherwise the global world. `quality.get(entity, name [, world])` returns the present value or `nil` if absent. It does not substitute a default, preserving consistency with Datalog queries.

`quality.set(entity, name, value [, world])` and `quality.add(entity, name, delta [, world])` perform the corresponding keyed `set` and `adjust`, applying metadata constraints. A constraint violation raises an error; values are not silently clamped. `quality.add` requires an existing initialized value. All quality mutations inside narrative effects participate in the active transaction.

### 11.3 — Derived qualities

Qualities inferred by rules should be represented using separate derived relations. `quality` itself is keyed and extensional, so rules cannot write to it. Aggregate rules may compute totals or effective ratings from quality and equipment relations without modifying base qualities.

## 12 — Events, Time, and Deferred Commands

### 12.1 — Event emission

Inside an effect, `narrative.emit(kind, ...)` appends an event to the session's append-only history as part of the surrounding transaction. `kind` must be a symbol, and event arguments must be persistently serializable values. Events are assigned monotonically increasing sequence numbers at commit and carry the session turn at which they occurred.

The runtime exposes committed history through a read-only relation `narrative_event(sequence, turn, kind, args)`, in which `args` is an immutable sequence value. The relation may be queried but not changed through `fact`, `set`, `retract`, or `delete`. For conveniently queryable domain-specific state, effects should also insert appropriately shaped ordinary facts.

### 12.2 — Time

A completed player choice advances the game turn by one. Automatic actions, presentations, and queries do not independently advance the turn. Periods such as game days are explicitly maintained using `session:set_period`, rather than inferred from real-world wall-clock time.

### 12.3 — Scheduled events

`narrative.schedule(kind, args, after_turns)` schedules a named event for a future turn. `after_turns` must be a nonnegative integer; events due at the current turn are processed after the current effect commits, never during Datalog evaluation. Due scheduled events are processed before automatic actions in the post-choice phase (or, if due at initialization, before pre-choice actions), in due-turn and insertion-sequence order. They are persisted with the session. A scheduled event may invoke a registered narrative handler in its own transaction.

An implementation must impose an execution budget on immediate chains of scheduled events, analogous to the automatic-action limit.

### 12.4 — External effects

`narrative.defer(function_value)` requests a callback after successful transaction commit. Deferred callbacks are not part of the logical transaction and cannot be rolled back after invocation. They run only after commit and never after rollback. Persistent games should prefer named, serializable events over anonymous deferred callbacks.

## 13 — Save Files and Replay

### 13.1 — Save boundaries

A session may be saved only when no transaction, automatic action, choice effect, or presentation evaluation is active. `session:save()` returns a versioned serializable representation; `narrative.load(saved, world_factory)` restores it after validating the installed content and schema versions.

A save contains base tuples, world identification and version metadata, narrative turn, deck stack and draw history, completed-instance and once-per history, named period values, scheduled events, committed event history, RNG state, and the content-registry version. Derived tuples and temporary query iterators need not be serialized; they are reconstructed when needed.

### 13.2 — Restoring rule definitions

The content registry and world rule programs must be loaded from versioned authored code before saved base facts are restored. Arbitrary runtime-created rule closures and local relations are not serialized. A world containing non-reconstructible runtime rules is not eligible for portable save unless the host supplies an explicit reconstruction protocol.

On schema or content-version mismatch, loading must fail with a descriptive error unless the host provides a compatible migration. Silent reinterpretation of renamed or reordered predicates is prohibited.

### 13.3 — Serializable values

The portable save format supports `nil`, booleans, integers, finite floats, strings, symbols, and explicitly supported immutable sequences or records composed of such values. Ordinary mutable tables, Lua functions, coroutines, and userdata are not portable by default. A save must report unsupported values rather than silently omitting them.

A deterministic replay log may record the initial seed, content and schema versions, player choice instance keys, and external inputs. Given the same engine version, content, initial state, and input sequence, replay must reproduce committed logical state and narrative selections. External I/O and untrusted impure Lua code are outside this guarantee.

## 14 — Change Subscriptions and Authoring Diagnostics

### 14.1 — Relation-change subscriptions

The optional API `narrative.observe(world, relation_name, callbacks)` registers `on_enter` and `on_leave` callbacks receiving tuples added to or removed from the relation's **committed visible set**. Subscriptions are dispatched after commit, in canonical relation-and-tuple order. They never execute from within Datalog inference.

Callbacks may enqueue later narrative commands but must not synchronously mutate the notifying world. Subscription definitions are re-established by authored code and are not serialized as closures. Implementations may compute visible-set deltas by full differencing or incremental maintenance.

### 14.2 — Explanation facilities

`narrative.explain(session, storylet_id [, bindings])` returns a structured diagnostic identifying eligibility goals and which ones succeed or fail, together with any cooldown, deck, or once-per exclusion. A complete explanation of arbitrary recursive query failure is not required. Diagnostic output must not alter logical state or consume RNG draws.

### 14.3 — State-space analysis

`narrative.analyze(session, options)` may explore choices using cloned world and session snapshots, reporting unreachable content, dead ends, and automatic-action cycles. Its search depth and completeness are implementation-defined and must be reported. Any analysis run must leave the original session unchanged.

## 15 — Added Grammar

The following productions extend the grammar in the base specification. `exp`, `block`, `Name`, `goal`, `relref`, and Lua string/table productions retain their existing meanings. A `name-list` is a comma-separated list of column identifiers.

```ebnf
namedrelstat    ::= 'relation' Name '(' name-list ')' [ 'key' '(' name-list ')' ]

setstat         ::= 'set' relref '(' [expargs] ')'
deletestat      ::= 'delete' relref '(' [expargs] ')'
adjuststat      ::= 'adjust' relref '(' [expargs] ')' 'by' exp

transactionstat ::= 'transaction' [ '(' exp ')' ] 'do' block 'end'
rollbackstat    ::= 'rollback'

aggregategoal   ::= logicvar '=' aggregate '{' [ exp ':' ] goal { ',' goal } '}'
aggregate       ::= 'count' | 'sum' | 'min' | 'max'

storyletdef     ::= 'storylet' Name '(' [ params ] ')' whenclause
                    { storyletfield } choicedef { choicedef } 'end'

params          ::= logicvar { ',' logicvar }
whenclause      ::= 'when' '{' goal { ',' goal } '}'

storyletfield   ::= 'deck' symbol
                  | 'priority' exp
                  | 'weight' exp
                  | 'cooldown' exp
                  | 'repeatable' exp
                  | 'title' string
                  | 'text' string

choicedef       ::= 'choice' Name [ '(' [ params ] ')' ]
                    [ whenclause ] { choicefield }
                    'effect' 'do' block 'end' 'end'

choicefield     ::= 'title' string | 'text' string

actiondef       ::= 'action' Name '(' [ params ] ')' whenclause
                    { actionfield } 'effect' 'do' block 'end' 'end'

actionfield     ::= 'phase' symbol
                  | 'priority' exp
                  | 'once_per' symbol

deckdef         ::= 'deck' symbol tableconstructor
```

Here `symbol` refers to a symbol literal, and `string` to an ordinary Lua string literal (including long-bracket strings). Storylet and choice fields must precede nested choices and effect blocks respectively. The complete grammar imposes the required fields and uniqueness restrictions specified in the preceding sections.

`set`, `delete`, `adjust`, `transaction`, `rollback`, `storylet`, `choice`, `action`, `deck`, `when`, `effect`, `phase`, `priority`, `weight`, `cooldown`, `repeatable`, `title`, `text`, `key`, `by`, and aggregate names are contextual keywords. They retain their ordinary identifier meanings outside the corresponding syntactic positions. Existing Lua 5.4 programs not using the added forms retain their behavior.

## 16 — Conformance and Error Conditions

A conforming implementation of the **core stateful extensions** must enforce key uniqueness, atomic replacement/deletion/adjustment, transaction rollback and read consistency, and the specified world isolation. An implementation claiming **narrative extension** conformance must additionally implement storylet binding, transactional choice execution, automatic-action scheduling, deterministic deck selection, immutable presentation tokens, and portable save validation.

At minimum, the following are errors:

- Conflicting key declarations, duplicate named columns, or a rule head targeting a keyed relation.
- A conflicting `fact` insertion into a keyed relation.
- `set`, `delete`, or `adjust` with invalid arity, an unsuitable relation, or an invalid key/value.
- `adjust` on an absent key or a nonnumeric value.
- Cross-world mutation, prohibited nesting, yielding, or rule registration during a transaction.
- Unbound storylet/choice/action parameters and nonserializable instance identifiers.
- Duplicate content identifiers, unknown decks or placeholders, and invalid content options.
- A stale choice token, action budget exhaustion, or invalid transaction effect.
- Unsupported save values, non-reconstructible runtime rules, and incompatible content or schema versions.

Error messages should include source location where available, content/relation identifiers, and the failing constraint. Unless otherwise stated, invalid content fails at registry sealing, invalid updates fail at execution, and invalid query structures fail at their normal compile or registration stage.

---

**End of Companion Reference — Version 0.1**
