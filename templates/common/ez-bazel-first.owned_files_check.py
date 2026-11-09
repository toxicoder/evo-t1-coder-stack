#!/usr/bin/env python3
# managed-by: evo-t1-coder-stack -- stack-seeded helper. The canonical source is
# templates/common/ez-bazel-first.owned_files_check.py in evo-t1-coder-stack: change the seed there and
# re-materialize this copy; editing the copy in a home invites it being restored.
"""Fail when a tracked file is not reachable from any Bazel target.

The definition-of-done gate for a Bazel-first repo: every file `git ls-files`
reports must either be a source/data file of some target, or be named in the
exclusion ledger with a reason. The ledger is what keeps "100% coverage" honest
instead of pushing junk into a catch-all filegroup.

Label-to-path mapping is the part most often written wrong. A label is
`//pkg:file` or `//:file` for the root package; mapping it by replacing every
`:` with `/` leaves a leading slash on root-package files, which reports almost
every file unowned. `label_to_path` below handles both forms.

Usage:
    owned_files_check.py [--root DIR] [--ledger PATH] [--json] [--strict-ledger]

Exit codes: 0 clean, 1 unowned files found, 2 usage/environment error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Bazel's own control plane. These cannot be the source of any rule, so asking
# for a ledger entry per one of them would be noise.
CONTROL_PLANE = {
    ".bazelrc",
    ".bazelversion",
    ".bazelignore",
    ".bazeliskrc",
    "MODULE.bazel",
    "MODULE.bazel.lock",
    "WORKSPACE",
    "WORKSPACE.bazel",
    "WORKSPACE.bazelignore",
    "REPO.bazel",
}
CONTROL_PLANE_SUFFIX = (".bazelproject",)


def run(cmd, cwd):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        raise SystemExit(2)
    return proc.stdout


def label_to_path(label):
    """//pkg:file -> pkg/file ; //:file -> file ; @@repo//pkg:file -> pkg/file."""
    if label.startswith("@@"):
        label = label[1:]
    if label.startswith("@"):
        label = label[1:]
    if not label.startswith("//"):
        return None
    label = label[2:]
    pkg, sep, name = label.partition(":")
    if not sep:
        return None
    return f"{pkg}/{name}" if pkg else name


def is_control_plane(path):
    base = os.path.basename(path)
    if path in CONTROL_PLANE or base in CONTROL_PLANE:
        return True
    if base in ("BUILD", "BUILD.bazel"):
        return True
    if base.startswith("WORKSPACE") or base.startswith("MODULE.bazel"):
        return True
    return path.endswith(CONTROL_PLANE_SUFFIX)


def owned_paths(root):
    out = run(["bazelisk", "query", "kind('source file', deps(//...))",
               "--output=label"], root)
    paths = set()
    for line in out.splitlines():
        line = line.strip()
        if not (line.startswith("//") or line.startswith("@@//") or line.startswith("@")):
            continue
        mapped = label_to_path(line)
        if mapped:
            paths.add(mapped)
    return paths


def bazel_ignored_dirs(root):
    """.bazelignore removes whole directories from the workspace, so no target
    can ever own their contents."""
    path = os.path.join(root, ".bazelignore")
    dirs = set()
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            line = line.split("#", 1)[0].strip().strip("/")
            if line:
                dirs.add(line)
    return dirs


def read_ledger(path):
    """Ledger lines are `pattern<TAB>reason` (or two spaces). Blank lines and
    `#` comments are ignored. `*` and `?` work as globs."""
    entries = []
    if not os.path.isfile(path):
        return entries
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = re.split(r"\t+|\s{2,}", line.strip(), maxsplit=1)
        pattern = parts[0]
        reason = parts[1].strip() if len(parts) > 1 else ""
        regex = re.compile(
            "^" + re.escape(pattern).replace(r"\*", ".*").replace(r"\?", ".") + "$")
        entries.append((regex, pattern, reason))
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--ledger", default="bazel-unowned.txt")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict-ledger", action="store_true",
                    help="also fail on ledger entries that match nothing")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    ledger_path = args.ledger if os.path.isabs(args.ledger) else os.path.join(root, args.ledger)

    tracked = [t for t in run(["git", "ls-files", "-z"], root).split("\0") if t]
    if not tracked:
        sys.stderr.write("error: git ls-files returned nothing; is this a git repo?\n")
        return 2

    owned = owned_paths(root)
    ignored = bazel_ignored_dirs(root)
    ledger = read_ledger(ledger_path)

    unowned, excluded, hits = [], [], set()
    control = 0
    for f in tracked:
        if f in owned:
            continue
        if is_control_plane(f):
            control += 1
            continue
        if any(f == d or f.startswith(d + "/") for d in ignored):
            control += 1
            continue
        matched = None
        for regex, pattern, reason in ledger:
            if regex.match(f):
                matched = (pattern, reason)
                hits.add(pattern)
                break
        if matched:
            if not matched[1]:
                unowned.append((f, "ledger entry carries no reason"))
            else:
                excluded.append((f, matched[1]))
        else:
            unowned.append((f, "no target owns it and no ledger entry covers it"))

    stale = [p for _, p, _ in ledger if p not in hits]
    if args.strict_ledger:
        for p in stale:
            unowned.append((p, "ledger entry matches nothing (stale)"))

    if args.json:
        print(json.dumps({"tracked": len(tracked),
                          "target_owned": len(tracked) - control - len(excluded) - len(unowned),
                          "owned_labels": len(owned),
                          "control_plane": control, "excluded": len(excluded),
                          "stale_ledger": stale,
                          "unowned": [{"path": f, "why": w} for f, w in unowned]},
                         indent=2))
    else:
        for f, why in unowned:
            print(f"UNOWNED {f}  ({why})")
        # Every tracked file lands in exactly one bucket, so these must sum to
        # `tracked`; counting ledger files as target-owned was an off-by-N here.
        target_owned = len(tracked) - control - len(excluded) - len(unowned)
        print(f"summary: {len(tracked)} tracked | {target_owned} target-owned | {control} "
              f"control-plane | {len(excluded)} ledger-excluded (reasoned) | "
              f"{len(unowned)} unowned | {len(stale)} stale ledger entries")
    return 1 if unowned else 0


if __name__ == "__main__":
    sys.exit(main())
