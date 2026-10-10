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

Run on an otherwise idle machine. Ratios are portable between machines; absolute seconds are not
and are never enforced. `history/2026-10-09-perf/` holds the pre-suite experiment records
(including the old suite-level Datalog baseline); they are informational only.
[PERFORMANCE_WORK.md](PERFORMANCE_WORK.md) records the optimization work itself.
