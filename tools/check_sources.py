#!/usr/bin/env python3
"""Repository source checks (used by the pre-commit hook and `make check-sources`).

* every source/**/*.d module is listed in the Makefile (AGENTS.md keeps that list explicit),
  except cli.d, which the Makefile appends to the executable build only;
* every .d file carries the PUC-Rio license header (AGENTS.md invariant 1).
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STANDALONE = {"source/varis/cli.d"}


def tracked_d_files():
    out = subprocess.run(["git", "ls-files", "*.d"], cwd=ROOT, capture_output=True, text=True, check=True)
    return [f for f in out.stdout.split() if not f.startswith("c-implementation/")]


def check(files=None):
    errors = []
    makefile = (ROOT / "Makefile").read_text()
    listed = set(re.findall(r"source/varis/[\w/]+\.d", makefile))
    for f in sorted(Path(ROOT / "source").rglob("*.d")):
        rel = str(f.relative_to(ROOT))
        if rel not in listed and rel not in STANDALONE:
            errors.append(f"{rel}: not listed in Makefile SRC_FILES")
    for rel in sorted(listed):
        if not (ROOT / rel).exists():
            errors.append(f"{rel}: listed in Makefile but missing")
    for rel in files if files is not None else tracked_d_files():
        head = (ROOT / rel).read_text(errors="replace")[:600]
        if "PUC-Rio" not in head:
            errors.append(f"{rel}: missing license header")
    errors.extend(check_layers())
    errors.extend(check_game_leaf())
    return errors


# Layers, lowest first (AGENTS.md section 4.1). A module may import its own layer and lower ones.
LAYERS = [
    ("narrative", ("source/varis/narrative/", "source/varis/lib/narrative.d", "source/varis/lib/quality.d")),
    ("world model", ("source/varis/logic/", "source/varis/lib/logic.d")),
    ("tools", ("source/varis/workbench/", "source/varis/services/", "source/varis/cli.d")),
]
RANK = {"core": 0, "world model": 1, "narrative": 2, "tools": 3}
IMPORT_LAYER = [("varis.workbench", "tools"), ("varis.services", "tools"), ("varis.narrative", "narrative"), ("varis.lib.narrative", "narrative"),
                ("varis.lib.quality", "narrative"), ("varis.logic", "world model"), ("varis.lib.logic", "world model")]
# The two aggregators that open every library for a state are allowed to name the upper layers.
LAYER_EXEMPT = {"source/varis/package.d", "source/varis/lib/package.d"}


def layer_of(rel):
    for name, prefixes in LAYERS:
        if rel.startswith(prefixes):
            return name
    return "core"


def check_layers():
    """A lower layer must not import a higher one (the seam of PERFORMANCE_PLAN.md stage S1)."""
    errors = []
    for f in sorted(Path(ROOT / "source").rglob("*.d")):
        rel = str(f.relative_to(ROOT))
        if rel in LAYER_EXEMPT:
            continue
        own = layer_of(rel)
        for number, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            match = re.search(r"\bimport\s+(varis\.[\w.]+)", line)
            if not match:
                continue
            for prefix, layer in IMPORT_LAYER:
                if match.group(1).startswith(prefix):
                    if RANK[layer] > RANK[own]:
                        errors.append(f"{rel}:{number}: {own} module imports the {layer} layer ({match.group(1)})")
                    break
    return errors


def check_game_leaf():
    """The battle simulation (source/varis/game/) is a leaf: it imports nothing from Varis (plan B9)."""
    errors = []
    for f in sorted(Path(ROOT / "source/varis/game").rglob("*.d")):
        rel = str(f.relative_to(ROOT))
        for number, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            match = re.search(r"\bimport\s+(varis\.[\w.]+)", line)
            if match and not match.group(1).startswith("varis.game."):
                errors.append(f"{rel}:{number}: game module imports {match.group(1)} (game/ is a leaf)")
    return errors


def main(argv):
    errors = check(argv[1:] or None)
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
