> **Historical note (2026-10-10):** `bench.py`, `workloads.py`, `regression.py` and `datalog.py`
> referenced below were replaced by `tools/suite bench`; see [README.md](README.md). Raw results
> are in `history/2026-10-09-perf/`.

> **Direction note (2026-10-11):** the ≤2× C Lua goal this document works toward is closed and
> no longer pursued; see [ROADMAP.md](../ROADMAP.md). The measurements and the list of remaining
> costs are still accurate as a record. Future performance work targets narrative turn latency
> and memory on low-end hardware, starting with the inference engine.

# Performance work — October 9, 2026

## Stage 2 (target ≈ 2× C Lua)

Result on the six `bench.py` workloads (`python3 benchmarks/bench.py`, release CLI, execution only,
median of seven runs; raw data in [results/final-execution.json](results/final-execution.json)):

| Workload | Start of stage 2 | Now | C Lua (s) |
|---|---:|---:|---:|
| fibonacci_recursive | 16.4× | 2.0–2.3× | 0.066 |
| numeric_for_loop | 4.3× | 1.6× | 0.035 |
| table_array_access | 6.4× | 1.6× | 0.013 |
| table_hash_access | 3.2× | 1.4–1.5× | 0.014 |
| string_manipulation | 4.4× | 0.6× | 0.011 |
| sieve_of_eratosthenes | 8.6× | 1.3× | 0.0024 |

`benchmarks/workloads.py` (`make benchmark-workloads`) adds eleven application-style programs:
0.2–2.7× C Lua (sort 0.23×, `pairs` 0.63×, strings 1.2×, varargs 1.8×, binary trees 2.0×,
closures 2.3×, coroutines 2.5×, OOP 2.5×).

Build-to-build variation is ±10% because the interpreter loop is one large function; compare
ratios from the same session (min-of-N alternating runs are stable within a build).
`benchmarks/regression.py` shows ≈1.5–2.5× on the small programs now that process start-up is
3 ms instead of 17 ms.

### Changes, in order of measured effect

1. **Dead-stack scrubbing was always on.** The CLI's start-up `collectgarbage("generational")`
   enabled `stackHygiene`, so every Lua call zeroed 16 KB. Mode/tuning calls no longer enable it.
2. **Interpreter loop.** One `vmAttention` flag guards every rare per-instruction duty (instruction
   budget, frame transactions, pending collection, interrupts, hooks); the loop walks an
   instruction pointer, always ends in a `Return` (`Prototype.execCode`), 32-byte instructions,
   operands read in the handlers that use them; inline fast paths for integer/float arithmetic,
   comparisons, numeric `for`, array-part `GetTable`/`SetTable`, `#`, `not`, unary minus and cached
   global/field reads. Mid-frame hook installation reconstructs the line-hook position (db.lua).
3. **Calls.** Lua→Lua calls run without argument copies, results are written
   straight into the caller's registers, call-site names/worlds come from a dense per-pc table,
   register views are sized to the frame, proper tail calls use a per-thread argument buffer,
   `CallInfo` records are updated in place and cleared by field.
4. **Tables.** Nil-padded power-of-two array part with Lua's rehash policy (so `for i = 2, n`
   fills the array), border hint for `#`, `nextFast` for `pairs`, constant-string inline caches
   (`findStringHinted`) and pre-hashed metatable `__index` chains.
5. **Built-ins.** `lib/fastcall.d` gives `type`, `select`, `rawget/rawset/rawequal`,
   `get/setmetatable`, `assert`, `next`, `pairs`, `ipairs`, `math.floor/ceil/sqrt/abs/min/max`,
   `string.len/sub/byte` and `table.insert` allocation-free entry points that decline (return -1)
   for every error or unusual case so the generic implementation still produces the diagnostics.
   `for … in pairs/ipairs` loops step the traversal directly.
6. **Quadratic closure creation.** Closed upvalues stayed in the frame's list, so creating closures in
   a loop was O(n²) (40,000 closures: 4.4 s, 200,000 `pcall(function() … end)`: 77 s). Closed
   upvalues now leave the list.
7. **Calls, round two.** Lua→Lua calls run `executeFrame` directly from the `Call` handler (no
   intermediate placement frame), tail-call requests live on the thread, and `table.sort`
   comparators, `table.insert(t, pos, v)` / `table.remove(t, pos)` use stack argument buffers and
   one block move on plain sequences. Table constructors carry size hints (`Prototype.tableSizeHints`,
   kept out of the instruction operands so fingerprints are unchanged) and string-key stores hash
   once (`rawsetStringHashed`, node hashes cached for rebuilds).
8. **Deep recursion.** Past 150 nested Lua frames, Lua→Lua calls run in `executeDeepFrame`, a
   second executor that parks the caller's state in a `SavedFrame` and runs the callee in the same
   native frame (it is a separate function because the bookkeeping slowed shallow calls). Native
   stack use becomes flat and a 333,000-level stack overflow unwinds in a loop: 3.7 s → 0.27 s,
   `limits` 60× → 2.6×. `tests/regression/deepframes.lua` pins its behaviour to C Lua's.
   Small hash parts (≤ 8 nodes) have no bucket array (linear scan over cached hashes) and open
   upvalues are an intrusive list instead of a per-frame array.
9. **Errors.** `pcall`/`xpcall` of a Lua function get the error back from `VM.callProtected` as a
   value instead of a second throw, and the builtin `error` is raised straight from the
   interpreter (no native-call wrapper to unwind through): 13–17 µs → ≈4.5 µs per caught error,
   `fuzz_expr` 3.3× → 2.2×. Closures with up to two upvalues carry their upvalue array inline.
10. **Frame exit.** Registers of native frames are a slice of a per-thread bump-allocated value
    stack, and clearing them is one `memset` (the element-wise `= LuaValue.init` assignment
    compiled to a ≈100-instruction loop per call). Hash nodes lost their `dead` flag (a node is dead
    when its key is nil), so a node is 56 bytes instead of 64.
11. **Start-up.** `-export_dynamic` exported every D symbol (≈8 ms of dyld work per process); the
   executable now exports only the C API subset listed in `lua_api.exports`.

### Validation

Every step: `make test` (all unit, Datalog, extension, narrative, benchmark-runner and regression
runner suites), `make test-official` (31 pass / 1 partial / 1 skipped / 0 fail), `make
test-regression` (16 programs, including the new `fastpaths` program that pins the fast paths to
C Lua's output), `make test-conformance-core` and `make benchmark-datalog` (all three Datalog
suites faster than their baselines; no baseline was rewritten).

### Remaining costs

Allocation itself is near parity with C Lua (`{}` 1.2×, `{x=,y=}` 1.2×, closure creation 0.9×,
string concatenation 0.4×; see the micro-measurements in this stage's notes), so the 2.0–2.5×
of the object-heavy workloads is the call path, not the collector: a Lua→Lua call executes ≈570
instructions per loop iteration of `for … do f(i) end` (≈200 of them compiler-generated
prologue/epilogue and dispatch), against ≈150 in C Lua.

* A Lua→Lua call is ≈400 instructions (C Lua ≈150): native recursion into `executeFrame`, call
  records, register buffers and the stack-limit emulation. Removing the native recursion would be
  the next structural step.
* D exceptions are slow on macOS (≈5 µs per throw, ≈2.5 µs per frame with cleanups):
  a caught error costs ≈4.5 µs (a D throw/catch on this platform), against 0.3 µs in C Lua.
* Object creation (two GC allocations per small table), closure creation, and coroutine switches,
  which are druntime fiber switches (≈30% of a resume/yield pair in thread-local lookups and
  context switching, outside this code base).

---


## Stage 1 (baseline for the above)

The ~2× target remained open after this stage. These are exploratory measurements on the existing
six-workload corpus, not final release acceptance. SumType, typed instructions and
D GC are preserved. The wider Phase 8 corpus and calibrated core regression
baseline remain to be completed.

## Execution evidence

Three samples, one measured body execution per process after one warmup; medians
of `os.clock` CPU time. Loading/compilation is outside execution timing. Both
interpreters run the same assertion-checked source. No test/profiling jobs were
running during these timing series. Raw samples and binary hashes are in the
linked JSON reports; short C workloads are susceptible to noise.

| Workload | Before (s) | Context (s) | Call records (s) | Registers (s) | Latest / C |
|---|---:|---:|---:|---:|---:|
| fibonacci_recursive | 2.846665 | 2.591381 | 1.880442 | 1.379372 | 22.82× |
| numeric_for_loop | 0.786247 | 0.284996 | 0.252752 | 0.248990 | 7.22× |
| table_array_access | 0.226911 | 0.094296 | 0.093475 | 0.093323 | 7.20× |
| table_hash_access | 0.097388 | 0.083374 | 0.057478 | 0.056381 | 3.42× |
| string_manipulation | 0.088510 | 0.075081 | 0.052278 | 0.050153 | 4.70× |
| sieve_of_eratosthenes | 0.045862 | 0.023112 | 0.024198 | 0.022328 | 9.57× |

[Before](results/before-execution.json), [context](results/context-execution.json),
[call records](results/storage-execution.json), [registers](results/registers-execution.json).

## Measured changes

1. Resolve the current thread and call-stack descriptor once per native execution
   frame; check hook masks before calling the hook dispatcher. The descriptor
   remains valid across backing-array growth; hook configuration is read dynamically.
2. Reuse call-record storage independently for the main state and each Fiber.
   Clear every popped record, including frame delegates and object references.
3. Reuse register buffers after frame cleanup, with at most 64 cached buffers of
   at most 256 values per Lua thread. Close upvalues first and clear every cached
   value. Larger/deeper frames retain ordinary allocation behavior.

Fibonacci allocation traffic from an exit-instrumented release CLI:

| Stage | Allocated bytes | GC cycles | GC time |
|---|---:|---:|---:|
| Original | 13,683,641,152 | 2,900 | 203 ms |
| Call records | 2,671,174,416 | 2,900 | 184 ms |
| Registers | 474,090,384 | 527 | 35 ms |

These are cumulative allocations, not resident memory. Exit instrumentation reads
`GC.stats()` and `GC.profileStats()` after the main Fiber returns. Normal binaries
are used for timings. Peak RSS for a separate single Fibonacci execution was
10,190,848 bytes originally and 6,373,376 bytes after call-record reuse. Raw
allocation and memory reports are in `results/`.

## Validation and next work

Context and call-record changes passed full `make test`, optimized assertion-enabled
VM tests, the core differential fixture, all 15 regression programs, and the official
suite (31 pass / 1 partial / 1 skipped / 0 fail). The partial remains `all.lua` with
`gc.lua` stubbed; `gc.lua` remains excluded by the established project decision.

Register reuse has passed full `make test`, optimized assertion-enabled VM tests,
the core differential fixture, 15 regression programs and the official suite
(31 pass / 1 partial / 1 skipped / 0 fail).

The updated numeric profile identifies generic SumType assignment overhead in
arithmetic and numeric-for handlers. A bounded value-copy experiment is under
validation. The updated recursive profile also identifies 16 KB dead-stack scrubbing
per Lua call as a major cost; preserving weak references/finalizers is required for
any change there. Further call-context and argument/result transfer work remains.

No Datalog baseline has been rewritten. Raw CPU profiles and build/source hashes
are retained in `results/`. No Git metadata exists in this checkout.

## Follow-up: native tail calls and the record-based executor experiment

- `return setmetatable(...)` (a `TailCall` to a native) now uses the built-in's `fastCall`
  entry instead of the generic call wrapper; the OOP workload went from ~2.46× to ~1.9× C Lua.
  `runTailCalls` skips `__call` resolution when the callee is already a Lua closure.
- A record-based inline executor (frames as pooled records instead of native recursion) was
  built, matched C Lua output, and was *not* faster (Fibonacci 0.129 s vs 0.126 s; numeric
  loop 2.2× vs 1.6×). It was abandoned; the native-recursive `executeFrame` remains.
- Remaining workloads above 2×: coroutines (~2.5×, a third of the time is druntime's
  `fiber_switchContext`/TLS lookups), recursive Fibonacci (~2.1×), closures (~2.15×),
  binary trees (~2.05×).

### Second follow-up (short-program overheads)

- Varargs of a plain call alias the caller's argument registers instead of being copied.
- `pcall`/`xpcall` borrow their argument view, reuse pooled error-boundary objects and build
  their result array in one allocation (5M `pcall(closure)`: 1.67 s → 0.99 s, C Lua 0.51 s).
- The dead-stack scrub (active once weak tables or finalizers exist) runs every 32nd call
  instead of every call; `fastpaths` went from 3.5× to 1.7× C Lua.
- `heapSizeFactor:4` for the D collector and smaller minimum frame register slices cut
  GC mark time during deep recursion (`limits` 2.7× → 1.4×, `deepframes` 3.3× → 2.0×).
- Coroutines: `resume`, `yield` and `wrap` functions borrow their argument views (the first
  resume copies them, since they become the coroutine's parameters), generic-`for` generator
  calls pass a stack pair, and the no-yield/read-only depth counters are `__gshared` (thread-local
  access costs ~10 ns on macOS). `coro` workload: 2.7× → 2.2× C Lua; the rest is druntime's
  fiber switch.
- Profile-guided optimization (LDC `-fprofile-instr-use` trained on the workloads) was tried:
  it improved Fibonacci, closures, OOP and binary trees by 5–10% but made the numeric `for`
  loop and array access 30% slower (dispatch-loop layout), so the worst ratio did not improve
  and it was not adopted.
- Compilation speed (`load`): AST node classes are `final` and tested with an exact-type `as!`
  instead of checked class casts; `Prototype.pushInstruction` grows code/liveTop buffers by
  doubling instead of slice appends. Loading small chunks went from ~2.6× to ~1.5× C Lua and
  `fuzz_expr` from 2.2× to 2.0×.
