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
BUILD_DIR = build
DEBUG_OBJ_DIR = $(BUILD_DIR)/debug/obj
DEBUG_STAMP = $(DEBUG_OBJ_DIR)/.built

# Unit tests link one shared, once-compiled object set instead of recompiling every module per test.
$(DEBUG_STAMP): $(SRC_FILES)
	mkdir -p $(DEBUG_OBJ_DIR)
	$(DC) -c -Isource -g -oq -od=$(DEBUG_OBJ_DIR) $(SRC_FILES)
	touch $@

# $(call unit_test,name)
define unit_test
	$(DC) $(DFLAGS) $(DEBUG_OBJ_DIR)/*.o tests/unit/$(1).d -of=$(BUILD_DIR)/debug/$(1)
	$(RUN_TEST) ./$(BUILD_DIR)/debug/$(1)
endef

.PHONY: suite-deps test-smoke test-fast test-legacy dlua-checked all check hooks fmt fmt-check check-sources test test-regression test-regression-record test-regression-runner benchmark-regression test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-runner test-official test-official-runner dlua c-lua benchmark benchmark-workloads benchmark-datalog benchmark-datalog-record test-benchmarks clean

all: test dlua

bin:
	mkdir -p $(BIN_DIR)

test-foundation: $(DEBUG_STAMP)
	$(call unit_test,test_foundation)

test-frontend: $(DEBUG_STAMP)
	$(call unit_test,test_parser)

test-vm: $(DEBUG_STAMP)
	$(call unit_test,test_vm)

test-libs: $(DEBUG_STAMP)
	$(call unit_test,test_libs)

test-logic: $(DEBUG_STAMP)
	$(call unit_test,test_logic)

test-stateful: $(DEBUG_STAMP)
	$(call unit_test,test_stateful)

test-narrative: $(DEBUG_STAMP)
	$(call unit_test,test_narrative)

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

# The unified driver (tools/suite, tests/manifest.toml) is the single test entry point.
SUITE = python3 tools/suite
suite-deps: dlua c-lua test-runner $(DEBUG_STAMP)

test-smoke: suite-deps
	$(SUITE) test --tier smoke -q

test-fast: suite-deps
	$(SUITE) test --tier fast -q

test: suite-deps
	$(SUITE) test --tier full -q

# The previous per-suite targets, retained until the unified driver has been trusted for a release cycle.
test-legacy: test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-benchmarks test-official-runner test-regression-runner

# Optimized build with assertions enabled (no -release): the "checked" validation profile.
dlua-checked: $(SRC_FILES) source/dlua/cli.d
	mkdir -p $(BUILD_DIR)/checked
	$(DC) -Isource -O3 $(EXPORT_DYNAMIC) $(SRC_FILES) source/dlua/cli.d -of=$(BUILD_DIR)/checked/dlua

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

# Fast gate used by the pre-push hook.
check: fmt-check check-sources test-fast
