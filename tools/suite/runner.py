import concurrent.futures as cf
import json
import platform
import subprocess
import time
from pathlib import Path

from . import model as M
from .kinds import KINDS, Ctx, identity
from .proc import run, text


def git_commit(root):
    p = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root, capture_output=True, text=True)
    return p.stdout.strip() or None


def apply_ledger(results, ledger):
    """Skips/partials/known gaps need a matching ledger entry; stale entries are failures."""
    out = []
    seen = set()
    for r in results:
        entry = ledger.get(r.id)
        if r.status in M.LEDGER_STATUSES:
            seen.add(r.id)
            if entry is None or entry["status"] != r.status:
                r = M.Result(r.id, r.suite, M.FAIL, r.seconds,
                             f"{r.status} without a matching ledger entry in tests/manifest.toml")
        elif entry is not None and r.status == M.PASS and not entry.get("allow_pass"):
            r = M.Result(r.id, r.suite, M.XPASS, r.seconds, "ledger entry is stale: case now passes")
        out.append(r)
    return out


def prepare(cases, ctx):
    """Build prerequisites once so parallel cases do not race on them."""
    steps = []
    if any(c.kind == "d-unit" for c in cases):
        steps.append(["make", "-s", "build/debug/obj/.built"])
    for cmd in steps:
        code, out, err, _ = run(cmd, cwd=ctx.root, timeout=1800)
        if code != 0:
            raise SystemExit(f"prepare failed: {' '.join(cmd)}\n{text(err)[-1000:]}")


def select(cases, tier, filters=(), suites=(), tags=()):
    rank = M.tier_rank(tier)
    sel = [c for c in cases if M.tier_rank(c.tier) <= rank]
    if suites:
        sel = [c for c in sel if c.suite in suites]
    if tags:
        sel = [c for c in sel if set(tags) & set(c.tags)]
    if filters:
        sel = [c for c in sel if any(f in c.id for f in filters)]
    return sel


def execute(cases, ctx, jobs=4, on_result=None):
    results = []

    def one(case):
        try:
            return KINDS[case.kind](case, ctx)
        except Exception as e:  # harness bug or environment problem: never hide it as a pass
            return [M.Result(case.id, case.suite, M.ERROR, 0, f"{type(e).__name__}: {e}")]

    heavy = [c for c in cases if c.kind in ("official",)]
    light = [c for c in cases if c.kind not in ("official",)]

    # Heavy, timing-sensitive groups (the official suite) run alone after everything else: a
    # one-off 240 s timeout of all.lua was observed when it shared the machine with other cases.
    for batch, width in ((light, jobs), (heavy, 1)):
        if not batch:
            continue
        with cf.ThreadPoolExecutor(max_workers=max(1, width)) as pool:
            futs = {pool.submit(one, c): c for c in batch}
            for f in cf.as_completed(futs):
                for r in f.result():
                    results.append(r)
                    if on_result:
                        on_result(r)
    return results


def report(results, ctx, tier, wall):
    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    return {"schema": 1, "kind": "tests", "tier": tier, "machine": platform.platform(),
            "commit": git_commit(ctx.root), "candidate": identity(ctx.candidate),
            "reference": identity(ctx.reference) if ctx.reference else None,
            "wall_seconds": round(wall, 2), "counts": counts,
            "results": [r.as_dict() for r in sorted(results, key=lambda r: r.id)]}
