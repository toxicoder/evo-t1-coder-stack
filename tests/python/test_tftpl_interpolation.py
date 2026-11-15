#!/usr/bin/env python3
"""Unit tests for scripts/lib/tftpl_interpolation.py, the .tftpl vars-map gate.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

The checker parses both sides of every templatefile() call under a templates
tree: the keys the .tf declares in its vars map, and the names the body it names
interpolates. The contract under test is therefore the exit code plus the finding
lines - the defect class is a body that reads `${shell_var}` as an interpolation
while the map never passes it, which no grep can tell from the `$${shell_var}`
escape. Every test builds a real .tf with its real .tftpl bodies on disk and
drives main(argv), because the parsers only mean something against the text the
CLI actually reads. scripts/lib is not a package, so the module is loaded by file
path with importlib, and the shipped `if __name__ == "__main__"` guard is
executed with runpy rather than skipped.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import runpy
import sys
import tempfile
import types
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_LIB = REPO_ROOT / "scripts" / "lib"
MODULE_PATH = SCRIPTS_LIB / "tftpl_interpolation.py"
PROGRAM = "tftpl_interpolation.py"

USAGE = "usage: tftpl_interpolation.py TEMPLATES_DIR [--strict] [--list]\n"
CLEAN_SUMMARY = "summary: 1 call(s) checked, 0 warnings, 0 failed\n"
EMPTY_SUMMARY = "summary: 0 call(s) checked, 0 warnings, 0 failed\n"

# The one call shape most fixtures share: the body asks for exactly `payload`, so
# a silent exit 0 means the map declared that key and the parser read it.
CLEAN_TF = 'x = templatefile("${path.module}/body.sh.tftpl", { payload = "x" })\n'
CLEAN_BODY = "echo ${payload}\n"


def load_module() -> types.ModuleType:
    """Import the checker by file path under a throwaway name."""
    spec = importlib.util.spec_from_file_location("tftpl_interpolation", MODULE_PATH)
    # scripts/lib is not a package, so a missing or loader-less spec means the
    # checkout is wrong, which no test can work around.
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


def run_argv(*argv: str) -> tuple[int, str, str]:
    """Call main() the way the CLI does and return (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = MODULE.main([PROGRAM, *argv])
    return code, out.getvalue(), err.getvalue()


def rows(text: str) -> list[tuple[str, ...]]:
    """Split --list stdout into the tab-separated fields of each row."""
    return [tuple(line.split("\t")) for line in text.splitlines() if line]


class CheckerTestCase(unittest.TestCase):
    """Base for the suites that drive the checker over a scratch templates tree."""

    tmp: tempfile.TemporaryDirectory[str]

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def root(self) -> pathlib.Path:
        """The scratch directory, handed to the checker as TEMPLATES_DIR."""
        return pathlib.Path(self.tmp.name)

    def make_file(self, name: str, content: str) -> pathlib.Path:
        """Write one fixture file, creating its parent directories."""
        path = self.root() / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def check(self, *flags: str) -> tuple[int, str, str]:
        """Run the checker over the scratch tree and return the captured trio."""
        return run_argv(str(self.root()), *flags)

    def one_clean_call(self) -> tuple[pathlib.Path, pathlib.Path]:
        """A tree holding the single clean call; returns its .tf and its body."""
        return (self.make_file("main.tf", CLEAN_TF),
                self.make_file("body.sh.tftpl", CLEAN_BODY))

    def call_with_body(self, body: str, var_map: str = '{ payload = "x" }'
                       ) -> tuple[pathlib.Path, pathlib.Path]:
        """A one-call tree whose body text and vars map are the ones under test."""
        tf = self.make_file("main.tf",
                            'x = templatefile("${path.module}/body.sh.tftpl", %s)\n' % var_map)
        return tf, self.make_file("body.sh.tftpl", body)


class CleanTreeTest(CheckerTestCase):
    """A body that interpolates only what its call passes is a silent pass."""

    def test_a_clean_call_reports_one_checked_call_and_says_nothing_else(self) -> None:
        self.one_clean_call()
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_bare_body_name_resolves_beside_the_tf(self) -> None:
        # _resolve_body tries the .tf's own directory first, so a body that only
        # one template uses needs no ${path.module}/ prefix.
        tf = self.make_file("main.tf", 'x = templatefile("body.txt", { payload = "x" })\n')
        body = self.make_file("body.txt", "echo ${payload}\n")
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual([(str(tf), "1", str(body), "payload")], rows(out))

    def test_a_body_under_templates_common_is_reached_from_a_sibling_directory(self) -> None:
        # Both template twins share templates/common/*.tftpl, which is why the
        # fallback exists; a call from a sibling directory still resolves it.
        tf = self.make_file("sibling/one.tf",
                            'x = templatefile("${path.module}/shared.sh.tftpl", { flag = 1 })\n')
        body = self.make_file("common/shared.sh.tftpl", "if [ ${flag} ]; then :; fi\n")
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual([(str(tf), "1", str(body), "flag")], rows(out))


class UsageTest(CheckerTestCase):
    """A bad command line is exit 2, before anything is read."""

    def test_no_argument_prints_the_usage(self) -> None:
        self.assertEqual((2, "", USAGE), run_argv())

    def test_two_directories_are_refused(self) -> None:
        self.make_file("a/main.tf", "")
        self.make_file("b/main.tf", "")
        self.assertEqual((2, "", USAGE),
                         run_argv(str(self.root() / "a"), str(self.root() / "b")))

    def test_a_path_that_is_not_a_directory_is_reported(self) -> None:
        tf = self.make_file("main.tf", CLEAN_TF)
        code, out, err = run_argv(str(tf))
        self.assertEqual((2, "", "error: %s is not a directory\n" % tf), (code, out, err))

    def test_the_flags_are_not_counted_as_positional_arguments(self) -> None:
        tf, body = self.one_clean_call()
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check("--strict"))
        code, out, err = self.check("--list", "--strict")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual([(str(tf), "1", str(body), "payload")], rows(out))


class UndeclaredNameTest(CheckerTestCase):
    """The defect class: a bare single-dollar name the map never passes."""

    def test_an_undeclared_name_fails_and_names_itself(self) -> None:
        tf, body = self.call_with_body("echo ${payload} ${shell_var}\n")
        code, out, err = self.check()
        self.assertEqual(1, code)
        self.assertEqual("", err)
        self.assertEqual(
            [
                "error: %s:1: 'shell_var' interpolates but %s:1 passes no such key" % (
                    body, tf),
                "summary: 0 call(s) checked, 0 warnings, 1 failed",
            ],
            out.splitlines(),
        )

    def test_the_same_name_on_the_same_line_is_reported_once(self) -> None:
        self.call_with_body("echo ${payload} ${shell_var} ${shell_var}\n")
        _, out, _ = self.check()
        self.assertEqual(1, out.count("'shell_var'"))
        self.assertIn("summary: 0 call(s) checked, 0 warnings, 1 failed", out)

    def test_a_declared_name_is_not_reported_even_when_the_call_is_otherwise_bad(self) -> None:
        # Two bodies, one clean and one broken: the clean call still counts itself
        # checked, so the summary adds up per call rather than per tree.
        self.make_file("main.tf",
                       'a = templatefile("${path.module}/ok.sh.tftpl", { p = 1 })\n'
                       'b = templatefile("${path.module}/bad.sh.tftpl", { p = 1 })\n')
        self.make_file("ok.sh.tftpl", "echo ${p}\n")
        self.make_file("bad.sh.tftpl", "echo ${p} ${oops}\n")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("summary: 1 call(s) checked, 0 warnings, 1 failed", out)
        self.assertIn("'oops' interpolates but", out)
        self.assertNotIn("'p' interpolates", out)


class EscapeTest(CheckerTestCase):
    """The $$ and %% escapes are the shell's own; they must stay quiet."""

    def test_a_doubled_dollar_and_a_doubled_percent_are_literal_text(self) -> None:
        self.call_with_body("echo $${shell_var} %%{directive} ${payload}\n")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_doubled_dollar_alone_needs_no_keys_at_all(self) -> None:
        self.call_with_body("echo $${HOME}\n", "{}")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_trailing_dollar_is_ordinary_text(self) -> None:
        # The last character has no successor, so the walker looks at it alone.
        self.call_with_body("echo $", "{}")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())


class DirectiveTest(CheckerTestCase):
    """%{ ... } directives reference map keys too, except the names they bind."""

    def test_a_declared_directive_condition_passes(self) -> None:
        self.call_with_body("%{ if flag ~}on%{ endif ~}\n", "{ flag = true }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_an_undeclared_directive_condition_fails(self) -> None:
        self.call_with_body("%{ if flag ~}on%{ endif ~}\n", "{}")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'flag' interpolates but", out)

    def test_a_for_directive_binds_its_loop_names_locally(self) -> None:
        # `k` and `v` come from the directive, so the map only owes `pairs`.
        self.call_with_body("%{ for k, v in pairs ~}${k}=${v};%{ endfor ~}\n",
                            "{ pairs = [] }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_loop_alias_read_outside_its_loop_is_a_missing_key(self) -> None:
        # The binding lives between the for and its endfor and nowhere else. Read after
        # the loop closes, `a` is an ordinary name the map owes, which is the plan
        # failure a body-wide whitelist would have waved through.
        self.call_with_body("%{ for a in items ~}${a}%{ endfor ~}\nafter ${a}\n",
                            "{ items = [] }")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'a' interpolates but", out)

    def test_a_nested_loop_sees_its_own_aliases_and_those_of_its_parent(self) -> None:
        self.call_with_body("%{ for k in outer ~}%{ for v in inner ~}${k}=${v}%{ endfor ~}"
                            "%{ endfor ~}\n", "{ outer = [], inner = [] }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_stray_endfor_binds_nothing_and_harms_nothing(self) -> None:
        # No open frame to pop: the pop is skipped rather than taking a frame that
        # belongs to an enclosing loop with it.
        self.call_with_body("${payload}%{ endfor ~}\n", '{ payload = "x" }')
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_for_directive_without_in_binds_nothing(self) -> None:
        # Malformed as HCL, but the parser must not invent a binding: `x` stays
        # the caller's debt, which is why the map has to carry it here.
        self.call_with_body("%{ for x ~}${x}%{ endfor ~}\n", "{ x = 1 }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())
        self.call_with_body("%{ for x ~}${x}%{ endfor ~}\n", "{}")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'x' interpolates but", out)

    def test_an_empty_directive_asks_for_nothing(self) -> None:
        self.call_with_body("echo %{ ~}\n", "{}")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())


class ExpressionTest(CheckerTestCase):
    """What an interpolation asks for, and what it merely mentions."""

    def test_a_function_name_is_not_required_in_the_map(self) -> None:
        # The body calls join() and reads `list`; only `list` is the caller's debt.
        self.call_with_body('echo ${join(",", list)}\n', "{ list = [1, 2] }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_function_name_does_not_stand_in_for_the_variable_it_takes(self) -> None:
        self.call_with_body('echo ${join(",", list)}\n', "{ join = [1, 2] }")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'list' interpolates but", out)
        self.assertNotIn("'join' interpolates", out)

    def test_the_literals_and_operators_stay_silent(self) -> None:
        self.call_with_body("echo ${true} ${false} ${null} ${true and false}\n", "{}")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_not_is_an_operator_and_its_operand_still_has_to_be_declared(self) -> None:
        self.call_with_body("echo ${not flag}\n", "{ flag = true }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())
        self.call_with_body("echo ${not flag}\n", "{}")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'flag' interpolates but", out)
        self.assertNotIn("'not' interpolates", out)

    def test_a_name_inside_a_quoted_string_is_not_a_variable(self) -> None:
        self.call_with_body('echo ${join("shell_var", names)} ${index(things, "other_var")}\n',
                            "{ names = [], things = [] }")
        code, out, err = self.check()
        self.assertEqual((0, CLEAN_SUMMARY, ""), (code, out, err))

    def test_a_single_quoted_run_is_stripped_as_well(self) -> None:
        self.call_with_body("echo ${index(things, 'other_var')}\n", "{ things = [] }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_nested_brace_inside_an_interpolation_is_closed(self) -> None:
        self.call_with_body("echo ${jsonencode({ map_key = 1 })}\n", "{ map_key = 1 }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_backslash_in_a_quoted_argument_does_not_end_the_string(self) -> None:
        # The escape has to be honoured while the walker looks for the closing
        # brace, or the interpolation reads as unbalanced and the call is dropped.
        self.call_with_body('echo ${index(names, "a\\b")}\n', "{ names = [] }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_member_of_a_declared_object_is_not_a_key(self) -> None:
        # `${conf.enabled}` asks the map for `conf` and reads `enabled` off whatever
        # comes back. Demanding the member too would redden the gate on valid HCL.
        self.call_with_body("echo ${conf.enabled}\n", "{ conf = {} }")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())
        self.call_with_body("echo ${conf.enabled}\n", "{}")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("'conf' interpolates but", out)
        self.assertNotIn("'enabled' interpolates", out)

    def test_an_unterminated_interpolation_is_a_finding(self) -> None:
        # _match_brace gives up, so nothing after the broken brace is read. Terraform
        # refuses to render a body like this, so counting it clean would be the gate
        # going quiet on the one thing it is here for.
        self.call_with_body("echo ${broken\nmore ${payload}\n", "{ payload = 1 }")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("never closes", out)

    def test_an_unterminated_directive_is_a_finding(self) -> None:
        self.call_with_body("echo %{ if broken\n", "{}")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("never closes", out)


class UnusedKeyTest(CheckerTestCase):
    """A key the body never reads is a warning, or a failure under --strict."""

    def test_a_key_the_body_never_reads_warns_and_still_passes(self) -> None:
        tf, _ = self.call_with_body("echo ${a}\n", "{ a = 1, b = 2 }")
        code, out, err = self.check()
        self.assertEqual(0, code)
        self.assertEqual("", err)
        self.assertEqual(
            [
                "warning: %s:1: passes 'b', body.sh.tftpl never interpolates it" % tf,
                "summary: 1 call(s) checked, 1 warnings, 0 failed",
            ],
            out.splitlines(),
        )

    def test_strict_turns_the_warning_into_a_failure(self) -> None:
        self.call_with_body("echo ${a}\n", "{ a = 1, b = 2 }")
        code, out, _ = self.check("--strict")
        self.assertEqual(1, code)
        self.assertIn("warning: ", out)
        self.assertIn("summary: 1 call(s) checked, 0 warnings, 1 failed", out)

    def test_strict_says_nothing_about_a_tree_with_nothing_to_warn_about(self) -> None:
        self.one_clean_call()
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check("--strict"))


class ListModeTest(CheckerTestCase):
    """--list puts the rows on stdout and every word of prose on stderr."""

    def test_the_rows_are_tab_separated_and_the_prose_stays_on_stderr(self) -> None:
        tf, body = self.one_clean_call()
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual([(str(tf), "1", str(body), "payload")], rows(out))

    def test_the_exit_code_still_reflects_the_errors(self) -> None:
        tf = self.make_file("main.tf",
                            'a = templatefile("${path.module}/ok.sh.tftpl", { p = 1 })\n'
                            'b = templatefile("${path.module}/bad.sh.tftpl", { p = 1 })\n')
        good = self.make_file("ok.sh.tftpl", "echo ${p}\n")
        bad = self.make_file("bad.sh.tftpl", "echo ${p} ${oops}\n")
        code, out, err = self.check("--list")
        self.assertEqual(1, code)
        self.assertEqual([(str(tf), "1", str(good), "p"), (str(tf), "2", str(bad), "p")],
                         rows(out))
        self.assertEqual(
            ["error: %s:1: 'oops' interpolates but %s:2 passes no such key" % (bad, tf)],
            err.splitlines(),
        )
        self.assertNotIn("summary:", out + err)


class VarsMapTest(CheckerTestCase):
    """Reading the keys out of the vars map, and refusing to guess them."""

    def test_a_nested_call_keeps_its_own_map(self) -> None:
        # The inner map belongs to the inner call: `payload` is the inner caller's
        # debt, and the outer map's only key is `inner`.
        tf = self.make_file("main.tf",
                            "locals {\n"
                            '  outer = templatefile("${path.module}/outer.sh.tftpl", {\n'
                            '    inner = templatefile("${path.module}/inner.sh.tftpl",'
                            ' { payload = "y" })\n'
                            "  })\n"
                            "}\n")
        outer = self.make_file("outer.sh.tftpl", "echo ${inner}\n")
        inner = self.make_file("inner.sh.tftpl", "echo ${payload}\n")
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual(
            [
                (str(tf), "2", str(outer), "inner"),
                (str(tf), "3", str(inner), "payload"),
            ],
            rows(out),
        )

    def test_a_comparator_at_an_entry_start_is_not_read_as_a_key(self) -> None:
        self.call_with_body("echo ${payload}\n", '{ payload = "x", a == b, c => d }')
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual("payload", rows(out)[0][3])

    def test_a_key_that_does_not_open_with_an_ascii_letter_is_not_a_key(self) -> None:
        # IDENT_RE is ASCII-only while str.isalpha() is not, so an entry that
        # opens with a non-ASCII letter is not an identifier and the walker moves
        # on rather than reading it as a key.
        self.call_with_body('echo ${payload}\n', '{ payload = "x", \u00fcnknown = 1 }')
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual("payload", rows(out)[0][3])

    def test_an_argument_that_is_not_a_map_is_reported(self) -> None:
        tf = self.make_file("main.tf",
                            'x = templatefile("${path.module}/body.sh.tftpl", var.values)\n')
        self.make_file("body.sh.tftpl", "echo hi\n")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("%s:1: cannot read the vars map for body.sh.tftpl" % tf, out)

    def test_an_empty_map_with_a_body_that_asks_for_nothing_passes(self) -> None:
        self.call_with_body("echo plain text\n", "{}")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())


class CallScanningTest(CheckerTestCase):
    """What counts as a templatefile() call in a .tf, and what merely mentions one."""

    def test_a_call_in_a_hash_comment_is_not_a_call(self) -> None:
        self.make_file("main.tf", '# templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_a_call_in_a_slash_comment_is_not_a_call(self) -> None:
        self.make_file("main.tf", '// templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_a_call_in_a_block_comment_is_not_a_call(self) -> None:
        self.make_file("main.tf",
                       '/* templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n'
                       "   still inside the block comment\n"
                       "*/\n")
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_an_unterminated_block_comment_blanks_the_rest_of_the_file(self) -> None:
        self.make_file("main.tf",
                       "/* the block comment never closes\n"
                       'x = templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_a_call_in_a_heredoc_body_is_not_a_call(self) -> None:
        # The <<- terminator is indented, so it has to be searched for rather than
        # expected at column 0; getting that wrong would also swallow the real
        # call below it, which is what the line number in the row proves.
        tf = self.make_file("main.tf",
                            'resource "local_file" "a" {\n'
                            "  proto = <<-EOT\n"
                            '    # templatefile("${path.module}/ghost.sh.tftpl", { a = 1 })\n'
                            "  EOT\n"
                            '  data = templatefile("${path.module}/body.sh.tftpl",'
                            ' { payload = "x" })\n'
                            "}\n")
        body = self.make_file("body.sh.tftpl", "echo ${payload}\n")
        code, out, err = self.check("--list")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual([(str(tf), "5", str(body), "payload")], rows(out))

    def test_an_unclosed_heredoc_blanks_the_rest_of_the_file(self) -> None:
        self.make_file("main.tf",
                       'resource "local_file" "a" {\n'
                       "  proto = <<-EOT\n"
                       '    x = templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_a_shift_operator_is_not_a_heredoc(self) -> None:
        # `<<` with no tag after it is not an opener, so it must not blank the
        # file and lose the call that follows it.
        self.make_file("main.tf",
                       "locals {\n"
                       "  bitshift = 1 << (2)\n"
                       '  real = templatefile("${path.module}/body.sh.tftpl",'
                       ' { payload = "x" })\n'
                       "}\n")
        self.make_file("body.sh.tftpl", "echo ${payload}\n")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_name_that_only_ends_with_templatefile_is_not_a_call(self) -> None:
        self.make_file("main.tf", 'x = mytemplatefile("${path.module}/gone.sh.tftpl", {})\n')
        self.assertEqual((0, EMPTY_SUMMARY, ""), self.check())

    def test_the_terraform_working_directory_is_skipped(self) -> None:
        # .terraform/ holds downloaded modules whose bodies are not this tree's,
        # so a call there is not a call here.
        self.make_file(".terraform/modules/leak/main.tf",
                       'x = templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        self.one_clean_call()
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())


class OrphanBodyTest(CheckerTestCase):
    """Every body under the tree has to be named by a call that renders it."""

    def test_a_body_no_call_reaches_is_reported(self) -> None:
        # A rename that left the old file behind, or a payload the push stopped
        # staging beside its twin: the tree carries text nobody renders, and a
        # passing gate that only walks *.tf would never notice.
        self.one_clean_call()
        self.make_file("stale.sh.tftpl", "echo ${nobody_passes_me}\n")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("no templatefile() call under", out)
        self.assertIn("stale.sh.tftpl", out)

    def test_a_body_reached_through_the_shared_directory_is_not_an_orphan(self) -> None:
        self.make_file("pair/main.tf",
                       'x = templatefile("${path.module}/shared.sh.tftpl", { a = 1 })\n')
        self.make_file("common/shared.sh.tftpl", "echo ${a}\n")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())

    def test_a_body_under_the_terraform_working_directory_is_not_an_orphan(self) -> None:
        self.one_clean_call()
        self.make_file(".terraform/modules/leak/vendored.sh.tftpl", "echo ${a}\n")
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.check())


class BadCallTest(CheckerTestCase):
    """A call this parser cannot read is reported, never passed in silence."""

    def test_a_call_with_one_argument_is_reported(self) -> None:
        self.make_file("main.tf", 'x = templatefile("${path.module}/body.sh.tftpl")\n')
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("templatefile() called with 1 arguments", out)

    def test_an_unbalanced_call_is_reported(self) -> None:
        # No closing paren, so the argument splitter walks off the end of the file
        # and hands back the one argument it did read.
        self.make_file("main.tf", 'x = templatefile("${path.module}/body.sh.tftpl", { a = 1 }\n')
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("templatefile() called with 1 arguments", out)

    def test_a_path_that_is_not_a_plain_string_is_reported(self) -> None:
        tf = self.make_file("main.tf", "x = templatefile(var.path, { a = 1 })\n")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("%s:1: templatefile() path argument is not a plain string" % tf, out)

    def test_a_path_holding_an_escaped_quote_is_not_a_plain_string(self) -> None:
        self.make_file("main.tf",
                       'x = templatefile("${path.module}/q\\"uote.sh.tftpl", {})\n')
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("path argument is not a plain string", out)

    def test_a_path_built_dynamically_is_reported(self) -> None:
        tf = self.make_file("main.tf",
                            'x = templatefile("${var.dir}/body.sh.tftpl", { a = 1 })\n')
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("%s:1: templatefile() path ${var.dir}/body.sh.tftpl"
                      " is built dynamically" % tf, out)

    def test_a_missing_body_is_reported(self) -> None:
        tf = self.make_file("main.tf",
                            'x = templatefile("${path.module}/gone.sh.tftpl", { a = 1 })\n')
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("%s:1: no body found for ${path.module}/gone.sh.tftpl" % tf, out)

    def test_a_path_that_names_a_directory_is_reported(self) -> None:
        # Only a bare name, or ${path.module}/<name>: the checker will not guess
        # which template directory a nested path is meant to sit in.
        tf = self.make_file("main.tf",
                            'x = templatefile("${path.module}/sub/body.sh.tftpl", { a = 1 })\n')
        self.make_file("sub/body.sh.tftpl", "echo ${a}\n")
        code, out, _ = self.check()
        self.assertEqual(1, code)
        self.assertIn("%s:1: no body found for ${path.module}/sub/body.sh.tftpl" % tf, out)


class MainGuardTest(CheckerTestCase):
    """The shipped __main__ guard is a real code path: the shell runs the file."""

    def run_as_program(self, *argv: str) -> tuple[int, str, str]:
        # 255 is not a verdict the checker returns, so it stands for "the guard
        # ran to its end without calling sys.exit()".
        code = 255
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", [PROGRAM, *argv]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                runpy.run_path(str(MODULE_PATH), run_name="__main__")
            except SystemExit as exc:
                verdict = exc.code
                assert isinstance(verdict, int), "the guard exits with an int"
                code = verdict
        self.assertNotEqual(255, code, "the guard ran without calling sys.exit()")
        return code, out.getvalue(), err.getvalue()

    def test_running_the_file_exits_with_the_checker_verdict(self) -> None:
        self.one_clean_call()
        self.assertEqual((0, CLEAN_SUMMARY, ""), self.run_as_program(str(self.root())))
        self.make_file("body.sh.tftpl", "echo ${shell_var}\n")
        self.assertEqual(1, self.run_as_program(str(self.root()))[0])
        self.assertEqual((2, "", USAGE), self.run_as_program())


if __name__ == "__main__":
    unittest.main()
