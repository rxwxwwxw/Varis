# Consolidation Plan: one test suite, one benchmark suite, a real repository

Status: **implemented** (October 10, 2026). The body below is the plan as originally
written, before the language was renamed from `dlua` to **Varis**; read `dlua` as the
previous name (`source/dlua` is now `source/varis`, `bin/dlua` is `bin/varis`).
The rename was done immediately after Phase 3 rather than as a later stage.

## Implementation record

| Phase | Result |
| --- | --- |
| 0 Git and history | Repository initialized; commit 0 = Oct 9 19:19 snapshot (tag `baseline/v0-snapshot`), commit 1 = tree after the perf work (`baseline/v1-perf-final`). The snapshot builds and passes acceptance (15/15). `dlua.zip` had been overwritten with the current tree before import; the snapshot was recovered from an earlier extraction and archived in `.cache/legacy/` (ignored). The experiment binaries `dlua-{values,registers,callstorage}` had been deleted from `bin/` before they could be archived; their results remain in `benchmarks/history/`. |
| 1 Formatting, hooks | dfmt 0.15.2 with `.editorconfig` (otbs, 120 columns, `keep_line_breaks`); formatting is one commit listed in `.git-blame-ignore-revs`. Hooks in `.githooks/` (pre-commit, commit-msg, pre-push); `make hooks/fmt/fmt-check/check-sources/check`. |
| 2 Test suite | `tools/suite` + `tests/manifest.toml`: 145 cases / 221 results, tiers smoke/fast/full, ledger, parity mutation tests (`tools/suite/tests`), traceability (`tests/requirements.toml` → `tests/TRACEABILITY.md`), shared debug object set, per-test D `unittest` results. Full tier about 45 s, fast about 10 s. |
| 3 Benchmark suite | `tools/suite bench`: 73 workloads in seven groups (`core`, `programs`, `regression`, `startup`, in-process `datalog` and `narrative` kernels, end-to-end `scenarios` and `narrative_e2e`), comparators `clua`/`v0-snapshot`/`v1-perf-final` built from git refs, goals/gates/floors in `benchmarks/targets.toml`, confirmation re-runs, baselines in `benchmarks/baselines/`, `suite report`/`make status` → `docs/STATUS.md`. Old runners retired. The synthetic-slowdown check is recorded in `benchmarks/README.md`. |
| 4 Docs, cleanup | README/AGENTS updated (commands, git workflow); acceptance programs moved to `tests/datalog/acceptance/`; legacy Makefile targets removed; `make test-legacy` removed. |
| 5 Rename | Done: module tree, binary, Makefile targets, headers (PUC-Rio notice preserved), docs. `_VERSION` and `lua_*` C API names unchanged. The checkout directory name on disk is outside the repository. |

Found while implementing: `narrative.analyze` broke host `io` file handles (per-module FILE* metatable
overwritten by the analysis state; fixed, regression case `analysis_host_isolation`), and the intermittent
`all.lua` hang was a stale reserved register plus missing live-register data in binary chunks (fixed,
see tests/official/README.md; regression case `weak_stale_register`).

Deviations from the plan: the unit-test tier names are `smoke`/`fast`/`full` plus `release`
(benchmarks); `unit:` traceability names are D `@("name") unittest` blocks; GitHub Actions is deferred
until a remote exists; `docs/STATUS.md` is generated from the recorded baseline JSON (the full
benchmark run takes well over an hour on a loaded machine).

---

## 1. Where things stand

### 1.1 Repository

| Fact | Consequence |
| --- | --- |
| Not a git repository. 159 MB on disk, of which `bin/` is 152 MB of build output. | No history, no review diffs, no way to build "the previous version" except by hand. |
| No `.gitignore`; `.DS_Store`, `__pycache__/`, `*.o`, three experimental binaries in `bin/`. | Must be ignored before the first `git add`. |
| One earlier snapshot exists: `~/repos/varis.zip` (Oct 9 19:19, pre-optimization). Its `source/` differs from the current tree in 22 files and lacks `lib/fastcall.d`; it also lacks `benchmarks/workloads*`, and the regression programs `deepframes`, `fastpaths`, `wrapcalls` and extension case `narrative_sticky_order`. | It is the only buildable "previous version". It becomes commit 0. |
| `bin/varis-values`, `-registers`, `-callstorage` are experiment builds with no source (only `benchmarks/results/runtime-changes.patch`, 133 lines). | Record their SHA-256 in history metadata; never treat them as release baselines. |
| No formatter. Style is 4-space indent, same-line braces (`dfmt` defaults to Allman). | Needs an explicit dfmt config chosen by experiment, then one isolated reformat commit. |
| `dfmt` 0.15.2 is available via `brew` (not installed); `dub` is at `/usr/local/bin/dub`; `ldc2` at `/opt/homebrew/bin`. | No new toolchain dependencies beyond dfmt. |
| `"varis"` appears 5,402 times in 291 files; `module varis.*` / `import varis.*` in 55 source/test files. | The rename is mechanical but wide. Do not smear it across other work. |

### 1.2 Tests: seven mechanisms, four reporting formats

| Suite | Where | Runner | Cases | Wall time (release CLI) |
| --- | --- | --- | --- | --- |
| D unit tests | `tests/unit/*.d` | 7 binaries, each recompiling all 54 modules at `-g`; bare `assert` in `main`-called functions (53 test functions, no `unittest` blocks) | 7 executables | compile-dominated (not yet measured) |
| Datalog acceptance | `tests/datalog/acceptance/` | `run-tests.sh` | 12 positive + 3 negative | 0.5 s |
| Datalog scenarios | `tests/datalog/` | `run.py` + `known_gaps/` | 19 programs × 2 scales, golden output | 14.2 s |
| Extension/stress | `tests/extensions/` | `run-tests.py` | 54 cases | 0.9 s |
| Narrative | `tests/unit/test_narrative.d`, `tests/narrative/README.md` | D binary; README holds a hand-maintained requirement matrix | 14 functions | n/a |
| Differential regression | `tests/regression/` | `run.py` (vs C Lua, checksums in `expected.json`) | 15 programs | 0.6 s (Varis only) |
| Official Lua suite | `tests/runner.d`, `tests/official/` | D runner + `baseline.json`, `differential.py` | 33 files: 31 pass / 1 partial / 1 skip | minutes (`errors.lua` ~25 s, `all.lua` ~70 s) |
| Runner self-tests | `benchmarks/test_*.py`, `tests/*/test_*.py` | `unittest` | — | seconds |

Observations that drive the design:

* **Functional suites are already fast.** Everything except scenarios and the official suite
  runs in under 2 s. The slow parts of `make test` are the seven full recompiles and the
  official suite. A single "fast tier" should fit in well under a minute once builds are shared.
* **Every runner invents its own CLI flags, timeout variables, JSON and exit-code conventions.**
  There is no single report, no single place a skip/known-gap is accounted for.
* **Requirement coverage is a hand-maintained table** (`tests/narrative/README.md`), which
  AGENTS.md invariants 8–9 require to stay accurate. It will drift.

### 1.3 Benchmarks: four methodologies, one real target

| Mechanism | Method | Comparator | Gate |
| --- | --- | --- | --- |
| `benchmarks/bench.py` (6 workloads as inline strings) | in-process `os.clock`, warmup + 7×5 samples, interleaved | C Lua | `--max-ratio` flag, off by default |
| `benchmarks/workloads.py` + `workloads/*.lua` (11 programs) | whole-process wall, best of N | C Lua | none ("informational") |
| `benchmarks/regression.py` | wall time of the 15 regression programs | C Lua (output only) | 30 s budget |
| `benchmarks/datalog.py` | median wall time of *running the test suites* (acceptance, extensions, scenarios) | none | ±25 % + 0.1 s of **absolute seconds** from a machine-specific `datalog-baseline.json` |
| `benchmarks/results/*.json` (6 snapshots: before → final) | ad hoc, produced by `bench.py` | C Lua | none |

Current standing (`final-execution.json`, C Lua = 1.0): fib 1.92×, numeric loop 1.63×,
array 1.64×, hash 1.42×, string 0.59×, sieve 1.33×. Before the perf work the same six were
43×, 23×, 17×, 6×, 8×, 20×. `fib(30)`: C Lua 0.060 s, current 0.111 s, the Oct 9 snapshot's
shipped binary 2.61 s.

Problems:

1. **The Datalog "benchmark" times the test runners**, including process start and Python
   overhead, at suite granularity. A 3× regression in one scenario hides inside a 17.7 s median.
2. **Absolute-second baselines are not portable** and are the opposite of what the project
   needs. Ratios against a comparator measured *in the same session* are portable.
3. **The project's own target (≤ 2× C Lua per workload, no geometric-mean cover) is not
   enforced anywhere**, and fib at 1.92–2.3× sits on the line.
4. **"Previous versions" are not addressable.** Result files are named by experiment, not by
   the code that produced them, so nobody can re-run "the version before the register work".
5. Workload bodies live inside Python strings (`bench.py`) or a second directory (`workloads/`),
   with different check conventions.
6. No memory or startup targets, no `pcall`/error-path, GC-pressure, parse/compile throughput,
   or narrative-session workloads (known cost centers and the whole second half of the project).

---

## 2. Principles

1. **Targets are ratios against a comparator run in the same session**, never absolute seconds.
   Absolute numbers are recorded for humans, not enforced.
2. **Three kinds of target**, and the report never blurs them:
   * *Goal* – what the project wants (e.g. ≤ 2.0× C Lua). Failing a goal is reported, not fatal.
   * *Gate* – the ratchet that stops regressions (current measured value × headroom). Failing is fatal.
   * *Floor* – "must stay at least N× faster than version V" (previous-version targets).
3. **Ratchet, never reset.** Gates only tighten automatically. Loosening one is an explicit,
   reviewed edit that must carry a reason (enforced by a commit-msg hook). This is AGENTS.md
   "do not reset baselines to conceal regressions", made mechanical.
4. **Skips and known gaps are a ledger, not a silent status.** Each has an id, reason and owner
   field in the manifest; the gate fails if a skip appears that the ledger does not list, and
   if a "known gap" case starts passing (so the entry gets removed).
5. **One schema, many adapters.** Adopt existing runners first (zero semantic risk), prove parity,
   then fold them in natively and delete the duplicates.
6. **Builds are identified by (git commit, flags, compiler version).** A comparator is a git ref
   plus build profile, built on demand and cached; never a loose binary.
7. **The harness is name-agnostic** (Section 3.6): the candidate binary is a parameter.

---

## 3. Target design

### 3.1 Layout (end state; moves happen late, with `git mv`)

```
tools/
  suite/                 # stdlib-only Python 3.11+ package; the single driver
    __main__.py          # `suite test`, `suite bench`, `suite report`, `suite build`
    adapters/            # one module per case kind (lua, d-unit, official, golden, diagnostic…)
    schema.py            # result/baseline/target schemas (+ validation)
  check_sources.py       # every source/**/*.d is listed in Makefile; license header present
  hooks/                 # dfmt check, header check, size guard (called by .githooks/*)
tests/
  manifest.toml          # all cases: id, kind, path, tags, tier, timeout, covers, skip/gap ledger
  unit/  lua/  datalog/  extensions/  narrative/  official/    # content only; runners retire
benchmarks/
  manifest.toml          # workloads: id, file, params, category, check, comparators
  targets.toml           # goals, gates, floors (Section 4.2)
  workloads/{core,programs,datalog,narrative,startup}/*.lua
  baselines/             # committed result JSON per named version (schema-validated)
  history/               # the 2026-10-09 perf-work series, converted to the new schema
.githooks/  .gitignore  .gitattributes  .editorconfig  .git-blame-ignore-revs
```

### 3.2 Test manifest

One case = one row. Existing runners' semantics are preserved by the adapter that executes the row.

```toml
[[case]]
id      = "datalog.scenario.03_transitive_closure"
kind    = "golden-lua"            # run script, compare stdout to expected/, exit 0
path    = "tests/datalog/03_transitive_closure.lua"
tags    = ["datalog", "scenario"]
tier    = "fast"                  # smoke | fast | full | stress
timeout = 120
covers  = ["V1-R2", "V1-R3"]      # requirement ids; drives the traceability report

[[case]]
id      = "extensions.keyed.conflict_in_nested_savepoint"
kind    = "extension-case"
...

[[ledger]]                        # skips and known gaps
id     = "official.gc"
status = "skip"                   # skip | known-gap | partial
reason = "exact reachability conflicts with D-accessible objects (owner decision)"
```

Result schema (one JSON-lines record per case, one summary document per run):
`{id, suite, status: pass|fail|skip|known-gap|xpass|timeout|error, seconds, detail, binary: {sha256, profile, commit}}`.

### 3.3 Tiers

| Tier | Contents | Budget | Used by |
| --- | --- | --- | --- |
| `smoke` | build + parser/VM unit group, acceptance, 5 regression programs | < 30 s | pre-commit (optional), inner loop |
| `fast` | everything except official suite and stress | < 2 min *(target)* | pre-push, PR |
| `full` | `fast` + official suite + extension stress + large-scale scenarios | ~10 min | before merging to main |
| `release` | `full` + benchmark gates + optimized-with-assertions build | ~25 min | tags |

### 3.4 Build model

* Three profiles under `build/<profile>/`: `debug` (`-g`, unit tests), `checked` (`-O3`
  *without* `-release`, assertions on — what AGENTS.md invariant 10 calls "optimized
  assertion-enabled validation"), `release` (`-O3 -release`, the CLI). They no longer overwrite each other.
* Unit tests link a once-built object set (or a static library) instead of recompiling 54
  modules seven times; a single `tests/unit` binary with group selection replaces seven.
* The explicit `SRC_FILES` list stays in the Makefile (AGENTS.md says to keep it explicit);
  `tools/check_sources.py` fails the hook if a module on disk is missing from it.
* Comparator builds: `git worktree add .cache/src/<sha> <ref>` → `make varis` with the same
  profile → `.cache/builds/<sha>-<profileHash>/varis`. The C Lua reference is built once into
  `.cache/builds/clua-5.4.9-O2/` with its flags recorded (it is `-O2`; Varis is `-O3`).

### 3.5 Repository hygiene

* `.gitignore`: `build/`, `bin/`, `.cache/`, `*.o`, `__pycache__/`, `.DS_Store`,
  `c-implementation/src/{*.o,lua,luac,liblua.a}`, `benchmarks/results/local/`.
* `.gitattributes`: `c-implementation/lua-5.4.9-tests/** -text` (the official suite contains
  byte-exact fixtures; line-ending normalization would silently change them), `*.d text eol=lf`.
* `c-implementation/` stays vendored (3.2 MB, license obligation, offline reference); only
  build outputs are ignored. A pinned SHA-256 for the 5.4.9 tarball goes in `tools/versions.toml`.
* **Hooks** live in `.githooks/`, enabled by `make hooks` (`git config core.hooksPath .githooks`).
  No third-party hook framework: this is a one-developer, Python-already-required project.
  * `pre-commit` (< 5 s): dfmt conformance of staged `.d` files (dfmt has no check-only flag
    to my knowledge, so compare its stdout with the staged blob), license header on new `.d`
    files, `check_sources.py`, blob > 1 MB or anything under `bin/`/`build/`, `git diff --cached --check`.
  * `commit-msg`: if `benchmarks/targets.toml` or the ledger is loosened, require a
    `Perf-Regression-Accepted:` / `Skip-Accepted:` trailer with a reason.
  * `pre-push`: `suite test --tier fast`.
  * Benchmarks are deliberately **not** in hooks (noise, duration).
* **Formatting**: choose settings by experiment (Phase 1), commit once, list that commit in
  `.git-blame-ignore-revs`, and set `blame.ignoreRevsFile`. `make fmt` rewrites, `make fmt-check` verifies.

### 3.6 Rename readiness

Make these true *before* a name is chosen, so choosing one is a find-and-replace:

* The harness takes `--candidate PATH` (default from `$SUITE_BIN` or `build/release/<NAME>`);
  `NAME` is one Makefile/`tools/versions.toml` variable. No test or baseline stores the name;
  baselines are keyed by version label + commit.
* Test expectations that embed the name (chunk names, `_VERSION`, error prefixes) are listed by
  a grep audit in Phase 2 and either normalized or tagged `name-sensitive` so they are the only
  files the rename touches in `tests/`.
* The rename itself is one commit after Phase 3: `git mv` the module tree, rewrite
  `module`/`import` lines and the license header's project line (**keeping the PUC-Rio notice**),
  update `lua_api.exports` (check which symbols are stock `lua_*` names and must not change),
  regenerate docs, run `suite test --tier full` and the benchmark gates. Whether the new
  language keeps a `lua_*` C-API surface and the `_VERSION` string is a product decision to make
  *then*; AGENTS.md's "Preserve observable Lua 5.4 semantics" mission line needs a rewrite with it.

---

## 4. Benchmark suite design

### 4.1 Workload corpus (one set, five categories)

| Category | Source today | Additions (gaps) |
| --- | --- | --- |
| `core` — micro kernels, in-process timing, C Lua comparable | `bench.py`'s six | method dispatch, closures/upvalues, `pcall`/`error` round trip, string ops (`gsub`, `format`, `rep`, concat), table insert/remove, `table.sort`, GC churn (allocation-heavy), deep recursion, coroutine switch |
| `programs` — application-style, whole-process, C Lua comparable | `workloads/*.lua` (11), the 15 regression programs reused as checksum-verified macro workloads | JSON-ish encode/decode, a small interpreter, n-body, spectral-norm |
| `startup` | none | empty script, `-e "return 1"`, `require`-heavy script (startup was 17 ms → 3 ms; protect it) |
| `datalog` — no C Lua comparator | scenarios at large scale (19), acceptance cases | per-scenario in-process timing; transitive closure N=…, join-heavy, negation-heavy, incremental fact add/retract + re-query |
| `narrative` — no C Lua comparator | `sample-game/tools/check.lua`, stress/replay in `tests/narrative` | turn throughput, deck draws, transaction commit/rollback, save/load/replay |

All workloads are `.lua` files with a header table (name, category, params, expected checksum)
and a body that **asserts its own result**. Python strings disappear. Each workload exposes
`scale` so one file serves both a quick check and a long measurement.

### 4.2 Measurement protocol

* In-process: load once, warm once, then ≥ 7 interleaved samples of ≥ 5 repetitions
  (the existing `bench.py` method, which already produced stable numbers). Whole-process
  workloads: best/median of N fresh processes. Startup workloads: wall via `os`/`posix_spawn`.
* Record median, min, MAD/CV, peak RSS (`/usr/bin/time -l`), machine fingerprint, and the
  binaries' (sha256, commit, flags). A sample set with CV above a threshold is reported
  *inconclusive*, not failed.
* A gate failure is **confirmed by two re-runs** before the process exits non-zero.
* Ratios are paired per run (candidate time ÷ comparator time from the same iteration), then
  the median of ratios is taken. This removes most thermal/frequency drift.
* The interpreter is one large function; ±10 % layout noise between builds is known
  (`PERFORMANCE_WORK.md`). Gate headroom is sized accordingly (below), never zero.

### 4.3 Comparators and targets

Comparators are named in `benchmarks/targets.toml`:

| Label | What | Notes |
| --- | --- | --- |
| `clua` | stock C Lua 5.4.9 built `-O2` from `c-implementation/` | Only for workloads using no extension syntax. |
| `v0-snapshot` | commit 0: the Oct 9 19:19 `varis.zip` source | Built with the same flags as the candidate for fairness; the as-shipped `bin/varis` (2.61 s fib) is recorded as history only. |
| `v1-perf-final` | tag of the tree on Oct 9 after the interpreter/table work | The "current good" anchor for ratchets until the next release tag. |
| `prev` | the most recent `release-*` tag | Moves with releases. |

```toml
[workload.core.fib]
goal.clua       = 2.0     # project target, reported not enforced
gate.clua       = 2.20    # measured 1.92–2.3 ⇒ gate at upper observed + headroom, tighten as it improves
floor.v0-snapshot = 15.0  # must remain ≥ 15× faster than the pre-optimization snapshot (measured ≈ 23×)
gate.prev       = 1.10    # no more than 10 % slower than the last release

[workload.datalog.scenario_17_same_generation]
gate.prev       = 1.15
floor.v0-snapshot = 1.0   # exact value measured in Phase 3
# no clua entry: stock Lua cannot run the syntax
```

Rules for initial values (so nobody picks numbers by feel):

1. **Gate** = worst of the last three recorded medians × 1.10 (core) or × 1.20 (programs, datalog, narrative).
2. **Goal** = 2.0× C Lua for every `clua`-comparable workload; the project's "no geometric mean cover" rule is honoured because the report lists each workload.
3. **Floor** = ≥ 60 % of the measured speedup over `v0-snapshot`, so a large regression trips it even if `prev` is stale.
4. For workloads without a C Lua comparator, calibrate in-session against a fixed core kernel *and* the `prev` build; if `prev` is unavailable (fresh clone, no tags), fall back to the committed baseline ratio-to-kernel, with a warning that absolute drift is possible.
5. `benchmarks/datalog-baseline.json` (absolute seconds) is retired once rows exist for every scenario; its numbers are carried into `history/` unchanged.

### 4.4 Reporting

`suite report` emits `report.json` and a Markdown table (workload, candidate, comparator,
ratio, goal/gate/floor status, memory ratio, noise flag). README/AGENTS performance prose is
replaced by a link plus a generated `docs/STATUS.md`; hard-coded figures like "54 cases" and
"1.6×" in README.md and AGENTS.md go away because they are already drifting.

---

## 5. Phases

Each phase ends in a state where `main` is green and the previous phase's guarantees still hold.

### Phase 0 — Safety net: git and history (S)

1. Create a scratch export of the current tree **before** touching it (`cp -c`/tar into the
   scratchpad); `git init` in place with `main`.
2. Write `.gitignore` / `.gitattributes` first; verify `git status` shows no `bin/`, `*.o`, `.DS_Store`, `__pycache__`.
3. **Commit 0** = source tree from `varis.zip` (strip `__MACOSX`, `.DS_Store`, `bin/`, `*.o`; keep
   `c-implementation` once, unchanged). **Commit 1** = current tree on top. Use the files' mtimes
   for `GIT_AUTHOR_DATE`; message states these were reconstructed from snapshots.
   Tag `baseline/v0-snapshot` and `baseline/v1-perf-final`.
4. Verify commit 0 builds with today's `ldc2` in a worktree and passes at least `make test-datalog`.
   If it does not build, record why and fall back to the as-shipped binary as a `history-only` comparator.
5. Move `bin/varis-{values,registers,callstorage}` out to `.cache/legacy/` with a manifest of SHA-256s;
   convert `benchmarks/results/*` into `benchmarks/history/2026-10-09-perf/` (index README, originals unchanged).
6. Update `AGENTS.md` (§5 item 5 mentions no VCS; add the git workflow) and the
   auto-memory note "no git here".

**Done when:** `git log` shows 2 commits; `git clean -ndx` lists only build outputs; a fresh clone + `make varis` works.

### Phase 1 — Formatting and hooks (S)

1. `brew install dfmt` (0.15.2); record the version in `tools/versions.toml`.
2. Experiment in a scratch copy: run dfmt over `source/` and `tests/` with a handful of
   candidate `.editorconfig`s (`dfmt_brace_style = otbs`, `max_line_length` 100/120/140,
   `dfmt_soft_max_line_length`). Pick the config minimizing changed lines; handle any construct
   dfmt mangles with `// dfmt off` blocks. Gate on the **full test tier passing** after the reformat
   — binaries will differ (assert messages carry line numbers), so equality of binaries is not the check.
3. One commit: "Format with dfmt" and nothing else. Add it to `.git-blame-ignore-revs`.
4. Install `.githooks/` and `make hooks` / `fmt` / `fmt-check`.
5. Write `tools/check_sources.py` and the license-header check.

**Done when:** `make fmt-check` is clean; a deliberately misformatted staged file is rejected; blame skips the format commit.

### Phase 2 — One test suite (M)

2a. **Build model**: profiles under `build/`, shared object set, single unit binary with group
    selection. Measure before/after wall time of `make test-foundation … test-narrative` and record it in this document.
2b. **Harness skeleton** (`tools/suite`): schema, manifest loader, adapters that *wrap* the
    existing runners and normalize their output. First milestone: `suite test --tier fast` runs
    every existing suite through its old runner and prints one table. No semantics change.
2c. **Manifest + ledger**: enumerate all cases (D groups, 15 acceptance, 19 scenarios, 54 extension
    cases, 15 regression programs, 33 official files). Assert case counts equal today's; ledger
    holds `gc.lua` skip, `all.lua` partial, and `tests/datalog/known_gaps/*`.
2d. **Parity proof before deletion**: seed each suite with a handful of deliberate mutations
    (break a rule, flip a golden line, change a diagnostic) and verify old and new harness agree
    on the failure. Only then retire the old runner's CLI (keep its `unittest` tests until the
    native adapter has equivalents).
2e. **Traceability**: add `covers = [...]` to cases; `suite report --traceability` fails if any
    of the nine v0.1 requirements or any LANGUAGE_EXTENSIONS2 §16 item has zero cases. Replace
    the hand-maintained matrix in `tests/narrative/README.md` with the generated one.
2f. **D unit tests → `unittest` blocks** (optional, can trail): enables per-test ids and
    continue-after-failure. Mechanical per function; do it per group with the group's coverage held constant.
2g. **Name audit**: grep for tests that embed the project name; classify per Section 3.6.

**Done when:** `make test` = `suite test --tier full` minus nothing that `make test` ran before;
one JSON report; skips/gaps only via ledger; `make test-<group>` targets remain as thin aliases.

### Phase 3 — One benchmark suite (M–L)

3a. **Comparator builder**: `suite build --ref <git-ref> --profile release` with the cache from §3.4;
    C Lua built once with flags captured.
3b. **Port the corpus**: `bench.py` strings → `.lua` files with headers; fold `workloads/` and
    regression programs in; verify each workload yields identical output on `clua` and candidate.
3c. **Runner**: protocol in §4.2; one JSON schema; `benchmarks/baselines/<label>.json`.
3d. **Datalog/narrative in-process workloads**: split the scenario programs into timed kernels
    (the existing 19 scenarios already support "two scales"); add narrative kernels.
    Validate that in-process timing agrees with the old suite-level median to within noise
    before deleting `datalog.py`.
3e. **Targets**: record `v0-snapshot`, `v1-perf-final` and `clua` baselines on this machine;
    derive `targets.toml` using the rules in §4.3; commit the first baseline set.
3f. **Enforcement**: `make bench-check` (gates + floors, confirmed on failure) and
    `make bench-report`; wire into the `release` tier only.
3g. **Retire** `bench.py`, `workloads.py`, `regression.py`, `datalog.py`, `datalog-baseline.json`
    (history preserved in git and `benchmarks/history/`).

**Done when:** `suite bench` runs all five categories; every workload has a goal, a gate and at
least one of {`clua`, `prev`, `v0-snapshot`}; a synthetic 20 % slowdown (e.g. disabling one
fast path in a scratch build) trips exactly the expected gates; fib's goal shortfall is visible, not hidden.

### Phase 4 — Docs and cleanup (S)

* Collapse duplicate build/test instructions between README.md and AGENTS.md; generated `docs/STATUS.md`
  for counts and ratios. Add the git/hook/suite commands to AGENTS.md §6 (existing invariants stay).
* Move `lua54_datalog_tests/` under `tests/datalog/` (done: `tests/datalog/acceptance/`).
* Remove `Makefile` wrapper targets nobody uses after two weeks of the new driver.
* Optional: GitHub Actions for `fast` tier (macOS arm64 *and* a Linux job that exercises the
  non-Darwin `--export-dynamic` path, which is currently untested) — enabled when the remote exists (Section 7).

### Phase 5 — Rename (S, when the name exists)

Execute §3.6. Re-run `release` tier, keep a `v1-perf-final` comparator under its **old** name's tag
(tags are history; they stay), record the rename commit in `.git-blame-ignore-revs`.

---

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Reformatting breaks something dfmt mis-parses (templates, UDAs, `static if` chains) | Scratch experiment first; full tier gate; `// dfmt off` escape hatch; isolate in one revertable commit. |
| Commit 0 does not build with today's compiler | Phase 0 step 4 detects it; fall back to as-shipped binary, history-only. |
| Timing noise causes flaky gates | Paired ratios, ≥ 7 interleaved samples, confirmation re-runs, CV-based "inconclusive", headroom ≥ 10 %. Gates only run in the release tier. |
| Layout effects (±10 %) make fib flap around 2.0× | Gate at the observed worst + headroom; goal stays 2.0 and is reported as "behind goal" until a real fix lands. |
| Absolute-time baselines creep back in | Schema rejects baselines without a comparator or ratio; only `history/` may hold seconds. |
| Adapter-era harness hides runner behaviour (e.g. negative-diagnostic checks, known-gap strictness) | Parity mutation tests in 2d before any old runner is deleted. |
| Rename churn collides with open work | Rename is last and mechanical; harness already name-agnostic. |
| Official suite requires building C test modules and an `sh` shim | Keep `tests/runner.d` as the adapter's executor; do not port it to Python in this effort. |

## 7. Decisions (confirmed October 10, 2026)

1. **Remote CI will exist eventually**, not yet. Design consequences: the `fast` tier must be
   runnable from a clean clone with only `ldc2`, `dfmt` and Python (no machine-local paths);
   `tools/versions.toml` pins tool versions for CI to read; the Phase 4 workflow is written
   to the same `suite` commands as the hooks. Hosted runners are too noisy for absolute
   times, so CI runs functional tiers plus ratio gates against comparators built in the same
   job; the `release` tier's full benchmark gates stay on a dedicated/local machine.
2. **Rename happens after this stage** (after Phase 3/4). Phase 5 stands as written.
3. **No other snapshots or backups exist.** The comparator set is `v0-snapshot`,
   `v1-perf-final`, and future release tags. Because history before commit 0 is
   unrecoverable, the Phase 0 reconstruction and tags are the only record: do them carefully.
4. **Gate headroom accepted**: +10 % core, +20 % programs/datalog/narrative, as in Section 4.3.

## 8. Suggested first sessions

1. Phase 0 end to end (about one sitting) — everything after it is easier and safer.
2. Phase 1's dfmt experiment and the reformat commit.
3. Phase 2a–2c (build profiles, harness skeleton, manifest with case-count parity).
4. Phase 3a–3c, then 3e once the numbers exist.
