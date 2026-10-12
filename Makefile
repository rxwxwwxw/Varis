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
            source/varis/logic/store.d \
            source/varis/logic/naive.d \
            source/varis/logic/query.d \
            source/varis/narrative/codec.d \
            source/varis/narrative/templates.d \
            source/varis/narrative/fingerprint.d \
            source/varis/narrative/session.d source/varis/narrative/persistence.d source/varis/narrative/observe.d source/varis/narrative/diagnostics.d source/varis/narrative/analysis.d \
            source/varis/narrative/registry.d \
            source/varis/lib/narrative.d source/varis/lib/quality.d \
            source/varis/lib/logic.d \
            source/varis/workbench/page.d source/varis/workbench/server.d

# Per-test timeout for a unit executable (seconds).
TIMEOUT ?= 300
RUN_TEST = python3 -c "import subprocess, sys; sys.exit(subprocess.run(sys.argv[1:], timeout=$(TIMEOUT)).returncode)"

BIN_DIR = bin
BUILD_DIR = build
DEBUG_OBJ_DIR = $(BUILD_DIR)/debug/obj
DEBUG_STAMP = $(DEBUG_OBJ_DIR)/.built
SUITE = python3 tools/suite

.PHONY: all varis varis-checked c-lua clean \
        test test-smoke test-fast suite-deps unit-test test-runner test-regression-record \
        bench bench-check bench-record release \
        hooks fmt fmt-check check-sources check

all: test varis

bin:
	mkdir -p $(BIN_DIR)

# ---- Builds ---------------------------------------------------------------------------------

# Optimized release CLI.
varis: bin
	$(DC) -Isource -O3 -release $(EXPORT_DYNAMIC) $(SRC_FILES) source/varis/cli.d -of=$(BIN_DIR)/varis

# Optimized with assertions enabled (no -release): the "checked" validation profile.
varis-checked: $(SRC_FILES) source/varis/cli.d
	mkdir -p $(BUILD_DIR)/checked
	$(DC) -Isource -O3 $(EXPORT_DYNAMIC) $(SRC_FILES) source/varis/cli.d -of=$(BUILD_DIR)/checked/varis

# Reference interpreter (stock Lua 5.4.9, -O2).
c-lua:
	$(MAKE) -C c-implementation/src $(if $(filter Darwin,$(UNAME_S)),macosx,linux)

# Unit tests link one shared, once-compiled object set instead of recompiling every module.
$(DEBUG_STAMP): $(SRC_FILES)
	mkdir -p $(DEBUG_OBJ_DIR)
	$(DC) -c -Isource -g -oq -od=$(DEBUG_OBJ_DIR) $(SRC_FILES)
	touch $@

# Build and run one D unit group: make unit-test UNIT=test_vm [ARGS=testName]
unit-test: $(DEBUG_STAMP)
	$(DC) $(DFLAGS) -I. -unittest $(DEBUG_OBJ_DIR)/*.o tests/unit/$(UNIT).d -of=$(BUILD_DIR)/debug/$(UNIT)
	$(RUN_TEST) ./$(BUILD_DIR)/debug/$(UNIT) $(ARGS)

# Official-suite runner (D) used by the `official` cases.
test-runner: bin
	$(DC) $(DFLAGS) tests/runner.d -of=$(BIN_DIR)/test_runner

clean:
	rm -rf $(BIN_DIR) $(BUILD_DIR) *.o

# ---- Tests: tools/suite + tests/manifest.toml is the single entry point ------------------------

suite-deps: varis c-lua test-runner $(DEBUG_STAMP)

test-smoke: suite-deps
	$(SUITE) test --tier smoke -q

test-fast: suite-deps
	$(SUITE) test --tier fast -q

test: suite-deps
	$(SUITE) test --tier full -q

# Deliberate: rewrites tests/regression/expected.json from the current outputs.
test-regression-record: varis c-lua
	python3 tests/regression/run.py --record

# ---- Benchmarks (benchmarks/manifest.toml, benchmarks/targets.toml) ------------------------------

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

# Regenerate docs/STATUS.md from a fresh release-tier test run and an enforced benchmark run (idle machine).
status: suite-deps
	mkdir -p build
	$(SUITE) test --tier release -q --json build/test-full.json
	$(SUITE) bench --check --json build/bench-all.json
	$(SUITE) report --tests build/test-full.json --bench build/bench-all.json --out docs/STATUS.md

# ---- Repository hygiene ------------------------------------------------------------------------

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
