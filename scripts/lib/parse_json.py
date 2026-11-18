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

The Spark file-SD document is the other family and it is a top-level **list** of target
groups, which is why the top level is allowed to be a list. Its groups are checked as
hardly more loosely: Prometheus reads the file verbatim, so a group that lost its
``targets`` scrapes nothing and a group that lost ``hostname`` or ``exporter`` is either
invisible to its job or orphaned from the box it belongs to. Both read as "no Sparks" on
the dashboards rather than as an error, so the gate is the only thing that says so.
"""

import json
import sys

# The three labels //scripts:spark-monitor stamps on every group. observability/prometheus
# /rules/spark.rules.yml groups every Spark series by hostname, and the four jobs in
# observability/prometheus/prometheus.yml each keep on exporter, so a group missing one is
# a silently missing box rather than a rejected file.
SD_LABELS = ("box", "exporter", "hostname")


def check_group(path: str, index: int, group: object) -> str | None:
    """Return a one-line reason one file-SD target group is unusable, or None."""
    if not isinstance(group, dict):
        return f"{path}: group {index} is {type(group).__name__}, expected an object"
    if "targets" not in group:
        return f"{path}: group {index} has no targets, so it scrapes nothing"
    if not isinstance(group["targets"], list):
        return (
            f"{path}: group {index} targets is "
            f"{type(group['targets']).__name__}, expected a list"
        )
    labels = group.get("labels", {})
    if not isinstance(labels, dict):
        return f"{path}: group {index} labels is {type(labels).__name__}, expected an object"
    missing = [name for name in SD_LABELS if not str(labels.get(name, "")).strip()]
    if missing:
        return f"{path}: group {index} labels is missing {'/'.join(missing)}, so the box is orphaned"
    return None


def check(path: str) -> str | None:
    """Return a one-line reason the file is unusable, or None if it is fine."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return f"{path}: {exc}"
    if isinstance(doc, list):
        # The generated file-SD document. An empty list is the shipped default -
        # SPARK_MONITOR_ENABLED=false prints it - and is a valid "no Sparks".
        for index, group in enumerate(doc):
            reason = check_group(path, index, group)
            if reason:
                return reason
        return None
    if not isinstance(doc, dict):
        return (
            f"{path}: top level is {type(doc).__name__}, expected an object or a list"
        )
    # Only the dashboards carry a title, so the check stays conditional.
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
