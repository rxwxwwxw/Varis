# Lua 5.4.9 conformance audit

**Role (October 11, 2026):** Lua 5.4 conformance is no longer a project goal (see
[ROADMAP.md](../../ROADMAP.md)). This suite stays in `make test` as a regression net for the
procedural core: a new failure is still a failure, but no work is planned on the remaining
issues listed here, and a deliberate divergence may turn a file into a ledgered skip.

**Scope (decided by the project owner):** conformance means the official suite as a normal
Lua 5.4 binary runs it (`T == nil`), with only `gc.lua` excluded. Running `api.lua`/`code.lua` with
an ltests-style `T` library is explicitly out of scope.

**State (October 9, 2026, release CLI, `-O3 -release`):** across the 33 official files,
**31 pass, 1 partial, 1 skipped, 0 fail, 0 timeout** with a 240-second per-file limit and the
bundled C Lua as reference (`--reference`). [baseline.json](baseline.json) records per-file
status, diagnostics, exit codes and timings.

The single skip is `gc.lua`, **excluded by decision**: exact collector reachability and
memory-accounting assertions conflict with keeping Varis objects directly accessible from D, so
the conservative D collector is kept. The single partial is the suite driver `all.lua`, which the
runner executes in a scratch copy of the suite with `gc.lua` replaced by a stub; that run
(`final OK !!!`) additionally pushes every file through `string.dump`/`load` and exercises
`main.lua` and `files.lua` in the combined configuration. No assertion of any other file is
removed or altered: the C test modules are built and loaded through the Varis C API subset, and
the nested-shell status check runs against an `sh` shim (see below).

Run `python3 tools/suite test --suite official` (strict exit codes; 120 s default timeout, use `--timeout 240` for the
slow all.lua driver) or, for a JSON report,
`./bin/test_runner --strict --timeout 240 --reference c-implementation/src/lua --json /tmp/varis-official.json`.
`python3 tools/suite test --suite core` compares the deterministic core fixture with C Lua. `make test`
includes the runner's regression tests but not the official suite itself (`errors.lua` alone
takes ~30 s, `all.lua` ~70 s).

## Runner statuses

- **PASS**: the unmodified file ran and exited successfully.
- **PARTIAL**: ran, but with a named environment adjustment that changes what is exercised.
- **SKIP**: not executed; the reason is printed and recorded. Skips are never counted as
  successes.
- **FAIL / TIMEOUT**: unsuccessful; the runner exits non-zero under `--strict`.

## Environment the runner provides

- **C modules**: `libs/lib1`, `lib11`, `lib2`, `lib21`, `lib2-v2` are compiled with the system
  C compiler (`-undefined dynamic_lookup` on macOS) and loaded through `package.loadlib` and the
  C searchers. If no compiler is available the `-l lib2-v2` check of `main.lua` is removed and
  `main.lua` is reported PARTIAL.
- **Nested shell**: `files.lua` checks that `sh -c 'kill -s HUP $$'` reports an exit status. macOS
  `sh` replaces itself and reports a signal (C Lua behaves the same there), so the file runs with
  `PATH` prefixed by an `sh` wrapper that behaves like dash for this case. The file itself is
  untouched.
- **stdin** is a closed pipe, so `io.stdin:seek` fails as in the suite's expectations.

## Skipped and partial files

| File | Status | Reason |
| --- | --- | --- |
| `gc.lua` | SKIP | Excluded by decision (see above). It now runs to its last two assertions: exact `collectgarbage("count")` memory limits after releasing dead keys, and collection of unreachable self-referencing suspended coroutines (D fiber stacks are always GC roots) |
| `all.lua` | PARTIAL | Run with `gc.lua` stubbed in a scratch copy |

`api.lua` and `code.lua` pass in the way they do under a stock C Lua built without the internal
`T` library: they detect `T == nil`, print a notice and return, so their C-API and opcode-listing
assertions are not exercised (Varis's C API is a small subset and its instruction set differs).
`heavy.lua` is not run by `all.lua`; it passes here because array growth is bounded at 2^27
slots and reports `not enough memory` (C Lua reports the same when the machine is exhausted).

### Why `api.lua` and `code.lua` are not a gap for a stock Lua 5.4

`T` is provided only by `ltests.c`, which is compiled into a special *debug* build of C Lua
(`LUA_USER_H="ltests.h"`) to test the C implementation's own internals: it inspects C Lua's
bytecode (`T.listcode`, `T.listk`), allocator and collector state (`T.totalmem`, `T.gcage`) and
drives the C API through a mini-language (`T.testC`). A normal Lua 5.4 binary does not define
`T`, and the suite is written for that case: both files test `T == nil` and return. The bundled
reference binary (`c-implementation/src/lua`) is such a build, and the runner shows identical
behaviour for it and for Varis:

```
$ c-implementation/src/lua api.lua    >>> testC not active: skipping API tests <<<
$ bin/varis                 api.lua    >>> testC not active: skipping API tests <<<
$ c-implementation/src/lua code.lua   >>> testC not active: skipping opcode tests <<<
$ bin/varis                 code.lua   >>> testC not active: skipping opcode tests <<<
```

Running them *with* `T` would not test Lua 5.4 language or library behaviour; it would test that
Varis reproduces C Lua's bytecode listings (Varis uses its own typed instruction set by design,
AGENTS.md section 2.7) and a complete C API with its yield/error continuation semantics (Varis
exposes a D API instead; the C API subset in `capi.d` exists to load simple C modules). That
would be a different project (an ltests-compatible C Lua clone), so it is documented as out of
scope rather than as a conformance failure.

## What was implemented to reach this state

- **Lua-5.4-style compiler output**: RK operands, condition-jump codegen, accumulator-register
  binary chains, luac-like line attribution, strip semantics, parser limits and lparser error
  messages; assignment evaluation order.
- **VM**: lvm.c-style numeric `for` preparation, error messages with variable info, `__eq`/`__index`
  loops, hook transfer info, native stack guards and C-call depth emulation (`cCalls` limit 200,
  error-in-error-handling at 220), Lua slot limit of 1,000,000.
- **Libraries**: auxlib-style argument errors with call-site names, ports of lstrlib, ltablib
  (quicksort), lmathlib (xoshiro256**), loslib, liolib (on `FILE*`), loadlib/package searchers
  (C modules via `dlopen`) and lcorolib; real binary chunk header and `string.dump`/`load` of
  binary chunks (private body, `dump.d`).
- **C API subset** (`source/varis/capi.d`, exported from the executable): stack manipulation,
  pushing/reading scalars and strings, `lua_pushfstring`, globals, table fields, `luaL_setfuncs`
  and `luaL_checkversion_`; enough for `lua_CFunction` modules that do not call back into Lua or
  raise errors.
- **CLI**: port of `lua.c` (options, REPL, `LUA_INIT`, SIGINT, traceback handler).
- **GC emulation** (`varis/gc.d`): weak tables (keys/values/ephemerons) and `__gc`/`__close`
  finalizers on top of D's collector by hiding references; ephemerons resolve through forked
  reachability probes; removed-entry keys are released at cycles; explicit collections settle
  bookkeeping garbage; a precise heap collector is selected (`rt_options`); stack scrubbing is
  forced through an optimizer-proof call.
- **Debug**: hooks, `getinfo`, `getlocal`/`setlocal`, upvalue ids/joins, uservalues, registry,
  traceback with `package.loaded`-based global function names.
- **Tables**: insertion-ordered hash part with O(1) `next`.

## Remaining issues

- **`gc.lua`** (excluded by decision), see the table above.
- **A file-level PASS means the process exited successfully.** Official fixtures may disable
  sections internally (`T`-guarded sections, `_port`/`_soft` guards); this is not proof of
  feature completeness beyond the executed assertions.
- **C API is a subset.** Modules that need `lua_call`, `lua_error`, userdata, upvalues or the
  registry are not supported, and unwinding errors across C frames is not attempted.
- **Native stack use is large** (~5 KB per Lua call frame: the interpreter runs on a 4 GB
  virtual-stack Fiber and coroutines on 256 MB Fibers), and unwinding a very deep recursion error
  takes about 2.4 s. These are performance and footprint issues for Phase 8.
- `errors.lua` takes ~30 s and `cstack.lua` ~7 s; slow paths are candidates for profiling in
  milestone 21.
- **Differential regression programs** (`tests/regression`, 15 programs, identical output and
  checksum under C Lua): all pass. Known remaining difference: rare variable-info suffixes for
  `(x or K) and K2`-shaped operands (Varis's code shape differs from luac's degenerate jump);
  the stack-overflow unwind in `limits.lua` takes about 7 s versus 0.05 s (Phase 8).
- The differential fixture (`core.lua`) is focused coverage, not a replacement for the official
  suite.

## Fixed: `all.lua` hung in `closure.lua` (stale register + loaded chunks)

Found 2026-10-10 and fixed the same day; recorded because the symptom looked like a conservative-GC
flake. `closure.lua` waits in `while x[1] do <make garbage> end` for an automatic collection to clear a
weak-table entry. The cycle that clears it fires at one of the three `Concat` instructions of
`local a = A..A..A..A`, always the same one for a given allocation threshold, and the threshold depends
on the heap size, hence "a third of the runs". At the two inner concatenations the register reserved
for `a` still held the table from the loop test (the dead condition temporary), so the object stayed
reachable and the loop never ended.

Two defects combined: (1) the compiler reserves a new local's register before its initializer runs, so
initializers that compute temporaries leave the reserved register's old contents alive (stock Lua
evaluates into that register first); (2) `all.lua` runs every file through `string.dump`/`load`, and the
binary chunk format dropped the per-instruction live-register data the collector uses to clear dead
registers. Fixes: `compileLocalDecl` clears the reserved registers when the initializer needs
temporaries, and chunks carry the live-register bound (`dump.d`, format marker `dLu2`). Regression case:
`tests/extensions/cases/weak_stale_register.lua`. 0 hangs in 15 `all.lua` runs afterwards (3 in 15 before).
