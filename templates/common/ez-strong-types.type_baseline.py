#!/usr/bin/env python3
# managed-by: evo-t1-coder-stack -- stack-seeded helper. The canonical source is
# templates/common/ez-strong-types.type_baseline.py in evo-t1-coder-stack: change the seed there and
# re-materialize this copy; editing the copy in a home invites it being restored.
"""Measure broad-type usage per language so "strong types" is a number, and a
ratchet, rather than an intention.

Zero `Any` on a legacy tree in one pass is a fantasy; a budget that can only go
down is enforceable. Print the baseline, wire the same command as a gate with
--fail-on-increase, and every later change must remove at least as much breadth
as it adds.

Usage:
    type_baseline.py [--root DIR] [--json]
    type_baseline.py --fail-on-increase baseline.json [--root DIR]

Exit codes: 0 clean, 1 regression against the baseline, 2 usage/environment error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

LANGS = {
    "python": {
        "ext": (".py",),
        "metrics": {
            "explicit_any": r":\s*Any\b|->\s*Any\b|\[\s*Any\b|\bAny\s*\]|=\s*Any\b",
            "type_ignore": r"#\s*type:\s*ignore",
            "bare_cast": r"\bcast\s*\(\s*Any\b",
            "untyped_def": r"^\s*(?:async\s+)?def\s+\w+\s*\([^)]*\)\s*(:|\#)",
            "object_param": r"def\s+\w+\([^)]*\b\w+\s*:\s*object\b",
        },
    },
    "typescript": {
        "ext": (".ts", ".tsx", ".mts", ".cts"),
        "metrics": {
            "explicit_any": r":\s*any\b|\bas\s+any\b|<\s*any\s*>|\[\s*any\s*\]|\(\s*any\s*\)",
            "unknown_widening": r":\s*unknown\b",
            "ts_ignore": r"@ts-ignore|@ts-expect-error",
            "non_null_assert": r"!\s*[.,)\]}]",
        },
    },
    "shell": {
        "ext": (".sh",),
        "metrics": {
            "missing_strict_header": r"__MISSING_STRICT__",
            "eval": r"(?<![\w-])eval\s",
            "unquoted_expansion": r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(?![\"}])",
        },
    },
}

STRICT_RE = re.compile(r"\bset\s+-[a-z]*e[a-z]*\b.*\|\s*pipefail|set\s+-euo\s+pipefail")


def tracked(root):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                         capture_output=True, text=True).stdout
    return [p for p in out.split("\0") if p]


def measure(root):
    files = tracked(root)
    report = {}
    for lang, spec in LANGS.items():
        paths = [f for f in files if f.endswith(spec["ext"])]
        counts = {m: 0 for m in spec["metrics"]}
        compiled = {m: re.compile(p) for m, p in spec["metrics"].items() if not p.startswith("__")}
        for rel in paths:
            try:
                text = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            lines = text.splitlines()
            for name, rx in compiled.items():
                if name == "unquoted_expansion":
                    # Too noisy to count per occurrence; count files instead.
                    counts[name] += 1 if any(rx.search(l) for l in lines) else 0
                else:
                    counts[name] += len(rx.findall(text))
            if lang == "shell" and not any(STRICT_RE.search(l) for l in lines):
                counts["missing_strict_header"] += 1
        counts["files"] = len(paths)
        report[lang] = counts
    report["totals"] = {
        "broad_types": sum(r.get("explicit_any", 0) for k, r in report.items() if k != "totals")
    }
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fail-on-increase", metavar="BASELINE",
                    help="exit 1 if any metric exceeds the recorded baseline")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not tracked(root):
        sys.stderr.write("error: git ls-files returned nothing; is this a git repo?\n")
        return 2

    current = measure(root)

    if args.json:
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0

    width = max(len(k) for k in current if k != "totals")
    for lang in [k for k in current if k != "totals"]:
        row = current[lang]
        print(f"== {lang} ({row['files']} files)")
        for metric, value in sorted(row.items()):
            if metric == "files":
                continue
            print(f"  {metric:<24} {value}")
    print(f"summary: {current['totals']['broad_types']} explicit broad types across "
          f"{', '.join(k for k in current if k != 'totals')}")

    if args.fail_on_increase:
        try:
            baseline = json.load(open(args.fail_on_increase, encoding="utf-8"))
        except OSError as exc:
            sys.stderr.write(f"error: cannot read baseline {args.fail_on_increase}: {exc}\n")
            return 2
        regressions = []
        for lang, row in current.items():
            if lang == "totals":
                continue
            for metric, value in row.items():
                if metric == "files":
                    continue
                allowed = baseline.get(lang, {}).get(metric)
                if allowed is not None and value > allowed:
                    regressions.append(f"{lang}.{metric}: {value} > baseline {allowed}")
        for r in regressions:
            print(f"REGRESSION {r}")
        if regressions:
            print(f"error: {len(regressions)} metric(s) regressed; strong types only "
                  "moves forward")
            return 1
        print("ok: no metric exceeds the recorded baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
