#!/usr/bin/env python3
"""Build an instrumented mirror of the production shell tree.

Used by tests/coverage/shell_cov.sh. The mirror is a directory whose top-level
entries are symlinks back into the real tree, so anything a suite reads by path
sees the real file, except the production shell scripts: each of those is
copied with one extra statement at the top of every function body that appends
"<relative-path>\\t<function-name>" to $EVO_COV_LEDGER.

Why a mirror and a ledger, and not bash xtrace: an xtrace run traced every bash
in the process tree, including bats-core itself, wrote gigabytes of log, and
leaked trace lines into the stderr that bats captures per test, which turned
output-asserting suites red. The ledger answers the narrower question the gate
asks, which is whether a function's body ran, and it answers it without changing
what any test observes.

Three access patterns matter, and all three go through the mirror because each
resolves under ${REPO_ROOT}: running a CLI as a subprocess, sourcing a lib and
calling a function, and tests/test_helpers.sh::load_shell_function pulling one
function out with tests/extract_fn.py.

Usage:
  python3 tests/coverage/instrument.py --root DIR --out DIR
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

# Production shell the stack ships. tests/ is the harness and stays untouched.
PRODUCTION_DIRS = (
    "scripts",
    "lints",
    "templates/common",
    "docs",
    "docs-site",
)
PRODUCTION_FILES = ("fix.sh",)

# Never mirrored, symlinked, or traced.
SKIP_TOP = {".git", "bazel-bin", "bazel-out", "bazel-testlogs", "coverage"}
SKIP_DIRS = {"node_modules", "out", ".next", "__pycache__", ".turbo"}

MARKER = "printf '%s\\t%s\\n' '{rel}' '{name}' >>\"${{EVO_COV_LEDGER:-/dev/null}}\";"


def production_shell_files(root: str) -> set[str]:
    """Repo-relative paths of every production .sh file."""
    found: set[str] = set()
    for top in PRODUCTION_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(".sh"):
                    found.add(os.path.relpath(os.path.join(dirpath, name), root))
    for rel in PRODUCTION_FILES:
        if os.path.isfile(os.path.join(root, rel)):
            found.add(rel)
    return found


def is_function_header(line: str) -> tuple[str, bool] | None:
    """Return (name, single_line) when the line opens a column-0 function."""
    stripped = line.rstrip()
    if not stripped or stripped[0] in " \t#":
        return None
    if "(" not in stripped or ")" not in stripped:
        return None
    name = stripped.split("(", 1)[0]
    if not name or not (name[0].isalpha() or name[0] == "_"):
        return None
    if not name.replace("_", "").isalnum():
        return None
    rest = stripped.split(")", 1)[1].strip()
    if not rest.startswith("{"):
        return None
    single = rest.count("{") - rest.count("}") <= 0 and "{" in rest
    return name, single


def instrument(text: str, rel: str) -> str:
    """Return the file with a ledger statement at the top of each function body."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    for line in lines:
        out.append(line)
        parsed = is_function_header(line)
        if parsed is None:
            continue
        name, single_line = parsed
        marker = MARKER.format(rel=rel.replace("'", "'\\''"), name=name)
        newline = "\n" if line.endswith("\n") else ""
        bare = line[:-1] if newline else line
        if single_line and "{" in bare:
            head, _, tail = bare.partition("{")
            out[-1] = f"{head}{{ {marker} {tail.lstrip()}{newline}"
        else:
            out.append(f"  {marker}{newline}")
    return "".join(out)


def materialize_dir(root: str, out: str, rel_dir: str, prods: set[str]) -> None:
    """Fill mirror/rel_dir with symlinks, instrumenting the production .sh files."""
    src_dir = os.path.join(root, rel_dir)
    dst_dir = os.path.join(out, rel_dir)
    os.makedirs(dst_dir, exist_ok=True)
    for name in sorted(os.listdir(src_dir)):
        src = os.path.join(src_dir, name)
        dst = os.path.join(dst_dir, name)
        rel = os.path.join(rel_dir, name)
        if os.path.isdir(src):
            if name in SKIP_DIRS:
                continue
            # A subdirectory that holds production shell has to be materialized
            # so its instrumented files land beside symlinks for its siblings.
            prefix = rel + os.sep
            if any(f == rel or f.startswith(prefix) for f in prods):
                materialize_dir(root, out, rel, prods)
            elif not os.path.lexists(dst):
                os.symlink(os.path.abspath(src), dst)
            continue
        if rel in prods and name.endswith(".sh"):
            with open(src, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            with open(dst, "w", encoding="utf-8") as handle:
                handle.write(instrument(text, rel))
            shutil.copymode(src, dst)
        elif not os.path.lexists(dst):
            os.symlink(os.path.abspath(src), dst)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="the tree to mirror")
    parser.add_argument("--out", required=True, help="mirror directory to build")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    out = os.path.abspath(args.out)
    prods = production_shell_files(root)
    if not prods:
        print("error: no production shell files found", file=sys.stderr)
        return 1

    os.makedirs(out, exist_ok=True)
    # Every directory on the path to a production file has to be materialized,
    # not just its leaf: templates/common holds shell, and a mirror that only
    # creates templates/common loses templates/workspace and templates/devcontainer
    # as siblings, which several suites read by path.
    dirs_to_materialize: set[str] = set()
    for rel in prods:
        parent = os.path.dirname(rel)
        while parent:
            dirs_to_materialize.add(parent)
            grandparent = os.path.dirname(parent)
            if grandparent == parent:
                break
            parent = grandparent
    for rel_dir in sorted(d for d in dirs_to_materialize if d):
        materialize_dir(root, out, rel_dir, prods)

    # Everything else at the top level is a plain symlink back into the tree.
    materialized_top = {d.split(os.sep)[0] for d in dirs_to_materialize if d}
    for name in sorted(os.listdir(root)):
        if name in SKIP_TOP or name in materialized_top or name in PRODUCTION_DIRS:
            continue
        dst = os.path.join(out, name)
        if not os.path.lexists(dst):
            os.symlink(os.path.join(root, name), dst)

    print(f"instrumented {len(prods)} shell files into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
