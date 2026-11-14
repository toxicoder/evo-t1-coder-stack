#!/usr/bin/env python3
# managed-by: evo-t1-coder-stack -- stack-seeded helper. The canonical source is
# templates/common/ez-micro-plan.plan_check.py in evo-t1-coder-stack: change the seed there and
# re-materialize this copy; editing the copy in a home invites it being restored.
"""Check a micro-plan before a fleet is dispatched, and print the ready wave.

The gate for a fan-out that is meant to fill every subagent slot. A plan whose
first wave is narrower than the fleet leaves slots idle for the whole run, and
two ready tasks that share a file collide the moment both are spawned, so both
are refused here rather than discovered at wave 3.

Parsed shape (see the skill body for the format): a `## Dispatch` block with
`slots:` and `lane:`, a `## Lanes` table, `### T<nn> -- <summary>` task blocks
each carrying lane/role/owns/reads/needs/calls/done/report, and a `## Ledger`
table with one row per task.

Usage:
    ez-micro-plan.plan_check.py PLAN [--slots N] [--ready] [--json]
                                      [--no-files] [--strict]

Exit codes: 0 clean, 1 violations found, 2 usage/environment error.
"""

import argparse
import json
import os
import re
import sys

MARKER = "ez-micro-plan v1"
SECTIONS = ("Goal", "Dispatch", "Lanes", "Tasks", "Ledger")
TASK_KEYS = ("lane", "role", "owns", "reads", "needs", "calls", "done", "report")
ROLES = ("general-purpose", "explore", "plan")
READ_ONLY_ROLES = ("explore", "plan")
LEDGER_STATES = ("ready", "running", "done", "failed", "blocked", "skipped")
CALLS_HARD_MAX = 25
CALLS_SOFT_MAX = 15
OWNS_SOFT_MAX = 3

TASK_RE = re.compile(r"^###\s+(T\d+)\s+(?:--|-{1,2})\s+(.*)$")
KEY_RE = re.compile(r"^-\s+([a-z]+)\s*:\s*(.*)$")
DISPATCH_RE = re.compile(r"^-\s+([a-z][a-z -]*[a-z])\s*:\s*(.*)$")
TABLE_RE = re.compile(r"^\|(.*)\|\s*$")


class Report:
    """Collect findings so the exit code is one decision at the end."""

    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, text):
        self.errors.append(text)

    def warn(self, text):
        self.warnings.append(text)


def split_sections(lines):
    """Return {section-title: [lines]} for every `## <title>` block."""
    sections = {}
    current = None
    for line in lines:
        if line.startswith("## ") and not line.startswith("### "):
            current = line[3:].strip()
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    return sections


def parse_table(lines):
    """Return the data rows of the first markdown table in `lines`."""
    rows = []
    for line in lines:
        match = TABLE_RE.match(line.strip())
        if not match:
            if rows:
                break
            continue
        cells = [cell.strip() for cell in match.group(1).split("|")]
        if not cells or all(cell.strip("- ") == "" for cell in cells):
            continue
        rows.append(cells)
    if rows:
        rows = rows[1:]  # the header row is layout, not data
    return rows


def parse_dispatch(lines):
    dispatch = {}
    for line in lines:
        match = DISPATCH_RE.match(line.strip())
        if match:
            dispatch[match.group(1).strip().lower()] = match.group(2).strip()
    return dispatch


def parse_tasks(lines):
    """Return ordered task dicts from the `## Tasks` block."""
    tasks = []
    current = None
    for line in lines:
        heading = TASK_RE.match(line)
        if heading:
            current = {"id": heading.group(1), "summary": heading.group(2).strip()}
            tasks.append(current)
            continue
        if line.startswith("### ") or line.startswith("## "):
            current = None
            continue
        if current is None:
            continue
        key = KEY_RE.match(line.strip())
        if key:
            current[key.group(1)] = key.group(2).strip()
    return tasks


def split_list(value):
    """Split a comma list; `-`, empty, and `none` all mean nothing."""
    if value is None:
        return []
    text = value.strip()
    if text in ("", "-", "none", "None", "n/a"):
        return []
    return [item.strip().strip("`") for item in text.split(",") if item.strip()]


def strip_line_range(path):
    """`src/lib/spark.sh:40-75` names a window; the file is the part that exists."""
    if ":" in path and not path.startswith("/") and not re.match(r"^[A-Za-z]:", path):
        head, _, tail = path.rpartition(":")
        if head and re.match(r"^\d+(-\d+)?$", tail):
            return head
    return path


def parse_needs(tasks, report):
    """Attach dependency lists and name unknown task ids."""
    known = {task["id"] for task in tasks}
    for task in tasks:
        needs = split_list(task.get("needs"))
        for need in needs:
            if need not in known:
                report.error("%s needs unknown task %s" % (task["id"], need))
        task["_needs"] = [need for need in needs if need in known]


def ancestors(task_id, needs, seen=None):
    """Every task reachable from task_id through `needs`."""
    seen = set() if seen is None else seen
    for need in needs.get(task_id, []):
        if need not in seen:
            seen.add(need)
            ancestors(need, needs, seen)
    return seen


def check_acyclic(tasks, report):
    needs = {task["id"]: task["_needs"] for task in tasks}
    for task in tasks:
        if task["id"] in ancestors(task["id"], needs):
            report.error("dependency cycle through %s" % task["id"])


def check_collisions(tasks, report):
    """Two tasks that may run at once must not share an owned path."""
    needs = {task["id"]: task["_needs"] for task in tasks}
    order = {task["id"]: ancestors(task["id"], needs) for task in tasks}
    owners = {}
    for task in tasks:
        for path in split_list(task.get("owns")):
            owners.setdefault(path, []).append(task["id"])
    for path, claimants in sorted(owners.items()):
        if len(claimants) < 2:
            continue
        for index, first in enumerate(claimants):
            for second in claimants[index + 1:]:
                ordered = second in order[first] or first in order[second]
                if not ordered:
                    report.error(
                        "%s and %s both own %s and no dependency orders them"
                        % (first, second, path))


def check_context_files(plan_dir, tasks, lanes, report, want_files):
    """Every context file a task reads must exist, and be the lane it belongs to."""
    if not want_files:
        return
    for task in tasks:
        for ref in split_list(task.get("reads")):
            if ref == "L0":
                want = os.path.join(plan_dir, "ctx", "L0.md")
                if not os.path.isfile(want):
                    report.error("%s reads L0 but %s is missing"
                                 % (task["id"], os.path.join("ctx", "L0.md")))
            elif ref.startswith("L1-"):
                lane = ref[3:]
                want = os.path.join(plan_dir, "ctx", "L1-%s.md" % lane)
                if not os.path.isfile(want):
                    report.error("%s reads %s but %s is missing"
                                 % (task["id"], ref, os.path.join("ctx", "L1-%s.md" % lane)))
                elif task.get("lane") and task["lane"] != lane:
                    report.warn("%s reads the %s brief from lane %s"
                                % (task["id"], ref, task.get("lane")))
            elif ref.startswith("L2-"):
                want = os.path.join(plan_dir, "ctx", "%s.md" % ref)
                if not os.path.isfile(want):
                    report.error("%s reads %s but %s is missing"
                                 % (task["id"], ref, os.path.join("ctx", "%s.md" % ref)))
                elif ref[3:] != task["id"]:
                    report.warn("%s reads %s, another task's brief" % (task["id"], ref))
            else:
                path = strip_line_range(ref)
                if not os.path.exists(path):
                    report.warn("%s reads %s, which is not in the checkout"
                                % (task["id"], ref))
        report_path = task.get("report")
        if report_path:
            expected = os.path.join("results", "%s.md" % task["id"])
            if report_path != expected:
                report.warn("%s reports to %s, not %s" % (task["id"], report_path, expected))
    for lane, row in sorted(lanes.items()):
        brief = row.get("brief")
        if brief and not os.path.exists(os.path.join(plan_dir, brief)):
            report.error("lane %s names brief %s, which is missing" % (lane, brief))


def check_tasks(tasks, lanes, report):
    if not tasks:
        report.error("no task blocks in ## Tasks")
    for task in tasks:
        missing = [key for key in TASK_KEYS if key not in task]
        if missing:
            report.error("%s is missing %s" % (task["id"], ", ".join(missing)))
        if not task.get("summary"):
            report.error("%s has no summary on its heading" % task["id"])
        role = task.get("role", "")
        if role and role not in ROLES:
            report.error("%s role %r is not one of %s" % (task["id"], role, ", ".join(ROLES)))
        lane = task.get("lane", "")
        if lane and lanes and lane not in lanes:
            report.error("%s names lane %s, which ## Lanes does not list" % (task["id"], lane))
        owns = split_list(task.get("owns"))
        if role in READ_ONLY_ROLES and owns:
            report.error("%s is %s but owns %s" % (task["id"], role, ", ".join(owns)))
        if role == "general-purpose" and not owns:
            report.warn("%s writes nothing and is not read-only" % task["id"])
        if len(owns) > OWNS_SOFT_MAX:
            report.warn("%s owns %d files; a micro task carries %d or fewer"
                        % (task["id"], len(owns), OWNS_SOFT_MAX))
        if not task.get("done"):
            report.error("%s has no done check" % task["id"])
        reads = split_list(task.get("reads"))
        if reads and "L0" not in reads:
            report.warn("%s reads no L0, so it starts without the contract every "
                        "other child was given" % task["id"])
        calls = task.get("calls", "")
        if calls:
            if not re.match(r"^\d+$", calls):
                report.error("%s calls %r is not a number" % (task["id"], calls))
            else:
                count = int(calls)
                if count > CALLS_HARD_MAX:
                    report.error("%s budgets %d calls; split it (max %d)"
                                 % (task["id"], count, CALLS_HARD_MAX))
                elif count > CALLS_SOFT_MAX:
                    report.warn("%s budgets %d calls; a micro task is %d or fewer"
                                % (task["id"], count, CALLS_SOFT_MAX))


def check_ledger(tasks, rows, report, section_present):
    if not section_present:
        return {}
    states = {}
    seen = []
    for row in rows:
        if not row:
            continue
        task_id = row[0]
        if not task_id:
            report.warn("ledger row is blank")
            continue
        seen.append(task_id)
        state = row[1].strip().lower() if len(row) > 1 else ""
        if state and state not in LEDGER_STATES:
            report.warn("ledger row %s has state %r" % (task_id, state))
        states[task_id] = state
    known = {task["id"] for task in tasks}
    for task in tasks:
        if task["id"] not in seen:
            report.error("%s has no ledger row" % task["id"])
    for task_id in seen:
        if task_id not in known:
            report.error("ledger row %s has no task block" % task_id)
    return states


def ready_wave(tasks, states, slots):
    """Tasks whose needs are all done and which are not already running."""
    done_states = ("done", "skipped")
    wave = []
    for task in tasks:
        if states.get(task["id"], "ready") in ("running", "done", "failed", "skipped", "blocked"):
            continue
        if all(states.get(need, "ready") in done_states for need in task["_needs"]):
            wave.append(task["id"])
    return wave[:slots]


def main():
    parser = argparse.ArgumentParser(description="Check a micro-plan and print its ready wave.")
    parser.add_argument("plan", help="path to .grok/plans/<slug>/plan.md")
    parser.add_argument("--slots", type=int, default=None,
                        help="override the plan's slots (default: its Dispatch value)")
    parser.add_argument("--ready", action="store_true",
                        help="print the dispatchable task ids, one per line, after the summary")
    parser.add_argument("--json", action="store_true", help="emit the findings as JSON")
    parser.add_argument("--no-files", action="store_true",
                        help="skip checking that context files exist on disk")
    parser.add_argument("--strict", action="store_true",
                        help="treat warnings as failures")
    args = parser.parse_args()

    if not os.path.isfile(args.plan):
        sys.stderr.write("error: no plan at %s\n" % args.plan)
        return 2
    try:
        with open(args.plan, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("error: cannot read %s: %s\n" % (args.plan, exc))
        return 2

    report = Report()
    lines = text.splitlines()
    if MARKER not in text:
        report.error("no `%s` marker; this is not a micro-plan" % MARKER)

    sections = split_sections(lines)
    for name in SECTIONS:
        if name not in sections:
            report.error("missing `## %s` section" % name)

    dispatch = parse_dispatch(sections.get("Dispatch", []))
    slots_value = dispatch.get("slots", "")
    if args.slots is not None:
        slots = args.slots
    elif re.match(r"^\d+$", slots_value or ""):
        slots = int(slots_value)
    else:
        report.error("Dispatch needs a numeric `slots:` (the session's [subagents] max_concurrent)")
        slots = 1
    if slots < 1:
        report.error("slots must be at least 1")
        slots = 1
    if not dispatch.get("lane"):
        report.error("Dispatch names no `lane:` the fleet rides")
    if not dispatch.get("parent keeps"):
        report.warn("Dispatch lists no `parent keeps:`; hotspots stay with the parent")

    lanes = {}
    for row in parse_table(sections.get("Lanes", [])):
        if row and row[0]:
            lanes[row[0]] = {"owns": row[1] if len(row) > 1 else "",
                             "role": row[2] if len(row) > 2 else "",
                             "brief": strip_line_range(row[3]) if len(row) > 3 else ""}

    tasks = parse_tasks(sections.get("Tasks", []))
    parse_needs(tasks, report)
    check_acyclic(tasks, report)
    check_tasks(tasks, lanes, report)
    check_collisions(tasks, report)
    states = check_ledger(tasks, parse_table(sections.get("Ledger", [])), report,
                          "Ledger" in sections)
    check_context_files(os.path.dirname(os.path.abspath(args.plan)), tasks, lanes, report,
                        not args.no_files)

    wave = ready_wave(tasks, states, slots)
    initial_ready = [task["id"] for task in tasks if not task["_needs"]
                     and states.get(task["id"], "ready") == "ready"]
    if tasks and len(initial_ready) < min(slots, len(tasks)):
        report.error("wave 1 is %d tasks wide against %d slots; the fleet idles, so split "
                     "the coarse tasks further" % (len(initial_ready), slots))
    used_lanes = {task.get("lane") for task in tasks}
    for lane in sorted(lanes):
        if lane not in used_lanes:
            report.warn("lane %s has no task" % lane)

    failed = bool(report.errors) or (args.strict and bool(report.warnings))
    if args.json:
        print(json.dumps({"plan": args.plan, "slots": slots, "tasks": len(tasks),
                          "lanes": len(lanes), "ready": wave,
                          "errors": report.errors, "warnings": report.warnings}, indent=2))
    else:
        for finding in report.errors:
            print("error: %s" % finding)
        for finding in report.warnings:
            print("warning: %s" % finding)
        print("summary: %d tasks | %d lanes | %d slots | wave width %d | %d errors, %d warnings"
              % (len(tasks), len(lanes), slots, len(wave), len(report.errors),
                 len(report.warnings)))
        if args.ready:
            for task_id in wave:
                print(task_id)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
