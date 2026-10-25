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


if __name__ == "__main__":
    unittest.main()
