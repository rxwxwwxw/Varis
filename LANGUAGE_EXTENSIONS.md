# Lua 5.4 — Declarative Programming Extensions

**Proposed Language Reference — Version 0.1**

## 1 — Introduction

The declarative extensions to Lua provide facilities for representing relations, asserting facts, defining inference rules, and querying the resulting logical database.

These extensions integrate a Datalog-style relational computation system into Lua. They are intended to support declarative computations within ordinary Lua programs, including computations defined inside functions and operating on values from the surrounding lexical environment.

The declarative subsystem provides:

- Interned symbols as a primitive Lua value type.
- Logic variables and relational patterns.
- Relations consisting of sets of tuples.
- Facts inserted and removed during procedural execution.
- Recursive inference rules.
- Stratified negation and relational constraints.
- Procedural predicates expressed as Lua guards.
- Lexically scoped relations.
- Independent logical worlds with snapshot inheritance.
- Query expressions producing Lua-compatible iterators.

Except where explicitly stated, the semantics of Lua 5.4 remain unchanged.

### 1.1 — Basic Example

```lua
fact edge(:a, :b)
fact edge(:b, :c)
fact edge(:c, :d)

rule reachable(?x, ?y) :-
    edge(?x, ?y)

rule reachable(?x, ?y) :-
    edge(?x, ?z),
    reachable(?z, ?y)

for match in query reachable(:a, ?target) do
    print(match.target)
end
```

The query produces the symbols `:b`, `:c`, and `:d`, in an unspecified order.

### 1.2 — Computational Model

The declarative subsystem uses a finite relational model with set semantics.

A relation is a set of fixed-arity tuples. A rule describes tuples derivable from existing relations. Recursive rules are interpreted according to their least fixed point.

Negation uses the closed-world assumption and requires stratification.

The order in which rules are declared does not determine the order in which they are evaluated.

Declarative computation does not use Prolog-style procedural backtracking or expose a cut operator.

Implementations may employ bottom-up evaluation, semi-naive evaluation, tabling, query specialization, or other strategies, provided that the observable results conform to this specification.

## 2 — Values and Types

### 2.1 — Symbols

The extension introduces a primitive type named `symbol`.

A symbol is an immutable, interned value identified by a byte string.

A symbol literal consists of a colon followed by a valid Lua identifier:

```lua
local a = :node1
local b = :node1
local c = :node2

assert(a == b)
assert(a ~= c)
assert(type(a) == "symbol")
```

Symbols are distinct from strings:

```lua
assert(:lava ~= "lava")
```

Symbols with identical names compare equal, regardless of the location or time of their creation.

Symbol identity is shared across all worlds within the same Lua state.

### 2.2 — Dynamic Symbol Construction

Symbols may be created programmatically:

```lua
local a = symbol("lava")
local b = :lava

assert(a == b)
```

The function `symbol` converts a string to the corresponding symbol. If its argument is already a symbol, it returns that symbol unchanged.

For all other argument types, it raises an error.

The function `logic.symbolname` returns the byte string identifying a symbol:

```lua
assert(logic.symbolname(:lava) == "lava")
```

A dynamically constructed symbol may contain characters that cannot appear in a symbol literal.

The string representation of a symbol produced by `tostring` consists of a colon followed by its name when the name is a valid identifier. Other names use a quoted representation.

Symbols may be used as table keys.

Symbols support equality and inequality comparisons. Ordering comparisons on symbols raise an error unless explicitly performed on their names.

### 2.3 — Relational Values

Relational tuples may contain Lua values of any type, including `nil`, subject to the restriction on NaN described below.

Relational equality is defined by raw Lua equality, without invoking equality metamethods.

Consequently:

- Numbers compare according to Lua's numerical equality rules.
- Strings compare by contents.
- Symbols compare by symbol identity.
- Tables, functions, threads, and userdata compare by identity.
- `nil` is a valid relational value.

NaN values are prohibited as tuple elements and captured relational constants because they do not have reflexive equality.

The use of mutable reference values does not copy those values. A relation containing a table stores a reference to that table, not a snapshot of its contents.

### 2.4 — Relational Constants

A relational constant is a Lua value appearing in a fact, a rule, or a query.

Relational constants originating from ordinary Lua expressions are evaluated at a well-defined point, as described in §5 and §7.

Logic variables and Lua expressions occupy distinct syntactic namespaces.

## 3 — Lexical Conventions

### 3.1 — Additional Tokens

The extension introduces the following lexical forms:

```text
:-
?name
:name
```

The token `:-` introduces the body of a rule.

The form `?name` denotes a logic variable.

The form `:name` denotes a symbol literal.

The characters `?` and `:` are interpreted according to their syntactic context. The existing meanings of `:` and `::` in Lua are preserved.

For example:

```lua
object:method()
local value = :method
::label::
```

remain distinguishable.

### 3.2 — Contextual Keywords

The following identifiers acquire special meanings in declarative syntactic positions:

```text
fact
rule
query
relation
retract
where
logic
```

These identifiers are contextual keywords and are not globally reserved.

For example, ordinary Lua code may still contain:

```lua
local fact = 12
local query = function(x) return x end
```

The parser recognizes declarative constructs from their complete syntactic forms.

The existing Lua keyword `not` is used for relational negation when it occurs in a rule or query body before a relation atom.

### 3.3 — Logic Variables

A logic variable consists of `?` followed by a Lua identifier.

```lua
?node
?destination
?terrain_type
```

Logic variables are not Lua local variables and cannot be assigned using Lua assignment statements.

Each rule has its own logic-variable scope.

Each query expression has its own logic-variable scope.

Repeated occurrences of the same logic-variable name within one scope refer to the same variable.

```lua
query edge(?x, ?x)
```

matches only edges whose two endpoints are equal.

### 3.4 — Anonymous Variables

The form `?_` denotes an anonymous logic variable.

Each occurrence is distinct, even when multiple occurrences appear in the same atom.

```lua
query edge(?from, ?_)
```

matches every edge and returns only the variable `from`.

Anonymous variables are not included in query results.

Anonymous variables cannot appear in rule heads, procedural guards, or relational constraints.

### 3.5 — Whitespace and Statement Termination

Declarative constructs do not depend on newline characters.

A rule body is a comma-separated sequence of goals. It ends after its final complete goal when the next token does not continue the goal sequence.

A trailing comma is not permitted.

A semicolon may separate declarative statements, as it does ordinary Lua statements.

Rules do not require Prolog-style terminating periods.

## 4 — Relations

### 4.1 — Definition

A relation is identified by a name, an arity, and an owning logical context.

The arity is the number of elements in every tuple belonging to that relation.

For example:

```lua
fact edge(:a, :b)
```

establishes or uses the relation `edge` with arity two.

A relation may contain zero or more tuples. Duplicate tuples are not stored.

Relations are untyped in this version of the extension. Every attribute may contain values of different Lua types.

### 4.2 — Relation Declarations

A relation may be explicitly declared:

```lua
relation edge(2)
relation hazard(1)
relation enabled(0)
```

The integer specifies its arity and must be nonnegative.

Declaring an existing relation with the same arity has no effect. Declaring it with a different arity raises an error.

Explicit relation declarations are optional for ordinary world-owned relations.

A relation is implicitly established when first used in a fact or rule definition. Relation names referenced by a rule body may establish initially empty relations.

Querying an entirely unknown relation raises an error.

### 4.3 — Relation Identity

Relations with the same name and arity in different worlds are distinct.

```lua
local a = logic.world()
local b = logic.world()
```

The relation `edge` belonging to `a` and the relation `edge` belonging to `b` have independent contents.

A relation is not identical to an ordinary Lua function with the same name.

### 4.4 — Base and Derived Tuples

Each relation consists conceptually of two parts:

1. Base tuples, inserted explicitly as facts.
2. Derived tuples, inferred from rules.

The visible contents of a relation are the union of these parts.

A tuple may simultaneously be a base tuple and a derived tuple.

Removing its base tuple does not remove it from the visible relation while it remains derivable.

## 5 — Facts

### 5.1 — Fact Statements

A fact statement inserts one tuple into a relation:

```lua
fact edge(:a, :b)
```

The fact statement is executed when program control reaches it.

It is not a compile-time declaration.

Consequently, facts may be inserted by loops, conditionals, and functions:

```lua
for i = 1, 10 do
    fact number(i)
end
```

The expressions used as fact arguments are ordinary Lua expressions, evaluated once during execution of the statement.

Each syntactic argument contributes exactly one Lua value, even if it is a function call capable of returning multiple results.

Facts with an incorrect number of arguments raise an arity error.

### 5.2 — Duplicate Facts

Facts have set semantics.

```lua
fact edge(:a, :b)
fact edge(:a, :b)
```

produces one base tuple.

Inserting an existing base tuple has no effect.

### 5.3 — Fact Retraction

A fact may be removed using `retract`:

```lua
retract edge(:a, :b)
```

Retraction removes the specified base tuple from the relation.

Retracting a nonexistent base tuple has no effect.

Retraction does not directly remove derived tuples or rule definitions. However, the removal may invalidate previously derived results.

### 5.4 — Effects of Mutation

Fact insertion and retraction are immediately visible to subsequently constructed queries.

The engine maintains the logical consequences of the current facts and rules.

Implementations may postpone recomputation until a query requires the affected relations, provided observable results remain correct.

Mutations do not affect query iterators that have already captured a query snapshot.

## 6 — Rules

### 6.1 — Rule Statements

A rule consists of a head and a body.

```lua
rule reachable(?x, ?y) :-
    edge(?x, ?y)
```

The head identifies the relation to which new tuples may be added.

The body specifies the conditions under which those tuples are derivable.

A rule is registered when execution reaches its declaration.

Rules may therefore be declared inside functions, loops, or conditional statements.

### 6.2 — Rule Bodies

A rule body is a conjunction of goals.

```lua
rule traversable(?a, ?b) :-
    edge(?a, ?b, ?terrain),
    not hazard(?terrain)
```

A rule succeeds for each assignment of its variables satisfying every goal.

Multiple rules with the same head contribute tuples to the same relation. Their results are combined using set union.

Thus:

```lua
rule connected(?x, ?y) :- edge(?x, ?y)
rule connected(?x, ?y) :- edge(?y, ?x)
```

defines an undirected connection relation from directed edges.

### 6.3 — Recursive Rules

Rules may refer to their own head relation, directly or indirectly.

```lua
rule path(?x, ?y) :-
    edge(?x, ?y)

rule path(?x, ?y) :-
    edge(?x, ?z),
    path(?z, ?y)
```

Recursive rules are interpreted using least-fixed-point semantics.

For a collection of mutually recursive positive rules, the derived relation is the smallest set of tuples satisfying all rules and containing the relevant base tuples.

Repeated derivations of identical tuples do not produce duplicate results.

### 6.4 — Rule Safety

A rule is safe if every named logic variable occurring in its head, negated goals, relational constraints, or procedural guards also occurs in at least one positive relation atom in the rule body.

The occurrence must supply a finite domain of candidate values.

For example, this rule is safe:

```lua
rule available(?x) :-
    room(?x),
    not occupied(?x)
```

The following rule is unsafe:

```lua
rule available(?x) :-
    not occupied(?x)
```

because the possible values of `?x` are unconstrained.

Unsafe rules raise an error when registered.

Repeated occurrences of a variable in positive atoms impose equality constraints.

### 6.5 — Range Restriction

Rules must not generate an unbounded domain of new values through recursive evaluation.

Accordingly, a rule head may contain only:

- Named logic variables bound by positive body atoms.
- Lua expressions that do not reference logic variables and are evaluated once at rule registration.

For example:

```lua
local category = :outdoor

rule categorized(?x, category) :-
    outdoor_room(?x)
```

is permitted.

By contrast, a computed recursive successor expression depending on a logic variable is not supported in rule heads.

This restriction ensures that a finite collection of facts and registered rules produces a finite relational domain.

### 6.6 — Rule Registration

A rule registration is an operation on the relation's owning logical context.

Registration performs arity checking, safety checking, and stratification validation.

If validation fails, registration raises an error and does not modify the logical program.

Rules registered more than once are separate rule instances. The resulting relation still uses set semantics.

Repeatedly registering equivalent rules may therefore consume additional resources without changing the logical result.

### 6.7 — Rule Lifetimes

A rule registered on an ordinary world-owned relation persists for the lifetime of that world unless the world is discarded or reset by a future program-management facility.

Leaving the Lua function or block containing the rule statement does not remove such a rule.

Rules associated with lexically local relations have a different lifetime, as described in §10.

Version 0.1 does not define individual rule retraction syntax.

## 7 — Logic Variables and Lua Expressions

### 7.1 — Separation of Environments

Declarative expressions have two distinct environments:

- A logic environment containing variable bindings.
- A Lua lexical environment containing ordinary Lua locals, upvalues, and globals.

For example:

```lua
local start = :a

query path(start, ?destination)
```

The identifier `start` denotes a Lua value.

The identifier `?destination` denotes a logic variable.

These forms are not interchangeable.

### 7.2 — Constants in Relations

An ordinary Lua expression appearing as a relational argument is evaluated once when the containing fact, rule, or query is constructed.

```lua
local room = :a

local results = query path(room, ?target)

room = :b
```

The query continues to use `:a`.

The same principle applies when rules capture constants:

```lua
function add_origin_rule(origin)
    rule origin_reachable(?x) :-
        edge(origin, ?x)
end
```

Each invocation registers a rule whose `origin` argument has the value supplied during that invocation.

### 7.3 — Capture Semantics

Constant expressions are evaluated at the time of rule registration.

Lua values referenced by procedural guard expressions are captured by value at rule registration. The compiler may implement this by constructing a closure whose environment contains those captured values.

Capturing a reference value does not copy the referenced object.

For example, capturing a table preserves a reference to the table, not its contents at the moment of capture.

The evaluation of guards is described in §9.

### 7.4 — Variable Binding

A positive relation atom binds its logic variables to elements of matching tuples.

All occurrences of the same named logic variable must have equal values.

Anonymous variables accept any value without introducing a named binding.

Neither negated relation atoms nor procedural guards introduce new variable bindings.

### 7.5 — Scope of Variables

Every rule declaration creates a separate logic-variable namespace.

Every query expression also creates its own namespace.

Logic-variable bindings do not escape a rule or query except through the result of a query.

Variables in two separate rules with the same spelling are unrelated.

## 8 — Negation and Constraints

### 8.1 — Relational Negation

A relation atom may be preceded by `not`:

```lua
rule safe(?room) :-
    room(?room),
    not dangerous(?room)
```

A negated atom succeeds when the corresponding tuple is absent from the completed relation.

Negation uses the closed-world assumption.

The absence of a tuple is treated as sufficient evidence for the negated goal to succeed.

### 8.2 — Stratification

The dependency graph of the logical program contains one node for each relation.

A positive occurrence of a relation creates a positive dependency.

A negated occurrence creates a negative dependency.

A valid program must admit a stratification in which every negative dependency points to a lower stratum.

Consequently, a dependency cycle containing negation is prohibited.

For example:

```lua
rule a(?x) :- domain(?x), not b(?x)
rule b(?x) :- domain(?x), not a(?x)
```

is invalid.

Positive recursion is permitted.

When a rule is registered, the implementation must reject any resulting unstratifiable dependency graph.

### 8.3 — Grounding of Negation

All named logic variables appearing in a negated atom must also appear in positive atoms of the same rule or query body.

Negation does not enumerate the complement of an infinite universe.

### 8.4 — Relational Comparisons

Rule and query bodies may contain comparisons:

```lua
rule adult(?person) :-
    age(?person, ?years),
    ?years >= 18
```

The supported operators are:

```text
==  ~=  <  <=  >  >=
```

Both operands must be grounded before the comparison is evaluated.

Equality and inequality use relational equality as defined in §2.3.

Ordering comparisons are defined for numbers and strings according to their ordinary Lua primitive ordering. Unsupported type combinations raise an error.

Comparisons do not bind variables.

### 8.5 — Evaluation Order

The textual order of goals does not prescribe their physical evaluation order.

An implementation may reorder positive atoms, negated atoms, and constraints to improve execution efficiency, provided that all variable-grounding and stratification requirements are respected.

Users must not rely on the order of evaluation for procedural side effects.

## 9 — Procedural Guards

### 9.1 — Guard Expressions

A procedural guard evaluates a Lua expression using the current logic-variable bindings.

Guards use the syntax:

```lua
where (expression)
```

For example:

```lua
rule low_threat(?room) :-
    room(?room),
    where (get_threat(?room) < 10)
```

Logic variables may appear inside the expression.

Their occurrences evaluate to the Lua values assigned to those variables by the logic engine.

All referenced logic variables must be grounded by positive relation atoms.

### 9.2 — Guard Results

A guard succeeds when its expression produces a truthy Lua value.

As in Lua, only `false` and `nil` are false.

Only the first result of the guard expression is used.

A guard never creates new logical bindings.

### 9.3 — Purity Requirement

Guards are required to behave as pure predicates with respect to a logical program version.

A guard must not:

- Insert or retract facts.
- Register rules.
- Mutate a world.
- Depend on changing external state without an explicit program rebuild.
- Produce observable side effects whose behavior depends on the order or number of evaluations.

The implementation is not required to prove purity.

A program that violates these requirements has unspecified declarative results.

Ordinary Lua computations outside guards are not subject to these restrictions.

### 9.4 — Referential Stability

For a fixed logical program version and fixed variable bindings, a guard must return the same logical result.

Implementations may cache guard results, invoke a guard multiple times, or omit evaluations already known to be redundant.

If a guard depends on mutable Lua data, the programmer must ensure that the data remains stable for the relevant logical computation.

Changing such data does not automatically invalidate the world.

### 9.5 — Errors and Yielding

Errors raised by a guard propagate to the query that caused its evaluation.

An error terminates that query evaluation but does not undo previously completed fact or rule mutations.

A guard must not yield to another coroutine during engine evaluation.

### 9.6 — Statement-Based Guards

Version 0.1 defines expression guards only.

Multi-statement procedural guards are reserved for a future extension.

Equivalent computations may be implemented by calling an ordinary Lua function from a `where` expression.

## 10 — Lexically Scoped Relations

### 10.1 — Local Relation Declarations

A local relation is declared with:

```lua
local relation reachable(1)
```

This declaration creates a new relation value with the specified arity and binds it to a lexical relation name.

Unlike an ordinary world-owned relation, a local relation is not inserted into the world's named relation registry.

Each execution of the declaration creates a fresh local relation.

### 10.2 — Local Rule Definitions

Rules referring to a visible local relation name operate on that local relation.

For example:

```lua
function reachable_from(start)
    local relation reachable(1)

    rule reachable(?x) :-
        edge(start, ?x)

    rule reachable(?x) :-
        reachable(?y),
        edge(?y, ?x)

    return query reachable(?destination)
end
```

Each invocation creates a new `reachable` relation, populated with rules capturing that invocation's `start` value.

The rules do not modify any globally named relation.

Recursive references resolve to the local relation.

### 10.3 — Relation Name Resolution

An unqualified relation name is resolved as follows:

1. If a lexically visible local relation declaration has that name, it is used.
2. Otherwise, the relation is resolved in the current default world.

Local relations shadow world-owned relations having the same name.

Ordinary Lua local variables do not shadow relation names, because ordinary variables and relation identifiers occupy separate namespaces.

An explicitly world-qualified relation reference bypasses local relation lookup.

### 10.4 — Scope and Lifetime

A local relation has lexical visibility, but its lifetime is governed by reachability.

A returned query iterator retains any local relations and rules needed for its evaluation.

Consequently, local relations may survive after their defining Lua function returns.

```lua
local results = reachable_from(:a)

for match in results do
    print(match.destination)
end
```

The relation remains available through `results`.

Once no live query, local relation, or other engine-owned object references the relation, it may be collected.

### 10.5 — Local Dependencies

Local relations may depend on:

- Other local relations visible in their lexical scope.
- Relations in their owning world.
- Recursive references to themselves.

Their dependencies participate in the same safety and stratification checks as ordinary rules.

A local relation is associated with the default world active when it is created.

That association remains fixed throughout the local relation's lifetime.

### 10.6 — Interaction with World-Owned Rules

Local relations are intended for computations whose definitions have lexical lifetimes.

A world-owned rule may not depend on a local relation. Attempting to register such a rule raises an error.

This prevents a persistent world rule from implicitly retaining a temporary lexical relation.

Local relations, however, may depend on world-owned relations.

### 10.7 — Repeated Local Declarations

A subsequent local relation declaration with the same name shadows the preceding declaration according to ordinary Lua lexical scoping rules.

Rules registered before the shadowing declaration continue to refer to the original relation.

## 11 — Logical Worlds

### 11.1 — Definition

A world is an independent logical context containing:

- Named relations and their arities.
- Base facts.
- World-owned rules.
- Dependency information.
- Evaluation and indexing state.

Every Lua state has a distinguished global world.

It is available through:

```lua
logic.global
```

Unqualified declarative operations use the global world unless another default world is established.

### 11.2 — Creating Worlds

A new world is created with:

```lua
local child = logic.world()
```

By default, the new world inherits the relational state of `logic.global` at the instant of creation.

A specific parent may be supplied:

```lua
local child = logic.world(parent)
```

An empty world may be created with:

```lua
local isolated = logic.emptyworld()
```

### 11.3 — Snapshot Inheritance

World inheritance is a point-in-time snapshot operation.

The child inherits:

- The relation names and arities of the parent.
- All base facts present in the parent.
- All world-owned rules present in the parent.
- The captured constant values and guard functions associated with those rules.

Derived tuples need not be physically copied. They must be logically reproducible from the inherited program state.

The inherited rules are rebound to the child's corresponding relations.

No live parent-child dependency is established.

### 11.4 — World Independence

Changes made to the parent after a child is created do not propagate to the child.

Changes made to the child do not propagate to the parent.

For example:

```lua
fact edge(:a, :b)

local child = logic.world()

fact edge(:b, :c)

-- child contains (:a, :b), but not (:b, :c)
```

The same applies to rules:

```lua
local child = logic.world()

rule global_rule(?x) :- source(?x)

-- child does not acquire global_rule
```

Rules inherited at creation remain present in the child independently of the parent's subsequent changes.

### 11.5 — Relational Snapshots and Lua References

World inheritance copies relational structure and tuple membership.

It does not recursively clone arbitrary Lua objects referenced by tuples, captured constants, or guard closures.

For example, a table stored in a parent fact is still the same table object when inherited by the child.

This does not violate relational snapshot independence, because table identity remains unchanged. However, observing mutable contents of such objects through procedural guards may violate guard purity.

### 11.6 — Qualified Relations

A relation may be explicitly qualified by a world:

```lua
fact child.edge(:a, :b)

rule child.path(?x, ?y) :-
    edge(?x, ?y)

for match in query child.path(:a, ?target) do
    print(match.target)
end
```

The qualifier identifies the world owning the relation.

All unqualified relation references inside the body of a world-qualified rule resolve in that same world, subject to the restriction on local relation dependencies.

The qualifier may be a Lua name or a chain of ordinary Lua field accesses whose value is a world.

For more complex world expressions, the world block described in §11.7 may be used.

### 11.7 — World Blocks

A lexical default world may be established with:

```lua
logic (world_expression) do
    block
end
```

For example:

```lua
local dungeon = logic.world()

logic (dungeon) do
    fact edge(:entrance, :hall)

    rule reachable(?x, ?y) :-
        edge(?x, ?y)

    rule reachable(?x, ?y) :-
        edge(?x, ?z),
        reachable(?z, ?y)
end
```

The world expression is evaluated once when execution enters the block.

It must produce a world.

The resulting world becomes the default world for declarative constructs lexically enclosed by the block.

Nested world blocks may override the surrounding default.

Functions defined within a world block capture its default world through ordinary lexical closure behavior.

Leaving the block restores the surrounding lexical default.

### 11.8 — Cross-World Dependencies

Version 0.1 does not permit rules whose bodies directly depend on relations belonging to a different world.

A qualified rule head establishes its owning world; its body is evaluated in that world.

Cross-world data movement may be performed procedurally using Lua query iteration and fact insertion.

This restriction ensures that world evaluation, stratification, and snapshot consistency remain local to one world.

### 11.9 — World Versions

Every world has a logical version identifying its current relational program state.

An effective insertion, retraction, or rule registration changes the version.

Implementations may maintain finer-grained version information for individual relations.

The version is an abstract property. Its internal representation is not prescribed.

## 12 — Query Expressions

### 12.1 — Simple Queries

A query expression has the form:

```lua
query relation(arguments...)
```

For example:

```lua
query path(:a, ?target)
```

It constructs an iterator over the distinct assignments satisfying the relation atom.

Ordinary Lua arguments are captured when the query is constructed.

Logic variables are bound through relational matching.

### 12.2 — Conjunctive Queries

A query may contain multiple goals by using a braced query body:

```lua
query {
    edge(:a, ?middle),
    edge(?middle, ?target),
    not hazard(?target)
}
```

The query succeeds for every distinct assignment of its named variables satisfying all goals.

The body may contain positive atoms, negated atoms, comparisons, and procedural guards.

The same safety rules that apply to rule bodies also apply to query bodies.

### 12.3 — Query Results

A query result is a binding record associating variable names with Lua values.

For example:

```lua
for match in query path(:a, ?target) do
    print(match.target)
end
```

The record exposes named variable bindings through Lua field access.

The `?` prefix is omitted from result field names.

Repeated occurrences of the same variable produce one field.

Anonymous variables are omitted.

### 12.4 — Nil Bindings

A query variable may legitimately be bound to `nil`.

In that case, ordinary field access produces `nil`:

```lua
print(match.value)
```

The function `logic.hasbinding` distinguishes a binding with value `nil` from an absent binding name.

```lua
logic.hasbinding(match, "value")
```

The function `logic.binding` retrieves a named binding and raises an error if the name is absent.

Binding records are immutable.

### 12.5 — Query Iterators

A query expression returns one callable Lua iterator.

A subsequent call returns the next binding record or `nil` when the query has been exhausted.

It is compatible with Lua's generic `for` statement:

```lua
for match in query path(:a, ?target) do
    print(match.target)
end
```

The iterator may also be stored:

```lua
local iterator = query path(:a, ?target)

local first = iterator()
local second = iterator()
```

Calling an exhausted iterator continues to return `nil`.

Each query expression evaluation constructs a new iterator.

### 12.6 — Query Snapshots

A query iterator observes the relational state present when the query expression is evaluated.

Subsequent changes to the owning world do not change the iterator's logical result set.

For example:

```lua
local iterator = query edge(?x, ?y)

fact edge(:new, :node)

-- iterator does not include the newly inserted fact
```

An implementation may use eager materialization, immutable versions, or copy-on-write data structures to provide this behavior.

It is not required to physically copy all relations at query construction.

### 12.7 — Ordering

Query results have no specified ordering.

An implementation may return results according to indexes, join order, insertion order, or another evaluation strategy.

Programs requiring deterministic ordering must collect and sort the results explicitly.

### 12.8 — Duplicates and Projection

Queries use set semantics.

Assignments that are equal on every returned named logic variable are considered duplicates and appear only once.

For example:

```lua
query edge(:a, ?target)
```

returns each distinct target once, even if several derivations produce the same target.

A query with no named logic variables returns exactly one empty binding record when its conditions succeed and no results otherwise.

### 12.9 — Query Lifetime

An iterator retains all necessary references to local relations, compiled rules, captured values, and relational snapshots.

The lifetime of its defining Lua function or lexical block does not affect its validity.

Discarding an iterator permits its retained resources to be reclaimed when they are no longer otherwise referenced.

### 12.10 — Query Errors

Errors encountered during query evaluation propagate to the caller invoking the iterator.

An iterator whose evaluation raises an error becomes invalid and cannot be resumed.

Query evaluation does not mutate the logical program.

## 13 — Relational Evaluation

### 13.1 — Least-Fixed-Point Semantics

For a positive recursive rule set, let \(E\) denote the base facts and let \(T\) denote the operator deriving consequences from the rules.

The logical interpretation is the least fixed point obtained by repeated application of:

\[
I_{n+1}=E\cup I_n\cup T(I_n)
\]

beginning with the relevant base facts.

The fixed point is reached when no new tuples can be derived.

For finite relational domains, the fixed point is finite.

### 13.2 — Stratified Evaluation

For a program containing negation, the dependency graph is partitioned into strata.

Relations in lower strata are completed before their results are used negatively by higher strata.

Positive recursive dependencies may occur within a stratum.

The meaning of a program is the result of evaluating strata in dependency order.

### 13.3 — Incremental Changes

An implementation may maintain derived relations incrementally.

However, the semantics are defined by the current base facts and rule set, not by the history of evaluation steps.

After removing a fact, every tuple that is no longer derivable must be absent from subsequent query results.

This requirement also applies to negation: adding a fact to a negated relation may remove tuples from a derived relation.

### 13.4 — Optimization Freedom

Implementations may:

- Reorder joins.
- Build indexes for frequently queried argument positions.
- Use semi-naive evaluation.
- Use query-driven evaluation.
- Materialize derived relations.
- Cache completed query results.
- Incrementally maintain materializations.
- Compile query plans using bound/free argument patterns.

Such optimizations must preserve the semantics of facts, rules, queries, snapshots, and pure guards.

The specification does not impose a particular physical evaluation strategy.

### 13.5 — Termination

For programs satisfying the range-restriction rules, containing finitely many registered rules and facts, and using terminating procedural guards, logical evaluation terminates under the finite-domain model.

This guarantee does not extend to nonterminating Lua functions invoked from guards or to unbounded procedural generation of additional facts and rules.

## 14 — Interaction with Lua Execution

### 14.1 — Procedural and Declarative Execution

Fact insertion, retraction, and rule registration are ordinary executed statements.

Query construction is an ordinary expression evaluation.

The inference engine performs declarative computation as required to satisfy queries.

For example:

```lua
function update_world(changes)
    for _, change in ipairs(changes) do
        if change.add then
            fact edge(change.from, change.to)
        else
            retract edge(change.from, change.to)
        end
    end
end
```

The behavior of the procedural control flow follows Lua's ordinary semantics.

### 14.2 — Lexical Scoping

Declarative constructs respect Lua lexical block structure.

Lua expressions used to construct constants can access locals and upvalues visible at their source location.

Local relation declarations follow Lua's lexical visibility rules.

A world block introduces a lexical default world, not a dynamically scoped process-wide setting.

### 14.3 — Functions and Closures

Rules may be declared inside Lua functions.

```lua
function matches_prefix(prefix)
    local relation matching(1)

    rule matching(?name) :-
        name(?name),
        where (string.sub(?name, 1, #prefix) == prefix)

    return query matching(?result)
end
```

The resulting iterator may outlive the function invocation.

Local relations and captured constants remain available for as long as needed.

### 14.4 — Error Handling

Errors originating in fact operations, rule registration, query construction, or query execution are ordinary Lua errors.

They may be caught with `pcall` or `xpcall`.

A failed rule registration or fact operation leaves the logical program unchanged by that operation.

A failure does not automatically roll back earlier successful statements.

### 14.5 — Garbage Collection

Symbols, world objects, local relations, query iterators, and binding records participate in garbage collection.

World snapshots may share immutable internal structures.

An implementation may reclaim those structures when they are unreachable from all worlds, local relations, and query iterators.

### 14.6 — Coroutines

Ordinary Lua coroutines may create worlds, insert facts, register rules, and consume queries.

Query iterators may be suspended between calls.

The implementation must preserve the snapshot associated with an iterator across such suspension.

Mutating a world from another coroutine between iterator calls does not change the iterator's results.

Yielding from within a procedural guard during active inference is prohibited.

## 15 — Standard Declarative Library

The extension provides a standard library table named `logic`.

### 15.1 — World Operations

`logic.global`

The default global world belonging to the Lua state.

`logic.world([parent])`

Creates a new world by taking a snapshot of `parent`. If omitted, `parent` is `logic.global`.

`logic.emptyworld()`

Creates a world with no relations, facts, or rules.

`logic.add(world, name, ...)`

Inserts a base fact into the named relation of the specified world. The name is a Lua string. Equivalent to a qualified `fact` statement.

`logic.retract(world, name, ...)`

Removes a base fact from the named relation. Equivalent to a qualified `retract` statement.

The library forms permit dynamically computed relation names.

### 15.2 — Symbol Operations

`symbol(name)`

Returns the interned symbol corresponding to `name`.

`logic.symbol(name)`

Identical to `symbol(name)`.

`logic.symbolname(value)`

Returns the name of a symbol as a string. Raises an error for other types.

### 15.3 — Binding Operations

`logic.hasbinding(record, name)`

Returns whether a query binding record contains the specified variable name.

`logic.binding(record, name)`

Returns the value bound to the specified variable. Raises an error if the name is absent.

### 15.4 — Programmatic Query Construction

Implementations may expose an additional programmatic API for constructing queries and rules without new syntax.

Such an API is implementation-defined in version 0.1.

Programs requiring dynamically generated predicates or variable structures should use this API rather than constructing and evaluating Lua source strings.

## 16 — Errors and Validation

The following conditions are errors:

- A relation is used with inconsistent arity.
- A rule or query contains an ungrounded named variable.
- A rule introduces recursion through negation.
- A world-qualified operation does not refer to a world.
- A persistent world-owned rule depends on a local relation.
- A comparison receives values unsupported by that comparison.
- A relation contains a NaN tuple element.
- A query references an unknown relation.
- A procedural guard raises an error.
- A procedural guard attempts to yield during inference.
- A declarative construct violates the grammar.

Pure-guard violations involving mutable external state cannot necessarily be detected automatically. Their declarative results are unspecified.

Implementations should report the location of the offending declarative statement and, where applicable, the relation name and variable responsible for a validation error.

## 17 — Syntax

This section summarizes the grammar additions.

The notation follows the extended BNF conventions of the Lua reference manual.

The nonterminals `exp`, `block`, `Name`, and related existing grammar productions retain their Lua 5.4 meanings.

### 17.1 — Added Lexical Forms

```ebnf
symbol         ::= ':' Name
logicvar       ::= '?' Name
anonymous      ::= '?' '_'
ruleop         ::= ':-'
```

The anonymous-variable form is treated specially and is not a named binding.

### 17.2 — Statements

```ebnf
factstat       ::= 'fact' relref '(' [expargs] ')'

retractstat    ::= 'retract' relref '(' [expargs] ')'

relationstat   ::= 'relation' Name '(' integer ')'

localrelstat   ::= 'local' 'relation'
                   Name '(' integer ')'

rulestat       ::= 'rule' relref '(' [headargs] ')'
                   ':-' goal { ',' goal }

worldstat      ::= 'logic' '(' exp ')' 'do'
                   block 'end'
```

### 17.3 — Query Expressions

```ebnf
queryexp       ::= 'query' relatom
                 | 'query' '{' goal { ',' goal } '}'
```

A simple query is equivalent to a braced query with one positive atom.

### 17.4 — Relation References

```ebnf
relref         ::= Name
                 | worldpath '.' Name

worldpath      ::= Name { '.' Name }

relatom        ::= relref '(' [terms] ')'
```

In an explicitly qualified reference, all components of `worldpath` are ordinary Lua field accesses. The final name is a static relation identifier.

### 17.5 — Terms and Arguments

```ebnf
headargs       ::= headterm { ',' headterm }

expargs        ::= exp { ',' exp }

terms          ::= term { ',' term }

headterm       ::= logicvar
                 | exp

term           ::= logicvar
                 | anonymous
                 | exp
```

An `exp` used as a relational term may not contain logic variables. Logic variables are permitted within procedural guard expressions.

### 17.6 — Goals

```ebnf
goal           ::= relatom
                 | 'not' relatom
                 | comparison
                 | guard

guard          ::= 'where' '(' guardexp ')'

comparison     ::= term compareop term

compareop      ::= '==' | '~='
                 | '<'  | '<='
                 | '>'  | '>='
```

The production `guardexp` is a Lua expression extended to permit references to logic variables as primary expressions.

Its logic-variable references are reads from the current binding environment, not new bindings.

### 17.7 — Grammar Integration

The Lua statement grammar is extended with:

```ebnf
stat           ::= ...
                 | factstat
                 | retractstat
                 | relationstat
                 | localrelstat
                 | rulestat
                 | worldstat
```

The expression grammar is extended with:

```ebnf
exp            ::= ...
                 | symbol
                 | queryexp
```

Logic variables are not general-purpose Lua expressions outside declarative contexts.

## 18 — Examples

### 18.1 — Reachability

```lua
fact edge(:a, :b)
fact edge(:b, :c)
fact edge(:c, :a)
fact edge(:c, :d)

rule path(?x, ?y) :-
    edge(?x, ?y)

rule path(?x, ?y) :-
    edge(?x, ?z),
    path(?z, ?y)

for m in query path(:a, ?target) do
    print(m.target)
end
```

Cycles do not cause indefinite recursive derivation.

The relation `path` contains each reachable pair once.

### 18.2 — Procedural Fact Generation

```lua
local blocked = {
    lava = true,
    acid = true,
    radiation = true
}

for name in pairs(blocked) do
    fact hazard(symbol(name))
end

rule traversable(?a, ?b) :-
    edge(?a, ?b, ?terrain),
    not hazard(?terrain)
```

### 18.3 — Independent Worlds

```lua
fact edge(:a, :b)

local simulation = logic.world()

fact edge(:b, :c)

logic (simulation) do
    fact edge(:b, :d)

    for m in query edge(?x, ?y) do
        print(m.x, m.y)
    end
end
```

The simulation inherits the first edge but does not observe the edge inserted into the global world after the simulation's creation.

### 18.4 — Local Recursive Computation

```lua
function closure(start)
    local relation result(1)

    rule result(?x) :-
        edge(start, ?x)

    rule result(?x) :-
        result(?y),
        edge(?y, ?x)

    return query result(?node)
end

local iterator = closure(:a)

for match in iterator do
    print(match.node)
end
```

The local relation does not permanently modify the global world's rule set.

### 18.5 — Recursive Computation with a Guard

```lua
function affordable_routes(start, limit)
    local relation affordable(1)

    rule affordable(?room) :-
        edge(start, ?room, ?cost),
        where (?cost <= limit)

    rule affordable(?room) :-
        affordable(?previous),
        edge(?previous, ?room, ?cost),
        where (?cost <= limit)

    return query affordable(?destination)
end
```

This example limits each individual edge's cost. It does not compute a cumulative minimum path cost.

### 18.6 — Conjunctive Queries

```lua
for match in query {
    person(?person),
    works_at(?person, :laboratory),
    knows(?person, ?colleague),
    not retired(?colleague)
} do
    print(match.person, match.colleague)
end
```

### 18.7 — Mutable Facts and Derived Relations

```lua
fact node(:a)
fact node(:b)

fact blocked(:a)

rule available(?x) :-
    node(?x),
    not blocked(?x)

for m in query available(?x) do
    print(m.x)  -- :b
end

retract blocked(:a)

for m in query available(?x) do
    print(m.x)  -- :a and :b
end
```

The derived relation is updated logically after the retraction.

## 19 — Compatibility and Extension Boundaries

### 19.1 — Lua Compatibility

The extension preserves the ordinary semantics of Lua 5.4 except for the introduction of new syntactic forms, a symbol value type, and standard declarative facilities.

Existing valid Lua expressions and statements retain their meanings.

The extension does not require ordinary Lua functions or tables to become logical relations.

### 19.2 — Features Not Defined in Version 0.1

The following features are outside the scope of this specification:

- Arbitrary Prolog-style compound terms and unification of term trees.
- Prolog cuts and procedural search control.
- Non-stratified negation or well-founded semantics.
- General constraint solving over infinite domains.
- Aggregation operators in rule bodies.
- Disjunctive rule heads.
- Provenance and derivation tracing.
- Probabilistic or weighted relations.
- Automatic detection of dependencies on mutable Lua objects.
- Reactive updates to previously returned query records.
- Cross-world rule dependencies.
- Transactions involving multiple worlds.
- Individual rule deletion and rule replacement.

These facilities may be added by subsequent revisions without changing the fundamental fact, rule, local relation, and query syntax.

### 19.3 — Implementation Conformance

An implementation conforms to version 0.1 if it:

1. Accepts the grammar defined in §17.
2. Implements symbol identity and relational equality as specified.
3. Implements fact and rule registration at runtime.
4. Enforces rule safety and stratified negation.
5. Computes the specified least-fixed-point relational results.
6. Supports independent worlds with snapshot inheritance.
7. Supports lexically scoped recursive local relations.
8. Produces query iterators with snapshot and set semantics.
9. Preserves the specified interaction with Lua scoping, function calls, and error handling.

The implementation may use any internal representation or evaluation strategy satisfying these requirements.


