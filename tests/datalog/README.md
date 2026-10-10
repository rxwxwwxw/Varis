# Datalog scenario programs

Nineteen small, self-checking Lua programs that cover the base declarative
facilities in the [Varis reference](../../docs/relations.md), and double as
benchmarks. The coverage table and source comments retain former specification
section numbers, resolved by the [migration map](../../docs/coverage.md).

```sh
make test-scenarios                              # unit tests + both scales + known gaps
python3 tests/datalog/run.py --scale small 08    # one program, hand-checkable size
python3 tests/datalog/run.py --record            # deliberately rewrite golden output
make benchmark-datalog                           # includes the "scenarios" suite
```

## How a program reads

Each program starts with a comment saying which spec sections it covers and,
where a count is not obvious, the closed-form formula it must satisfy. Then it
alternates short code blocks with calls to

```lua
expect("label", got, want)      -- asserts got == want, prints "label<TAB>got"
```

so the printed lines are the observable behaviour and the expected value sits
right next to the code that produces it. Programs never depend on result order;
they print counts, or sorted `collect(...)` strings of one field. Nothing is
trusted from a golden file alone: `want` is derived in the source (for example
`N * (N - 1) // 2` pairs on a chain of `N` nodes).

Every program takes the scale as its first argument (`arg[1]`):

| scale | purpose | typical size |
| --- | --- | --- |
| `small` | a reasonable person can verify it by hand; run in the milliseconds | 4–10 nodes |
| `large` | benchmark workload; 0.2–2.4 s each on the reference machine | 50–60 000 items |

`expected/NAME.SCALE.txt` is the exact stdout for each pair; `run.py` fails on
any difference, a non-zero exit, a crash or a timeout.

## Coverage

| Program | Spec | What it establishes |
| --- | --- | --- |
| `01_symbols` | §2.1–2.2, §15.2 | interning, `symbol()`, `symbolname`, `tostring`, binary names, table keys, no ordering, `:` vs methods/labels |
| `02_facts_and_relations` | §4, §5 | declarations, arity, set semantics, retraction, raw equality (`1`/`1.0`, tables), loop-executed facts, single-value arguments |
| `03_transitive_closure` | §6.3, §13.1 | right, left and doubly recursive closures agree; chain size formulas |
| `04_cycles` | §1.2, §6.3, §18.1 | cycles terminate; ring of N has N² pairs; cutting the ring |
| `05_rule_unions` | §6.2, §6.5–6.7 | union of same-head rules, mutual recursion, duplicate rules, head constants, rule lifetime |
| `06_stratified_negation` | §8.1–8.3, §13.2 | three strata, effect of changing a negated relation, rejected cycle |
| `07_comparisons_and_guards` | §8.4, §9 | all six comparisons, int/float and string ordering, type errors, truthiness, first result, capture by value, prime sieve with guards |
| `08_mutation_and_invalidation` | §4.4, §5.3–5.4, §13.3, §18.7 | retraction invalidates derived tuples, base+derived overlap, repeated cut/restore |
| `09_query_semantics` | §12 | iterator protocol, snapshots, projection, anonymous/repeated variables, ground queries, nil bindings, immutable records, many live snapshots |
| `10_worlds` | §11 | snapshot inheritance both ways, rules, qualified names, field-chain qualifiers, `logic.add/retract`, world blocks, shared references, inherited guards |
| `11_local_relations` | §10, §14.3 | per-call relations, shadowing, qualified bypass, iterator outliving its function, redeclaration, local→world association, world-rule rejection |
| `12_constants_and_capture` | §5.1, §7 | single evaluation at statement/rule/query construction, capture per invocation, truncated multi-results, NaN constants |
| `13_errors_and_atomicity` | §14.4, §16, §9.5, §12.10 | every listed error, failed registration leaves no state, guard errors and yields, invalid iterators |
| `14_conjunctive_queries` | §12.2, §12.8, §18.6 | multi-relation joins with negation, comparisons and guards |
| `15_coroutines` | §14.6 | suspended iterators keep snapshots, coroutines build and mutate worlds |
| `16_contextual_syntax` | §3, §17 | keywords as ordinary names, `:`/`?` contexts, free-form layout, generated source |
| `17_same_generation` | §6.3 | classic recursive benchmark with a closed form |
| `18_triangles` | §6.4, §8.4 | three-way self join with ordering constraints |
| `19_grid_reachability` | §8, §11.7, §13.2 | negation inside recursion, two worlds from one rule set |

The nine conformance requirements of §19.3 map to: grammar (16), symbols and
equality (01, 02), runtime registration (05, 12), safety/stratification (06, 13),
fixed points (03, 04, 17), worlds (10, 19), local relations (11), snapshot/set
iterators (09, 15), scoping and errors (12, 13).

## Known gaps

`known_gaps/*.lua` are tiny programs for spec behaviour the interpreter does
not yet have. Each names the diagnostic it currently produces in a
`-- KNOWN-GAP:` line. The runner reports them as `XFAIL`; if one starts to
succeed (`XPASS`) or fails with a different diagnostic, the run fails so the
change is noticed and the program is moved into the numbered suite.

| Program | Spec | Current behaviour |
| --- | --- | --- |
| `constant_left_comparison` | §17.6 | `limit < ?a` is a syntax error; only `?a > limit` parses |
| `anonymous_in_comparison` | §3.4 | `?a == ?_` is accepted; the spec says it is an error |
| `world_block_checks_entry` | §11.7 | `logic (5) do end` is accepted; only a declarative statement inside notices |

## Performance notes

The large scale is sized so the whole suite takes ~18 s. Two behaviours dominate:
every query recomputes its dependency closure (nothing is reused between
queries), and a right-recursive closure over a chain costs far more than linear
per doubling of the chain (a 80-node chain: 0.19 s per query; 160 nodes: 2.4 s,
a 13x increase). The `03`, `06`, `08` and `18` programs are the ones that expose
this; see [benchmarks/README.md](../../benchmarks/README.md) for how regressions
are enforced.
