# Benchmarks

One suite, one driver: `python3 tools/suite bench` (Make: `make bench`, `make bench-check`).

**Role since October 11, 2026:** matching C Lua is no longer a project goal. The C Lua ratios
below are kept as regression gates for the procedural core. The performance targets that matter
for the product (turn latency, content load time and memory on a reference game running on
low-end hardware) are planned in [ROADMAP.md](../ROADMAP.md), Phase 11, and are **not yet in this
suite**; the `datalog`, `scenarios`, `narrative` and `narrative_e2e` groups are the closest existing
measures. [PERFORMANCE_PLAN.md](PERFORMANCE_PLAN.md) has the first scale measurements (from
`experiments/synthetic_game.lua`, which is not part of the suite) and the staged plan.
Design and rationale: [CONSOLIDATION_PLAN.md](../CONSOLIDATION_PLAN.md) §4.

## What is measured

| Group | Kind | Source | Comparators |
| --- | --- | --- | --- |
| `core` | in-process (`os.clock`, load once, warm once, up to 5 timed repeats per sample; 3 or 2 for kernels slower than 0.1 s / 0.3 s) | `workloads/core/*.lua` | C Lua |
| `programs` | fresh process, CPU time (rusage) | `workloads/programs/*.lua` | C Lua (output must match) |
| `regression` | fresh process | `tests/regression/*.lua` (checksum programs reused) | C Lua |
| `startup` | fresh process | `workloads/startup/*.lua` | C Lua |
| `datalog` | in-process kernels, fresh world per run | `workloads/datalog/*.lua` | none (absolute budget only) |
| `scenarios` | fresh process, `large` scale | `tests/datalog/NN_*.lua` | none (absolute budget only) |
| `datalog_comp` | fresh process, paired `.lua`/`.dl` programs | `workloads/datalog_comp/*` | Soufflé (normalized output must match) |
| `narrative` | in-process kernels on the sample game | `workloads/narrative/*.lua` | none (absolute budget only) |
| `narrative_e2e` | fresh process | `sample-game/tools/check.lua` | none (absolute budget only) |

Every sample is interleaved across interpreters (alternating order); ratios are paired per
sample and the **median of paired ratios** is reported. Peak RSS is recorded. A candidate
whose samples have CV > 15 % is flagged `noisy`. Sampling stops after 3 rounds when a workload's
samples are expensive (≥ 0.4 s each) and agree within 3 % CV, so long kernels are not repeated
needlessly. A full `bench --check` takes about two minutes.

## Comparators

Declared in [manifest.toml](manifest.toml): `clua` (stock Lua 5.4.9, `-O2`) and, for the
`datalog_comp` group only, `souffle` (the Soufflé interpreter, single-threaded, found on `PATH`). Older versions
(`baseline/v0-snapshot`, `baseline/v1-perf-final`) were retired as comparators: they were 10–40×
slower and cost more than 80 % of the run time. The mechanism for `ref = "<git ref>"` comparators
(built on demand under `.cache/`) remains available for ad-hoc comparisons, e.g. a future
`release-*` tag, via `--compare`.

## Targets

[targets.toml](targets.toml): per workload,

* `goal.<comparator>` – an informational ratio against C Lua: 1.2 on twelve `core` workloads
  (set in commit `15522b1`) and 2.0, the former project target, elsewhere. Reported as
  "behind goal", never fatal; no planned work aims at these values.
* `gate.<comparator>` – regression ratchet; exceeding it fails `make bench-check`
  (confirmed by two re-runs before failing).
* `gate.time` – absolute budget in candidate CPU seconds (per repetition for in-process kernels).
  It catches gross regressions without any comparator; `gate.clua` is the sharp,
  machine-independent check.
* `floor.<comparator>` – minimum speedup over a named comparator (none is defined at present).

Gates are derived from measurement (`python3 tools/suite targets benchmarks/baselines/*.json`):
worst observed ratio × 1.10 (core) or × 1.20 (others; 1.60 for workloads under 20 ms) plus
0.10 absolute slack; `gate.time` is the measured median × 1.5 (at least the group headroom), rounded
up to two significant figures and never below 0.02 s. Absolute budgets depend on the machine class:
re-derive them (`python3 tools/suite targets <bench.json> --merge` after deleting the old
`gate.time` lines) when the reference machine changes. Gates only tighten automatically.
Loosening one (or a floor) is blocked by the commit-msg
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

Gates are strict: a machine busy with other work can make memory-heavy workloads such as
`core.deep_recursion` exceed its `gate.clua`; that is a failed check, not an exemption. Run the
benchmarks on an idle machine.

Run on an otherwise idle machine. Ratios are portable between machines; the absolute
`gate.time` budgets are generous (50 % headroom) but belong to this machine class. `history/2026-10-09-perf/` holds the pre-suite experiment records
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

| Workload | Candidate / C Lua | Candidate / `v1-perf-final` (retired comparator) | Result |
| --- | --- | --- | --- |
| `core.numeric_loop` | 5.34× | 3.33× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| `core.array_access` | 3.58× | 1.96× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| `core.sieve` | 3.29× | 2.45× | **GATE** clua, **GATE** v1, **FLOOR** v0 |
| the other 12 core workloads (no numeric `for` loop on their hot path) | unchanged | 0.99–1.03× | pass |

Exit status was non-zero and named exactly those three workloads. A milder +11 % injection on
`numeric_loop` stayed inside its 1.20× gate, which is the intended headroom, not a miss.
