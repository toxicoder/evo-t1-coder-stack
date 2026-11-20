#!/usr/bin/env python3
# Canonical source: skills/reflect-and-evolve/scripts/session_signals.py in
# evo-t1-coder-stack. It ships with the /reflect-and-evolve skill and is stdlib only, so a
# workspace runs it with the python3 already on its PATH.
"""Rank the recent sessions of one repository by the friction they already recorded.

The retrospective this feeds asks "where did the last two weeks actually hurt", and the
honest answer is sitting in the session store as counters, not in anyone's memory. Each
session directory carries a `summary.json` (title, last activity, model) and a sibling
`signals.json` (turn, tool-call, tool-failure, error, regeneration and compaction counts,
plus context window usage). Reading only those two files per session turns a store of
hundreds of directories into one screen of ranked rows.

Reading only those two files is the point and the safety boundary. A session directory also
holds `chat_history.jsonl`, `prompt_history.jsonl` and `events.jsonl`, and those carry
prompts, tool output and diffs: this program never opens them, so a retrospective run cannot
leak a transcript into the transcript. It never prints a message body, a prompt, a diff, a
credential or a file's contents either, only counters and a truncated title.

Usage:
    session_signals.py [--home DIR] [--repo PATH] [--limit N] [--since DAYS] [--json]

Exit codes: 0 a run that read the store (or found no store), 2 usage error.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Dict, List, NamedTuple, Optional, Sequence, TextIO, Tuple, Union

DEFAULT_LIMIT = 20
DEFAULT_SINCE_DAYS = 90
TITLE_MAX = 48
LINE_MAX = 120
SUMMARY_NAME = "summary.json"
SIGNALS_NAME = "signals.json"

# One width per column, so the numbers line up under the header tokens
# sid8 title turns tools toolfail errors regen compaction ctx% age
WIDTHS: Tuple[int, ...] = (8, TITLE_MAX, 5, 6, 8, 6, 5, 10, 5, 4)

# What json.load can hand back, named rather than written as Any: every field read below is
# narrowed through this, so a session carrying a string where a counter belongs still prints
# a row instead of raising.
JsonValue = Union[
    None, bool, int, float, str, List["JsonValue"], Dict[str, "JsonValue"]
]

TIME_FORMATS = (
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d",
)


class ReadError(Exception):
    """One session file could not be read at all, which is a failure, not a warning."""


class Row(NamedTuple):
    """One session as the table prints it, and as one `--json` object spells it."""

    sid: str
    title: str
    turns: int
    tools: int
    toolfail: int
    errors: int
    regen: int
    compaction: int
    ctx_pct: Optional[int]
    age: str
    score: int
    last_active: Optional[datetime]


class Report:
    """Collect the prose lines of one run so the summary can stay the last line.

    Rows go out as they are rendered and these lines wait, because a reader scanning the
    table should see the ranked rows first and the skipped sessions after them. In `--json`
    mode the whole report moves to stderr so stdout stays machine-readable.
    """

    def __init__(self, stream: TextIO) -> None:
        self.stream = stream
        self.lines: List[str] = []
        self.ok = 0
        self.warnings = 0
        self.failed = 0

    def warn(self, line: str) -> None:
        self.lines.append("warning: %s" % line)
        self.warnings += 1

    def fail(self, line: str) -> None:
        self.lines.append("error: %s" % line)
        self.failed += 1

    def note(self, line: str) -> None:
        self.lines.append("note: %s" % line)

    def emit(self) -> None:
        for line in self.lines:
            self.stream.write("%s\n" % line)


def load_json_object(path: str) -> Optional[Dict[str, JsonValue]]:
    """Return the object at path, or None when it is absent or is not a JSON object.

    A session interrupted mid-write leaves a truncated file behind as often as a corrupt
    one does, so unparsable JSON is a warning about that session, not a failed run.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ReadError(str(exc))
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    return parsed


def as_int(doc: Dict[str, JsonValue], key: str) -> int:
    """Read one counter, defaulting anything that is not a plain number to zero.

    A session missing a field still prints a row, so every key access goes through here
    with a default instead of raising.
    """
    value = doc.get(key)
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return 0


def as_pct(doc: Dict[str, JsonValue], key: str) -> Optional[int]:
    """Read the context window usage, a 0..1 ratio, as a whole percent."""
    value = doc.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(round(float(value) * 100))


def as_str(doc: Dict[str, JsonValue], key: str) -> str:
    value = doc.get(key)
    return value if isinstance(value, str) else ""


def parse_time(raw: str) -> Optional[datetime]:
    """Parse an ISO-ish timestamp to an aware UTC datetime; None when it is unusable.

    The store writes `%Y-%m-%dT%H:%M:%S.%fZ`, and that trailing Z is trimmed first so the
    strptime list below does not need a %-z variant for the shape it always sees.
    """
    text = (raw or "").strip()
    if not text:
        return None
    if text.endswith(("Z", "z")):
        text = text[:-1]
    for fmt in TIME_FORMATS:
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def age_text(when: Optional[datetime], now: datetime) -> str:
    """How long ago the session was last active, in the coarsest unit that fits."""
    if when is None:
        return "-"
    seconds = (now - when).total_seconds()
    if seconds < 0:
        seconds = 0.0
    if seconds < 3600:
        return "%dm" % int(seconds // 60)
    if seconds < 86400:
        return "%dh" % int(seconds // 3600)
    return "%dd" % int(seconds // 86400)


def clean_title(raw: str) -> str:
    """Make one title safe to put on one line: no control character, no more than 48.

    A title is model-written text, so it can carry a stray tab or newline that would split
    a row across two lines, and a long one would push the counters past the line cap.
    """
    text = "".join(" " if ord(ch) < 32 or ord(ch) == 127 else ch for ch in raw)
    collapsed = " ".join(text.split())
    if not collapsed:
        return "-"
    if len(collapsed) > TITLE_MAX:
        return collapsed[: TITLE_MAX - 2].rstrip() + ".."
    return collapsed


def sessions_dir(home: str, repo: str) -> str:
    """The store path for one repository: every slash in the cwd becomes %2F."""
    return os.path.join(home, "sessions", repo.replace("/", "%2F"))


def row_for(
    sid: str,
    summary: Dict[str, JsonValue],
    signals: Dict[str, JsonValue],
    now: datetime,
) -> Row:
    """Fold the two documents into one row; the score is the ranking the skill reads."""
    toolfail = as_int(signals, "toolFailureCount")
    errors = as_int(signals, "errorCount")
    regen = as_int(signals, "regenerationCount")
    compaction = as_int(signals, "compactionCount")
    last_active = parse_time(as_str(summary, "last_active_at"))
    return Row(
        sid=sid[:8],
        title=clean_title(as_str(summary, "generated_title")),
        turns=as_int(signals, "turnCount") or as_int(summary, "num_messages"),
        tools=as_int(signals, "toolCallCount"),
        toolfail=toolfail,
        errors=errors,
        regen=regen,
        compaction=compaction,
        ctx_pct=as_pct(signals, "contextWindowUsage"),
        age=age_text(last_active, now),
        score=2 * toolfail + 2 * errors + regen + compaction,
        last_active=last_active,
    )


def collect(
    store: str, repo: str, since: Optional[timedelta], now: datetime, report: Report
) -> List[Row]:
    """Read every session directory under store; count each skip into the report."""
    try:
        names = sorted(os.listdir(store))
    except FileNotFoundError:
        report.note("no sessions for %s" % repo)
        return []
    except OSError as exc:
        report.fail("cannot read %s: %s" % (store, exc))
        return []

    rows: List[Row] = []
    seen = 0
    for name in names:
        session = os.path.join(store, name)
        if not os.path.isdir(session) or name.startswith("."):
            continue
        seen += 1
        try:
            summary = load_json_object(os.path.join(session, SUMMARY_NAME))
            signals = load_json_object(os.path.join(session, SIGNALS_NAME))
        except ReadError as exc:
            report.fail("%s could not be read: %s" % (name[:8], exc))
            continue
        if summary is None and signals is None:
            report.warn(
                "%s has no readable %s or %s, skipped"
                % (name[:8], SUMMARY_NAME, SIGNALS_NAME)
            )
            continue
        if summary is None:
            report.warn("%s has no readable %s, skipped" % (name[:8], SUMMARY_NAME))
            continue
        if signals is None:
            report.warn("%s has no readable %s, skipped" % (name[:8], SIGNALS_NAME))
            continue
        row = row_for(name, summary, signals, now)
        # A session with no usable timestamp is kept: dropping it would hide the one row
        # that might name a stalled run.
        if (
            since is not None
            and row.last_active is not None
            and now - row.last_active > since
        ):
            continue
        rows.append(row)

    if seen == 0:
        report.note("no sessions for %s" % repo)
    # Stable on purpose: the names arrive sorted, so a tie on score and recency keeps the
    # ids in that order rather than in whatever order the directory came back in.
    rows.sort(
        key=lambda item: (
            -(item.score),
            -(item.last_active.timestamp() if item.last_active else 0.0),
        )
    )
    return rows


def render_row(row: Row) -> str:
    """One table line: whitespace-separated columns, padded, never longer than the cap."""
    cells = [
        row.sid,
        row.title,
        str(row.turns),
        str(row.tools),
        str(row.toolfail),
        str(row.errors),
        str(row.regen),
        str(row.compaction),
        "-" if row.ctx_pct is None else "%d%%" % row.ctx_pct,
        row.age,
    ]
    line = " ".join(cell.ljust(width) for cell, width in zip(cells, WIDTHS)).rstrip()
    return line if len(line) <= LINE_MAX else line[: LINE_MAX - 3] + ".."


def json_row(row: Row) -> Dict[str, JsonValue]:
    """The same fields as the row, keyed by the column names, for a machine reader."""
    return {
        "sid": row.sid,
        "title": row.title,
        "turns": row.turns,
        "tools": row.tools,
        "toolfail": row.toolfail,
        "errors": row.errors,
        "regen": row.regen,
        "compaction": row.compaction,
        "ctx%": row.ctx_pct,
        "age": row.age,
    }


def run(
    home: str,
    repo: str,
    limit: int,
    since_days: int,
    as_json: bool,
    out: TextIO,
    err: TextIO,
    now: datetime,
) -> int:
    """Sweep one repository's store and print the table or the JSON lines."""
    report = Report(out if not as_json else err)
    since = timedelta(days=since_days) if since_days >= 0 else None
    rows = collect(sessions_dir(home, repo), repo, since, now, report)
    kept = rows[:limit]
    report.ok = len(kept)

    if as_json:
        for row in kept:
            out.write("%s\n" % json.dumps(json_row(row)))
    else:
        if rows:
            out.write("== session signals ==\n")
            for row in kept:
                out.write("%s\n" % render_row(row))
        if len(rows) > limit:
            report.note(
                "showing %d of %d sessions; raise --limit for the rest"
                % (limit, len(rows))
            )

    # Flushed first so that in --json mode a reader merging both streams still sees every
    # object before the prose and the summary.
    out.flush()
    report.emit()
    (err if as_json else out).write(
        "summary: %d ok, %d warnings, %d failed\n"
        % (report.ok, report.warnings, report.failed)
    )
    return 0


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Rank this repository's sessions by the friction their signals "
        "already recorded."
    )
    parser.add_argument(
        "--home",
        default=None,
        help="profile home holding sessions/ (default $GROK_HOME, else ~/.grok)",
    )
    parser.add_argument(
        "--repo",
        default=None,
        help="repository whose sessions to read (default the cwd)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help="rows to print, default %d" % DEFAULT_LIMIT,
    )
    parser.add_argument(
        "--since",
        type=int,
        default=DEFAULT_SINCE_DAYS,
        help="days of history to keep, default %d" % DEFAULT_SINCE_DAYS,
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print one JSON object per session, with the summary on stderr",
    )
    args = parser.parse_args(list(argv))

    if args.limit < 1:
        parser.error("--limit must be at least 1")
    if args.since < 0:
        parser.error("--since must be 0 or more days")

    home_env = os.environ.get("GROK_HOME", "")
    home_raw = args.home if args.home else (home_env if home_env else "~/.grok")
    home = os.path.abspath(os.path.expanduser(home_raw))
    repo = os.path.abspath(os.path.expanduser(args.repo if args.repo else os.getcwd()))
    return run(
        home,
        repo,
        args.limit,
        args.since,
        args.json,
        sys.stdout,
        sys.stderr,
        datetime.now(timezone.utc),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
