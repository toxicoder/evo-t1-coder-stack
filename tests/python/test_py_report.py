#!/usr/bin/env python3
"""Unit tests for tests/coverage/py_report.py, the Python coverage floor.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

py_report.py decides whether "the Python suites are green" means anything: it names every
shipped module the gate owes and fails on the ones the report has nothing to say about.
Its denominator is read out of the runfiles tree, so the interesting failures are the
ones where the tree it was handed is smaller than the tree it was promised -- a data edge
that lost a label, a directory that arrived empty. Both used to shrink the floor in
silence.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import pathlib
import shutil
import sys
import tempfile
import types
import unittest
from collections.abc import Callable
from typing import Final, cast

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

_module_ids = itertools.count()


def load_reporter() -> types.ModuleType:
    """Import tests/coverage/py_report.py by path under a throwaway name.

    tests/ is not a package and the shell driver runs the file as a program, so the suite
    loads it the way the interpreter would.
    """
    path = REPO_ROOT / "tests" / "coverage" / "py_report.py"
    name = "py_report_under_test_%d" % next(_module_ids)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


REPORTER = load_reporter()

expected_modules: Final = cast(
    "Callable[[pathlib.Path, list[str]], list[str]]", REPORTER.expected_modules
)


class ExpectedModulesTest(unittest.TestCase):
    """What the floor is measured over, and what makes that list too short."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def write(self, rel: str, body: str = "x = 1\n") -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")

    def expected(self, *dirs: str) -> list[str]:
        return expected_modules(self.root, list(dirs))

    def test_it_names_every_shipped_module_repo_relative(self) -> None:
        self.write("scripts/lib/one.py")
        self.write("scripts/lib/deep/two.py")
        self.write("litellm/three.py")
        self.assertEqual(
            ["litellm/three.py", "scripts/lib/deep/two.py", "scripts/lib/one.py"],
            sorted(self.expected("scripts/lib", "litellm")),
        )

    def test_the_suites_themselves_are_not_part_of_the_floor(self) -> None:
        # The suites are Python too; charging them the floor would let a suite raise its
        # own coverage and call the module it tests covered.
        self.write("scripts/lib/helper.py")
        self.write("scripts/lib/test_helper.py")
        self.write("scripts/lib/conftest.py")
        self.write("scripts/lib/__init__.py")
        self.assertEqual(["scripts/lib/helper.py"], self.expected("scripts/lib"))

    def test_a_missing_directory_fails_loudly(self) -> None:
        self.write("scripts/lib/one.py")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as held:
            self.expected("scripts/lib", "litellm")
        self.assertEqual(2, held.exception.code)
        self.assertIn("litellm", errors.getvalue())

    def test_a_directory_that_ships_no_module_is_not_an_empty_floor(self) -> None:
        # The shape one dropped srcs entry leaves behind: the directory is there, the
        # file it holds is not in runfiles, and a denominator that quietly omits it turns
        # "we never executed that module" into a passing gate.
        self.write("scripts/lib/one.py")
        self.write("litellm/test_only_a_suite_lives_here.py")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as held:
            self.expected("scripts/lib", "litellm")
        self.assertEqual(2, held.exception.code)
        self.assertIn("litellm", errors.getvalue())
        self.assertIn("no module", errors.getvalue())

    def test_a_directory_of_nothing_at_all_is_the_same_failure(self) -> None:
        self.write("scripts/lib/one.py")
        (self.root / "litellm").mkdir()
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as held:
            self.expected("litellm")
        self.assertEqual(2, held.exception.code)
        self.assertIn("no module", errors.getvalue())

    def test_the_runfiles_symlink_shape_yields_the_same_list(self) -> None:
        # Under bazelisk test the expected directory is a symlink into the checkout, and
        # a walk that did not follow it would name nothing.
        real = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, real, True)
        (real / "mod.py").write_text("x = 1\n", encoding="utf-8")
        self.root.mkdir(exist_ok=True)
        link = self.root / "litellm"
        link.symlink_to(real, target_is_directory=True)
        self.assertEqual(["litellm/mod.py"], self.expected("litellm"))


if __name__ == "__main__":
    unittest.main()
