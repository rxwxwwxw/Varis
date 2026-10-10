# Differential regression programs

Self-checking Lua programs that must behave **identically under dlua and the bundled C Lua
5.4.9**. Each program prints every observable value through `harness.lua` and finishes with a
64-bit FNV-1a checksum of everything it printed:

```
CHECKSUM 972f08e0d74aa257 lines 1501
```

`run.py` runs each program under both interpreters and fails on any byte of difference in
stdout (showing the first differing line), on a non-zero exit, on a timeout, or when the
checksum differs from the one recorded in `expected.json`. The checksum recorded for the
reference makes a regression visible even when only dlua is available (`--no-reference`).

```sh
make test-regression            # differential run (needs bin/dlua and C Lua)
make test-regression-record     # deliberately re-record expected.json
make benchmark-regression       # timings, ratios and the per-program time budget
python3 tests/regression/run.py fuzz_expr strings --timeout 30
```

`make benchmark` also runs `benchmarks/regression.py`: the same comparison, best-of-N
timings for both interpreters, and a hard budget (30 s of dlua time per program) so that every
program terminates in a reasonable time. `make test` runs the unit tests of the runner.

## Programs

| Program | Covers |
| --- | --- |
| `int_float` | integer/float equality and ordering above 2^53, wraparound, `//` and `%` signs, shifts, string coercions, `tonumber` bases, `%q`/`%a`/`%g` formatting, numeric `for` limits |
| `strings` | find/match/gsub/gmatch (anchors, `%b`, `%f`, captures, replacement tables), `rep`/`byte`/`char`, `pack`/`unpack`, `utf8`, error messages of the string library |
| `tables` | `sort` (comparators, invalid orders), `insert`/`remove`/`move`/`unpack` bounds, length borders, `next` while clearing, key normalization |
| `metamethods` | arithmetic/bitwise/comparison/concat/len/call/index/newindex metamethods, `__eq` call counts, `__close` order, `__gc` order, protected metatables |
| `closures` | per-iteration upvalues, shared upvalues, goto/continue, varargs and `select`, assignment order, `_ENV`, stack overflow recovery |
| `coroutines` | wrap/resume/yield value passing, status, yield across `pcall` and metamethods, `close` with pending `<close>`, error identity |
| `errors` | variable info in messages (local/upvalue/global/field/method/constant), error levels, `xpcall` handlers, syntax error messages of `load` |
| `load_dump` | `string.dump` round trips (stripped and not), binary header checks, `load` modes/envs, `loadfile`/`dofile`, `require`/`package.preload`/`searchpath` |
| `io_os` | file reads/writes/seeks/modes, `io.lines`, default files, binary data, `os.date`/`os.time` normalization, `popen` |
| `random_math` | seeded `math.random` sequences (xoshiro256**) and libm-exact math functions |
| `weak_gc` | weak keys/values, ephemerons, finalizer order and resurrection, `collectgarbage` options and modes |
| `tbc_goto` | `<close>`/`<const>` semantics, generic-for closing value, goto validation, nested loops |
| `limits` | parser limits (locals, parameters, nesting, registers), long literals, escapes, recursion depth, huge `rep`/`unpack` |
| `fuzz_expr` | csmith-style: 1500 random expressions (arith, bitwise, comparison, concat, `and`/`or`, coercions) compiled with `load`, run under `pcall`, every result or message hashed. `FUZZ_SEED`, `FUZZ_COUNT`, `FUZZ_DEPTH` explore other seeds; the committed run is deterministic |
| `fuzz_table` | random sequences of table-library operations with a hash of every outcome |
| `fastpaths` | allocation-free built-ins (`type`/`select`/`rawget`/`setmetatable`/`math.*`/`string.sub`/`table.insert`...) incl. their fallback error cases, inline array and field access, `pairs`/`ipairs` loops, nil-padded array borders, tail-call buffers, mid-function hooks, upvalue closing at scale |
| `deepframes` | calls nested far past the native recursion threshold: results, varargs, tail calls, `<close>` ordering, error positions, tracebacks, hooks, coroutines, native boundaries and stack overflow recovery |
| `workloads` | n-body, fannkuch, binary trees, sieve, collatz, gcd, string building, matrix multiply: results and checksums |

## Writing a program

* `local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")`, then `T.emit(...)` for
  every value that matters and `T.try(f, ...)` for protected calls; finish with `T.done()`.
* Be deterministic: no addresses (`tostring(table)`), no unseeded `math.random`, no hash
  iteration order, no timing, no dependence on `lua.c` extras (it appends a traceback to some
  errors raised inside `load`: compare only the first line).
* Keep each program under a few seconds of C Lua time; the benchmark budget is for dlua.

## Bugs this suite found

Each was fixed in dlua when the suite was added:

* the placeholder `%s` leaked into "number has no integer representation" for constant operands;
* `return f(...)` with a C function target lost the call-site name and line (`'floor'` vs
  `'math.floor'`, missing position);
* `(constant 'x')` variable info for string constant operands, including `""`;
* `coroutine.resume/status/close/isyieldable` argument errors said "coroutine expected";
* constant folding of numeric operations and of `K and x` / `nil or x` as in `lcode.c`, which
  changes variable info and bytecode shape;
* `math.exp`/`log`/`sin`/`pow` used D's own implementations instead of libm (last-digit
  differences);
* `a.b.c.d` chains needed one register per level ("too many registers" at ~250 levels);
* the local-variable/parameter limit was reported at the wrong token;
* `package.path` contained a hard-coded test directory;
* the standalone interpreter did not start in generational mode like `lua.c`.

## Known differences (not covered by the checked-in seeds)

Fuzzing other seeds still finds rare differences in the *variable info* appended to errors when
the operand is the result of `(x or K) and K2`-style expressions: C Lua emits a degenerate
jump-to-next instruction there and reports `(constant ...)`, dlua's code generator differs in
shape. Results and error messages without variable info are identical.
