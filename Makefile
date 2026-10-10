# Makefile for varis (D port of Lua 5.4)

DC ?= ldc2
UNAME_S := $(shell uname -s)
EXPORT_DYNAMIC := $(if $(filter Darwin,$(UNAME_S)),-L-exported_symbols_list -Llua_api.exports,-L--export-dynamic)
DFLAGS ?= -Isource -g $(EXPORT_DYNAMIC)

SRC_FILES = source/varis/package.d \
            source/varis/types.d \
            source/varis/exception.d \
            source/varis/table.d \
            source/varis/state.d \
            source/varis/ast.d \
            source/varis/lexer.d \
            source/varis/parser.d \
            source/varis/opcode.d \
            source/varis/fiber.d \
            source/varis/compiler.d \
            source/varis/vm.d \
            source/varis/pattern.d \
            source/varis/lib/package.d \
            source/varis/lib/base.d \
            source/varis/lib/math.d \
            source/varis/lib/string.d \
            source/varis/lib/pack.d \
            source/varis/lib/auxlib.d \
            source/varis/lib/fastcall.d \
            source/varis/dump.d \
            source/varis/gc.d \
            source/varis/lib/table.d \
            source/varis/lib/coroutine.d \
            source/varis/lib/os.d \
            source/varis/lib/io.d \
            source/varis/lib/utf8.d \
            source/varis/lib/package_lib.d \
            source/varis/capi.d \
            source/varis/lib/debug_lib.d \
            source/varis/logic/model.d \
            source/varis/logic/world.d \
            source/varis/logic/validate.d \
            source/varis/logic/evaluate.d \
            source/varis/logic/query.d \
            source/varis/narrative/codec.d \
            source/varis/narrative/templates.d \
            source/varis/narrative/fingerprint.d \
            source/varis/narrative/session.d source/varis/narrative/persistence.d source/varis/narrative/observe.d source/varis/narrative/diagnostics.d source/varis/narrative/analysis.d \
            source/varis/narrative/registry.d \
            source/varis/lib/narrative.d source/varis/lib/quality.d \
            source/varis/lib/logic.d

# Test runner timeout (in seconds, default 5 minutes)
TIMEOUT ?= 300
DATALOG_TIMEOUT ?= 300
EXTENSIONS_TIMEOUT ?= 300
SCENARIOS_TIMEOUT ?= 120
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

.PHONY: bench bench-check bench-record release suite-deps test-smoke test-fast test-legacy varis-checked all check hooks fmt fmt-check check-sources test test-regression test-regression-record test-regression-runner test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-runner test-official test-official-runner varis c-lua clean

all: test varis

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

test-datalog: varis
	TEST_TIMEOUT=$(DATALOG_TIMEOUT) sh lua54_datalog_tests/run-tests.sh ./$(BIN_DIR)/varis

# Self-checking Datalog scenario programs (tests/datalog/README.md): golden
# output at a hand-checkable and at a benchmark scale, plus visible known gaps.
test-scenarios: varis
	python3 -m unittest discover -s tests/datalog -p 'test_*.py'
	python3 tests/datalog/run.py --binary ./$(BIN_DIR)/varis --timeout $(SCENARIOS_TIMEOUT)

test-extensions: varis
	$(RUN_TEST) python3 tests/extensions/test_runner.py
	python3 tests/extensions/run-tests.py ./$(BIN_DIR)/varis --timeout $(EXTENSIONS_TIMEOUT)

test-runner: bin
	$(DC) $(DFLAGS) tests/runner.d -of=$(BIN_DIR)/test_runner

test-official: varis test-runner
	./$(BIN_DIR)/test_runner --strict

test-official-runner: test-runner
	python3 -m unittest discover -s tests/official -p 'test_*.py'

.PHONY: test-conformance-core
test-conformance-core: varis c-lua
	python3 tests/official/differential.py

# The unified driver (tools/suite, tests/manifest.toml) is the single test entry point.
SUITE = python3 tools/suite
suite-deps: varis c-lua test-runner $(DEBUG_STAMP)

test-smoke: suite-deps
	$(SUITE) test --tier smoke -q

test-fast: suite-deps
	$(SUITE) test --tier fast -q

test: suite-deps
	$(SUITE) test --tier full -q

# The previous per-suite targets, retained until the unified driver has been trusted for a release cycle.
test-legacy: test-foundation test-frontend test-vm test-libs test-logic test-stateful test-narrative test-datalog test-scenarios test-extensions test-official-runner test-regression-runner

# Optimized build with assertions enabled (no -release): the "checked" validation profile.
varis-checked: $(SRC_FILES) source/varis/cli.d
	mkdir -p $(BUILD_DIR)/checked
	$(DC) -Isource -O3 $(EXPORT_DYNAMIC) $(SRC_FILES) source/varis/cli.d -of=$(BUILD_DIR)/checked/varis

varis: bin
	$(DC) -Isource -O3 -release $(EXPORT_DYNAMIC) $(SRC_FILES) source/varis/cli.d -of=$(BIN_DIR)/varis

c-lua:
	$(MAKE) -C c-implementation/src macosx


clean:
	rm -rf $(BIN_DIR) *.o

# Differential regression programs: byte-identical output and checksums against C Lua.
test-regression: varis c-lua
	python3 tests/regression/run.py

# Deliberate: rewrites tests/regression/expected.json from the current outputs.
test-regression-record: varis c-lua
	python3 tests/regression/run.py --record

# Unit tests of the regression runner itself (no interpreters needed).
test-regression-runner:
	python3 -m unittest discover -s tests/regression -p 'test_*.py'


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

# Benchmarks (tools/suite, benchmarks/manifest.toml, benchmarks/targets.toml).
bench: varis c-lua
	$(SUITE) bench

# Enforce gates and floors; comparators (git refs) are built on demand under .cache/builds.
bench-check: varis c-lua
	$(SUITE) bench --check

# Record the current machine's results as a named baseline: make bench-record LABEL=name
bench-record: varis c-lua
	$(SUITE) bench --record $(LABEL)

# Everything a tag must pass: full tests and enforced performance targets.
release: test bench-check
