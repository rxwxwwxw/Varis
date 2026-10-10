"""Load tests/manifest.toml and expand it into cases and ledger entries."""
import glob
import tomllib
from pathlib import Path

from .model import Case

ROOT = Path(__file__).resolve().parents[2]


class ManifestError(Exception):
    pass


def load(path=None):
    path = Path(path or ROOT / "tests/manifest.toml")
    with open(path, "rb") as f:
        return tomllib.load(f)


def _case(suite, name, params, sc):
    return Case(
        id=f"{suite['id']}.{name}", suite=suite["id"], kind=suite["kind"],
        tier=sc.get("tier", suite.get("tier", "fast")),
        tags=list(suite.get("tags", [])) + list(sc.get("tags", [])),
        timeout=float(sc.get("timeout", suite.get("timeout", 120))),
        covers=list(sc.get("covers", [])), params=params)


def expand(manifest, root=ROOT):
    """Returns (cases, ledger dict, expected_counts dict). Raises ManifestError on count mismatch."""
    cases, counts = [], {}
    for suite in manifest.get("suite", []):
        sid = suite["id"]
        overrides = suite.get("override", {})
        base = {k: v for k, v in suite.items() if k not in ("id", "kind", "tier", "tags", "timeout", "glob",
                                                           "override", "cases", "scales", "expect_count")}
        made = []
        if "glob" in suite:
            files = sorted(Path(p) for p in glob.glob(str(root / suite["glob"])))
            files = [f for f in files if f.name not in suite.get("exclude", [])]
            for f in files:
                ov = overrides.get(f.stem, {})
                params = dict(base, path=str(f.relative_to(root)), **{k: v for k, v in ov.items()
                                                                       if k not in ("tier", "tags", "timeout", "covers")})
                if "scales" in suite:
                    for scale, tier in suite["scales"].items():
                        c = _case(suite, f"{f.stem}.{scale}", dict(params, scale=scale), dict(ov, tier=ov.get("tier", tier)))
                        made.append(c)
                else:
                    made.append(_case(suite, f.stem, params, ov))
        else:
            for sc in suite.get("cases", []):
                params = dict(base, **{k: v for k, v in sc.items() if k not in ("id", "tier", "tags", "timeout", "covers")})
                made.append(_case(suite, sc["id"], params, sc))
        counts[sid] = len(made)
        if "expect_count" in suite and suite["expect_count"] != len(made):
            raise ManifestError(f"suite {sid}: expected {suite['expect_count']} cases, found {len(made)}")
        cases.extend(made)
    ids = [c.id for c in cases]
    dup = {i for i in ids if ids.count(i) > 1}
    if dup:
        raise ManifestError(f"duplicate case ids: {sorted(dup)}")
    ledger = {e["id"]: e for e in manifest.get("ledger", [])}
    return cases, ledger, counts
