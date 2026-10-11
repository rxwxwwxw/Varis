"""Benchmark driver: paired, interleaved measurements against named comparators, with targets."""
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import tempfile
import time
import tomllib
import glob as _glob
from pathlib import Path

from .manifest import ROOT

HARNESS = """
local path = ...
local report = print
if os.getenv("BENCH_SILENT") == "1" then
  print = function() end
  io.write = function() end
end
local argline = os.getenv("BENCH_ARGS")
if argline and argline ~= "" then
  arg = {[0] = path}
  for a in argline:gmatch("%S+") do arg[#arg + 1] = a end
end
local t0 = os.clock()
local body = assert(loadfile(path))
local compile = os.clock() - t0
body()
local reps = tonumber(os.getenv("BENCH_REPEATS")) or 5
t0 = os.clock()
for _ = 1, reps do body() end
report(string.format("%.9f %.9f", (os.clock() - t0) / reps, compile))
"""


# ---------------------------------------------------------------- manifest / targets

def load_manifest(path=None):
    with open(path or ROOT / "benchmarks/manifest.toml", "rb") as f:
        return tomllib.load(f)


def load_targets(path=None):
    p = Path(path or ROOT / "benchmarks/targets.toml")
    if not p.exists():
        return {}
    with open(p, "rb") as f:
        return tomllib.load(f).get("workload", {})


def workloads(manifest):
    out = []
    d = manifest.get("defaults", {})
    for g in manifest["group"]:
        entries = []
        if "glob" in g:
            for f in sorted(_glob.glob(str(ROOT / g["glob"]))):
                p = Path(f)
                if p.name in g.get("exclude", []):
                    continue
                entries.append({"id": p.stem, "path": str(p.relative_to(ROOT)),
                                "cwd": str(p.parent.relative_to(ROOT)) if g.get("cwd_is_parent") else g.get("cwd", ".")})
        for c in g.get("cases", []):
            entries.append({"id": c["id"], "path": c["path"], "cwd": c.get("cwd", ".")})
        for e in entries:
            out.append({"id": f"{g['id']}.{e['id']}", "group": g["id"], "kind": g["kind"], "path": e["path"],
                        "cwd": e["cwd"], "args": g.get("args", []), "comparable": g.get("comparable", False), "silent": g.get("silent", False),
                        "runs": g.get("runs", d.get("runs", 7)), "repeats": g.get("repeats", d.get("repeats", 5)),
                        "timeout": g.get("timeout", d.get("timeout", 180))})
    return out


# ---------------------------------------------------------------- building comparators

def _git(*a, cwd=ROOT):
    return subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def toolchain_id():
    v = subprocess.run(["ldc2", "--version"], capture_output=True, text=True).stdout.splitlines()
    return v[0].strip() if v else "unknown-ldc"


def build_ref(ref, log=print):
    sha = _git("rev-parse", "--verify", ref + "^{commit}")
    key = hashlib.sha256(f"{sha}|release|{toolchain_id()}".encode()).hexdigest()[:10]
    out_dir = ROOT / ".cache/builds" / f"{sha[:8]}-{key}"
    out = out_dir / "interpreter"
    if out.exists():
        return out
    src = ROOT / ".cache/src" / sha[:8]
    if not src.exists():
        src.parent.mkdir(parents=True, exist_ok=True)
        _git("worktree", "add", "--detach", str(src), sha)
    log(f"building {ref} ({sha[:8]}) ...")
    # Trees before the rename build `dlua`; later ones build `varis`.
    name = "varis" if (src / "source/varis").is_dir() else "dlua"
    p = subprocess.run(["make", name], cwd=src, capture_output=True, text=True)
    if p.returncode or not (src / "bin" / name).exists():
        raise RuntimeError(f"build of {ref} failed:\n{p.stderr[-800:]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    (src / "bin" / name).replace(out)
    (out_dir / "identity.json").write_text(json.dumps(
        {"ref": ref, "commit": sha, "profile": "release", "toolchain": toolchain_id()}, indent=2))
    return out


def resolve_comparators(manifest, wanted, log=print):
    """Returns {label: Path|None}. Unavailable comparators are None (reported, not fatal)."""
    out = {}
    for label in wanted:
        spec = manifest.get("comparator", {}).get(label)
        if spec is None:
            out[label] = None
            continue
        try:
            if "path" in spec:
                p = ROOT / spec["path"]
                out[label] = p if p.is_file() else None
            else:
                out[label] = build_ref(spec["ref"], log)
        except Exception as e:  # noqa: BLE001
            log(f"comparator {label} unavailable: {e}")
            out[label] = None
    return out


# ---------------------------------------------------------------- measurement

def _rss_kb(ru):
    return ru.ru_maxrss / 1024 if platform.system() == "Darwin" else ru.ru_maxrss


def spawn(cmd, cwd, timeout, env=None):
    """Run once; returns (cpu_seconds, wall_seconds, rss_kb, stdout bytes). Raises RuntimeError on failure."""
    start = time.perf_counter()
    proc = subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    out = err = b""
    import threading
    chunks = {}

    def drain(name, f):
        chunks[name] = f.read()

    ts = [threading.Thread(target=drain, args=("o", proc.stdout)), threading.Thread(target=drain, args=("e", proc.stderr))]
    for t in ts:
        t.start()
    deadline = start + timeout
    while True:
        pid, status, ru = os.wait4(proc.pid, os.WNOHANG)
        if pid:
            break
        if time.perf_counter() > deadline:
            try:
                os.killpg(proc.pid, 9)
            except ProcessLookupError:
                pass
            os.wait4(proc.pid, 0)
            for t in ts:
                t.join()
            raise RuntimeError(f"timeout after {timeout:g}s")
        time.sleep(0.002)
    wall = time.perf_counter() - start
    for t in ts:
        t.join()
    proc.returncode = os.waitstatus_to_exitcode(status)
    out, err = chunks.get("o", b""), chunks.get("e", b"")
    if proc.returncode != 0:
        raise RuntimeError(f"exit {proc.returncode}: {err.decode(errors='replace')[-300:]}")
    return ru.ru_utime + ru.ru_stime, wall, _rss_kb(ru), out


def measure(w, binary):
    if w["kind"] == "inproc":
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(HARNESS)
        try:
            env = dict(os.environ, BENCH_REPEATS=str(w["repeats"]), BENCH_ARGS=" ".join(w["args"]),
                       BENCH_SILENT="1" if w.get("silent") else "0")
            cpu, wall, rss, out = spawn([binary, f.name, str(ROOT / w["path"])], ROOT / w["cwd"],
                                        w["timeout"] * w["repeats"], env)
        finally:
            os.unlink(f.name)
        exec_s, compile_s = map(float, out.split())
        if exec_s <= 0:
            raise RuntimeError("nonpositive execution time")
        return {"time": exec_s, "compile": compile_s, "rss_kb": rss, "wall": wall}
    cpu, wall, rss, out = spawn([binary, os.path.relpath(ROOT / w["path"], ROOT / w["cwd"]), *w["args"]],
                                ROOT / w["cwd"], w["timeout"])
    return {"time": cpu, "wall": wall, "rss_kb": rss, "out": hashlib.sha256(out).hexdigest()}


def summarize(xs):
    med = statistics.median(xs)
    mad = statistics.median([abs(x - med) for x in xs]) if len(xs) > 1 else 0.0
    return {"median": med, "min": min(xs), "max": max(xs), "cv": (1.4826 * mad / med) if med else 0.0, "samples": xs}


def run_workload(w, cand, comps, runs=None, log=lambda *_: None, caps=None):
    """Interleaved samples. Returns a record with per-binary summaries and paired ratios."""
    runs = runs or w["runs"]
    labels = ["candidate"] + [l for l, b in comps.items() if b]
    bins = {"candidate": cand, **{l: b for l, b in comps.items() if b}}
    series = {l: [] for l in labels}
    rss = {l: [] for l in labels}
    outs = {l: set() for l in labels}
    failed = {}
    for i in range(runs):
        order = list(labels)
        if i % 2:
            order.reverse()
        for l in order:
            if l in failed or (caps and l in caps and i >= caps[l]):
                continue
            try:
                m = measure(w, bins[l])
            except RuntimeError as e:
                failed[l] = str(e)
                continue
            series[l].append(m["time"])
            rss[l].append(m["rss_kb"])
            if "out" in m:
                outs[l].add(m["out"])
    rec = {"id": w["id"], "group": w["group"], "kind": w["kind"], "runs": runs, "errors": failed, "binaries": {}, "ratios": {}}
    if "candidate" in failed:
        rec["status"] = "error"
        return rec
    for l in labels:
        if l in failed or not series[l]:
            continue
        rec["binaries"][l] = {**summarize(series[l]), "rss_kb": max(rss[l])}
    for l in labels:
        if l == "candidate" or l not in rec["binaries"]:
            continue
        n = min(len(series["candidate"]), len(series[l]))
        paired = [series["candidate"][k] / series[l][k] for k in range(n) if series[l][k] > 0]
        if paired:
            rec["ratios"][l] = {"median": statistics.median(paired), "min": min(paired), "max": max(paired),
                                "rss": rec["binaries"]["candidate"]["rss_kb"] / max(rec["binaries"][l]["rss_kb"], 1)}
    if w["kind"] == "process" and "clua" in outs and outs["clua"] and outs["candidate"] and outs["clua"] != outs["candidate"]:
        rec["errors"]["output"] = "candidate output differs from C Lua"
    rec["noisy"] = rec["binaries"]["candidate"]["cv"] > 0.15
    rec["status"] = "measured"
    return rec


# ---------------------------------------------------------------- targets

LOAD_FACTOR = 0.75


def machine_loaded():
    """True when the 1-minute load average says other work is competing for the cores."""
    try:
        return os.getloadavg()[0] > LOAD_FACTOR * (os.cpu_count() or 1)
    except OSError:
        return False


def evaluate(rec, target):
    """Findings: dicts {kind, label, value, limit, ok}. goal misses are informational.

    On a loaded machine a ratio against a binary built by a different toolchain (`clua`) is not
    trustworthy: memory-heavy workloads suffer from contention more than the C interpreter does. Such
    gate failures are reported with ok=None (inconclusive) instead of failing the check; ratios between
    two builds of this project (same toolchain, same load) and floors keep being enforced.
    """
    findings = []
    loaded = rec.get("loaded", False)
    for kind in ("goal", "gate"):
        for label, limit in target.get(kind, {}).items():
            r = rec["ratios"].get(label)
            if r is None:
                findings.append({"kind": kind, "label": label, "value": None, "limit": limit, "ok": None})
            else:
                ok = r["median"] <= limit
                if not ok and loaded and kind == "gate" and label == "clua":
                    ok = None
                    kind_note = "inconclusive: machine loaded"
                else:
                    kind_note = ""
                findings.append({"kind": kind, "label": label, "value": r["median"], "limit": limit,
                                 "ok": ok, "note": kind_note})
    for label, limit in target.get("floor", {}).items():
        r = rec["ratios"].get(label)
        if r is None:
            findings.append({"kind": "floor", "label": label, "value": None, "limit": limit, "ok": None})
        else:  # speedup over the comparator
            sp = 1.0 / r["median"]
            findings.append({"kind": "floor", "label": label, "value": sp, "limit": limit, "ok": sp >= limit})
    for label, limit in target.get("memory", {}).items():
        r = rec["ratios"].get(label)
        if r is not None:
            findings.append({"kind": "memory", "label": label, "value": r["rss"], "limit": limit, "ok": r["rss"] <= limit})
    return findings


def hard_failed(findings):
    return any(f["ok"] is False and f["kind"] in ("gate", "floor", "memory") for f in findings)


def needed_labels(w, target):
    labels = set()
    for kind in ("goal", "gate", "floor", "memory"):
        labels |= set(target.get(kind, {}))
    if not labels and w["comparable"]:
        labels.add("clua")
    return labels


# ---------------------------------------------------------------- derivation

HEADROOM = {"core": 1.10}
DEFAULT_HEADROOM = 1.20
SHORT_SECONDS = 0.02
SHORT_HEADROOM = 1.60
GATE_SLACK = 0.10  # absolute ratio slack added to every derived gate


def derive(rec, history=None):
    """Initial targets for one measured workload using the policy in CONSOLIDATION_PLAN.md §4.3."""
    head = HEADROOM.get(rec["group"], DEFAULT_HEADROOM)
    cand = rec.get("binaries", {}).get("candidate", {}).get("median")
    if cand is not None and cand < SHORT_SECONDS:
        head = max(head, SHORT_HEADROOM)  # a few milliseconds of CPU time is mostly quantization noise
    t = {"goal": {}, "gate": {}, "floor": {}}
    for label, r in rec["ratios"].items():
        worst = r["median"]
        if history and label in history:
            worst = max(worst, history[label])
        if label == "clua":
            t["goal"]["clua"] = 2.0
            t["gate"]["clua"] = round(worst * head + GATE_SLACK, 2)
        elif label == "v0-snapshot":
            sp = 1.0 / r["median"]
            if sp > 1.5:
                t["floor"][label] = round(sp * 0.6, 1)
        else:
            t["gate"][label] = round(max(worst, 1.0) * head + GATE_SLACK, 2)
    return {k: v for k, v in t.items() if v}


def render_targets(derived):
    out = ["# Performance targets. Ratios are candidate/comparator CPU time measured in one session.",
           "# goal: project target, reported only.   gate: regression ratchet (fatal when exceeded).",
           "# floor: minimum speedup over a named older version (fatal when below).",
           "# Loosening a gate/floor needs a `Perf-Regression-Accepted:` commit trailer (see commit-msg hook).", ""]
    for wid in sorted(derived):
        out.append(f'[workload."{wid}"]')
        for kind in ("goal", "gate", "floor", "memory"):
            for label, v in sorted(derived[wid].get(kind, {}).items()):
                out.append(f"{kind}.{label} = {v}")
        out.append("")
    return "\n".join(out).rstrip("\n")
