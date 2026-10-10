# Makefile for dlua (D port of Lua 5.4)

DC ?= ldc2
UNAME_S := $(shell uname -s)
EXPORT_DYNAMIC := $(if $(filter Darwin,$(UNAME_S)),-L-exported_symbols_list -Llua_api.exports,-L--export-dynamic)
DFLAGS ?= -Isource -g $(EXPORT_DYNAMIC)

SRC_FILES = source/dlua/package.d \
            source/dlua/types.d \
            source/dlua/exception.d \
            source/dlua/table.d \
            source/dlua/state.d \
            source/dlua/ast.d \
            source/dlua/lexer.d \
            source/dlua/parser.d \
            source/dlua/opcode.d \
            source/dlua/fiber.d \
            source/dlua/compiler.d \
            source/dlua/vm.d \
            source/dlua/pattern.d \
            source/dlua/lib/package.d \
            source/dlua/lib/base.d \
            source/dlua/lib/math.d \
            source/dlua/lib/string.d \
            source/dlua/lib/pack.d \
            source/dlua/lib/auxlib.d \
            source/dlua/lib/fastcall.d \
            source/dlua/dump.d \
            source/dlua/gc.d \
            source/dlua/lib/table.d \
            source/dlua/lib/coroutine.d \
            source/dlua/lib/os.d \
            source/dlua/lib/io.d \
            source/dlua/lib/utf8.d \
            source/dlua/lib/package_lib.d \
            source/dlua/capi.d \
            source/dlua/lib/debug_lib.d \
            source/dlua/logic/model.d \
            source/dlua/logic/world.d \
            source/dlua/logic/validate.d \
            source/dlua/logic/evaluate.d \
            source/dlua/logic/query.d \
            source/dlua/narrative/codec.d \
            source/dlua/narrative/templates.d \
            source/dlua/narrative/fingerprint.d \
            source/dlua/narrative/session.d source/dlua/narrative/persistence.d source/dlua/narrative/observe.d source/dlua/narrative/diagnostics.d source/dlua/narrative/analysis.d \
            source/dlua/narrative/registry.d \
            source/dlua/lib/narrative.d source/dlua/lib/quality.d \
            source/dlua/lib/logic.d

# Test runner timeout (in seconds, default 5 minutes)
TIMEOUT ?= 300
DATALOG_TIMEOUT ?= 300
EXTENSIONS_TIMEOUT ?= 300
SCENARIOS_TIMEOUT ?= 120
BENCHMARK_RUNS ?= 3
DATALOG_REGRESSION ?= 0.25
DATALOG_SLACK ?= 0.1
DATALOG_BASELINE ?= benchmarks/datalog-baseline.json
DATALOG_BENCH_ARGS = --runs $(BENCHMARK_RUNS) --baseline $(DATALOG_BASELINE) --tolerance $(DATALOG_REGRESSION) --slack $(DATALOG_SLACK)
RUN_TEST = python3 -c "import subprocess, sys; sys.exit(subprocess.run(sys.argv[1:], timeout=$(TIMEOUT)).returncode)"

BIN_DIR = bin

.PHONY: all check hooks fmt fmt-check check-sources test test-regression test-regression-record test-regression-runner benchmark-regression test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-runner test-official test-official-runner dlua c-lua benchmark benchmark-workloads benchmark-datalog benchmark-datalog-record test-benchmarks clean

all: test dlua

bin:
	mkdir -p $(BIN_DIR)

test-foundation: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_foundation.d -of=$(BIN_DIR)/test_foundation
	$(RUN_TEST) ./$(BIN_DIR)/test_foundation

test-frontend: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_parser.d -of=$(BIN_DIR)/test_parser
	$(RUN_TEST) ./$(BIN_DIR)/test_parser

test-vm: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_vm.d -of=$(BIN_DIR)/test_vm
	$(RUN_TEST) ./$(BIN_DIR)/test_vm

test-libs: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_libs.d -of=$(BIN_DIR)/test_libs
	$(RUN_TEST) ./$(BIN_DIR)/test_libs

test-logic: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_logic.d -of=$(BIN_DIR)/test_logic
	$(RUN_TEST) ./$(BIN_DIR)/test_logic

test-stateful: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_stateful.d -of=$(BIN_DIR)/test_stateful
	$(RUN_TEST) ./$(BIN_DIR)/test_stateful

test-narrative: bin
	$(DC) $(DFLAGS) $(SRC_FILES) tests/unit/test_narrative.d -of=$(BIN_DIR)/test_narrative
	$(RUN_TEST) ./$(BIN_DIR)/test_narrative

test-datalog: dlua
	TEST_TIMEOUT=$(DATALOG_TIMEOUT) sh lua54_datalog_tests/run-tests.sh ./$(BIN_DIR)/dlua

# Self-checking Datalog scenario programs (tests/datalog/README.md): golden
# output at a hand-checkable and at a benchmark scale, plus visible known gaps.
test-scenarios: dlua
	python3 -m unittest discover -s tests/datalog -p 'test_*.py'
	python3 tests/datalog/run.py --binary ./$(BIN_DIR)/dlua --timeout $(SCENARIOS_TIMEOUT)

test-extensions: dlua
	$(RUN_TEST) python3 tests/extensions/test_runner.py
	python3 tests/extensions/run-tests.py ./$(BIN_DIR)/dlua --timeout $(EXTENSIONS_TIMEOUT)

test-runner: bin
	$(DC) $(DFLAGS) tests/runner.d -of=$(BIN_DIR)/test_runner

test-official: dlua test-runner
	./$(BIN_DIR)/test_runner --strict

test-official-runner: test-runner
	python3 -m unittest discover -s tests/official -p 'test_*.py'

.PHONY: test-conformance-core
test-conformance-core: dlua c-lua
	python3 tests/official/differential.py

test: test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-benchmarks test-official-runner test-regression-runner

dlua: bin
	$(DC) -Isource -O3 -release $(EXPORT_DYNAMIC) $(SRC_FILES) source/dlua/cli.d -of=$(BIN_DIR)/dlua

c-lua:
	$(MAKE) -C c-implementation/src macosx

benchmark: dlua c-lua
	python3 benchmarks/bench.py
	python3 benchmarks/regression.py
	python3 benchmarks/datalog.py $(DATALOG_BENCH_ARGS)

# Whole-process timings of the application-style programs in benchmarks/workloads/ (informational).
benchmark-workloads: dlua c-lua
	python3 benchmarks/workloads.py

benchmark-datalog: dlua
	python3 benchmarks/datalog.py $(DATALOG_BENCH_ARGS)

# Deliberate calibration only; normal benchmark runs never update the baseline.
benchmark-datalog-record: dlua
	python3 benchmarks/datalog.py $(DATALOG_BENCH_ARGS) --record

test-benchmarks:
	python3 -m unittest discover -s benchmarks -p 'test_*.py'

clean:
	rm -rf $(BIN_DIR) *.o

# Differential regression programs: byte-identical output and checksums against C Lua.
test-regression: dlua c-lua
	python3 tests/regression/run.py

# Deliberate: rewrites tests/regression/expected.json from the current outputs.
test-regression-record: dlua c-lua
	python3 tests/regression/run.py --record

# Unit tests of the regression runner itself (no interpreters needed).
test-regression-runner:
	python3 -m unittest discover -s tests/regression -p 'test_*.py'

benchmark-regression: dlua c-lua
	python3 benchmarks/regression.py

# Repository hygiene (see CONSOLIDATION_PLAN.md).
hooks:
	git config core.hooksPath .githooks
	git config blame.ignoreRevsFile .git-blame-ignore-revs

fmt:
	dfmt -i $$(git ls-files '*.d' | grep -v '^c-implementation/')
	dfmt -i $$(git ls-files '*.d' | grep -v '^c-implementation/')

fmt-check:
	python3 tools/hooks/fmt_check.py

check-sources:
	python3 tools/check_sources.py

# Fast gate used by the pre-push hook; becomes `suite test --tier fast` in Phase 2.
check: fmt-check check-sources test
