#!/usr/bin/env python3
"""Unit tests for tests/bazel_deps.py, the Bazel data-map gate.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

tests/bazel_deps.py is a `main(argv)` CLI that scans the tree and prints one line per
finding, so the contract under test is the one the Bats gate sees: the exit code, the
summary line, and which finding strings appear. The pure scanners (token matcher, line
filter, Starlark reader) are exercised against small strings, and the three checks run
against a fixture tree in a tmpdir, so a broken map can be demonstrated without
touching the repo. The `if __name__ == "__main__"` guard is a shipped code path (the
Bats suite runs the file directly), so it is executed with runpy rather than skipped.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import pathlib
import runpy
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "tests" / "bazel_deps.py"

_module_ids = itertools.count()

# The groups //:stack_data aggregates; a fixture that satisfies check_aggregate lists
# all of them, which is the same list the checker keeps as its expectation.
STACK_DATA_LABELS = [
    "//:compose_file",
    "//:devcontainer",
    "//:env_example",
    "//:env_sample",
    "//:githooks",
    "//:license",
    "//:templates_payload",
    "//hermes:payload",
    "//homepage:payload",
    "//images/dev:context",
    "//litellm:config",
    "//proxy:confs",
    "//searxng:settings",
]


def load_checker() -> object:
    """Import tests/bazel_deps.py by path under a throwaway name.

    tests/ is not a package and the Bats gate runs the file as a script, so the test
    loads it the way the interpreter would rather than import a package that is not
    there.
    """
    name = f"bazel_deps_under_test_{next(_module_ids)}"
    spec = importlib.util.spec_from_file_location(name, CHECKER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bd = load_checker()


def write(root: pathlib.Path, rel: str, text: str) -> None:
    """Create one file of a fixture tree, making its parent directories."""
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_repo(root: pathlib.Path) -> None:
    """Write a fixture repo whose maps are honest, so any finding is the bug's own."""
    aggregate = "".join(f'        "{label}",\n' for label in STACK_DATA_LABELS)
    write(root, "docker-compose.yml", "services:\n  coder:\n    image: x\n")
    write(root, "BUILD.bazel",
          f'filegroup(\n    name = "stack_data",\n    srcs = [\n{aggregate}    ],\n)\n')
    write(root, "scripts/BUILD.bazel", """\
_SCRIPT_LIBS = {
    "foo": [
        "lib/common.sh",
    ],
}
_SCRIPT_PAYLOAD = {
    "foo": [
        "//litellm:config",
    ],
}
_SCRIPT_PAYLOAD_ALLOW = {
    # The path only ever appears in help text.
    "foo": [
        "//proxy:confs",
    ],
}
""")
    write(root, "scripts/foo.sh", """\
#!/usr/bin/env bash
source "${SELF_DIR}/lib/common.sh"
cat "${root}/litellm/config.yaml"
""")
    write(root, "scripts/lib/common.sh", "# a helper mentioning scripts/bootstrap.sh once\n")
    write(root, "tests/BUILD.bazel", """\
_BATS_COMMON = [
    "//:compose_file",
]
_SUITE_PAYLOAD = {
    "foo.bats": [
        "//litellm:config",
    ],
}
_SUITE_PAYLOAD_ALLOW = {
    # The suite builds its own scratch Dockerfile.
    "foo.bats": [
        "//images/dev:dockerfile",
    ],
}
""")
    write(root, "tests/bats/foo.bats", """\
#!/usr/bin/env bats
@test "foo reads the config" {
  run cat "${REPO}/litellm/config.yaml"
}
""")


def make_tmp(label: str) -> pathlib.Path:
    """Create one fixture root and queue it for removal by the running test."""
    directory = tempfile.TemporaryDirectory(prefix=f"evo-bazel-deps-{label}-")
    _tmp_roots.append(directory)
    return pathlib.Path(directory.name)


_tmp_roots: list[tempfile.TemporaryDirectory] = []


def run_checker(root: pathlib.Path, *args: str) -> tuple[int, str]:
    """Invoke main(argv) with the output captured, the way the CLI runs."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        status = bd.main(["--root", str(root), *args])
    return status, buffer.getvalue()


class CheckerTestCase(unittest.TestCase):
    """Base class that removes the tmpdir fixtures a test created."""

    def setUp(self) -> None:
        for directory in _tmp_roots:
            self.addCleanup(directory.cleanup)
        _tmp_roots.clear()


class TokenMatcherTest(unittest.TestCase):
    """A payload path is a path, and a word that only looks like one is not."""

    def test_a_slashed_directory_matches(self) -> None:
        self.assertTrue(bd.token_pattern("homepage/").search('cat "${root}/homepage/config"'))

    def test_a_bare_word_in_an_assertion_does_not_match(self) -> None:
        self.assertIsNone(bd.token_pattern("hermes/").search('[ "${output}" = "hermes" ]'))

    def test_a_service_name_in_a_url_does_not_match(self) -> None:
        self.assertIsNone(bd.token_pattern("litellm/").search("URL=http://litellm:4000/v1"))

    def test_a_file_that_borrows_a_directory_name_does_not_match(self) -> None:
        self.assertIsNone(bd.token_pattern("homepage/").search('cert="proxy/certs/homepage.crt"'))

    def test_a_file_token_rejects_a_longer_stem(self) -> None:
        self.assertIsNone(bd.token_pattern("LICENSE").search("touch LICENSE.txt"))

    def test_a_file_token_accepts_the_exact_name(self) -> None:
        self.assertTrue(bd.token_pattern("LICENSE").search('cmp "${root}/LICENSE" "${other}"'))

    def test_present_tokens_reports_only_what_the_source_opens(self) -> None:
        tokens = bd.present_tokens(['cat "${root}/litellm/config.yaml"\n# proxy/router.conf\n'])
        self.assertEqual({"litellm/"}, tokens)


class LineFilterTest(unittest.TestCase):
    """Comments, here-doc bodies, messages and scratch writes are not dependencies."""

    def test_a_comment_line_is_dropped(self) -> None:
        self.assertEqual("", bd.code_lines("# see proxy/router.conf\n"))

    def test_a_trailing_comment_is_stripped_and_the_code_kept(self) -> None:
        self.assertIn("cat f", bd.code_lines("cat f  # reads proxy/router.conf\n"))

    def test_a_hash_inside_quotes_survives(self) -> None:
        self.assertIn('grep "#"', bd.code_lines('grep "#" "${file}"\n'))

    def test_a_heredoc_body_is_dropped(self) -> None:
        source = "cat <<EOF\nusage: litellm and hermes\nEOF\n"
        self.assertNotIn("litellm", bd.code_lines(source))

    def test_a_message_line_is_dropped(self) -> None:
        self.assertEqual("", bd.code_lines('printf "see litellm/config.yaml\\n"\n'))

    def test_a_bats_test_title_is_dropped(self) -> None:
        self.assertEqual("", bd.code_lines('@test "an empty Dockerfile prints nothing" {\n'))

    def test_a_scratch_mkdir_is_dropped(self) -> None:
        self.assertEqual("", bd.code_lines('mkdir -p "${root}/homepage"\n'))

    def test_a_redirect_from_a_strong_reader_survives(self) -> None:
        line = 'awk -f "${here}/lib/env_set_key.awk" "${file}" >"${stage}"'
        self.assertIn("env_set_key.awk", bd.code_lines(line))

    def test_is_write_separates_building_from_reading(self) -> None:
        self.assertTrue(bd.is_write('cat >"${dir}/Dockerfile"'))
        self.assertFalse(bd.is_write('awk -f lib/x.awk "$f" >"$stage"'))

    def test_read_lines_keeps_only_lines_with_a_read_verb(self) -> None:
        source = 'local tpl="${root}/templates/common/x"\n[[ -f ${tpl} ]]\n'
        self.assertNotIn("local tpl", bd.read_lines(source))
        self.assertIn("[[ -f", bd.read_lines(source))


class StarlarkReaderTest(unittest.TestCase):
    """The maps are read as literals, which is what keeps them machine-readable."""

    def test_parse_dict_reads_a_literal_map(self) -> None:
        text = '_SCRIPT_LIBS = {\n    "foo": [\n        "lib/common.sh",\n    ],\n}\n'
        self.assertEqual({"foo": ["lib/common.sh"]}, bd.parse_dict(text, "_SCRIPT_LIBS"))

    def test_parse_dict_returns_none_for_a_missing_map(self) -> None:
        self.assertIsNone(bd.parse_dict("x = 1\n", "_SCRIPT_LIBS"))

    def test_parse_filegroup_returns_the_labels(self) -> None:
        text = ('filegroup(\n    name = "stack_data",\n    srcs = [\n'
                '        ":a",\n        "//b:c",\n    ],\n)\n')
        self.assertEqual([":a", "//b:c"], bd.parse_filegroup(text, "stack_data"))

    def test_parse_filegroup_returns_empty_for_an_absent_group(self) -> None:
        self.assertEqual([], bd.parse_filegroup('filegroup(name = "other")\n', "stack_data"))


class DriftTest(unittest.TestCase):
    """Drift is reported in both directions, and an allow entry stops both."""

    def test_a_read_with_no_group_is_missing(self) -> None:
        missing, unused = bd.drift(['cat "${root}/litellm/config.yaml"\n'], set(), [])
        self.assertEqual(["litellm/"], missing)
        self.assertEqual([], unused)

    def test_a_declared_group_nobody_opens_is_unused(self) -> None:
        missing, unused = bd.drift(["echo nothing\n"], {"//litellm:config"}, [])
        self.assertEqual([], missing)
        self.assertEqual(["//litellm:config"], unused)

    def test_an_allowed_label_is_exempt_from_both_directions(self) -> None:
        missing, _ = bd.drift(['cat "${root}/litellm/config.yaml"\n'], set(), ["//litellm:config"])
        self.assertEqual([], missing)
        _, unused = bd.drift(["echo nothing\n"], {"//litellm:config"}, ["//litellm:config"])
        self.assertEqual([], unused)


class SourcedLibsTest(CheckerTestCase):
    """The lib closure follows sources and bare program names, and stops at comments."""

    def test_the_closure_is_transitive_and_repo_relative(self) -> None:
        root = make_tmp("closure")
        write(root, "scripts/foo.sh", 'source "${d}/lib/common.sh"\n')
        write(root, "scripts/lib/common.sh", 'source "${d}/lib/deep.sh"\n')
        write(root, "scripts/lib/deep.sh", ": \n")
        self.assertEqual({"scripts/lib/common.sh", "scripts/lib/deep.sh"},
                         bd.sourced_libs(root, "scripts/foo.sh"))

    def test_a_name_in_a_comment_is_not_a_dependency(self) -> None:
        root = make_tmp("comment")
        write(root, "scripts/foo.sh", '# it uses lib/ghost.sh\nsource "${d}/lib/real.sh"\n')
        write(root, "scripts/lib/real.sh", ": \n")
        write(root, "scripts/lib/ghost.sh", ": \n")
        self.assertEqual({"scripts/lib/real.sh"}, bd.sourced_libs(root, "scripts/foo.sh"))

    def test_a_bare_probe_name_resolves_under_lib_probes(self) -> None:
        root = make_tmp("probe")
        write(root, "scripts/lib/config_seed.sh",
              'cat "${_CONFIG_SEED_DIR}/probes/seed-owner.sh"\n')
        write(root, "scripts/lib/probes/seed-owner.sh", ": \n")
        self.assertIn("scripts/lib/probes/seed-owner.sh",
                      bd.sourced_libs(root, "scripts/lib/config_seed.sh"))

    def test_declared_libs_expands_the_named_group(self) -> None:
        declared = bd.declared_libs(["lib/common.sh", ":seed_probes"])
        self.assertIn("lib/common.sh", declared)
        self.assertIn("lib/probes/seed-write.sh", declared)


class CheckTest(CheckerTestCase):
    """Each check reports nothing on an honest tree and names the drift otherwise."""

    def test_the_fixture_tree_passes_all_three_checks(self) -> None:
        root = make_tmp("honest")
        make_repo(root)
        lines: list[str] = []
        for check in (bd.check_scripts, bd.check_suites, bd.check_aggregate):
            self.assertEqual(0, check(root, lines.append), "\n".join(lines))
        self.assertEqual([], lines)

    def test_a_script_that_starts_reading_a_payload_fails(self) -> None:
        root = make_tmp("missing")
        make_repo(root)
        # searxng/ is in neither map for this fixture, so the read has no group at all.
        write(root, "scripts/foo.sh",
              'source "${SELF_DIR}/lib/common.sh"\n'
              'cat "${root}/litellm/config.yaml"\ncat "${root}/searxng/settings.yml"\n')
        lines: list[str] = []
        self.assertEqual(1, bd.check_scripts(root, lines.append))
        self.assertIn("reads searxng/ with no group declared for it", "\n".join(lines))

    def test_a_script_that_stops_reading_its_payload_fails(self) -> None:
        root = make_tmp("unused")
        make_repo(root)
        write(root, "scripts/foo.sh", 'source "${SELF_DIR}/lib/common.sh"\n:\n')
        lines: list[str] = []
        self.assertEqual(1, bd.check_scripts(root, lines.append))
        self.assertIn("declares //litellm:config that no source mentions", "\n".join(lines))

    def test_an_undeclared_lib_is_reported(self) -> None:
        root = make_tmp("lib")
        make_repo(root)
        write(root, "scripts/lib/extra.sh", ": \n")
        write(root, "scripts/foo.sh",
              'source "${SELF_DIR}/lib/common.sh"\nsource "${SELF_DIR}/lib/extra.sh"\n'
              'cat "${root}/litellm/config.yaml"\n')
        lines: list[str] = []
        self.assertEqual(1, bd.check_scripts(root, lines.append))
        self.assertIn("sources lib/extra.sh without declaring it", "\n".join(lines))

    def test_a_suite_covered_by_the_cli_it_execs_passes(self) -> None:
        root = make_tmp("suite")
        make_repo(root)
        write(root, "tests/bats/foo.bats",
              '@test "drives the cli" {\n  run "${REPO}/scripts/foo.sh"\n}\n')
        lines: list[str] = []
        self.assertEqual(0, bd.check_suites(root, lines.append), "\n".join(lines))

    def test_a_suite_that_drops_its_cli_reads_fails(self) -> None:
        root = make_tmp("suite-drift")
        make_repo(root)
        write(root, "tests/BUILD.bazel",
              '_BATS_COMMON = [\n    "//:compose_file",\n]\n'
              '_SUITE_PAYLOAD = {\n    "foo.bats": [],\n}\n')
        lines: list[str] = []
        self.assertEqual(1, bd.check_suites(root, lines.append))
        self.assertIn("reads litellm/ with no group declared for it", "\n".join(lines))

    def test_a_label_in_both_payload_maps_is_reported(self) -> None:
        root = make_tmp("overlap")
        make_repo(root)
        write(root, "tests/BUILD.bazel",
              '_BATS_COMMON = [\n    "//:compose_file",\n]\n'
              '_SUITE_PAYLOAD = {\n    "foo.bats": [\n        "//litellm:config",\n    ],\n}\n'
              '_SUITE_PAYLOAD_ALLOW = {\n    # A reason that repeats the map above.\n'
              '    "foo.bats": [\n        "//litellm:config",\n    ],\n}\n')
        lines: list[str] = []
        self.assertEqual(1, bd.check_suites(root, lines.append))
        self.assertIn("lists //litellm:config in both suite payload maps", "\n".join(lines))

    def test_overlap_names_only_the_shared_label(self) -> None:
        self.assertEqual(["//c:d"], bd.overlap(["//a:b", "//c:d"], ["//c:d"]))
        self.assertEqual([], bd.overlap(["//a:b"], ["//c:d"]))

    def test_a_payload_group_left_out_of_the_aggregate_is_reported(self) -> None:
        root = make_tmp("aggregate")
        make_repo(root)
        build = (root / "BUILD.bazel").read_text(encoding="utf-8")
        write(root, "BUILD.bazel", build.replace('        "//searxng:settings",\n', ""))
        lines: list[str] = []
        self.assertEqual(1, bd.check_aggregate(root, lines.append))
        self.assertIn("//:stack_data omits //searxng:settings", "\n".join(lines))


class MainTest(CheckerTestCase):
    """The CLI prints the report shape the rest of the stack parses."""

    def test_the_real_repo_passes_the_whole_gate(self) -> None:
        status, output = run_checker(REPO_ROOT)
        self.assertEqual(0, status, output)
        self.assertIn("summary: 3 ok, 0 warnings, 0 failed", output)

    def test_one_target_selects_one_check(self) -> None:
        status, output = run_checker(REPO_ROOT, "--target", "aggregate")
        self.assertEqual(0, status, output)
        self.assertIn("-> checking aggregate", output)
        self.assertNotIn("-> checking scripts", output)

    def test_a_broken_tree_exits_one_with_a_summary(self) -> None:
        root = make_tmp("broken")
        make_repo(root)
        write(root, "scripts/foo.sh", 'cat "${root}/proxy/router.conf"\n')
        status, output = run_checker(root)
        self.assertEqual(1, status)
        self.assertIn("summary: 0 ok, 0 warnings,", output)
        self.assertIn("error: //scripts:foo", output)

    def test_the_shipped_main_guard_runs_as_a_script(self) -> None:
        argv = ["tests/bazel_deps.py", "--root", str(REPO_ROOT)]
        with contextlib.redirect_stdout(io.StringIO()) as buffer:
            with mock.patch.object(sys, "argv", argv):
                with self.assertRaises(SystemExit) as caught:
                    runpy.run_path(str(CHECKER_PATH), run_name="__main__")
        self.assertEqual(0, caught.exception.code)
        self.assertIn("summary: 3 ok", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
