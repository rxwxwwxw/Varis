#!/usr/bin/env python3
import time
import subprocess
import os
import sys
import argparse
import hashlib
import json
import platform
import statistics
from pathlib import Path

BENCHMARKS = [
    {
        "name": "fibonacci_recursive",
        "desc": "Recursive Fibonacci (fib(30))",
        "code": """
function fib(n)
    if n < 2 then return n end
    return fib(n-1) + fib(n-2)
end
local res = fib(30)
assert(res == 832040)
"""
    },
    {
        "name": "numeric_for_loop",
        "desc": "10M iterations arithmetic loop",
        "code": """
local s = 0
for i = 1, 10000000 do
    s = s + i
end
assert(s == 50000005000000)
"""
    },
    {
        "name": "table_array_access",
        "desc": "1M table sequential array insertions & reads",
        "code": """
local t = {}
for i = 1, 1000000 do
    t[i] = i
end
local sum = 0
for i = 1, 1000000 do
    sum = sum + t[i]
end
assert(sum == 500000500000)
"""
    },
    {
        "name": "table_hash_access",
        "desc": "100k hash table insertions & reads",
        "code": """
local t = {}
for i = 1, 100000 do
    local k = "key_" .. tostring(i % 500)
    t[k] = i
end
for i=0,499 do assert(t["key_" .. i] == (i == 0 and 100000 or 99500+i)) end
"""
    },
    {
        "name": "string_manipulation",
        "desc": "100k substring & concatenation ops",
        "code": """
local s = "abcdefghijklmnopqrstuvwxyz"
for i = 1, 100000 do
    s = string.sub(s, 2) .. "a"
end
assert(s == string.rep("a", 26))
"""
    },
    {
        "name": "sieve_of_eratosthenes",
        "desc": "Sieve of Eratosthenes primes up to 100k",
        "code": """
local max = 100000
local is_prime = {}
for i = 2, max do is_prime[i] = true end
for p = 2, math.floor(math.sqrt(max)) do
    if is_prime[p] then
        for i = p * p, max, p do
            is_prime[i] = false
        end
    end
end
local count = 0
for i = 2, max do
    if is_prime[i] then count = count + 1 end
end
assert(count == 9592)
"""
    }
]

def summarize(samples):
    return {"median": statistics.median(samples), "min": min(samples),
            "max": max(samples), "samples": samples}


def measure(executable, code, repeats, timeout):
    # Compile once, then measure repeated execution independently of startup and
    # frontend cost. Each body has assertions; failures always fail the process.
    harness = r"""
local start = os.clock()
local body = assert(load(%s, "=benchmark"))
local compile = os.clock() - start
body()
start = os.clock()
for repetition=1,%d do body() end
io.write(string.format("%%.9f %%.9f\n", os.clock()-start, compile))
""" % ("[====[" + code + "]====]", repeats)
    start = time.perf_counter()
    proc = subprocess.run([executable, "-e", harness], capture_output=True,
                          text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    wall = time.perf_counter()-start
    if proc.returncode:
        raise RuntimeError(f"{executable} exited {proc.returncode}: {proc.stderr[-2000:]}")
    execution, compilation = map(float, proc.stdout.split())
    if execution <= 0:
        raise RuntimeError("nonpositive execution measurement")
    return execution / repeats, compilation, wall


def identity(path):
    return {"path": str(Path(path).resolve()),
            "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest()}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--c-lua", default="c-implementation/src/lua")
    ap.add_argument("--dlua", default="bin/dlua")
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--only", action="append", choices=[b["name"] for b in BENCHMARKS])
    ap.add_argument("--json", type=Path)
    ap.add_argument("--max-ratio", type=float, help="explicit per-workload acceptance gate")
    args = ap.parse_args(argv)
    if args.runs < 1 or args.repeats < 1:
        ap.error("runs and repeats must be positive")
    report = {"machine": platform.platform(), "architecture": platform.machine(),
              "runs": args.runs, "repeats": args.repeats, "timing": "os.clock CPU seconds, load once; one warmup per process",
              "c": identity(args.c_lua), "dlua": identity(args.dlua), "workloads": {}}
    failed = False
    for bench in BENCHMARKS:
        if args.only and bench["name"] not in args.only:
            continue
        values = {"c": [], "dlua": []}
        compiles = {"c": [], "dlua": []}
        walls = {"c": [], "dlua": []}
        try:
            for run in range(args.runs):
                order = [("c", args.c_lua), ("dlua", args.dlua)]
                if run % 2: order.reverse()
                for label, binary in order:
                    elapsed, compile_time, wall = measure(binary, bench["code"], args.repeats, args.timeout)
                    values[label].append(elapsed)
                    compiles[label].append(compile_time)
                    walls[label].append(wall)
            ratio = statistics.median(values["dlua"]) / statistics.median(values["c"])
            report["workloads"][bench["name"]] = {
                "code_sha256": hashlib.sha256(bench["code"].encode()).hexdigest(),
                "execution": {k: summarize(v) for k, v in values.items()},
                "compile": {k: summarize(v) for k, v in compiles.items()},
                "process_wall": {k: summarize(v) for k, v in walls.items()}, "ratio": ratio}
            print(f"{bench['name']:<25} C={statistics.median(values['c']):.6f}s dlua={statistics.median(values['dlua']):.6f}s {ratio:.2f}x", flush=True)
            failed |= args.max_ratio is not None and ratio > args.max_ratio
        except (RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
            report["workloads"][bench["name"]] = {"error": str(error)}
            print(f"{bench['name']}: FAIL {error}", file=sys.stderr, flush=True)
            failed = True
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
