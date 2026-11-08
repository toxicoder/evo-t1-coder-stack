#!/usr/bin/env python3
"""Program purpose: fail when a tracked file is not reachable from any Bazel target.

The definition-of-done gate for a Bazelisk-first repo. Every path `git ls-files`
reports lands in exactly one of five buckets, and the buckets have to sum to the
tracked count:

  target-owned     a source or data file of some target under //...
  control-plane    Bazel's own configuration (.bazelrc, MODULE.bazel, every BUILD
                   file) plus anything under a .bazelignore directory -- no rule
                   can be the owner of the files that configure the rule
  ledger-excluded  named in unowned-files.txt with a reason
  unowned          a finding

The label-to-path mapping is the part most often written wrong. A label is
`//pkg:file`, or `//:file` for the root package; mapping it by replacing every
`:` with `/` leaves a leading slash on every root-package file, which reports
almost the whole tree unowned. `label_to_path` handles both spellings.

Bazel's dependency graph is the only record of what a target reads, so the
owned set comes from `bazelisk query` and this program needs a working Bazelisk
on PATH. That is why the gate is `bazelisk run //tests:owned_files_audit`: a
`bazel test` action holds the server its own query would need, while `bazel run`
hands it one, the way //scripts:bazel-map already does. The bucketing itself is
pinned hermetically by tests/bats/owned_files.bats and
tests/python/test_owned_files_check.py, which drive this file against a stub.

Usage:
  python3 tests/owned_files_check.py [--root DIR] [--ledger FILE] [--json]
                                     [--strict-ledger]
Exit:
  0 clean, 1 findings, 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Sequence
from typing import Final, NamedTuple

# Bazel's own control plane. None of these can be the source of any rule, so
# asking for a ledger entry per one of them would be noise. A basename match
# covers the per-package copies (docs/BUILD.bazel and friends) in one rule.
CONTROL_PLANE: Final[frozenset[str]] = frozenset(
    {
        ".bazelignore",
        ".bazelrc",
        ".bazelversion",
        ".bazeliskrc",
        "MODULE.bazel",
        "MODULE.bazel.lock",
        "REPO.bazel",
        "WORKSPACE",
        "WORKSPACE.bazel",
        "WORKSPACE.bazelignore",
    },
)

# IDE and editor project files that configure the Bazel integration itself.
CONTROL_PLANE_SUFFIXES: Final[tuple[str, ...]] = (".bazelproject",)

# A ledger line as read: the compiled matcher, the pattern as written (so a
# stale entry can be named back to the operator), and the reason it earns its
# place in the file.
class Entry(NamedTuple):
    regex: re.Pattern[str]
    pattern: str
    reason: str


# One tracked file that landed in the `unowned` bucket, with the sentence that
# says which rule put it there.
class Finding(NamedTuple):
    path: str
    why: str

# Every bucket of one assessment, in file counts. `assess` fills it and both
# printers read it, so the two output shapes can never disagree about the math.
class Report(NamedTuple):
    tracked: int
    target_owned: int
    control_plane: int
    excluded: int
    stale: tuple[str, ...]
    unowned: tuple[Finding, ...]


def run(cmd: Sequence[str], cwd: str) -> subprocess.CompletedProcess[str]:
    """Run `cmd` in `cwd` and hand back the completed process.

    The caller decides what a non-zero status means, so this must not fold it into
    empty output: an empty successful `bazelisk query` is a graph that declared
    nothing, while a failed one is a broken environment. Reading the second as the
    first reports every file unowned and buries a real graph in UNOWNED lines.
    """
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except OSError as exc:  # Bazelisk or git missing from PATH entirely.
        sys.stderr.write("error: cannot run %s: %s\n" % (" ".join(cmd), exc))
        raise SystemExit(2) from exc


def label_to_path(label: str) -> str | None:
    """Map `//pkg:file` to `pkg/file` and `//:file` to `file`; else None.

    The root package has no package directory, which is why the empty package
    half must not be joined with a slash: doing so is the classic bug that makes
    every root file look unowned.
    """
    if label.startswith("@@"):
        label = label[1:]
    if label.startswith("@"):
        label = label[1:]
    if not label.startswith("//"):
        return None
    pkg, sep, name = label[2:].partition(":")
    if not sep or not name:
        return None
    return f"{pkg}/{name}" if pkg else name


def is_control_plane(path: str) -> bool:
    """True when no rule could own `path` because it configures the rules."""
    base = os.path.basename(path)
    if base in CONTROL_PLANE or base in ("BUILD", "BUILD.bazel"):
        return True
    return path.endswith(CONTROL_PLANE_SUFFIXES)


def query_owned(root: str) -> set[str] | None:
    """Every tracked-path the graph reaches, via `bazelisk query`.

    Returns None when the query itself failed, which the caller reports as an
    environment error rather than as "nothing is owned".
    """
    proc = run(
        [
            "bazelisk",
            "query",
            "kind('source file', deps(//...))",
            "--output=label",
            "--noshow_progress",
        ],
        root,
    )
    if proc.returncode != 0:
        # Bazel left an ERROR line and an empty stdout. Treat it as "the graph is
        # not enumerable" rather than as "the graph owns nothing".
        sys.stderr.write(proc.stderr[-4000:])
        return None
    paths: set[str] = set()
    for line in proc.stdout.splitlines():
        mapped = label_to_path(line.strip())
        if mapped is not None:
            paths.add(mapped)
    return paths


def bazel_ignored_dirs(root: str) -> set[str]:
    """Directories .bazelignore removes from the workspace.

    No target can own their contents, so they count as control plane. The
    shipped example is proxy/certs/, which bootstrap issues on the host.
    """
    path = os.path.join(root, ".bazelignore")
    dirs: set[str] = set()
    if not os.path.isfile(path):
        return dirs
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            entry = line.split("#", 1)[0].strip().strip("/")
            if entry:
                dirs.add(entry)
    return dirs


def read_ledger(path: str) -> list[Entry]:
    """Parse `pattern<sep>reason` lines; `#` comments and blanks are ignored.

    The separator is a tab or two-or-more spaces, and `*`/`?` work as globs, so
    the file stays readable as a table. An entry whose reason is empty is a
    finding, not an exemption: the reason is what keeps the ledger from becoming
    the place files go to hide.
    """
    entries: list[Entry] = []
    if not os.path.isfile(path):
        return entries
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = re.split(r"\t+|\s{2,}", line.strip(), maxsplit=1)
            pattern = parts[0]
            reason = parts[1].strip() if len(parts) > 1 else ""
            regex = re.compile(
                "^" + re.escape(pattern).replace(r"\*", ".*").replace(r"\?", ".") + "$",
            )
            entries.append(Entry(regex=regex, pattern=pattern, reason=reason))
    return entries


def ledger_is_tracked(root: str, ledger_path: str) -> bool:
    """True when git has the ledger. An ignored ledger excuses nothing.

    This guard exists because the first ledger here was named bazel-unowned.txt and
    .gitignore's `/bazel-*` line, written for Bazel's convenience symlinks, matched it.
    The gate then read a file that was never in the repository and reported a clean
    tree: the exemptions applied to whoever ran it locally and to nobody in CI.
    """
    try:
        rel = os.path.relpath(ledger_path, root)
    except ValueError:
        return False
    if rel.startswith(".."):
        return False
    return run(["git", "ls-files", "--error-unmatch", "--", rel], root).returncode == 0


def assess(
    tracked: Sequence[str],
    owned: set[str],
    ignored: set[str],
    ledger: Sequence[Entry],
    *,
    strict_ledger: bool,
) -> Report:
    """Sort `tracked` into the buckets and count them.

    Every tracked file lands in exactly one bucket, so the counts must sum to
    `tracked`. Counting ledger-covered files as target-owned is the off-by-N
    that makes a check look green while exempting half the tree.
    """
    unowned: list[Finding] = []
    excluded = 0
    control = 0
    hits: set[str] = set()

    for path in tracked:
        if path in owned:
            continue
        if is_control_plane(path):
            control += 1
            continue
        if any(path == entry or path.startswith(entry + "/") for entry in ignored):
            control += 1
            continue
        for entry in ledger:
            if entry.regex.match(path):
                hits.add(entry.pattern)
                if entry.reason:
                    excluded += 1
                else:
                    unowned.append(Finding(path, "ledger entry carries no reason"))
                break
        else:
            unowned.append(Finding(path, "no target owns it and no ledger entry covers it"))

    stale = tuple(entry.pattern for entry in ledger if entry.pattern not in hits)
    if strict_ledger:
        unowned.extend(
            Finding(pattern, "ledger entry matches nothing (stale)") for pattern in stale
        )

    return Report(
        tracked=len(tracked),
        target_owned=len(tracked) - control - excluded - len(unowned),
        control_plane=control,
        excluded=excluded,
        stale=stale,
        unowned=tuple(unowned),
    )


def tracked_files(root: str) -> list[str]:
    """`git ls-files` for `root`, or exit 2 when the answer comes back empty."""
    proc = run(["git", "ls-files", "-z"], root)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        sys.stderr.write("error: git ls-files failed in %s\n" % root)
        raise SystemExit(2)
    files = [entry for entry in proc.stdout.split("\0") if entry]
    if not files:
        sys.stderr.write("error: git ls-files returned nothing; is this a git repo?\n")
        raise SystemExit(2)
    return files


def report_json(report: Report, owned_labels: int) -> None:
    """Print the assessment as one JSON object for a machine reader."""
    print(
        json.dumps(
            {
                "tracked": report.tracked,
                "target_owned": report.target_owned,
                "owned_labels": owned_labels,
                "control_plane": report.control_plane,
                "excluded": report.excluded,
                "stale_ledger": list(report.stale),
                "unowned": [{"path": item.path, "why": item.why} for item in report.unowned],
            },
            indent=2,
        ),
    )


def report_text(report: Report) -> None:
    """Print one `UNOWNED` line per finding and the closing tally."""
    for item in report.unowned:
        print("UNOWNED %s  (%s)" % (item.path, item.why))
    print(
        "summary: %d tracked | %d target-owned | %d control-plane | %d "
        "ledger-excluded (reasoned) | %d unowned | %d stale ledger entries"
        % (
            report.tracked,
            report.target_owned,
            report.control_plane,
            report.excluded,
            len(report.unowned),
            len(report.stale),
        ),
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Load the three inputs, assess, print, and return the exit status."""
    parser = argparse.ArgumentParser(
        description="Fail when a tracked file is not reachable from any Bazel target.",
    )
    parser.add_argument("--root", default=".", help="repo root to check")
    parser.add_argument(
        "--ledger",
        default="unowned-files.txt",
        help="exclusion ledger, relative to --root unless absolute",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    parser.add_argument(
        "--strict-ledger",
        action="store_true",
        help="also fail on a ledger entry that matches nothing",
    )
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    ledger_path = args.ledger if os.path.isabs(args.ledger) else os.path.join(root, args.ledger)

    # Read the ledger only after proving git can see it: a missing reason is a finding,
    # and a missing-from-git ledger is the same failure wearing a green suit.
    if os.path.isfile(ledger_path) and not ledger_is_tracked(root, ledger_path):
        sys.stderr.write(
            "error: the ledger %s is not tracked by git; a file .gitignore hides makes "
            "this gate report a clean tree while exempting nobody\n"
            % os.path.relpath(ledger_path, root),
        )
        return 1

    owned = query_owned(root)
    if owned is None:
        sys.stderr.write("error: could not enumerate the owned set; is bazelisk on PATH?\n")
        return 2

    report = assess(
        tracked_files(root),
        owned,
        bazel_ignored_dirs(root),
        read_ledger(ledger_path),
        strict_ledger=args.strict_ledger,
    )

    if args.json:
        report_json(report, len(owned))
    else:
        report_text(report)
    return 1 if report.unowned else 0


if __name__ == "__main__":
    sys.exit(main())
