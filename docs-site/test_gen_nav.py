#!/usr/bin/env python3
"""Unit tests for the nav generator (docs-site/scripts/gen_nav.py).

Run: bazelisk test //docs-site:nav_test   (or: python3 -m unittest -v test_gen_nav.py)

The generator writes the tree the sidebar and the prev/next footer are built from, and
``npm run nav:check`` is what keeps the committed file from drifting. These tests pin the
tree shape, the on-disk validation, and the drift check itself.
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import runpy
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "scripts"))

import gen_nav  # noqa: E402


class ToTreeTests(unittest.TestCase):
    """The declaration converts into the tab/page layout the site imports."""

    def test_tabs_and_pages_keep_declaration_order(self) -> None:
        tabs = gen_nav.to_tree([("Start", [("Overview", "index.mdx")]), ("Operate", [("Dash", "dashboard.md")])])
        self.assertEqual(["Start", "Operate"], [tab["title"] for tab in tabs])
        self.assertEqual(["index.mdx"], [p["path"] for p in tabs[0]["pages"]])
        self.assertEqual("Dash", tabs[1]["pages"][0]["title"])

    def test_serialize_is_stable_and_trailing_newline(self) -> None:
        tabs = gen_nav.to_tree(gen_nav.NAV)
        first = gen_nav.serialize(tabs)
        self.assertEqual(first, gen_nav.serialize(tabs))
        # The tree is a list of tabs, so the file ends with the array close, not an object.
        self.assertTrue(first.endswith("]\n"))

    def test_the_shipped_tree_is_valid_json(self) -> None:
        tabs = json.loads(gen_nav.serialize(gen_nav.to_tree(gen_nav.NAV)))
        self.assertTrue(all(tab["pages"] for tab in tabs), "a tab with no pages renders an empty sidebar")

    def test_serialize_keeps_non_ascii_text_verbatim(self) -> None:
        # ensure_ascii=False is what keeps the committed file readable by a human.
        text = gen_nav.serialize(gen_nav.to_tree([("Start", [("Caf\u00e9 setup", "index.mdx")])]))
        self.assertIn("Caf\u00e9 setup", text)
        self.assertNotIn("\\u00e9", text)


class ValidateTests(unittest.TestCase):
    """The tree is checked against the files that actually exist."""

    def test_every_declared_page_resolves_on_disk(self) -> None:
        self.assertEqual([], gen_nav.validate(gen_nav.to_tree(gen_nav.NAV)))

    def test_a_missing_page_is_reported(self) -> None:
        problems = gen_nav.validate(gen_nav.to_tree([("Start", [("Nope", "nope.md")])]))
        self.assertEqual(["nav page missing on disk: docs/nope.md"], problems)

    def test_an_mdx_page_declared_as_markdown_still_resolves(self) -> None:
        self.assertEqual([], gen_nav.validate(gen_nav.to_tree([("Start", [("Home", "index.md")])])))

    def test_a_page_listed_twice_is_reported(self) -> None:
        problems = gen_nav.validate(
            gen_nav.to_tree([("Start", [("A", "index.mdx")]), ("Again", [("A", "index.mdx")])])
        )
        self.assertEqual(["nav page listed twice: docs/index.mdx"], problems)


class MainTests(unittest.TestCase):
    """--check passes on the committed file and fails when it drifts."""

    def test_check_passes_on_the_committed_file(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gen_nav.main(["--check"]))

    def test_check_fails_when_the_committed_file_is_stale(self) -> None:
        committed = gen_nav.OUT_JSON
        with tempfile.TemporaryDirectory() as tmp:
            stale = pathlib.Path(tmp) / "nav.json"
            stale.write_text("[]\n", encoding="utf-8")
            gen_nav.OUT_JSON = stale
            try:
                with contextlib.redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(1, gen_nav.main(["--check"]))
                self.assertIn("stale", err.getvalue())
            finally:
                gen_nav.OUT_JSON = committed

    def test_check_fails_when_a_declared_page_vanishes(self) -> None:
        declared = gen_nav.NAV
        gen_nav.NAV = [("Start", [("Nope", "definitely-not-a-page.md")])]
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(1, gen_nav.main(["--check"]))
        finally:
            gen_nav.NAV = declared


class WriteTests(unittest.TestCase):
    """Without --check the generator writes the tree out and says what it wrote."""

    def setUp(self) -> None:
        self.saved = (gen_nav.REPO_ROOT, gen_nav.OUT_JSON)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        gen_nav.REPO_ROOT = self.root
        gen_nav.OUT_JSON = self.root / "docs-site" / "lib" / "nav.json"

    def tearDown(self) -> None:
        gen_nav.REPO_ROOT, gen_nav.OUT_JSON = self.saved
        self.tmp.cleanup()

    @staticmethod
    def _run(argv: list[str]) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gen_nav.main(argv)
        return code, out.getvalue()

    @staticmethod
    def _payload() -> str:
        return gen_nav.serialize(gen_nav.to_tree(gen_nav.NAV))

    def test_a_missing_file_is_written_creating_its_parent_dirs(self) -> None:
        self.assertFalse(gen_nav.OUT_JSON.exists())
        code, stdout = self._run([])
        self.assertEqual(0, code)
        self.assertEqual(self._payload(), gen_nav.OUT_JSON.read_text(encoding="utf-8"))
        tabs = len(gen_nav.NAV)
        pages = sum(len(pages_of_tab) for _, pages_of_tab in gen_nav.NAV)
        self.assertEqual(f"wrote docs-site/lib/nav.json ({tabs} tabs, {pages} pages)\n", stdout)

    def test_a_write_replaces_whatever_was_there(self) -> None:
        gen_nav.OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
        gen_nav.OUT_JSON.write_text("[]\n", encoding="utf-8")
        self.assertEqual(0, self._run([])[0])
        self.assertEqual(self._payload(), gen_nav.OUT_JSON.read_text(encoding="utf-8"))

    def test_a_file_this_wrote_needs_no_fix_up(self) -> None:
        self._run([])
        code, stdout = self._run(["--check"])
        self.assertEqual((0, "nav.json is up to date.\n"), (code, stdout))

    def test_check_without_any_file_on_disk_is_stale_and_writes_nothing(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(1, gen_nav.main(["--check"]))
        self.assertIn("stale", err.getvalue())
        self.assertFalse(gen_nav.OUT_JSON.exists())

    def test_a_validation_problem_is_reported_before_any_write(self) -> None:
        declared = gen_nav.NAV
        gen_nav.NAV = [("Start", [("Nope", "definitely-not-a-page.md")])]
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(1, gen_nav.main([]))
        finally:
            gen_nav.NAV = declared
        self.assertEqual("nav problem: nav page missing on disk: docs/definitely-not-a-page.md\n", err.getvalue())
        self.assertFalse(gen_nav.OUT_JSON.exists())


class GuardTests(unittest.TestCase):
    """The script run as a program exits with the verdict main() returns."""

    def test_the_script_exits_zero_on_a_current_committed_file(self) -> None:
        # --check only, so the guard cannot rewrite the committed nav.json here.
        out = io.StringIO()
        saved_argv = sys.argv
        sys.argv = ["docs-site/scripts/gen_nav.py", "--check"]
        try:
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(pathlib.Path(gen_nav.__file__)), run_name="__main__")
        finally:
            sys.argv = saved_argv
        self.assertEqual(0, caught.exception.code)
        self.assertEqual("nav.json is up to date.\n", out.getvalue())


if __name__ == "__main__":
    unittest.main()
