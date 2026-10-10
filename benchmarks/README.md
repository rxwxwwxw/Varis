# Performance checks

`make benchmark` compares ordinary Lua workloads with C Lua, times the
[regression programs](../tests/regression/README.md) (`regression.py`: identical output and
checksum required, 30 s dlua budget per program), then checks the Datalog suites against
`datalog-baseline.json`. `make benchmark-datalog` runs
only the Datalog check. Compilation is excluded from timings.

The Datalog benchmark executes all 15 acceptance cases, all 54 extension
regression/stress cases and the 19 [scenario programs](../tests/datalog/README.md)
(at their large, benchmark scale, with golden output checked) through their
normal runners, in fresh processes. The scenarios suite also prints one timing
per program on its first run. It
includes process startup and runner overhead. Functional failures, incorrect
negative-case diagnostics, crashes, and timeouts fail the check before recording
or comparing timing data. The acceptance runner checks each negative case's
intended diagnostic instead of accepting arbitrary failures.

Each suite is run three times. Its median must be at most
`baseline_seconds * (1 + tolerance) + slack_seconds`. The defaults are 25%
tolerance and 0.1 seconds of slack, allowing for scheduling noise on these short
suites. Each entire suite has a 300-second deadline. Run on an otherwise idle
machine with the same compiler/build settings for meaningful comparisons.

```sh
make benchmark-datalog
make benchmark-datalog DATALOG_REGRESSION=0.10 DATALOG_SLACK=0.05 BENCHMARK_RUNS=5
```

The checked-in baseline describes this machine's optimized release interpreter,
including the join optimization. It is machine-specific, not a portable speed
requirement. Calibrate a different machine explicitly with a separate file:

```sh
make benchmark-datalog-record DATALOG_BASELINE=/tmp/dlua-baseline.json
make benchmark-datalog DATALOG_BASELINE=/tmp/dlua-baseline.json
```

A suite that has no baseline entry (or one you want to recalibrate) can be
recorded alone, leaving the other entries untouched and still compared:

```sh
make benchmark-datalog DATALOG_BENCH_ARGS="--record-suite scenarios"
python3 benchmarks/datalog.py --record-suite scenarios
```

To deliberately update the repository baseline after a reviewed performance
change, use `make benchmark-datalog-record`. The command writes a baseline only
after every measured run succeeds; ordinary benchmark runs never rewrite it.
Treat threshold failures as bugs to investigate before recalibrating.

`make test-benchmarks` verifies the regression enforcement, median selection,
explicit recording, functional-failure handling, and timeout cleanup. These
tests are also part of `make test`. Performance checks remain in `make benchmark`
so compiling/running debug unit tests does not contaminate performance samples.
