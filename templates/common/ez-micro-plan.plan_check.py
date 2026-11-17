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
`slots:`, the optional `fleet:` stream ceiling, `lane:` and the optional `review:`
skeptic panel, a `## Lanes` table,
`### T<nn> -- <summary>` task blocks each carrying
lane/role/owns/reads/needs/calls/done/report and the optional `spawns:`, and a
`## Ledger` table with one row per task.

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
# The tree-wide stream ceiling: 3 Spark boxes x PARALLEL 5, scripts/spark-configure.sh.
FLEET_DEFAULT = 15

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
    """Split a comma or space separated list; `-`, empty, and `none` mean nothing.

    Both separators are accepted because the plan prose writes both -- `reads: L0,
    L1-src` beside `review: T14 T15 T16` -- and a checker that reads only one of
    them turns a three-skeptic panel into one unknown id, which is how a review
    phase silently stops being a panel. These keys hold ids and paths, which carry
    no space here.
    """
    if value is None:
        return []
    text = value.strip()
    if text in ("", "-", "none", "None", "n/a"):
        return []
    return [item.strip("`") for item in re.split(r"[,\s]+", text) if item.strip("`")]


def spawn_count(task):
    """How many children the task spawns itself; absent or unreadable is none."""
    spawns = task.get("spawns", "")
    return int(spawns) if re.match(r"^\d+$", spawns) else 0


def task_streams(task):
    """The model streams one task holds: itself plus every child it spawns."""
    return 1 + task.get("_spawns", 0)


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


def check_spawns(tasks, fleet, report):
    """A spawner pays for every child it fans out, and ships nothing itself.

    `spawns` is optional and a task without it holds the single stream it always
    did. Each child is a session of its own holding a stream too, so a task plus
    its children has to fit the fleet, and a task that spawns is not also a writer.
    """
    for task in tasks:
        raw = task.get("spawns", "")
        if raw and not re.match(r"^\d+$", raw):
            report.error("%s spawns %r is not a number" % (task["id"], raw))
        task["_spawns"] = spawn_count(task)
        if not task["_spawns"]:
            continue
        owned = split_list(task.get("owns"))
        if owned:
            report.error("%s spawns %d children but owns %s; a spawner ships nothing"
                         % (task["id"], task["_spawns"], ", ".join(owned)))
        if task_streams(task) > fleet:
            report.error("%s and its %d children need %d streams; the fleet holds %d"
                         % (task["id"], task["_spawns"], task_streams(task), fleet))


def check_review_task(dispatch, tasks, report):
    """Every named skeptic waits on every producer and ships nothing itself.

    A plan with no `review:` is legal but incomplete, so its absence warns. Once
    one is named it is a contract: a reviewer that owns a file is its own producer,
    and one that skips a producer never re-runs that producer's `done` check. The
    key takes a comma list, and each rule below runs once per named skeptic.
    """
    reviewers = split_list(dispatch.get("review"))
    if not reviewers:
        report.warn("Dispatch names no `review:` task, so nothing re-runs the "
                    "producers' own done checks but their own reports")
        return
    for review_id in reviewers:
        check_reviewer(review_id, tasks, report)


def check_reviewer(review_id, tasks, report):
    """The rules one named skeptic is held to, run once per reviewer in the panel."""
    by_id = {task["id"]: task for task in tasks}
    if review_id not in by_id:
        report.error("Dispatch reviews with %s, which ## Tasks does not define" % review_id)
        return
    reviewer = by_id[review_id]
    owned = split_list(reviewer.get("owns"))
    if owned:
        report.error("%s is the review task but owns %s; a skeptic cannot review "
                     "its own work" % (review_id, ", ".join(owned)))
    needs = {task["id"]: task["_needs"] for task in tasks}
    waits = set(reviewer["_needs"])
    for task in tasks:
        if task["id"] == review_id:
            continue
        produced = split_list(task.get("owns"))
        if produced and split_list(task.get("needs")).count(review_id) > 1:
            report.error("%s lists %s in needs twice" % (task["id"], review_id))
        # A fix-up task is allowed to sit behind the reviewer, so it is not one of
        # the producers the reviewer has to wait for.
        if not produced or review_id in ancestors(task["id"], needs):
            continue
        if task["id"] not in waits:
            report.error("%s reviews but does not need %s, which owns %s"
                         % (review_id, task["id"], ", ".join(produced)))


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
        if role == "general-purpose" and not owns and not spawn_count(task):
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


def ready_wave(tasks, states, slots, fleet):
    """Tasks whose needs are all done and which are not already running.

    Two budgets, and they are not the same number: `slots` caps how many children
    one parent holds in flight, and the wave also stops once the tree would hold
    more than `fleet` model streams, a spawner paying for each child it fans out.
    """
    done_states = ("done", "skipped")
    wave = []
    streams = 0
    for task in tasks:
        if states.get(task["id"], "ready") in ("running", "done", "failed", "skipped", "blocked"):
            continue
        if all(states.get(need, "ready") in done_states for need in task["_needs"]):
            if len(wave) >= slots:
                break
            if streams + task_streams(task) > fleet:
                # Skip, do not stop. A spawner too heavy for the streams still
                # free does not own the tasks behind it: the budget exists to
                # fill the fleet, and a cheaper ready task still fits it.
                continue
            wave.append(task["id"])
            streams += task_streams(task)
    return wave, streams


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
    fleet_value = (dispatch.get("fleet") or "").strip()
    fleet = FLEET_DEFAULT
    if fleet_value:
        if re.match(r"^\d+$", fleet_value) and int(fleet_value) >= 1:
            fleet = int(fleet_value)
        else:
            report.warn("Dispatch fleet %r is not a stream count; using %d"
                        % (fleet_value, FLEET_DEFAULT))
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
    check_spawns(tasks, fleet, report)
    check_collisions(tasks, report)
    check_review_task(dispatch, tasks, report)
    states = check_ledger(tasks, parse_table(sections.get("Ledger", [])), report,
                          "Ledger" in sections)
    check_context_files(os.path.dirname(os.path.abspath(args.plan)), tasks, lanes, report,
                        not args.no_files)

    wave, wave_streams = ready_wave(tasks, states, slots, fleet)
    # Wave 1 is only a design question while the plan is still unstarted. Once a
    # task has been dispatched the opening wave has already filled the fleet, and a
    # plan being driven late in the run has an empty initial wave by construction
    # (its review task needs everything), so re-proving it then is a false error.
    started = any(states.get(t["id"], "ready") != "ready" for t in tasks)
    initial_tasks = [task for task in tasks if not task["_needs"]]
    if tasks and not started:
        initial_ready = [task for task in initial_tasks
                         if states.get(task["id"], "ready") == "ready"]
        if len(initial_ready) < min(slots, len(tasks)):
            report.error("wave 1 is %d tasks wide against %d slots; the fleet idles, so "
                         "split the coarse tasks further" % (len(initial_ready), slots))
    # The stream price of the opening wave is arithmetic over what the plan declares,
    # so it stays true as the Ledger advances and is checked whatever the state.
    wave1_streams = sum(task_streams(task) for task in initial_tasks)
    if tasks and wave1_streams > fleet:
        report.error("wave 1 costs %d streams against a fleet of %d; a spawner pays "
                     "for its children, so narrow the fan-out"
                     % (wave1_streams, fleet))
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
            sys.stderr.write("cost: %d streams of %d\n" % (wave_streams, fleet))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
