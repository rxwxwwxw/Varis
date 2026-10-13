#!/usr/bin/env python3
"""`varis play` and `varis test`, and the CI recipe (stage A6).

    python3 tests/play/play_test.py <varis binary>
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(binary, cwd, *args, stdin=None, env=None):
    return subprocess.run([binary, *args], cwd=cwd, input=stdin, capture_output=True, text=True, timeout=120, env=env)


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    work = pathlib.Path(tempfile.mkdtemp(prefix="varis-play-"))
    try:
        game = work / "game"
        shutil.copytree(ROOT / "sample-game", game)

        # Author tests: the sample game's walkthrough passes.
        done = run(binary, game, "test")
        assert done.returncode == 0 and "3 test(s) passed, 0 failed" in done.stdout, done.stdout + done.stderr

        # A failing test is a diagnostic on the failing line, and says why the storylet is missing.
        zz = game / "tests" / "zz.varis"
        zz.write_text(
            'test.case("lamp from the start", function()\n    local t = test.play { seed = 1 }\n    t:expect_shown "lamp"\nend)\n')
        done = run(binary, game, "test", "--json")
        report = json.loads(done.stdout)
        assert done.returncode == 1 and report["passed"] == 3, done.stdout
        failure = report["problems"][0]
        assert (failure["code"], failure["file"] in ("tests/zz.varis", "tests/zz.lua"), failure["line"]) == ("test", True, 3), failure
        assert "lamp is not available" in failure["message"] and "goal 1 at(...)" in failure["message"], failure
        zz.unlink()

        # Text playtest: choose, ask why, quit; and a recorded game replays to the same transcript.
        script = "2\nwhy lamp\n1\nquit\n"
        first = run(binary, game, "play", "--seed", "7", "--record", "rec.txt", stdin=script)
        assert first.returncode == 0, first.stderr
        assert "lamp is not available" in first.stdout, first.stdout
        recorded = (game / "rec.txt").read_text().splitlines()
        assert recorded[0] == "# varis play --seed 7" and len(recorded) == 3, recorded
        again = run(binary, game, "play", "--seed", "7", "--replay", "rec.txt")
        assert again.returncode == 0, again.stderr
        # The same presentations are shown in the same order.
        titles = lambda text: [l for l in text.splitlines() if l and not l.startswith(("  [", ">", "  lamp", "    goal", "  (", "Nothing"))]
        assert titles(again.stdout)[:12] == [t for t in titles(first.stdout) if not t.startswith("  lamp")][:12]

        # The CI recipe passes a good project and rejects a seeded bad submission, by storylet.
        env = dict(__import__("os").environ, VARIS=binary)
        done = subprocess.run(["sh", str(ROOT / "tools" / "project_ci.sh")], cwd=game, capture_output=True, text=True, env=env)
        assert done.returncode == 0, done.stdout + done.stderr
        lamp_path = game / "content" / ("lamp.varis" if (game / "content" / "lamp.varis").exists() else "lamp.lua")
        lamp = lamp_path.read_text()
        lamp_path.write_text(lamp.replace("    priority 60\n", "    priority 60\n    deck :marktet\n", 1))
        done = subprocess.run(["sh", str(ROOT / "tools" / "project_ci.sh")], cwd=game, capture_output=True, text=True, env=env)
        assert done.returncode == 1, done.stdout
        assert "storylet lamp is in deck :marktet" in done.stdout and ("content/lamp.varis:" in done.stdout or "content/lamp.lua:" in done.stdout), done.stdout
        print("play and test passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
