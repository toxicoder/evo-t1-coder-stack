#!/usr/bin/env python3
"""Turn the coverage ledger into the verdict //tests:shell_coverage reports.

tests/coverage/shell_cov.sh builds an instrumented mirror, runs the Bats suites
against it, and collects one "<relative-path>\\t<function-name>" line per function
invocation. This reads that ledger and answers the question the gate cares about:
did every production shell function's body actually run at least once.

Statement-level line coverage is not measured here. bash gives no cheap, honest
line signal without xtrace (see the note in shell_cov.sh), so the shell gate is
function coverage, and the line and branch floors live where a real instrument
can supply them: coverage.py for Python and v8 for the docs site.

Usage:
  python3 tests/coverage/aggregate.py --root DIR --ledger FILE
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# Production shell the stack ships and runs. tests/ is the harness, not a target.
PRODUCTION_DIRS = (
    "scripts",
    "lints",
    "templates/common",
    "docs",
    "docs-site",
)
PRODUCTION_FILES_EXTRA = ("fix.sh",)
SKIP_DIRS = {"node_modules", "out", ".next", "__pycache__"}

FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{?[ \t]*$")
FUNC_RE_INLINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{")


def discover_shell(root: str) -> list[str]:
    """Return repo-relative paths of the production shell files to measure."""
    found: list[str] = []
    for top in PRODUCTION_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(filenames):
                if name.endswith(".sh"):
                    found.append(os.path.relpath(os.path.join(dirpath, name), root))
    for rel in PRODUCTION_FILES_EXTRA:
        if os.path.isfile(os.path.join(root, rel)):
            found.append(rel)
    return sorted(set(found))


def parse_functions(path: str) -> list[tuple[str, int]]:
    """Return (name, declaration line) for each column-0 bash function."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    funcs: list[tuple[str, int]] = []
    index = 0
    while index < len(lines):
        match = FUNC_RE.match(lines[index]) or FUNC_RE_INLINE.match(lines[index])
        if match:
            funcs.append((match.group(1), index + 1))
            # Skip to the closing brace so a nested definition is not counted twice.
            depth, started, cursor = 0, False, index
            while cursor < len(lines):
                depth += lines[cursor].count("{") - lines[cursor].count("}")
                if "{" in lines[cursor]:
                    started = True
                if started and depth <= 0:
                    break
                cursor += 1
            index = cursor + 1
            continue
        index += 1
    return funcs


def read_ledger(ledger_path: str) -> set[tuple[str, str]]:
    """Return the (file, function) pairs the instrument recorded."""
    hits: set[tuple[str, str]] = set()
    if not os.path.isfile(ledger_path):
        return hits
    with open(ledger_path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            rel, _, name = raw.rstrip("\n").partition("\t")
            if rel and name:
                hits.add((rel, name))
    return hits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="repository root")
    parser.add_argument("--ledger", required=True, help="ledger written by the mirror")
    parser.add_argument(
        "--min-functions",
        type=int,
        default=int(os.environ.get("EVO_COV_MIN_FUNCTIONS", "100")),
        help="required percentage of production functions reached",
    )
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    files = discover_shell(root)
    if not files:
        print("error: no production shell files discovered", file=sys.stderr)
        return 1
    hits = read_ledger(args.ledger)

    total = covered = 0
    uncovered: list[str] = []
    dead_files: list[str] = []

    for rel in files:
        funcs = parse_functions(os.path.join(root, rel))
        if not funcs:
            continue
        missed = [f"{name}:{line}" for name, line in funcs if (rel, name) not in hits]
        total += len(funcs)
        covered += len(funcs) - len(missed)
        if len(missed) == len(funcs):
            dead_files.append(rel)
        uncovered.extend(f"{rel}:{entry}" for entry in missed)

    pct = 100.0 if total == 0 else round(100.0 * covered / total, 2)
    print("== shell coverage ==")
    print(f"files measured: {len(files)}")
    print(f"functions: {covered}/{total} reached ({pct}%)")
    if dead_files:
        print("files whose functions never ran at all:")
        for rel in dead_files:
            print(f"  {rel}")
    if uncovered:
        print(f"unreached functions ({len(uncovered)}):")
        for item in uncovered:
            print(f"  {item}")

    if pct < args.min_functions:
        print(
            f"summary: {covered} reached, {total - covered} unreached of {total}, "
            f"floor {args.min_functions}%",
            file=sys.stderr,
        )
        return 1
    print(f"summary: every production function reached (floor {args.min_functions}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
