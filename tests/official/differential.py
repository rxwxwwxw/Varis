"""Compare deterministic core fixtures with the bundled Lua reference."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
fixture = root / "tests/official/core.varis" if (root / "tests/official/core.varis").exists() else root / "tests/official/core.lua"
outputs = []
for binary in (root / "c-implementation/src/lua", root / "bin/varis"):
    result = subprocess.run([str(binary), str(fixture)], capture_output=True, timeout=30)
    if result.returncode:
        sys.stderr.buffer.write(result.stdout + result.stderr)
        raise SystemExit(f"{binary.name} failed with exit code {result.returncode}")
    outputs.append(result.stdout)
if outputs[0] != outputs[1]:
    for name, output in zip(("C Lua", "varis"), outputs):
        print(f"{name}:\n{output.decode(errors='replace')}")
    raise SystemExit("Core Lua differential fixture differs")
print("Core Lua differential fixture passed")
