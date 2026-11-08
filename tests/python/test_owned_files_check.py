#!/usr/bin/env python3
"""Unit tests for tests/owned_files_check.py, the tracked-file ownership gate.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

tests/bats/owned_files.bats pins the CLI a build sees: the exit code, the summary
line, and which UNOWNED strings appear. This file pins the three pure decisions
underneath that CLI, where a regression is cheapest to name: `label_to_path`
(the root package has no package directory, and getting it wrong makes almost
every file look unowned), `is_control_plane` (too broad and the gate exempts the
tree it is supposed to measure), and `assess` (the buckets must sum to the
tracked count, which is what stops ledger files being counted as target-owned).
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import tempfile
import sys
import types
import unittest
from collections.abc import Sequence
from typing import Protocol, cast

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_module() -> types.ModuleType:
    """Import tests/owned_files_check.py by path, the way the Bats suite runs it."""
    path = REPO_ROOT / "tests" / "owned_files_check.py"
    spec = importlib.util.spec_from_file_location("owned_files_check", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["owned_files_check"] = module
    spec.loader.exec_module(module)
    return module


CHECKER = load_module()


class LedgerEntry(Protocol):
    """One parsed ledger line, as read_ledger builds it and assess consumes it."""

    regex: re.Pattern[str]
    pattern: str
    reason: str


class Finding(Protocol):
    """One unowned file, carrying the rule that refused it."""

    path: str
    why: str


class Report(Protocol):
    """The buckets assess returns, and the sum every test re-checks."""

    tracked: int
    target_owned: int
    control_plane: int
    excluded: int
    stale: tuple[str, ...]
    unowned: tuple[Finding, ...]


def entry(pattern: str, reason: str) -> LedgerEntry:
    """Build a ledger Entry the way read_ledger would, for assess() to consume."""
    return cast(
        LedgerEntry,
        CHECKER.Entry(
            regex=re.compile("^" + re.escape(pattern).replace(r"\*", ".*") + "$"),
            pattern=pattern,
            reason=reason,
        ),
    )


def assess(tracked: Sequence[str], owned: Sequence[str], **kwargs: object) -> Report:
    """Bucket `tracked` against `owned`, defaulting to no ignores and no ledger."""
    return cast(
        Report,
        CHECKER.assess(
            list(tracked),
            set(owned),
            kwargs.get("ignored", set()),
            kwargs.get("ledger", []),
            strict_ledger=bool(kwargs.get("strict_ledger", False)),
        ),
    )


class LabelToPathTest(unittest.TestCase):
    """The mapping every other decision depends on."""

    def test_package_label_maps_to_its_directory(self) -> None:
        self.assertEqual(CHECKER.label_to_path("//scripts:run.sh"), "scripts/run.sh")

    def test_root_package_label_has_no_leading_slash(self) -> None:
        # The classic bug: replacing ':' with '/' turns //:file into /file, so every
        # root file lands in the unowned bucket and the gate looks red for no reason.
        self.assertEqual(CHECKER.label_to_path("//:README.md"), "README.md")

    def test_labels_outside_this_repo_are_not_repo_paths(self) -> None:
        # External-repo labels are dropped on purpose: //tests:bats_tool pulls bats from
        # @bats_core, and its files are never in `git ls-files`, so mapping them would
        # invent owners for paths this repo does not track.
        self.assertEqual(CHECKER.label_to_path("@@//litellm:config.yaml"), "litellm/config.yaml")
        self.assertIsNone(CHECKER.label_to_path("@rules_shell//shell:sh_test.bzl"))

    def test_a_label_without_a_name_is_not_a_path(self) -> None:
        self.assertIsNone(CHECKER.label_to_path("//scripts"))
        self.assertIsNone(CHECKER.label_to_path("//scripts:"))
        self.assertIsNone(CHECKER.label_to_path("scripts:run.sh"))


class ControlPlaneTest(unittest.TestCase):
    """What the gate may excuse without a ledger entry, and what it may not."""

    def test_bazel_configuration_is_control_plane(self) -> None:
        for path in (".bazelrc", ".bazelversion", "MODULE.bazel", ".bazelignore", "REPO.bazel"):
            self.assertTrue(CHECKER.is_control_plane(path), path)

    def test_every_packages_build_file_is_control_plane(self) -> None:
        for path in ("BUILD.bazel", "docs/BUILD.bazel", "tests/BUILD", "docs-site/BUILD.bazel"):
            self.assertTrue(CHECKER.is_control_plane(path), path)

    def test_a_payload_file_that_mimics_the_control_plane_is_not_exempt(self) -> None:
        # A file merely living beside a BUILD file has to stay measurable, or one
        # misplaced directory would hide a whole subtree from the gate.
        self.assertFalse(CHECKER.is_control_plane("docs/notes.md"))
        self.assertFalse(CHECKER.is_control_plane("litellm/config.yaml"))
        self.assertFalse(CHECKER.is_control_plane("proxy/BUILDING.md"))


class AssessTest(unittest.TestCase):
    """The bucketing, and the sum that keeps it honest."""

    def test_every_bucket_sums_to_the_tracked_count(self) -> None:
        report = assess(
            ["README.md", "MODULE.bazel", "Makefile", "orphan.txt"],
            ["README.md"],
            ledger=[entry("Makefile", "shim that forwards to //:targets")],
        )
        self.assertEqual(report.tracked, 4)
        self.assertEqual(report.target_owned, 1)
        self.assertEqual(report.control_plane, 1)
        self.assertEqual(report.excluded, 1)
        self.assertEqual(len(report.unowned), 1)
        total = report.target_owned + report.control_plane + report.excluded + len(report.unowned)
        self.assertEqual(total, report.tracked)

    def test_an_unowned_finding_names_the_file_and_the_rule(self) -> None:
        report = assess(["orphan.txt"], [])
        self.assertEqual(report.unowned[0].path, "orphan.txt")
        self.assertIn("no ledger entry covers it", report.unowned[0].why)

    def test_a_ledger_entry_without_a_reason_is_a_finding(self) -> None:
        report = assess(["Makefile"], [], ledger=[entry("Makefile", "")])
        self.assertEqual(report.excluded, 0)
        self.assertIn("carries no reason", report.unowned[0].why)

    def test_an_ignored_directory_lands_in_control_plane(self) -> None:
        report = assess(["proxy/certs/stack.crt"], [], ignored={"proxy/certs"})
        self.assertEqual(report.control_plane, 1)
        self.assertEqual(len(report.unowned), 0)

    def test_an_ignored_prefix_is_not_a_substring_match(self) -> None:
        # proxy/certs must not excuse proxy/certificates/, which is a real payload
        # directory one character away from being silently exempt.
        report = assess(["proxy/certificates/stack.crt"], [], ignored={"proxy/certs"})
        self.assertEqual(len(report.unowned), 1)

    def test_a_stale_entry_is_counted_and_only_strict_mode_fails_on_it(self) -> None:
        stale = entry("gone.txt", "deleted with its target")
        loose = assess(["README.md"], ["README.md"], ledger=[stale])
        self.assertEqual(loose.stale, ("gone.txt",))
        self.assertEqual(len(loose.unowned), 0)

        strict = assess(["README.md"], ["README.md"], ledger=[stale], strict_ledger=True)
        self.assertEqual(len(strict.unowned), 1)
        self.assertIn("matches nothing", strict.unowned[0].why)

    def test_an_entry_that_matched_is_never_reported_stale(self) -> None:
        report = assess(["Makefile"], [], ledger=[entry("Makefile", "shim")])
        self.assertEqual(report.stale, ())


class ReadLedgerTest(unittest.TestCase):
    """The ledger file format, which is where an exemption is granted."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory(prefix="owned-files-ledger-")
        self.addCleanup(self._tmpdir.cleanup)

    def write(self, body: str) -> str:
        path = pathlib.Path(self._tmpdir.name) / "unowned-files.txt"
        path.write_text(body, encoding="utf-8")
        return str(path)

    def test_comments_blanks_and_both_separators_are_honoured(self) -> None:
        path = self.write("# a comment\n\nMakefile\tshim\nREADME.md  prose\n")
        entries = CHECKER.read_ledger(path)
        self.assertEqual([e.pattern for e in entries], ["Makefile", "README.md"])
        self.assertEqual(entries[0].reason, "shim")
        self.assertEqual(entries[1].reason, "prose")

    def test_a_single_space_does_not_split_pattern_from_reason(self) -> None:
        # If it did, `.vscode/tasks.json editor convenience` would register a pattern
        # that matches nothing and the real file would stay unowned.
        path = self.write(".vscode/tasks.json editor convenience\n")
        entries = CHECKER.read_ledger(path)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].pattern, ".vscode/tasks.json editor convenience")
        self.assertEqual(entries[0].reason, "")

    def test_a_glob_pattern_matches_a_whole_directory(self) -> None:
        path = self.write(".vscode/*\teditor convenience\n")
        entries = CHECKER.read_ledger(path)
        self.assertTrue(entries[0].regex.match(".vscode/tasks.json"))
        self.assertIsNone(entries[0].regex.match("Makefile"))

    def test_a_missing_ledger_is_empty_and_not_an_error(self) -> None:
        self.assertEqual(CHECKER.read_ledger(str(REPO_ROOT / "no-such-ledger.txt")), [])


if __name__ == "__main__":
    unittest.main()
