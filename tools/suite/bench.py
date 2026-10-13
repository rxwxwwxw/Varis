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
local reps = tonumber(os.getenv("BENCH_REPEATS")) or 5
local w0 = os.clock()
body()
w0 = os.clock() - w0
-- A slow kernel needs fewer repetitions for the same precision (the result is a per-repetition mean).
if w0 >= 0.3 then reps = math.min(reps, 2) elseif w0 >= 0.1 then reps = math.min(reps, 3) end
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
            entries.append({"id": c["id"], "path": c["path"], "cwd": c.get("cwd", "."), "args": c.get("args")})
        for e in entries:
            out.append({"id": f"{g['id']}.{e['id']}", "group": g["id"], "kind": g["kind"], "path": e["path"],
                        "cwd": e["cwd"], "args": e.get("args") or g.get("args", []), "comparable": g.get("comparable", False), "silent": g.get("silent", False),
                        "comparator": g.get("comparator", "clua"),
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
            if "binary" in spec:
                import shutil
                p = shutil.which(spec["binary"])
                out[label] = Path(p) if p else None
            elif "path" in spec:
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


def normalize_output(out_bytes):
    """Normalize stdout lines between Varis and Souffle for exact content verification."""
    lines = out_bytes.decode(errors="replace").splitlines()
    data = []
    for line in lines:
        s = line.strip()
        if not s or s.startswith("---") or s.startswith("===") or s.startswith("count_"):
            continue
        data.append(s)
    return "\n".join(data).encode("utf-8")


def measure(w, binary, label="candidate"):
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
    prog_path = ROOT / w["path"]
    if label == "souffle":
        dl_path = prog_path.with_suffix(".dl")
        cmd = [binary, "-j", "1", os.path.relpath(dl_path, ROOT / w["cwd"])]
    else:
        cmd = [binary, os.path.relpath(prog_path, ROOT / w["cwd"]), *w["args"]]
    cpu, wall, rss, out = spawn(cmd, ROOT / w["cwd"], w["timeout"])
    norm_out = normalize_output(out)
    return {"time": cpu, "wall": wall, "rss_kb": rss, "out": hashlib.sha256(norm_out).hexdigest()}


def summarize(xs):
    med = statistics.median(xs)
    mad = statistics.median([abs(x - med) for x in xs]) if len(xs) > 1 else 0.0
    return {"median": med, "min": min(xs), "max": max(xs), "cv": (1.4826 * mad / med) if med else 0.0, "samples": xs}


MIN_RUNS = 3
SETTLED_SAMPLE_SECONDS = 0.4   # estimated process time of one sample at which sampling may stop early
SETTLED_CV = 0.03


def _settled(xs, w):
    """True when the candidate's samples are individually expensive and already agree closely."""
    if len(xs) < MIN_RUNS:
        return False
    per_sample = statistics.median(xs) * (w["repeats"] + 1 if w["kind"] == "inproc" else 1)
    return per_sample >= SETTLED_SAMPLE_SECONDS and summarize(xs)["cv"] <= SETTLED_CV


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
        if i >= MIN_RUNS and _settled(series["candidate"], w):
            runs = i  # long, stable workload: further samples would only repeat the same number
            break
        order = list(labels)
        if i % 2:
            order.reverse()
        for l in order:
            if l in failed or (caps and l in caps and i >= caps[l]):
                continue
            try:
                m = measure(w, bins[l], label=l)
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
    if w["kind"] == "process":
        for l in labels:
            if l != "candidate" and l in outs and outs[l] and outs["candidate"] and outs[l] != outs["candidate"]:
                rec["errors"]["output"] = f"candidate output differs from {l}"
    rec["noisy"] = rec["binaries"]["candidate"]["cv"] > 0.15
    rec["status"] = "measured"
    return rec


# ---------------------------------------------------------------- targets

def evaluate(rec, target):
    """Findings: dicts {kind, label, value, limit, ok}. goal misses are informational."""
    findings = []
    cand = rec.get("binaries", {}).get("candidate", {}).get("median")
    for kind in ("goal", "gate"):
        for label, limit in target.get(kind, {}).items():
            if label == "time":  # absolute CPU-second budget of the candidate, no comparator involved
                if kind == "gate" and cand is not None:
                    findings.append({"kind": "gate", "label": "time", "value": cand, "limit": limit,
                                     "ok": cand <= limit})
                continue
            if label == "rss_mb":  # absolute peak-RSS budget of the candidate, in megabytes (10^6 bytes)
                rss_kb = rec.get("binaries", {}).get("candidate", {}).get("rss_kb")
                if kind == "gate" and rss_kb is not None:
                    mb = rss_kb * 1024 / 1e6
                    findings.append({"kind": "gate", "label": "rss_mb", "value": mb, "limit": limit,
                                     "ok": mb <= limit})
                continue
            r = rec["ratios"].get(label)
            if r is None:
                findings.append({"kind": kind, "label": label, "value": None, "limit": limit, "ok": None})
            else:
                findings.append({"kind": kind, "label": label, "value": r["median"], "limit": limit,
                                 "ok": r["median"] <= limit})
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
    labels.discard("time")
    labels.discard("rss_mb")
    if not labels and w["comparable"]:
        labels.add(w.get("comparator", "clua"))
    return labels


# ---------------------------------------------------------------- derivation

HEADROOM = {"core": 1.10}
DEFAULT_HEADROOM = 1.20
SHORT_SECONDS = 0.02
SHORT_HEADROOM = 1.60
GATE_SLACK = 0.10  # absolute ratio slack added to every derived gate


TIME_FLOOR = 0.02       # seconds; below this a budget would be pure process-start noise
TIME_HEADROOM = 1.5     # absolute budgets tolerate machine state; the clua ratio is the sharp check


def _ceil_sig(x, digits=2):
    """Rounds up to `digits` significant figures (0.1234 -> 0.13, 17.2 -> 18)."""
    if x <= 0:
        return x
    scale = 10 ** (math.floor(math.log10(x)) - digits + 1)
    return round(math.ceil(x / scale - 1e-9) * scale, 6)


def derive(rec, history=None):
    """Initial targets for one measured workload (policy in CONSOLIDATION_PLAN.md §4.3, amended:
    the candidate's own median time with 50 % headroom is the absolute budget, rounded up to two
    significant figures; the older version comparators are gone)."""
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
        elif label == "souffle":
            t["goal"]["souffle"] = 2.0
            t["gate"]["souffle"] = round(worst * head + GATE_SLACK, 2)
        else:
            t["gate"][label] = round(max(worst, 1.0) * head + GATE_SLACK, 2)
    if cand:
        t["gate"]["time"] = max(TIME_FLOOR, _ceil_sig(cand * max(head, TIME_HEADROOM)))
    return {k: v for k, v in t.items() if v}


def render_targets(derived):
    out = ["# Performance targets. Ratios are candidate/comparator CPU time measured in one session.",
           "# goal: project target, reported only.   gate: regression ratchet (fatal when exceeded);",
           "# gate.time is the candidate's absolute CPU-second budget, gate.<comparator> a ratio.",
           "# floor: minimum speedup over a named older version (fatal when below).",
           "# Loosening a gate/floor needs a `Perf-Regression-Accepted:` commit trailer (see commit-msg hook).", ""]
    for wid in sorted(derived):
        out.append(f'[workload."{wid}"]')
        for kind in ("goal", "gate", "floor", "memory"):
            for label, v in sorted(derived[wid].get(kind, {}).items()):
                out.append(f"{kind}.{label} = {v}")
        out.append("")
    return "\n".join(out).rstrip("\n")
