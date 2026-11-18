#!/usr/bin/env python3
"""Parse JSON files with json.load; exit 1 on the first failure.

Usage: parse_json.py FILE [FILE...]

Used by scripts/validate.sh so the JSON check is not an inline python -c. Prints
nothing on success. It covers the two JSON payload families the stack ships or
generates: the Grafana dashboard tree, which the file provider loads whatever it
finds, and the generated Spark file-SD targets. A dashboard that fails here shows
up in Grafana as an empty panel and nothing else, which is why it is worth a gate.

A dashboard is checked a little further than "is it JSON": the file provider gives
Grafana no schema, so a JSON object that is not a dashboard, or a dashboard whose
``title`` is missing, is a panel that silently never appears in the folder listing.
Both are rejected here rather than discovered in the browser.
"""

import json
import sys


def check(path: str) -> str | None:
    """Return a one-line reason the file is unusable, or None if it is fine."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return f"{path}: {exc}"
    if not isinstance(doc, dict):
        return f"{path}: top level is {type(doc).__name__}, expected an object"
    # Only the dashboards carry a title; the file-SD document is a list of target
    # groups and a title requirement there would reject a valid generated file.
    if "title" in doc and not str(doc["title"]).strip():
        return f"{path}: title is present but empty, so the page never lists"
    if "panels" in doc and not isinstance(doc["panels"], list):
        return f"{path}: panels is {type(doc['panels']).__name__}, expected a list"
    if "targets" in doc and not isinstance(doc["targets"], list):
        return f"{path}: targets is {type(doc['targets']).__name__}, expected a list"
    return None


def main(argv: list[str]) -> int:
    # sys.argv verbatim: slot 0 is the script name, the files start at 1.
    if len(argv) < 2:
        sys.stderr.write("usage: parse_json.py FILE [FILE...]\n")
        return 1
    for path in argv[1:]:
        reason = check(path)
        if reason:
            sys.stderr.write(f"parse_json: {reason}\n")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
