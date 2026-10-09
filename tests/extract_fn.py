#!/usr/bin/env python3
"""Print one column-0 bash function so a Bats test can eval the real body."""

import sys

path, name = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
start = None
for i, line in enumerate(lines):
    if line.startswith(name + "()") or line.startswith(name + " ()"):
        start = i
        break
if start is None:
    sys.stderr.write(f"extract_fn: {name} not in {path}\n")
    sys.exit(1)

depth = 0
started = False
out = []
for line in lines[start:]:
    out.append(line)
    depth += line.count("{") - line.count("}")
    if "{" in line:
        started = True
    if started and depth <= 0:
        sys.stdout.write("\n".join(out) + "\n")
        sys.exit(0)

sys.stderr.write(f"extract_fn: unbalanced {name} in {path}\n")
sys.exit(1)
