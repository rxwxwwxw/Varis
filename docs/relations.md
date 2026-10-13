# Varis Reference Manual — Relations and State

[Contents](README.md) · [Procedural language](language.md) · [Narrative](narrative.md)

## 4 — Relational computation

### 4.1 — Relations and equality

A relation is a set of fixed-length tuples with a stable identity and an owning
world or lexical context. Arity is the tuple length. A zero-arity relation is
valid and can contain one empty tuple. Duplicate membership has no multiplicity.
Relations are untyped: column names describe positions, not types.

Tuple matching, duplicate elimination, keys, and relational equality use raw
value equality without invoking `__eq`. Integers and mathematically equal floats
match, strings compare by bytes, symbols by interned name, and reference objects
by identity. Nil is a legitimate element, including a key. NaN is prohibited in
tuples and captured relational constants. Infinities are legal relational
numbers, although not portable narrative scalars. Referenced objects are shared;
storing a table does not freeze its fields.

A visible relation is the union of **base** facts and **derived** tuples. A tuple
can belong to both. Retracting its base membership does not remove a surviving
rule derivation. No update directly edits a derived tuple.

### 4.2 — Worlds and relation resolution

Each runtime state owns `logic.global`. `logic.world([parent])` snapshots the
specified parent, defaulting to `logic.global` even inside another world block.
`logic.emptyworld()` creates a world without inherited user facts or rules;
standard-library configuration still installs the reserved quality schema.

A snapshot copies relation schemas, base membership, rules, and captured
constants/guards. Inherited rule references are rebound to child relation
identities, including originally qualified references. Parent and child then
change independently. Lua reference objects held by facts or captures retain
shared identity; this is a relational snapshot, not a deep object clone.

```lua
local w = logic.emptyworld()
logic (w) do
    relation edge(2)
    fact edge(:a, :b)
    local function visit()
        return query edge(:a, ?next)
    end
end
```

`logic (expression) do ... end` evaluates the expression once and makes that
world the lexical default of enclosed declarative constructs. Nested blocks
shadow the default. Functions defined there capture it after the block exits;
calling such a function elsewhere does not dynamically retarget its world.

An unqualified relation name resolves first to a visible local relation, then
to the lexical default world. Ordinary Lua locals do not shadow relations.
`worldpath.relation(...)` bypasses local relation lookup; the path is a Lua name
and zero or more ordinary field accesses whose value must be a world. For a
complex world expression, use a world block.

A qualified rule head sets the owning world for its unqualified body references,
subject to local-dependency validation. Rules cannot depend on another world.
Braced queries can combine explicitly qualified worlds: each referenced world
contributes its construction-time snapshot. They do not create cross-world rules.

### 4.3 — Declaration and facts

```lua
relation edge(2)
relation enabled(0)
fact edge(:a, :b)
fact enabled()
retract edge(:a, :b)
```

A numeric declaration establishes nonnegative arity. Repeating the same arity is
a no-op and preserves any existing named schema. A conflicting arity is an error.
Facts and rules can implicitly establish ordinary named world relations, including
empty body dependencies, when not inside a transaction. Querying an unknown
relation is an error. Retraction from an unknown relation is a no-op and does not
establish it.

Each fact or retraction evaluates its ordinary argument expressions once when
the statement executes. Each syntactic argument supplies one value; a final
function call or vararg does not expand. Arity and values are validated before
publication. A duplicate base insertion or absent-base retraction is a no-op.
A failed operation leaves its logical changes, including implicit declarations,
uncommitted. Earlier independent statements remain in effect.

### 4.4 — Rules and variable scope

```lua
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
```

A rule registers when execution reaches it. Its head identifies the destination
relation; its comma-separated body is a conjunction. Multiple rules contribute
set union. Registering the same rule again creates another rule instance even if
it adds no new visible tuples. World rules persist after their defining block
or function returns; individual rule deletion is not defined.

`?name` is a logic variable scoped to one rule or query. Repeated names require
equal values. `?_` is a fresh anonymous variable at each occurrence and is never
returned. Anonymous variables are invalid in heads, comparisons, and guards.
Ordinary names remain procedural expressions evaluated in the lexical environment.

A head term is a named variable or a constant procedural expression containing no
logic variables. Constant expressions are evaluated once at registration, and
reference values are retained by identity. Heads do not compute new recursive
values from variable bindings. Registration validates arity, safety, ownership,
and stratification atomically before publishing the rule or its implicit relations.

### 4.5 — Safety, negation, comparisons, and guards

A positive atom supplies finite bindings. Every named variable used by a head,
comparison, guard, or negated atom must be grounded by positive atoms, or by a
permitted aggregate result. Safety is checked over the body independently of
textual ordering; comparisons and negation never create bindings.

```lua
rule available(?x) :- room(?x), not occupied(?x)
rule adult(?person) :- age(?person, ?years), ?years >= 18
rule quiet(?room) :- room(?room), where (noise(?room) < 10)
```

`not relation(...)` succeeds when the matching tuple is absent from the completed
relation. It does not enumerate an infinite complement. Anonymous positions are
existential wildcards. Negative dependencies must point to strictly lower
strata; a dependency cycle through negation is rejected.

Relational comparisons support `== ~= < <= > >=` on grounded operands. Equality
is raw relational equality. Ordering accepts primitive numbers or strings and
raises an error for other combinations; it never calls ordering metamethods.

`where (expression)` is an expression guard. Bound logic variables may appear
inside it. Only its first result is tested using ordinary truthiness; a guard
does not bind variables. A helper function can implement multiple procedural
statements, but no statement-guard syntax is defined.

Free procedural values in a rule guard are captured by value at registration;
query guard captures occur at query construction. Captured tables/functions keep
their identity, including any mutable state reachable through them. Guards must
be pure and stable for fixed bindings and a fixed logical program version.
They must not mutate worlds, register rules, consume randomness, or produce
order-dependent effects. Engine mutations and yields during inference are
rejected, but arbitrary external-state purity is the programmer's obligation.
Changing a captured table does not invalidate logical caches. Violating stability
makes declarative results unspecified.

The evaluator may reorder goals consistent with grounding and strata. Programs
must not depend on guard call counts or order. Guard errors propagate when
inference runs and invalidate the query iterator. Inference and indirect helper
calls cannot yield, including through a resumed child coroutine.

### 4.6 — Aggregates

```lua
rule total(?person, ?amount) :-
    person(?person),
    ?amount = sum { ?bonus : equipped(?person, ?item), bonus(?item, ?bonus) }
```

Supported forms are `?n = count { goals }` and
`?n = sum|min|max { expression : goals }` (the vertical bars here denote
alternatives, not source syntax). The result must be a newly bound named variable.
Outer positive atoms are joined first. Aggregates then bind results in textual
order, before the remaining comparisons, guards, and negation.

Variables grounded outside an aggregate and used inside it are correlated inputs.
Inner-only variables and anonymous occurrences are local to the aggregate.
The input set consists of distinct full satisfying local assignments, including
anonymous positions, not distinct expression values. Two different items with the
same bonus contribute twice to a sum. With no local variables, a successful
subquery contributes one assignment.

| Operator | Result on empty input | Other requirements |
| --- | --- | --- |
| `count` | integer zero | Counts assignments; no value expression |
| `sum` | numeric zero | Numeric expression values; arithmetic errors propagate |
| `min`, `max` | Goal fails to bind; no outer result | Suitable primitive comparable values |

Correlated inputs must be grounded; inner goals obey ordinary safety rules.
Aggregate dependencies point to strictly lower strata. Recursion through an
aggregate is prohibited. A result can ground a head or subsequent constraint.
Aggregates are implemented in this edition; they were an optional companion
feature in the historical milestone scheme.

### 4.6a — Computed bindings and alternatives

A **computed binding** `?name := expression` binds a new variable from the values of
variables that are already grounded:

```lua
rule price(?item, ?cost) :- item(?item, ?base), ?cost := ?base * 100
local r = (query { item(:sword, ?n), ?double := ?n * 2, ?double > 10 })()
```

Within one conjunction the positive relation atoms are joined first, then
aggregates and computed bindings in the order written (a binding may use the result
of an earlier one, never a later one), then comparisons, guards and negated atoms.
The expression follows the guard rules above: it is evaluated by ordinary Lua, must
be pure and stable, and may not yield or change a world. Its value is any value a
tuple can hold, including `nil`; `NaN` is rejected. The variable must be new: using
one that is already bound is an error, as for an aggregate result.

A rule that contains a computed binding must not feed itself. Its body relations
are strictly lower than its head, so a recursive rule cannot generate an unbounded
set of new values; such a rule is rejected when it is registered. Ordinary relational
recursion without computed bindings is unchanged.

**Alternatives.** A parenthesized group of conditions with an `or` at its own level
is a filter that passes when any alternative is true:

```lua
rule exposed(?room) :- room(?room), level(?room, ?n), (?n < 2 or ?n > 8)
```

The alternatives are Lua conditions over grounded variables, tried left to right
with short-circuit evaluation: a group is exactly `where( a or b )`, and has the
semantics of a guard (equality is the Lua `==`, not the raw relational equality of a
comparison goal). Alternatives that introduce bindings are not supported; use
separate rules for those.

### 4.7 — Local relations

```lua
local function reachable_from(start)
    local relation reached(1)
    rule reached(?x) :- edge(start, ?x)
    rule reached(?x) :- reached(?y), edge(?y, ?x)
    return query reached(?destination)
end
```

`local relation name(integer)` creates a fresh identity on each execution,
associated with the current lexical world. Local declarations currently take
numeric arity only, not named/keyed schemas. They do not populate the world's
named registry. Local relations shadow earlier relations lexically; references
already resolved by a rule/query are never retargeted by later shadowing.

Local rules may depend on compatible local relations and relations of their
own world. A world-owned rule may not depend on a local relation. All such
rules still undergo safety and stratification validation. Closures and iterators
retain local handles and needed rules by reachability, so an iterator may outlive
the function that constructed it.

### 4.8 — Queries and binding records

```lua
local saved = query edge(?from, ?to)
local joined = query { edge(:a, ?middle), edge(?middle, ?to), not hazard(?to) }
for row in joined do print(row.middle, row.to) end
```

Each query constructs one callable iterator. It freezes the relevant world/local
program state and procedural constants immediately; inference is deferred to its
first call. Each call returns one immutable record or nil after exhaustion.
Generic-for state/control arguments are ignored. Exhausted calls keep returning
nil. An inference error makes the iterator permanently invalid; subsequent calls
raise `attempt to call an invalid query iterator`.

A record exposes names without `?` using field access. Unknown fields and
bindings to nil both read as nil. `logic.hasbinding(record, name)` distinguishes
presence; `logic.binding` returns even a nil binding but errors on absence.
Returned named bindings are deduplicated as a complete assignment. Anonymous
bindings are omitted. A successful query with no named variables returns exactly
one empty record; a failing ground query returns none.

Results are unordered. Collect and sort when an application needs an order.
An iterator retains all necessary snapshots, local relations, captures, and rules.
Later writes, rule registrations, or coroutine suspension do not change its
result set. Its snapshot does not recursively freeze mutable Lua objects.

### 4.8a — `exists` and single-result queries

`exists { goals }` is an expression that is true when the query has at least one
match and false otherwise. It exports no bindings and is read-only like any
query; variables inside it are local to it, and ordinary Lua values in scope are
captured as for any query.

```lua
if exists { at(:player, ?room), locked(?room) } then ... end
```

`logic.one(iterator)` takes a query iterator and returns the sole record, `nil`
when there is no match, and an error when there is more than one. Results of a
query are unordered, so there is deliberately no "first" function.

### 4.9 — Evaluation and versions

For a positive stratum, start with base facts, apply rules, and union new tuples
until no tuple can be added. This least fixed point is the meaning of positive
recursion, including mutually recursive rules. Lower strata are completed before
higher strata use their negations or aggregates. Range restriction and finite
input tuples prevent unbounded term generation.

The current evaluator recomputes the query dependency closure as needed. An
unrelated failing rule guard is not evaluated merely because it shares a world.
Only completed materializations are published as caches. Any optimization must
produce the same results from current facts/rules, including invalidation after
retraction or insertion into a negated dependency.

Effective facts/updates and rule registration change logical versions. Duplicate
facts, absent retractions/deletions, and identical keyed replacements do not.
Versions are abstract change identities, not a portable API for counting source
statements. No inference order, tuple iteration order, or internal cache layout
is part of the contract.

## 5 — State and transactions

### 5.1 — Named schemas and keys

```lua
relation location(entity, room) key(entity)
relation balance(owner, currency, amount) key(currency, owner)
```

Column names must be unique. A key lists existing distinct column names and must
be nonempty. Key argument order is the order in `key(...)`, even when it differs
from tuple column order. Keys compare by relational equality, including nil.

No two base tuples may agree on their key and differ elsewhere. Identical fact
insertion is a no-op; a differing fact at an existing key is an error. A keyed
relation is extensional and cannot be a rule head. It can be read by any otherwise
valid rule/query. Keys do not impose types or ordering.

Named/keyed schemas are immutable once established and are inherited by world
snapshots. A conflicting declaration, including an attempted named-schema
upgrade of an implicit or numeric relation, is an error. A numeric same-arity
declaration preserves an existing named schema. `relation empty()` is a named
zero-column declaration. Local declarations retain numeric arity syntax only.

### 5.2 — Atomic updates

```lua
set location(:player, :library)
set balance(:player, :coins, 15)
adjust balance(:coins, :player) by -10
delete balance(:coins, :player)
```

`set` requires a keyed relation and supplies a full tuple in column order. It
replaces the old base tuple at that key or inserts one if absent, as one atomic
operation. `delete` supplies only key values in key-declaration order and removes
that base tuple; an absent key is a no-op. `retract` still supplies a complete
exact tuple and does not delete a different tuple sharing its key.

`adjust` requires exactly one non-key column and an existing keyed tuple. The
key list follows key-declaration order. The current value and delta must be
numbers, not numeric strings. Integer addition wraps; arithmetic and runtime
constraints are checked before replacement. There is no absent-value default
or clamping. Failed operations preserve the previous tuple, indexes, and versions.

### 5.3 — Transaction execution

```lua
transaction (world) do
    adjust balance(:coins, :player) by -10
    set location(:player, :library)
end
```

The optional world expression is evaluated once. If omitted, the lexical default
world is selected. A transaction sees its entry snapshot plus its preceding
writes, including derived consequences. All mutations must target the selected
world. Tentative writes are private to the owning coroutine; another coroutine
can read committed state but cannot write or acquire a conflicting transaction
on that world. The runtime holds an exclusive mutation lock and never retries.

Normal exit commits. A `return`, loop exit, or valid `goto` commits each transaction
block it leaves before transferring control, after required scoped cleanup.
Breaking a loop wholly inside a transaction does not exit that transaction.
An escaping error rolls back before propagation. An error caught inside the
transaction leaves preceding successful tentative writes intact.

`rollback` discards and exits the innermost lexical transaction without raising
an error. It must occur inside a transaction in the same function; calling a
helper containing an out-of-scope rollback is not a dynamic rollback mechanism.

### 5.4 — Savepoints and iterator validity

Nested same-world transactions are savepoints. Child commit merges writes into
the parent; child rollback discards only child writes. Nesting a different world
is an error. A changed outer commit publishes the world and transaction-aware
narrative participants atomically and advances the world logical version once.

An iterator constructed in a transaction freezes its then-current tentative
state. After commit it retains that snapshot. Rollback permanently invalidates
iterators created inside the discarded transaction/savepoint, even if they have
already produced results. An outer rollback also invalidates iterators from
committed children. An iterator created before a discarded child remains valid.

### 5.5 — Permitted operations and limits

Transactions permit base fact insertion/retraction, keyed updates, and specified
transaction-aware narrative commands. They prohibit schema and rule registration,
even idempotent declarations. Facts must target predeclared relations: implicit
creation would change a schema. Local-relation mutations are prohibited because
they lie outside the named-world overlay; local reads remain permitted.

Yielding, cross-world writes, and other-world nested transactions are errors.
No-yield restrictions extend through helpers, native callbacks, and synchronously
resumed children. Arbitrary table mutation, global assignment, printing, I/O,
and external host actions are not transactional and are not undone. Defer an
external callback until commit when that is the intended effect.
