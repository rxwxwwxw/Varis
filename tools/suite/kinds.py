"""Executors for each case kind. Each takes (case, ctx) and returns a list of Result."""
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from . import model as M
from .proc import run, text


class Ctx:
    def __init__(self, root, candidate, reference=None, timeout_scale=1.0):
        self.root = Path(root)
        self.candidate = Path(candidate)
        self.reference = Path(reference) if reference else None
        self.timeout_scale = timeout_scale

    def t(self, case):
        return case.timeout * self.timeout_scale


def _res(case, status, secs=0.0, detail="", id=None):
    return [M.Result(id or case.id, case.suite, status, secs, detail)]


def _first_diff(got, want):
    g, w = got.splitlines(), want.splitlines()
    for n, (a, b) in enumerate(zip(g, w), 1):
        if a != b:
            return f"line {n}: got {a!r}, want {b!r}"
    return f"got {len(g)} lines, want {len(w)}"


def _crash(code):
    return code is not None and code < 0


def lua_ok(case, ctx):
    p = case.params
    code, out, err, secs = run([ctx.candidate, ctx.root / p["path"]], cwd=ctx.root, timeout=ctx.t(case))
    if code is None:
        return _res(case, M.TIMEOUT, secs, f"timed out after {ctx.t(case):g}s")
    if code != 0:
        return _res(case, M.FAIL, secs, (text(err) or text(out)).strip()[-400:] or f"exit {code}")
    return _res(case, M.PASS, secs)


def lua_reject(case, ctx):
    """Program must be rejected for the intended reason (not a crash, timeout or fallback error)."""
    p = case.params
    code, out, err, secs = run([ctx.candidate, ctx.root / p["path"]], cwd=ctx.root, timeout=ctx.t(case))
    log = text(out) + text(err)
    if code is None:
        return _res(case, M.TIMEOUT, secs, "timed out")
    if _crash(code):
        return _res(case, M.FAIL, secs, f"crashed with signal {-code}")
    if code == 0:
        return _res(case, M.FAIL, secs, "expected validation error, program succeeded")
    if "UNEXPECTED SUCCESS" in log:
        return _res(case, M.FAIL, secs, "reached fallback error, not a validation failure")
    expect = p.get("expect")
    if not expect:
        return _res(case, M.ERROR, secs, "manifest has no `expect` diagnostic for a rejection case")
    if not re.search(expect, log):
        return _res(case, M.FAIL, secs, f"wrong rejection diagnostic: {log.strip()[:300]}")
    return _res(case, M.PASS, secs)


def golden(case, ctx):
    p = case.params
    program = ctx.root / p["path"]
    scale = p["scale"]
    expected = program.parent / "expected" / f"{program.stem}.{scale}.txt"
    code, out, err, secs = run([ctx.candidate, program, scale], cwd=program.parent, timeout=ctx.t(case))
    if code is None:
        return _res(case, M.TIMEOUT, secs, f"timed out after {ctx.t(case):g}s")
    if code != 0:
        first = text(err).strip().splitlines()
        return _res(case, M.FAIL, secs, f"exit status {code}: {first[0] if first else ''}")
    if not expected.exists():
        return _res(case, M.FAIL, secs, f"missing {expected.name}")
    got, want = text(out), expected.read_text()
    if got != want:
        return _res(case, M.FAIL, secs, _first_diff(got, want))
    return _res(case, M.PASS, secs)


def known_gap(case, ctx):
    program = ctx.root / case.params["path"]
    m = re.search(r"^-- KNOWN-GAP: (.+)$", program.read_text(), re.M)
    if not m:
        return _res(case, M.FAIL, 0, "no '-- KNOWN-GAP:' line")
    fragment = m.group(1).strip()
    code, out, err, secs = run([ctx.candidate, program], cwd=program.parent, timeout=ctx.t(case))
    log = text(out) + text(err)
    if code is None:
        return _res(case, M.FAIL, secs, "timed out")
    if code == 0:
        return _res(case, M.XPASS, secs, "gap closed: move this program into the main suite")
    if code < 0:
        return _res(case, M.FAIL, secs, f"crashed with signal {-code}")
    if fragment not in log:
        return _res(case, M.FAIL, secs, f"failed, but not with '{fragment}': {log.strip()[:200]}")
    return _res(case, M.XFAIL, secs, fragment)


def extension(case, ctx):
    p = case.params
    src = ctx.root / p["path"]
    helpers = (ctx.root / p["helpers"]).read_text()
    expect = p.get("expect")
    source = helpers + "\n" + src.read_text()
    source += '\nprint("EXTENSION_CASE_COMPLETE")\n' if expect is None else '\nerror("UNEXPECTED SUCCESS")\n'
    with tempfile.TemporaryDirectory(prefix="suite-ext-") as d:
        script = Path(d) / src.name
        script.write_text(source)
        code, out, err, secs = run([ctx.candidate, script], cwd=d, timeout=ctx.t(case))
    log = text(out) + text(err)
    if code is None:
        return _res(case, M.TIMEOUT, secs, f"timed out after {ctx.t(case):g}s")
    if expect is None:
        ok = code == 0 and "EXTENSION_CASE_COMPLETE" in log
    else:
        ok = code > 0 and "UNEXPECTED SUCCESS" not in log and re.search(expect, log) is not None
    return _res(case, M.PASS if ok else M.FAIL, secs, "" if ok else log.strip()[-500:] or f"exit {code}")


def _checksum(b):
    for line in reversed(text(b).splitlines()):
        if line.startswith("CHECKSUM "):
            return line
    return None


def differential(case, ctx):
    """Candidate output must match the reference interpreter byte for byte and the recorded checksum."""
    p = case.params
    prog = ctx.root / p["path"]
    d = prog.parent
    code, out, err, secs = run([ctx.candidate, prog.name], cwd=d, timeout=ctx.t(case))
    if code is None:
        return _res(case, M.TIMEOUT, secs, "timed out")
    problems = []
    line = _checksum(out)
    if code != 0 or line is None:
        problems.append(f"candidate exit {code}: {text(err)[-300:]}")
    if ctx.reference and p.get("reference", True):
        rcode, rout, rerr, _ = run([ctx.reference, prog.name], cwd=d, timeout=ctx.t(case))
        if rcode != 0:
            problems.append(f"reference exit {rcode}: {text(rerr)[-300:]}")
        elif rout != out:
            problems.append(_first_diff(text(out), text(rout)))
        line = line or _checksum(rout)
    exp_path = ctx.root / p["expected"]
    if exp_path.exists() and line is not None:
        exp = json.loads(exp_path.read_text()).get(prog.stem)
        if exp is not None and exp != line:
            problems.append(f"checksum {line} != expected {exp}")
    return _res(case, M.FAIL if problems else M.PASS, secs, "; ".join(problems))


def script(case, ctx):
    """Run an arbitrary command; success is exit 0. {candidate}/{reference} are substituted."""
    sub = {"candidate": str(ctx.candidate), "reference": str(ctx.reference or "")}
    cmd = [a.format(**sub) for a in case.params["command"]]
    code, out, err, secs = run(cmd, cwd=ctx.root / case.params.get("cwd", "."), timeout=ctx.t(case))
    if code is None:
        return _res(case, M.TIMEOUT, secs, "timed out")
    if code != 0:
        return _res(case, M.FAIL, secs, (text(err) + text(out)).strip()[-600:])
    return _res(case, M.PASS, secs)


def d_unit(case, ctx):
    """One D unit-test executable, built from the shared debug object set via the Makefile."""
    code, out, err, secs = run(["make", "-s", case.params["target"]], cwd=ctx.root, timeout=ctx.t(case))
    log = text(out) + text(err)
    if code is None:
        return _res(case, M.TIMEOUT, secs, "timed out")
    if code != 0:
        return _res(case, M.FAIL, secs, log.strip()[-800:])
    passed = len(re.findall(r"\[PASS\]", log))
    return _res(case, M.PASS, secs, f"{passed} checks" if passed else "")


def official(case, ctx):
    """Run the official Lua suite through the D runner and expand its JSON into one result per file."""
    runner = ctx.root / "bin/test_runner"
    if not runner.exists():
        code, out, err, _ = run(["make", "-s", "test-runner"], cwd=ctx.root, timeout=600)
        if code != 0:
            return _res(case, M.ERROR, 0, "cannot build test_runner: " + text(err)[-300:])
    with tempfile.TemporaryDirectory(prefix="suite-official-") as d:
        jpath = Path(d) / "official.json"
        cmd = [runner, "--lua", ctx.candidate, "--timeout", str(case.params.get("file_timeout", 240)),
               "--json", jpath]
        if ctx.reference:
            cmd += ["--reference", ctx.reference]
        filt = case.params.get("filter")
        if filt:
            cmd += ["--filter", filt]
        code, out, err, secs = run(cmd, cwd=ctx.root, timeout=ctx.t(case))
        if code is None:
            return _res(case, M.TIMEOUT, secs, "official runner timed out")
        if not jpath.exists():
            return _res(case, M.ERROR, secs, (text(err) + text(out))[-500:])
        report = json.loads(jpath.read_text())
    mapping = {"PASS": M.PASS, "PARTIAL": M.PARTIAL, "SKIP": M.SKIP, "FAIL": M.FAIL, "TIMEOUT": M.TIMEOUT}
    results = []
    for r in report["results"]:
        status = mapping.get(r["status"].upper(), M.ERROR)
        detail = r.get("reason") or r.get("diagnostic") or ""
        results.append(M.Result(f"official.{Path(r['name']).stem}", case.suite, status,
                                float(r.get("duration_seconds", 0)), detail[:300]))
    return results


KINDS = {"lua-ok": lua_ok, "lua-reject": lua_reject, "golden": golden, "known-gap": known_gap,
         "extension": extension, "differential": differential, "script": script, "d-unit": d_unit,
         "official": official}


def identity(path):
    p = Path(path)
    if not p.is_file():
        return None
    return {"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
