#!/usr/bin/env python3
# managed-by: evo-t1-coder-stack -- stack-seeded helper. The canonical source is
# templates/common/ez-bazel-first.glob_budget.py in evo-t1-coder-stack: change the seed there and
# re-materialize this copy; editing the copy in a home invites it being restored.
"""Ratchet gate for glob() in BUILD files.

A Bazel-first repo gets its value from targets that name what they read: the
dependency graph is the machine-readable record, and a glob hides a file that
was added silently. Some globs are the contract, though (a payload directory
that grows by design), so the rule is not "no globs" -- it is "no unexplained
globs, and never more of them than yesterday".

Every `glob(` must carry a `# glob-policy: <reason>` comment on its own line or
within --context lines above it. The total must stay at or under --max, which
you set to the current count when you adopt the gate so it can only ratchet
down.

Usage:
    glob_budget.py [--root DIR] [--max N] [--context 3] [--json]

Exit codes: 0 clean, 1 violation, 2 usage/environment error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

GLOB_RE = re.compile(r"(?<![\w.])glob\s*\(")
POLICY_RE = re.compile(r"#\s*glob-policy\s*:\s*(\S.*)$", re.I)


def tracked_build_files(root):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                         capture_output=True, text=True).stdout
    files = []
    for f in (p for p in out.split("\0") if p):
        base = os.path.basename(f)
        if base in ("BUILD", "BUILD.bazel") or f.endswith((".bzl", ".bazelrc")):
            files.append(f)
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--max", type=int, default=-1,
                    help="allowed total glob() calls; -1 means report only")
    ap.add_argument("--context", type=int, default=3,
                    help="lines above the glob() searched for the policy comment")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    offenders, per_file, total = [], {}, 0

    for rel in tracked_build_files(root):
        path = os.path.join(root, rel)
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except OSError as exc:
            sys.stderr.write(f"error: cannot read {rel}: {exc}\n")
            return 2
        hits = 0
        for idx, line in enumerate(lines):
            if not GLOB_RE.search(line):
                continue
            hits += 1
            total += 1
            window = [lines[j] for j in range(max(0, idx - args.context), idx + 1)]
            if not any(POLICY_RE.search(w) for w in window):
                offenders.append({"file": rel, "line": idx + 1,
                                  "text": line.strip()[:90]})
        if hits:
            per_file[rel] = hits

    budget_hit = args.max >= 0 and total > args.max

    if args.json:
        print(json.dumps({"total": total, "max": args.max, "budget_hit": budget_hit,
                          "per_file": per_file, "unannotated": offenders}, indent=2))
    else:
        for o in offenders:
            print(f"UNANNOTATED {o['file']}:{o['line']}  {o['text']}")
        for rel, n in sorted(per_file.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  {n:>3}  {rel}")
        budget = "any" if args.max < 0 else str(args.max)
        print(f"summary: {total} glob() in {len(per_file)} BUILD files, budget {budget}, "
              f"{len(offenders)} unannotated (need '# glob-policy: <reason>')")
        if budget_hit:
            print(f"error: {total} glob() exceeds the budget of {args.max}; "
                  "replace a glob with an explicit list, then lower --max")
    return 1 if (offenders or budget_hit) else 0


if __name__ == "__main__":
    sys.exit(main())
