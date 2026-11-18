#!/usr/bin/env python3
"""Unit tests for scripts/lib/parse_json.py, the JSON payload gate.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

parse_json.py is what scripts/validate.sh runs over every Grafana dashboard and over
the generated Spark file-SD document, so the contract under test is the exit code, the
one stderr line a failure prints, and silence on success. "Is it JSON" is not enough
there: the file provider hands Grafana no schema, so a document that parses but is not
a dashboard, or one whose title is blank, is a panel that silently never appears in the
folder listing. Both are rejected here, so both are asserted here. scripts/lib is not a
package, so the module is loaded by file path with importlib; the shipped ``__main__``
guard is a path the CLIs actually take, so it is executed with runpy and as its own
subprocess rather than skipped.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import pathlib
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from collections.abc import Iterator

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_LIB = REPO_ROOT / "scripts" / "lib"
SCRIPT = SCRIPTS_LIB / "parse_json.py"

PROGRAM = "parse_json.py"
USAGE = "usage: parse_json.py FILE [FILE...]\n"

# One dashboard as the folder listing wants it, and one file-SD target set as the
# generator prints it. They are written as text, not built with json.dumps, so the
# bytes the helper reads are exactly the bytes this file says they are.
DASHBOARD = '{"title": "Host", "panels": [{"id": 1}], "schemaVersion": 39}\n'
# The shape //scripts:spark-monitor --targets actually prints: one object per scrape
# group, every one stamped with the three labels the rule files and the four Prometheus
# jobs depend on. An operator hand-edit that drops one of them is the failure this gate
# exists to catch, because the box then vanishes from the dashboards silently.
FILE_SD = (
    '[{"targets": ["spark-1.lan:9100"], "labels": '
    '{"box": "spark-1", "exporter": "node_exporter", "hostname": "spark-1.lan"}}]\n'
)
FILE_SD_NO_LABELS = '[{"targets": ["spark-1.lan:9100"]}, {"targets": ["x:9400"]}]\n'
FILE_SD_EMPTY = "[]\n"

_module_ids = itertools.count()


def load_helper(stem: str) -> types.ModuleType:
    """Import one scripts/lib helper by file path.

    Args:
        stem: Module name without suffix, which is also the file name.

    Returns:
        A freshly executed module under a unique name, so repeated loads never share
        state and never collide in ``sys.modules``.
    """
    path = SCRIPTS_LIB / f"{stem}.py"
    name = f"{stem}_under_test_{next(_module_ids)}"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def temp_dir() -> Iterator[pathlib.Path]:
    """Yield a scratch directory that is removed when the test ends."""
    with tempfile.TemporaryDirectory() as tmp:
        yield pathlib.Path(tmp)


def run_guard(path: pathlib.Path, argv: list[str]) -> tuple[int, str, str]:
    """Execute the helper the way the shell does: as ``__main__`` with argv.

    Args:
        path: The helper file to run.
        argv: ``sys.argv`` the program sees, program name first.

    Returns:
        ``(exit_code, stdout, stderr)`` from the guard's ``sys.exit(main(argv))``.
    """
    out, err = io.StringIO(), io.StringIO()
    saved_argv = sys.argv
    sys.argv = argv
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            runpy.run_path(str(path), run_name="__main__")
    except SystemExit as exc:
        if not isinstance(exc.code, int):
            raise AssertionError(
                f"{path.name} exited with {exc.code!r}, not an int"
            ) from exc
        return exc.code, out.getvalue(), err.getvalue()
    finally:
        sys.argv = saved_argv
    raise AssertionError(f"{path.name} ran as __main__ without calling sys.exit()")


def run_subprocess(argv: list[str]) -> tuple[int, str, str]:
    """Run the helper as its own process, the way scripts/validate.sh invokes it.

    Args:
        argv: The program's argv, script path first (after the interpreter).

    Returns:
        ``(exit_code, stdout, stderr)``.
    """
    proc = subprocess.run(
        [sys.executable, *argv], capture_output=True, text=True, check=False
    )
    return proc.returncode, proc.stdout, proc.stderr


class HelperCase(unittest.TestCase):
    """Shared wiring: a freshly loaded helper and one scratch directory."""

    def setUp(self) -> None:
        self.mod = load_helper("parse_json")
        self.addCleanup(sys.modules.pop, self.mod.__name__, None)
        self.dir = self.enterContext(temp_dir())

    def file(self, name: str, text: str) -> pathlib.Path:
        """Write one payload into the scratch directory and return its path."""
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return path

    def check(self, target: object) -> str | None:
        """Call the helper's check(), held to the return type it documents."""
        reason = self.mod.check(str(target))
        return None if reason is None else str(reason)

    def call_argv(self, argv: list[str]) -> tuple[int, str, str]:
        """Call main() with a verbatim argv and capture what it writes."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.mod.main(argv)
        return int(code), out.getvalue(), err.getvalue()

    def call(self, *paths: object) -> tuple[int, str, str]:
        """Call main() the way the CLI does, with the files starting at slot 1."""
        return self.call_argv([PROGRAM, *[str(path) for path in paths]])


class CheckReasonTests(HelperCase):
    """check() returns a one-line reason for an unusable payload, None for a good one."""

    def test_a_dashboard_that_carries_every_field_it_needs_is_fine(self) -> None:
        # Covers: the load succeeds, the document is an object, a printable title,
        # panels and targets both present and both lists, and the None return.
        good = self.file(
            "dash.json",
            '{"title": "Host", "panels": [{"id": 1}], "targets": ["a:9100"], '
            '"templating": {"list": []}}\n',
        )
        self.assertIsNone(self.check(good))

    def test_a_generated_file_sd_object_needs_no_title(self) -> None:
        # Only dashboards carry a title: requiring one on a target document would
        # reject a file the stack itself generates.
        sd = self.file("sd-object.json", '{"targets": ["spark-1.lan:9100"]}\n')
        self.assertIsNone(self.check(sd))

    def test_a_document_that_is_not_json_at_all_names_the_parse_position(self) -> None:
        bad = self.file("bad.json", "{not json\n")
        reason = self.check(bad)
        self.assertIsNotNone(reason)
        assert reason is not None
        self.assertTrue(reason.startswith(f"{bad}: "), reason)
        self.assertIn("line 1", reason)

    def test_an_empty_file_is_a_failure_rather_than_an_empty_document(self) -> None:
        empty = self.file("empty.json", "")
        reason = self.check(empty)
        self.assertTrue(reason is not None and reason.startswith(f"{empty}: "), reason)
        assert reason is not None
        self.assertIn("line 1", reason)

    def test_a_file_of_only_whitespace_is_the_same_failure(self) -> None:
        # Trailing newlines move the parser's position, so this one asserts the
        # parser spoke about the value rather than the exact column.
        blank = self.file("blank.json", "  \n\t\n")
        reason = self.check(blank)
        self.assertTrue(reason is not None and reason.startswith(f"{blank}: "), reason)
        assert reason is not None
        self.assertIn("Expecting value", reason)

    def test_a_missing_file_is_reported_as_an_oserror(self) -> None:
        gone = self.dir / "gone.json"
        reason = self.check(gone)
        self.assertIsNotNone(reason)
        assert reason is not None
        self.assertTrue(reason.startswith(f"{gone}: "), reason)
        self.assertIn("No such file or directory", reason)

    def test_a_directory_is_reported_as_an_error_not_a_crash(self) -> None:
        reason = self.check(self.dir)
        self.assertIsNotNone(reason)
        assert reason is not None
        self.assertTrue(reason.startswith(f"{self.dir}: "), reason)

    def test_the_generated_file_sd_array_is_accepted(self) -> None:
        # scripts/validate.sh feeds this helper the generated file-SD document whenever
        # a host has enrolled a Spark, and that document is a top-level array
        # (scripts/spark-monitor.sh, the printf at the end of the --targets block). A
        # correctly stamped document has to pass or every enrolled host fails validate.
        self.assertIsNone(self.check(self.file("sd.json", FILE_SD)))

    def test_an_empty_file_sd_array_is_the_unenrolled_fleet_and_passes(self) -> None:
        # SPARK_MONITOR_ENABLED=false prints [], which is the shipped default state.
        self.assertIsNone(self.check(self.file("sd-empty.json", FILE_SD_EMPTY)))

    def test_a_group_without_the_join_labels_is_refused(self) -> None:
        # spark.rules.yml groups by hostname and the four jobs keep on exporter, so a
        # group that lost its labels is a box that reads as absent rather than broken.
        sd = self.file("sd-nolabels.json", FILE_SD_NO_LABELS)
        reason = self.check(sd)
        assert reason is not None
        self.assertIn("group 0", reason)
        self.assertIn("box/exporter/hostname", reason)

    def test_a_group_is_refused_for_each_broken_shape_it_can_have(self) -> None:
        cases = (
            ("[7]\n", "group 0 is int, expected an object"),
            (
                '[{"labels": {"box": "b", "exporter": "dcgm", "hostname": "h"}}]\n',
                "has no targets",
            ),
            (
                '[{"targets": "spark-1.lan:9100", "labels": {"box": "b", "exporter": "dcgm", "hostname": "h"}}]\n',
                "targets is str, expected a list",
            ),
            (
                '[{"targets": [], "labels": "nope"}]\n',
                "labels is str, expected an object",
            ),
            (
                '[{"targets": ["a:9100"], "labels": {"box": "b", "exporter": "  ", "hostname": "h"}}]\n',
                "missing exporter",
            ),
        )
        for index, (body, needle) in enumerate(cases):
            with self.subTest(body=body):
                reason = self.check(self.file(f"sd-bad-{index}.json", body))
                self.assertIsNotNone(reason)
                assert reason is not None
                self.assertIn(needle, reason)

    def test_a_top_level_scalar_names_its_python_type(self) -> None:
        for body, kind in (
            ("null\n", "NoneType"),
            ('"text"\n', "str"),
            ("7\n", "int"),
            ("true\n", "bool"),
            ("1.5\n", "float"),
        ):
            scalar = self.file(f"scalar-{kind}.json", body)
            with self.subTest(body=body):
                self.assertEqual(
                    f"{scalar}: top level is {kind}, expected an object or a list",
                    self.check(scalar),
                )

    def test_a_title_that_is_present_but_blank_never_lists(self) -> None:
        for label, value in (
            ("empty", '""'),
            ("spaces", '"   "'),
            ("tabs", '"\\t \\n"'),
        ):
            titled = self.file(f"title-{label}.json", '{"title": %s}\n' % value)
            with self.subTest(title=value):
                self.assertEqual(
                    f"{titled}: title is present but empty, so the page never lists",
                    self.check(titled),
                )

    def test_a_title_that_is_not_a_string_is_judged_by_what_it_prints(self) -> None:
        # The check reads str(title).strip(), so a number lists fine and only
        # something that renders as nothing is refused.
        numbered = self.file("numbered.json", '{"title": 7, "panels": []}\n')
        self.assertIsNone(self.check(numbered))
        zero = self.file("zero.json", '{"title": 0}\n')
        self.assertIsNone(self.check(zero))

    def test_panels_must_be_a_list_when_it_is_there(self) -> None:
        for value, kind in (("{}", "dict"), ('"nope"', "str"), ("null", "NoneType")):
            dash = self.file(
                f"panels-{kind}.json", '{"title": "Host", "panels": %s}\n' % value
            )
            with self.subTest(panels=value):
                self.assertEqual(
                    f"{dash}: panels is {kind}, expected a list", self.check(dash)
                )

    def test_targets_must_be_a_list_when_it_is_there(self) -> None:
        for value, kind in (("{}", "dict"), ('"nope"', "str"), ("7", "int")):
            doc = self.file(f"targets-{kind}.json", '{"targets": %s}\n' % value)
            with self.subTest(targets=value):
                self.assertEqual(
                    f"{doc}: targets is {kind}, expected a list", self.check(doc)
                )

    def test_the_panel_check_reports_before_the_targets_check(self) -> None:
        # Both fields are broken; the reason the operator gets is the first one,
        # which is what pins the order the checks run in.
        both = self.file("both.json", '{"panels": {}, "targets": {}}\n')
        self.assertEqual(f"{both}: panels is dict, expected a list", self.check(both))


class MainTests(HelperCase):
    """main(argv): 0 and silence, or 1 and the first reason on stderr."""

    def test_no_file_argument_prints_the_usage_and_exits_one(self) -> None:
        self.assertEqual((1, "", USAGE), self.call_argv([PROGRAM]))

    def test_one_usable_file_exits_zero_without_printing(self) -> None:
        good = self.file("dash.json", DASHBOARD)
        self.assertEqual((0, "", ""), self.call(good))

    def test_every_file_in_the_list_is_checked(self) -> None:
        first = self.file("a.json", DASHBOARD)
        second = self.file("b.json", '{"title": "Containers", "panels": []}\n')
        third = self.file("sd-object.json", '{"targets": ["spark-2.lan:9400"]}\n')
        self.assertEqual((0, "", ""), self.call(first, second, third))

    def test_slot_zero_is_the_program_name_and_is_never_opened(self) -> None:
        # The comment at parse_json.py:43 promises argv[0] is skipped; naming a file
        # that does not exist there proves it never reaches the reader.
        good = self.file("dash.json", DASHBOARD)
        self.assertEqual(
            (0, "", ""), self.call_argv([str(self.dir / "nope.json"), str(good)])
        )

    def test_the_first_unusable_file_stops_the_sweep(self) -> None:
        good = self.file("a.json", DASHBOARD)
        bad = self.file("b.json", "{oops\n")
        worse = self.file("c.json", "[1,\n")
        code, out, err = self.call(good, bad, worse)
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertEqual(
            [
                f"parse_json: {bad}: Expecting property name enclosed in "
                f"double quotes: line 1 column 2 (char 1)"
            ],
            err.splitlines(),
        )
        self.assertNotIn(str(worse), err)

    def test_a_rejected_dashboard_prints_one_prefixed_line(self) -> None:
        dash = self.file("dash.json", '{"title": "  ", "panels": []}\n')
        self.assertEqual(
            (
                1,
                "",
                f"parse_json: {dash}: title is present but empty, so the page "
                "never lists\n",
            ),
            self.call(dash),
        )

    def test_a_missing_file_exits_one_and_names_itself(self) -> None:
        gone = self.dir / "gone.json"
        code, out, err = self.call(gone)
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertTrue(err.startswith(f"parse_json: {gone}: "), err)
        self.assertEqual(1, len(err.splitlines()))


class ProgramTests(HelperCase):
    """The shipped entry point: the guard in-process, and the CLI as its own process."""

    def test_run_as_a_program_it_exits_zero_in_silence(self) -> None:
        good = self.file("dash.json", DASHBOARD)
        self.assertEqual((0, "", ""), run_guard(SCRIPT, [str(SCRIPT), str(good)]))

    def test_run_as_a_program_it_exits_one_with_the_reason(self) -> None:
        bad = self.file(
            "bad.json", '[{"targets": ["a:9100"], "labels": {"box": "b"}}]\n'
        )
        code, out, err = run_guard(SCRIPT, [str(SCRIPT), str(bad)])
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertIn("parse_json:", err)
        self.assertIn("missing exporter/hostname", err)

    def test_run_as_a_program_it_accepts_the_generated_file_sd_document(self) -> None:
        # The invocation scripts/validate.sh makes once a Spark is enrolled: a top-level
        # array of stamped groups must exit 0, or every enrolled host fails the gate.
        good = self.file("sd.json", FILE_SD)
        self.assertEqual((0, "", ""), run_guard(SCRIPT, [str(SCRIPT), str(good)]))

    def test_run_as_a_program_with_no_argument_prints_the_usage(self) -> None:
        self.assertEqual((1, "", USAGE), run_guard(SCRIPT, [str(SCRIPT)]))

    def test_the_invocation_the_validator_makes_exits_zero(self) -> None:
        # scripts/validate.sh:109 passes every dashboard it globs as separate argv
        # slots, which is the shape the operator CLIs actually use.
        dash = self.file("dash.json", DASHBOARD)
        other = self.file("home.json", '{"title": "Home", "panels": []}\n')
        self.assertEqual(
            (0, "", ""), run_subprocess([str(SCRIPT), str(dash), str(other)])
        )

    def test_the_invocation_the_validator_makes_exits_one_once(self) -> None:
        good = self.file("dash.json", DASHBOARD)
        bad = self.file("bad.json", '{"title": "Host", "panels": {}}\n')
        code, out, err = run_subprocess([str(SCRIPT), str(good), str(bad)])
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertEqual(
            [f"parse_json: {bad}: panels is dict, expected a list"], err.splitlines()
        )

    def test_the_invocation_with_no_argument_prints_the_usage(self) -> None:
        self.assertEqual((1, "", USAGE), run_subprocess([str(SCRIPT)]))

    def test_a_relative_path_resolves_against_the_caller_directory(self) -> None:
        # The validator runs from the repo root and passes relative paths; a helper
        # that resolved them somewhere else would report a file it never opened.
        rel = "dash.json"
        self.file(rel, DASHBOARD)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), rel],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(self.dir),
        )
        self.assertEqual((0, "", ""), (proc.returncode, proc.stdout, proc.stderr))


if __name__ == "__main__":
    unittest.main()
