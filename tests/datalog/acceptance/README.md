# Lua 5.4 declarative extension — untyped conformance examples

This package contains **15 self-contained Lua programs** targeting the untyped
`fact` / `rule` / `query` extension described in the proposed v0.1 language
reference. The syntax is **not valid in stock Lua 5.4**; execute it with your
D-based extended Lua interpreter once the respective features are implemented.

## Running

```sh
./run-tests.sh /path/to/your-lua-interpreter
# or
LUA_BIN=/path/to/your-lua-interpreter ./run-tests.sh
```

The runner expects 12 programs under `positive/` to exit successfully and 3
programs under `negative/` to produce a validation error. Every positive program
checks its own results using Lua `assert`. Neither result order nor indexing
strategy is prescribed. All `negative/` files include a fallback error tagged
`UNEXPECTED SUCCESS`, which the runner detects so that arbitrary errors cannot
conceal a wrongly accepted invalid rule.

Both runners (`run-tests.sh` and the unified driver's `rejection` suite, whose expected
diagnostics live in `tests/manifest.toml`) require the intended diagnostic and reject crashes,
timeouts and the fallback marker, so an unrelated error cannot pass as a rejection.

## Programs

| File | Expected | Coverage |
| --- | --- | --- |
| `positive/01_symbols_and_facts.lua` | Pass | Interned symbols, type, dynamic constructors, symbol table keys, duplicate facts |
| `positive/02_recursive_reachability.lua` | Pass | Recursive closure, graph cycles, fixed point, ground queries |
| `positive/03_stratified_negation_and_retraction.lua` | Pass | Closed-world negation, invalidation on fact changes, base vs derived tuples |
| `positive/04_conjunctive_queries.lua` | Pass | Braced multi-goal queries, joins, variable equality, comparison, negation, guard |
| `positive/05_pure_guards_and_capture.lua` | Pass | Lua guard functions, variable values, rule-time capture |
| `positive/06_procedural_fact_generation.lua` | Pass | Procedural fact generation, symbols from strings, `logic.add` and `logic.retract` |
| `positive/07_world_snapshot_inheritance.lua` | Pass | Inherited rules and data, copy-on-write/snapshot semantics, qualified predicates |
| `positive/08_empty_parent_and_world_blocks.lua` | Pass | Empty worlds, explicit parent snapshots, nested lexical default-world blocks |
| `positive/09_local_relation_closures.lua` | Pass | Local recursive relations, per-invocation isolation, escaping query iterators |
| `positive/10_local_mutual_recursion.lua` | Pass | Local mutually recursive relations, local base fact, cyclic derivation |
| `positive/11_iterator_snapshot_and_immutability.lua` | Pass | Query-time snapshots, callable iteration, immutable result records |
| `positive/12_zero_arity_nil_and_projection.lua` | Pass | Arity-zero facts, `nil` bindings, false/zero distinction, anonymous-variable projection |
| `negative/13_unsafe_negation.lua` | Reject | Unsafe variable used only in negated atom |
| `negative/14_negation_cycle.lua` | Reject | Mutual dependency through negation violates stratification |
| `negative/15_relation_arity_mismatch.lua` | Reject | Fact incompatible with declared relation arity |

## Important assumptions

These tests intentionally follow the **proposed** untyped language semantics,
not an existing implementation. In particular:

1. `:name` is an interned primitive symbol, distinct from strings.
2. `relation name(N)` and `local relation name(N)` declare relations; ordinary
   relation declarations are optional when implicitly introduced by facts/rules.
3. `?name` is a scoped logic variable; `?_` denotes a fresh anonymous variable.
4. `query relation(...)` and `query { ... }` return callable generic-for iterators.
5. Queries use **set semantics**, projecting onto all named query variables and
   removing duplicate result bindings.
6. Result bindings are immutable and support named field access; `logic.binding`
   and `logic.hasbinding` handle `nil` values.
7. Registered rules capture Lua constants (including guard-local values) when
   executed, not when evaluated later.
8. `logic.world()` inherits the global world's fact/rule snapshot, while
   `logic.world(parent)` snapshots `parent`, and `logic.emptyworld()` starts empty.
9. `logic (world) do ... end` establishes a lexically scoped default world.
10. Local recursive relations are collected only when no iterator or closure
    retains them.
11. The specific implementation may validate erroneous rules either during
    compilation or during rule registration. Both count as expected rejection.

## Non-goals

These are functional examples, not microbenchmarks or fuzz tests; they run in the `acceptance`
and `rejection` suites of the unified driver (`python3 tools/suite test --suite acceptance --suite rejection`).
Datalog performance is measured on the larger scenario programs in the parent directory
(`python3 tools/suite bench --group datalog`; see [benchmark details](../../../benchmarks/README.md)).
They do not test typed extensions, aggregates, cross-world
rule dependencies, full purity certification, transactions, or rule removal.
