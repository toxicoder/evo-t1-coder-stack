#!/usr/bin/env python3
"""Fail unless every shipped Python module reached the coverage floor.

Usage:
  py_report.py --json FILE --root DIR --expect DIR [--expect DIR ...] [--min N]

This replaces `coverage report --include=a/*.py,b/*.py`. coverage resolves a
relative include pattern against the current directory, and under
`bazelisk test` the two halves disagree: the interpreter reports the *checkout*
path of an imported file (Python resolves the runfiles symlink) while the
working directory is the runfiles tree. The pattern then matches nothing,
coverage prints "No data to report", and an empty report looks exactly like a
passing one.

Matching each expected module by path suffix against the machine-readable
report fixes both problems. It is independent of the working directory, and a
module the suites never imported is reported as missing instead of vanishing
from the report: the floor only applies to files that are proven to exist in
the tree.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Test files are Python too, and their own lines are nobody's product surface.
TEST_FILE_PREFIXES = ("test_", "conftest.py")


def expected_modules(root: Path, expect_dirs: list[str]) -> list[str]:
    """List every shipped module under the expected directories, repo-relative.

    Symlinks are followed so the runfiles tree yields the same list as the
    checkout it points into. Files that read as tests are left out.
    """
    found: list[str] = []
    for rel_dir in expect_dirs:
        directory = root / rel_dir
        if not directory.is_dir():
            print(f"error: expected directory is missing: {rel_dir}", file=sys.stderr)
            raise SystemExit(2)
        for path in sorted(directory.rglob("*.py")):
            if not path.is_file():
                continue
            if path.name.startswith(TEST_FILE_PREFIXES) or path.name == "__init__.py":
                continue
            found.append(path.relative_to(root).as_posix())
    return found


def match_recorded(files: dict, wanted: str) -> dict | None:
    """Return the report entry for repo-relative path *wanted*, or None.

    The report keys are absolute and may sit under either the checkout or the
    runfiles tree, so the match is a path-segment suffix test.
    """
    suffix = "/" + wanted
    for key, entry in files.items():
        if key.endswith(suffix) or key == wanted:
            return entry
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", required=True, help="coverage json output")
    parser.add_argument("--root", required=True, help="repository root")
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        help="directory of shipped modules, repo-relative (repeatable)",
    )
    parser.add_argument("--min", type=int, default=100, help="floor, percent")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    report = json.loads(Path(args.json).read_text(encoding="utf-8"))
    files = report.get("files", {})

    wanted = expected_modules(root, args.expect)
    if not wanted:
        print("error: no Python modules found under --expect", file=sys.stderr)
        return 1

    failures: list[str] = []
    print(f"{'module':<44} {'stmts':>6} {'branch':>7} {'cover':>7}")
    for rel in wanted:
        entry = match_recorded(files, rel)
        if entry is None:
            print(f"{rel:<44} {'-':>6} {'-':>7} {'never':>7}")
            failures.append(f"{rel}: never executed by any suite")
            continue
        summary = entry.get("summary", {})
        statements = int(summary.get("num_statements", 0))
        branches = int(summary.get("num_branches", 0)) + int(
            summary.get("num_partial_branches", 0)
        )
        percent = float(summary.get("percent_covered", 0.0))
        shown = "100%" if percent >= 99.999 else f"{percent:.2f}%"
        print(f"{rel:<44} {statements:>6} {branches:>7} {shown:>7}")
        if percent + 1e-9 < args.min:
            missing = sorted(set(entry.get("missing_lines", [])) | set(
                pair[0] for pair in entry.get("missing_branches", [])
            ))
            detail = ",".join(str(line) for line in missing) if missing else "no lines"
            failures.append(f"{rel}: {percent:.2f}% < {args.min}% (lines {detail})")

    print(f"modules: {len(wanted) - len(failures)}/{len(wanted)} at or above {args.min}%")
    if failures:
        print(f"uncovered modules ({len(failures)}):", file=sys.stderr)
        for item in failures:
            print(f"  {item}", file=sys.stderr)
        print("summary: 0 ok, 0 warnings, %d failed" % len(failures), file=sys.stderr)
        return 1
    print(f"ok: every shipped module meets the {args.min}% floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
