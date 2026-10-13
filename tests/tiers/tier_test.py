#!/usr/bin/env python3
"""Milestone 26: the `.varis` source extension and runtime enforcement of the content tier.

    python3 tests/tiers/tier_test.py <varis binary>

Builds a scratch project whose content files are written in `.varis`, runs it through the
manifest's entry module, and checks what a content file may and may not reach.
"""
import pathlib
import subprocess
import sys
import tempfile

MANIFEST = """return {
    id = "tiers",
    language = "en",
    entry = "game",
    content = { "content/*.lua" },
    scripts = { "game.lua", "main.lua" },
    session = "game.new_session",
}
"""

GAME = """
local G = {}
narrative.helper("shout", function(text) return text:upper() end)
Secret = "engine only"
require("content.rooms")
narrative.seal("tiers-1")
function G.new_session(seed)
    local s = narrative.new(logic.global)
    s:seed(seed)
    return s
end
return G
"""

ROOMS = """relation open(1)
fact open(:cellar)
deck :default {draw = 1, replacement = true}
storylet visit()
    when { open(:cellar) }
    title "Visit"
    text "The cellar is quiet."
    choice go effect do fact open(:attic) end end
end
"""


def run(binary, cwd, *args):
    return subprocess.run([binary, *args], cwd=cwd, capture_output=True, text=True, timeout=60)


def project(root, rooms, extension="varis"):
    (root / "project.lua").write_text(MANIFEST)
    (root / "game.lua").write_text(GAME)
    (root / "content").mkdir(exist_ok=True)
    for old in (root / "content").glob("rooms.*"):
        old.unlink()
    (root / "content" / f"rooms.{extension}").write_text(rooms)


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="varis-tiers-") as scratch:
        root = pathlib.Path(scratch)

        # A content file in the Varis extension loads, and `varis check` reads it.
        project(root, ROOMS)
        done = run(binary, root, "check")
        assert done.returncode == 0, done.stdout + done.stderr
        done = run(binary, root, "-e", 'package.path = "./?.lua;" .. package.path; require("content.rooms"); print("loaded")')
        assert "loaded" in done.stdout, done.stdout + done.stderr

        # The same file under the `.lua` extension (still supported) loads too.
        project(root, ROOMS, "lua")
        assert run(binary, root, "check").returncode == 0

        # An unknown global in content is an error that names the helper mechanism.
        project(root, ROOMS + "\nlocal s = Secret\n")
        done = run(binary, root, "check")
        assert done.returncode != 0 and "narrative.helper" in done.stdout + done.stderr, done.stdout + done.stderr

        # Reaching io or os is refused before the file runs; an alias cannot get around it.
        for body in ["io.write('x')", "local o = os; o.exit(0)", "local f = load; f('x')",
                     "setmetatable({}, {})", "coroutine.wrap(function() end)"]:
            project(root, ROOMS + "\n" + body + "\n")
            done = run(binary, root, "check")
            text = done.stdout + done.stderr
            assert done.returncode != 0 and "content" in text, (body, text)

        # A function value in content is refused (the static rule, and at load time).
        project(root, ROOMS + "\nlocal f = function() end\n")
        done = run(binary, root, "check")
        assert done.returncode != 0 and "function" in done.stdout + done.stderr, done.stdout + done.stderr

        # Declared symbols: an undeclared one in content is refused when the file loads.
        declared = ROOMS.replace("fact open(:cellar)", "symbols cellar, attic\nfact open(:cellar)")
        project(root, declared)
        done = run(binary, root, "check")
        assert done.returncode == 0, done.stdout + done.stderr
        project(root, declared + "\nfact open(:garret)\n")
        done = run(binary, root, "check")
        text = done.stdout + done.stderr
        assert done.returncode != 0 and "garret" in text, text

        # A helper an engine script exposed is callable from content; a global it did not is not.
        project(root, ROOMS + '\nnarrative.meta(:visit, {note = shout("ok")})\n')
        done = run(binary, root, "check")
        assert done.returncode == 0, done.stdout + done.stderr
    print("tier tests passed")


if __name__ == "__main__":
    main()
