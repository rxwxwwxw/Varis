#!/usr/bin/env python3
import time
import subprocess
import os
import sys

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

def run_bench(executable, code, runs=3):
    times = []
    for _ in range(runs):
        start = time.perf_counter()
        proc = subprocess.run([executable, "-e", code], capture_output=True, text=True,
                              timeout=300)
        end = time.perf_counter()
        if proc.returncode != 0:
            print(f"Error running {executable}: {proc.stderr}", file=sys.stderr)
            return None
        times.append(end - start)
    return min(times)

def main():
    c_lua = os.path.abspath("c-implementation/src/lua")
    d_lua = os.path.abspath("bin/dlua")

    if not os.path.exists(c_lua):
        print(f"Building C Lua: {c_lua}")
        subprocess.run(["make", "-C", "c-implementation/src", "macosx"], check=True)

    if not os.path.exists(d_lua):
        print(f"Building dlua: {d_lua}")
        subprocess.run(["make", "dlua"], check=True)

    print("=" * 80)
    print(f"{'dlua vs C Lua 5.4 Benchmark Suite (Apple Silicon arm64)':^80}")
    print("=" * 80)
    print(f"  C Lua binary : {c_lua}")
    print(f"  dlua binary  : {d_lua}")
    print("-" * 80)
    print(f"{'Benchmark':<25} | {'C Lua (s)':<12} | {'dlua (s)':<12} | {'Ratio (dlua/C)':<15}")
    print("-" * 80)

    failed = False
    for bench in BENCHMARKS:
        t_c = run_bench(c_lua, bench["code"])
        t_d = run_bench(d_lua, bench["code"])

        if t_c is not None and t_d is not None:
            ratio = t_d / t_c
            print(f"{bench['name']:<25} | {t_c:10.4f} s | {t_d:10.4f} s | {ratio:13.2f}x")
        else:
            failed = True
            print(f"{bench['name']:<25} | FAILED")

    print("-" * 80)
    return int(failed)

if __name__ == "__main__":
    raise SystemExit(main())
