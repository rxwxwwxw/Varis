# Benchmarks

One suite, one driver: `python3 tools/suite bench` (Make: `make bench`, `make bench-check`).
Design and rationale: [CONSOLIDATION_PLAN.md](../CONSOLIDATION_PLAN.md) §4.

## What is measured

| Group | Kind | Source | Comparators |
| --- | --- | --- | --- |
| `core` | in-process (`os.clock`, load once, warm once, 5 timed repeats per sample) | `workloads/core/*.lua` | C Lua, previous versions |
| `programs` | fresh process, CPU time (rusage) | `workloads/programs/*.lua` | C Lua (output must match) |
| `regression` | fresh process | `tests/regression/*.lua` (checksum programs reused) | C Lua |
| `startup` | fresh process | `workloads/startup/*.lua` | C Lua |
| `datalog` | fresh process, `large` scale | `tests/datalog/NN_*.lua` | previous versions only |
| `narrative` | fresh process | `sample-game/tools/check.lua` | previous versions only |

Every sample is interleaved across interpreters (alternating order); ratios are paired per
sample and the **median of paired ratios** is reported. Peak RSS is recorded. A candidate
whose samples have CV > 15 % is flagged `noisy`.

## Comparators

Declared in [manifest.toml](manifest.toml): `clua` (stock Lua 5.4.9, `-O2`),
`v0-snapshot` (git tag `baseline/v0-snapshot`, the pre-optimization tree) and
`v1-perf-final` (tag `baseline/v1-perf-final`). A git-ref comparator is built on demand with
`make varis` in a worktree under `.cache/src/` and cached by (commit, profile, compiler) in
`.cache/builds/`. Add a `release-*` tag and a `prev` comparator when releases begin.

## Targets

[targets.toml](targets.toml): per workload,

* `goal.<comparator>` – project target (≤ 2.0× C Lua). Reported as "behind goal", never fatal.
* `gate.<comparator>` – regression ratchet; exceeding it fails `make bench-check`
  (confirmed by two re-runs before failing).
* `floor.<comparator>` – minimum speedup over an older version.

Gates are derived from measurement (`python3 tools/suite targets benchmarks/baselines/*.json`):
worst observed ratio × 1.10 (core) or × 1.20 (others; 1.60 for workloads under 20 ms) plus
0.10 absolute slack; floors are 60 % of the measured speedup over `v0-snapshot`.
Gates only tighten automatically. Loosening one (or a floor) is blocked by the commit-msg
hook unless the message carries `Perf-Regression-Accepted: <reason>`.

Known cost centres are visible as goal misses: `core.pcall_error` (D exceptions through the
platform unwinder) and `core.deep_recursion` (flat-stack executor past ~150 frames).

## Commands

```sh
make bench                          # report only
make bench-check                    # enforce gates/floors/memory
python3 tools/suite bench --group core --filter fib --runs 11
python3 tools/suite bench --list
make bench-record LABEL=2026-11-01  # store benchmarks/baselines/LABEL.json
```

A comparator entry may set `runs = N` to cap its interleaved samples (none does at present).
Gates are strict: a machine busy with other work can make memory-heavy workloads such as
`core.deep_recursion` exceed its `gate.clua`; that is a failed check, not an exemption. Run the
benchmarks on an idle machine.

Run on an otherwise idle machine. Ratios are portable between machines; absolute seconds are not
and are never enforced. `history/2026-10-09-perf/` holds the pre-suite experiment records
(including the old suite-level Datalog baseline); they are informational only.
[PERFORMANCE_WORK.md](PERFORMANCE_WORK.md) records the optimization work itself.

## Acceptance check: a synthetic slowdown trips exactly the expected gates

Reproducible from the committed harness: `python3 tools/suite/tests/synthetic_slowdown.py` (also the
`bench-gates.synthetic-for-loop-slowdown` case of the `release` test tier) builds a scratch worktree of
`HEAD` with three atomic additions in the `for`-loop handler (about 3.7× on `for` loops), runs `bench --check`
on eight core workloads and requires exactly `numeric_loop`, `array_access` and `sieve` to fail; the
other five pass. (A milder two-atomic variant was +29 % on `array_access` and +122 % on `numeric_loop`
and did trip those two, but `sieve` is a 3 ms workload with 1.6× gate headroom and sat just inside it.) The original one-off record follows.

Recorded 2026-10-10 (plan Phase 3 done-criterion). A scratch worktree of `main` was built with
three atomic additions injected into the `ForLoop` handler of the interpreter loop (about 3.7× on
`for` loops), then run as `python3 tools/suite bench --check --group core --candidate <that build>`:

| Workload | Candidate / C Lua | Candidate / `v1-perf-final` | Result |
| --- | --- | --- | --- |
| `core.numeric_loop` | 5.34× | 3.33× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| `core.array_access` | 3.58× | 1.96× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| `core.sieve` | 3.29× | 2.45× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| the other 12 core workloads (no numeric `for` loop on their hot path) | unchanged | 0.99–1.03× | pass |

Exit status was non-zero and named exactly those three workloads. A milder +11 % injection on
`numeric_loop` stayed inside its 1.20× gate, which is the intended headroom, not a miss.
