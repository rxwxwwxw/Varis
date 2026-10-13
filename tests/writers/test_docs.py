#!/usr/bin/env python3
"""Runs the code in the writer documentation (docs/writers/*.md).

A fenced block whose info string carries `file=PATH` is written into a scratch project.
At the end of each `##` section the project is checked (`varis check`, which must succeed) and,
when it has `tests/*.lua` files, tested (`varis test`). More markers on the info string:

  run                    after writing, run the file with `varis FILE`; it must exit 0
  check-error=TEXT       the file is checked alone and must fail with TEXT in the output
  play seed=N input=A,B  (on a ```text block) the block is the expected, normalized output of
                         `varis play --seed N` fed the inputs, one per line, then `quit`

`<!-- docs-test: fresh -->` anywhere in a document starts every `##` section with an empty
project; without it files accumulate through the document, a later block replacing an earlier
one with the same path. A document with no file= blocks is skipped.

Usage: test_docs.py VARIS_BINARY [DOC.md ...]
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_PROJECT = """return {
    id = "docs", language = "en", entry = "game",
    content = { "story.lua", "content/*.lua" },
    scripts = { "game.lua", "probe*.lua" },
    session = "game.new_session",
    tests = { "tests/*.lua" },
}
"""

DEFAULT_GAME = """for _, name in ipairs(__content_files or {}) do require(name) end
local M = {}
function M.new_session(seed)
    local session = narrative.new(logic.world())
    session:seed(seed or 1)
    return session
end
return M
"""

FENCE = re.compile(r"^```(\S*)\s*(.*)$")


def parse(path):
    sections = []  # (title, [blocks])
    current = ("(top)", [])
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("## "):
            sections.append(current)
            current = (line[3:].strip(), [])
        m = FENCE.match(line)
        if m and (m.group(1) or m.group(2)):
            lang, info = m.group(1), m.group(2)
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            current[1].append((lang, info, "\n".join(body) + "\n", i))
        i += 1
    sections.append(current)
    return sections


def options(info):
    result = {}
    for token in re.findall(r'(?:[^\s"]+|"[^"]*")+', info):
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value.strip('"')
        else:
            result[token] = True
    return result


def varis(binary, cwd, *args, stdin=None):
    return subprocess.run([binary, *args], cwd=cwd, input=stdin, capture_output=True, text=True, timeout=120)


def normalize(output):
    kept = []
    for line in output.replace("\r", "").split("\n"):
        line = line.strip()
        if line.startswith("> (number") or line.startswith(">"):
            line = re.sub(r"^> \(number[^)]*\)\s*", "", line)
        if line:
            kept.append(line)
    return "\n".join(kept)


def run_document(binary, path, failures):
    text = open(path, encoding="utf-8").read()
    fresh = "<!-- docs-test: fresh -->" in text
    sections = parse(path)
    files = {}
    checked = 0
    for title, blocks in sections:
        if fresh:
            files = {}
        pending_runs, plays = [], []
        wrote = False
        for lang, info, body, line in blocks:
            opts = options(info)
            if "file" in opts and "check-error" in opts:
                with tempfile.TemporaryDirectory() as scratch:
                    target = os.path.join(scratch, os.path.basename(opts["file"]))
                    open(target, "w", encoding="utf-8").write(body)
                    result = varis(binary, scratch, "check", "--no-load", os.path.basename(target))
                    if result.returncode == 0 or opts["check-error"] not in result.stdout + result.stderr:
                        failures.append(f"{path}:{line}: expected check error {opts['check-error']!r}, got "
                                        f"status {result.returncode}: {result.stdout}{result.stderr}")
                checked += 1
                continue
            if "file" in opts:
                files[opts["file"]] = body
                wrote = True
                if "run" in opts:
                    pending_runs.append((opts["file"], line))
            elif lang == "text" and "play" in opts:
                plays.append((opts, body, line))
        if not wrote:
            continue
        with tempfile.TemporaryDirectory() as scratch:
            names = dict(files)
            if "project.lua" not in names:
                names["project.lua"] = DEFAULT_PROJECT
            if "game.lua" not in names:
                names["game.lua"] = DEFAULT_GAME.replace(
                    "__content_files or {}",
                    "{" + ", ".join(
                        '"%s"' % n[:-4].replace("/", ".")
                        for n in sorted(names)
                        if n == "story.lua" or n.startswith("content/")) + "}")
            for name, body in names.items():
                target = os.path.join(scratch, name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                open(target, "w", encoding="utf-8").write(body)
            where = f"{os.path.relpath(path, ROOT)} section '{title}'"
            result = varis(binary, scratch, "check")
            checked += 1
            if result.returncode != 0:
                failures.append(f"{where}: varis check failed:\n{result.stdout}{result.stderr}")
                continue
            if any(n.startswith("tests/") for n in names):
                result = varis(binary, scratch, "test")
                if result.returncode != 0:
                    failures.append(f"{where}: varis test failed:\n{result.stdout}{result.stderr}")
            for name, line in pending_runs:
                result = varis(binary, scratch, name)
                if result.returncode != 0:
                    failures.append(f"{path}:{line}: running {name} failed:\n{result.stdout}{result.stderr}")
            for opts, expected, line in plays:
                inputs = [s for s in opts.get("input", "").split(",") if s] + ["quit"]
                result = varis(binary, scratch, "play", "--seed", opts.get("seed", "1"), stdin="\n".join(inputs) + "\n")
                if normalize(result.stdout) != normalize(expected):
                    failures.append(f"{path}:{line}: play transcript differs.\n--- expected\n{normalize(expected)}\n"
                                    f"--- actual\n{normalize(result.stdout)}")
    return checked


def main(argv):
    binary = os.path.abspath(argv[1])
    docs = argv[2:] or sorted(
        os.path.join(ROOT, "docs", "writers", n) for n in os.listdir(os.path.join(ROOT, "docs", "writers"))
        if n.endswith(".md"))
    failures = []
    total = 0
    for doc in docs:
        total += run_document(binary, doc, failures)
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"{total} project(s) and file(s) checked in {len(docs)} document(s); {len(failures)} failure(s)")
    if total == 0:
        print("no runnable blocks found", file=sys.stderr)
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
