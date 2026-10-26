#!/usr/bin/env python3
"""Unit tests for the standalone Python helpers under scripts/lib.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

Each helper is a `main(argv)` CLI the operator CLIs shell out to, so the contract
under test is the exit code, the bytes written, and the one stderr line a failure
prints. scripts/lib is not a package, so every module is loaded by file path with
importlib under a throwaway name, which also lets a test install its own `yaml`
before the module body runs. The `if __name__ == "__main__"` guard is a shipped
code path (the CLIs run the file directly), so it is executed with runpy rather
than skipped.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import json
import pathlib
import runpy
import socket
import sys
import tempfile
import types
import unittest
from collections.abc import Iterator
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_LIB = REPO_ROOT / "scripts" / "lib"

_MISSING = object()
_module_ids = itertools.count()

try:  # PyYAML ships in the golden image; a bare venv outside it may lack it.
    import yaml as _REAL_YAML
except ImportError:  # pragma: no cover - environment dependent
    _REAL_YAML = None


class StubYamlError(Exception):
    """Stands in for yaml.YAMLError, the type parse_yaml.py catches."""


class StubYaml(types.ModuleType):
    """Minimal PyYAML surface: safe_load plus the YAMLError the helper catches."""

    YAMLError = StubYamlError

    def __init__(self) -> None:
        super().__init__("yaml")

    def safe_load(self, fh: object) -> dict[str, bool]:
        """Load one document, rejecting an unterminated flow collection."""
        text = fh.read()  # type: ignore[attr-defined]
        unbalanced = text.count("[") - text.count("]") + text.count("{") - text.count("}")
        if unbalanced:
            raise StubYamlError("expected ',' or ']'")
        return {"ok": True}


def yaml_for_tests() -> types.ModuleType:
    """The PyYAML the helper should see: the real package when it is installed."""
    return _REAL_YAML if _REAL_YAML is not None else StubYaml()


@contextlib.contextmanager
def temp_dir() -> Iterator[pathlib.Path]:
    """Yield a scratch directory that is removed when the test ends."""
    with tempfile.TemporaryDirectory() as tmp:
        yield pathlib.Path(tmp)


def load_helper(stem: str) -> types.ModuleType:
    """Import one scripts/lib helper by file path.

    Args:
        stem: Module name without suffix, which is also the file name.

    Returns:
        A freshly executed module under a unique name, so repeated loads never
        share state and never collide in ``sys.modules``.
    """
    path = SCRIPTS_LIB / f"{stem}.py"
    name = f"{stem}_under_test_{next(_module_ids)}"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def run_guard(path: pathlib.Path, argv: list[str]) -> tuple[int, str, str]:
    """Execute one helper the way the shell does: as ``__main__`` with argv.

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
            raise AssertionError(f"{path.name} exited with {exc.code!r}, not an int") from exc
        return exc.code, out.getvalue(), err.getvalue()
    finally:
        sys.argv = saved_argv
    raise AssertionError(f"{path.name} ran as __main__ without calling sys.exit()")


def _gaierror(host: str, port: object) -> object:
    """A getaddrinfo stand-in that fails the way a dead lookup does."""
    raise socket.gaierror(-2, "Name or service not known")


def _answered(host: str, port: object) -> list[tuple[object, ...]]:
    """A getaddrinfo stand-in for a name that resolves."""
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.2", 0))]


class HostResolveTests(unittest.TestCase):
    """host_resolve.py exits 0 when the resolver answers for the name."""

    def setUp(self) -> None:
        self.mod = load_helper("host_resolve")
        self.addCleanup(sys.modules.pop, self.mod.__name__, None)

    @staticmethod
    def _call(mod: types.ModuleType, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = mod.main(["host_resolve.py", *args])
        return code, out.getvalue(), err.getvalue()

    def test_a_name_the_resolver_answers_for_exits_zero_silently(self) -> None:
        calls: list[tuple[object, object]] = []

        def fake(host: str, port: object) -> list[tuple[object, ...]]:
            calls.append((host, port))
            return _answered(host, port)

        with mock.patch.object(socket, "getaddrinfo", fake):
            self.assertEqual((0, "", ""), self._call(self.mod, "gmktec.local"))
        self.assertEqual([("gmktec.local", None)], calls)

    def test_localhost_resolves_through_the_real_resolver(self) -> None:
        # Unstubbed: the shipped path against the real resolver, which is what
        # scripts/lib/host_state.sh leans on when getent is absent.
        self.assertEqual((0, "", ""), self._call(self.mod, "localhost"))

    def test_a_failed_lookup_exits_one_with_no_output(self) -> None:
        with mock.patch.object(socket, "getaddrinfo", _gaierror):
            self.assertEqual((1, "", ""), self._call(self.mod, "no-such-host.invalid"))

    def test_no_argument_prints_the_usage_and_exits_one(self) -> None:
        self.assertEqual((1, "", "usage: host_resolve.py HOSTNAME\n"), self._call(self.mod))

    def test_too_many_arguments_are_refused(self) -> None:
        with mock.patch.object(socket, "getaddrinfo", _answered):
            self.assertEqual(
                (1, "", "usage: host_resolve.py HOSTNAME\n"),
                self._call(self.mod, "a", "b"),
            )

    def test_an_empty_name_is_refused_before_any_lookup(self) -> None:
        # getaddrinfo("") answers for the local hostname, so the empty argument
        # has to be rejected by the arity check, not by the lookup.
        with mock.patch.object(socket, "getaddrinfo", _answered):
            self.assertEqual(
                (1, "", "usage: host_resolve.py HOSTNAME\n"),
                self._call(self.mod, ""),
            )

    def test_run_as_a_program_it_exits_with_the_lookup_verdict(self) -> None:
        script = str(SCRIPTS_LIB / "host_resolve.py")
        with mock.patch.object(socket, "getaddrinfo", _answered):
            self.assertEqual((0, "", ""), run_guard(pathlib.Path(script), [script, "gw"]))
        with mock.patch.object(socket, "getaddrinfo", _gaierror):
            self.assertEqual((1, "", ""), run_guard(pathlib.Path(script), [script, "gw"]))
        self.assertEqual(
            (1, "", "usage: host_resolve.py HOSTNAME\n"),
            run_guard(pathlib.Path(script), [script]),
        )


class JsonCopyKeyTests(unittest.TestCase):
    """json_copy_key.py copies one key from CURRENT into DEST and nothing else."""

    def setUp(self) -> None:
        self.mod = load_helper("json_copy_key")
        self.addCleanup(sys.modules.pop, self.mod.__name__, None)
        self.dir = self.enterContext(temp_dir())

    def _file(self, name: str, text: str) -> pathlib.Path:
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return path

    def _call_argv(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.mod.main(argv)
        return code, out.getvalue(), err.getvalue()

    def _call(self, dest: object, current: object, key: str) -> tuple[int, str, str]:
        return self._call_argv(["json_copy_key.py", str(dest), str(current), key])

    def test_a_present_key_lands_in_dest_reindented_with_a_trailing_newline(self) -> None:
        current = self._file("current.json", '{"a":1,"cline.apiKey":"secret"}\n')
        dest = self._file("dest.json", '{"a":2}\n')
        self.assertEqual((0, "", ""), self._call(dest, current, "cline.apiKey"))
        self.assertEqual('{\n  "a": 2,\n  "cline.apiKey": "secret"\n}\n', dest.read_text("utf-8"))

    def test_scalars_keep_their_type_rather_than_their_text(self) -> None:
        current = self._file("current.json", '{"n":7,"t":true,"z":null,"l":[1],"m":{"k":1}}\n')
        dest = self._file("dest.json", "{}\n")
        for key in ("n", "t", "z", "l", "m"):
            self.assertEqual(0, self._call(dest, current, key)[0], key)
        self.assertEqual(
            {"n": 7, "t": True, "z": None, "l": [1], "m": {"k": 1}},
            json.loads(dest.read_text("utf-8")),
        )

    def test_a_key_already_in_dest_takes_the_current_value(self) -> None:
        current = self._file("current.json", '{"k":"from-current"}\n')
        dest = self._file("dest.json", '{"k":"from-dest"}\n')
        self.assertEqual(0, self._call(dest, current, "k")[0])
        self.assertEqual({"k": "from-current"}, json.loads(dest.read_text("utf-8")))

    def test_an_absent_key_is_a_no_op_exit_zero(self) -> None:
        current = self._file("current.json", '{"a":1}\n')
        dest = self._file("dest.json", '{"a":3}\n')
        self.assertEqual((0, "", ""), self._call(dest, current, "missing"))
        self.assertEqual('{"a":3}\n', dest.read_text("utf-8"))

    def test_an_absent_key_needs_no_dest_at_all(self) -> None:
        current = self._file("current.json", "{}\n")
        self.assertEqual(0, self._call(self.dir / "nope.json", current, "missing")[0])

    def test_wrong_arity_prints_the_usage(self) -> None:
        cases = [
            ["json_copy_key.py"],
            ["json_copy_key.py", "d"],
            ["json_copy_key.py", "d", "c"],
            ["json_copy_key.py", "d", "c", "k", "extra"],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                self.assertEqual(
                    (1, "", "usage: json_copy_key.py DEST CURRENT KEY\n"),
                    self._call_argv(argv),
                )

    def test_a_missing_current_file_is_reported_and_dest_is_untouched(self) -> None:
        dest = self._file("dest.json", "{}\n")
        code, out, err = self._call(dest, self.dir / "gone.json", "k")
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertTrue(err.startswith("json_copy_key: "), err)
        self.assertIn("gone.json", err)
        self.assertEqual("{}\n", dest.read_text("utf-8"))

    def test_an_unreadable_current_file_is_reported(self) -> None:
        self._file("dest.json", "{}\n")
        code, _, err = self._call(self.dir / "dest.json", self.dir, "k")
        self.assertEqual(1, code)
        self.assertTrue(err.startswith("json_copy_key: "), err)

    def test_malformed_current_json_is_reported(self) -> None:
        current = self._file("current.json", "{not json\n")
        dest = self._file("dest.json", '{"k":1}\n')
        code, _, err = self._call(dest, current, "k")
        self.assertEqual(1, code)
        self.assertIn("json_copy_key: ", err)
        self.assertEqual('{"k":1}\n', dest.read_text("utf-8"))

    def test_an_empty_current_file_is_reported(self) -> None:
        current = self._file("current.json", "")
        self.assertEqual(1, self._call(self._file("dest.json", "{}\n"), current, "k")[0])

    def test_a_current_whose_root_is_not_a_mapping_is_reported(self) -> None:
        # `key not in None` raises TypeError, which the helper turns into exit 1.
        current = self._file("current.json", "null\n")
        dest = self._file("dest.json", "{}\n")
        code, _, err = self._call(dest, current, "k")
        self.assertEqual(1, code)
        self.assertIn("json_copy_key: ", err)

    def test_a_missing_dest_file_is_reported_when_there_is_something_to_copy(self) -> None:
        current = self._file("current.json", '{"k":1}\n')
        code, _, err = self._call(self.dir / "gone.json", current, "k")
        self.assertEqual(1, code)
        self.assertIn("gone.json", err)

    def test_malformed_dest_json_is_reported(self) -> None:
        current = self._file("current.json", '{"k":1}\n')
        dest = self._file("dest.json", "nope\n")
        code, _, err = self._call(dest, current, "k")
        self.assertEqual(1, code)
        self.assertIn("json_copy_key: ", err)

    def test_a_dest_whose_root_is_a_list_cannot_take_a_key(self) -> None:
        current = self._file("current.json", '{"k":1}\n')
        dest = self._file("dest.json", "[1, 2]\n")
        code, _, err = self._call(dest, current, "k")
        self.assertEqual(1, code)
        self.assertIn("json_copy_key: ", err)
        self.assertEqual("[1, 2]\n", dest.read_text("utf-8"))

    def test_run_as_a_program_it_exits_with_the_copy_verdict(self) -> None:
        script = SCRIPTS_LIB / "json_copy_key.py"
        current = self._file("current.json", '{"k":"v"}\n')
        dest = self._file("dest.json", "{}\n")
        self.assertEqual(
            (0, "", ""),
            run_guard(script, [str(script), str(dest), str(current), "k"]),
        )
        self.assertEqual({"k": "v"}, json.loads(dest.read_text("utf-8")))
        self.assertEqual(
            (1, "", "usage: json_copy_key.py DEST CURRENT KEY\n"),
            run_guard(script, [str(script), str(dest)]),
        )


class ParseYamlTests(unittest.TestCase):
    """parse_yaml.py exits 1 on the first file yaml.safe_load cannot read."""

    def setUp(self) -> None:
        self.saved_yaml = sys.modules.get("yaml", _MISSING)
        self.dir = self.enterContext(temp_dir())

    def tearDown(self) -> None:
        if self.saved_yaml is _MISSING:
            sys.modules.pop("yaml", None)
        else:
            sys.modules["yaml"] = self.saved_yaml

    def _load(self, module: object | None) -> types.ModuleType:
        """Load parse_yaml.py with `module` installed as the yaml package."""
        sys.modules["yaml"] = module  # type: ignore[assignment]
        mod = load_helper("parse_yaml")
        self.addCleanup(sys.modules.pop, mod.__name__, None)
        return mod

    def _file(self, name: str, text: str) -> pathlib.Path:
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return path

    @staticmethod
    def _call(mod: types.ModuleType, *paths: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = mod.main(["parse_yaml.py", *paths])
        return code, out.getvalue(), err.getvalue()

    def test_without_pyyaml_the_program_says_so_and_exits_one(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            self._load(None)
        self.assertEqual(1, caught.exception.code)
        self.assertEqual("", out.getvalue())
        self.assertEqual("parse_yaml: PyYAML is not installed\n", err.getvalue())

    def test_no_file_prints_the_usage(self) -> None:
        self.assertEqual(
            (1, "", "usage: parse_yaml.py FILE [FILE...]\n"),
            self._call(self._load(yaml_for_tests())),
        )

    def test_a_valid_file_is_accepted_silently(self) -> None:
        good = self._file("good.yaml", "a: 1\nb: [2, 3]\n")
        self.assertEqual((0, "", ""), self._call(self._load(yaml_for_tests()), str(good)))

    def test_every_file_on_the_command_line_is_checked(self) -> None:
        first = self._file("a.yaml", "a: 1\n")
        second = self._file("b.yaml", "- x\n- y\n")
        empty = self._file("empty.yaml", "")
        self.assertEqual(
            (0, "", ""),
            self._call(self._load(yaml_for_tests()), str(first), str(second), str(empty)),
        )

    def test_a_malformed_file_names_itself_and_exits_one(self) -> None:
        good = self._file("good.yaml", "a: 1\n")
        bad = self._file("bad.yaml", "a: [\n")
        code, out, err = self._call(self._load(yaml_for_tests()), str(good), str(bad))
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertTrue(err.startswith(f"parse_yaml: {bad}: "), err)

    def test_the_first_failure_stops_the_sweep(self) -> None:
        bad = self._file("bad.yaml", "a: [\n")
        worse = self._file("worse.yaml", "b: {\n")
        _, _, err = self._call(self._load(yaml_for_tests()), str(bad), str(worse))
        self.assertIn(str(bad), err)
        self.assertNotIn(str(worse), err)

    def test_a_missing_file_is_reported_as_an_error_not_a_crash(self) -> None:
        gone = self.dir / "gone.yaml"
        code, out, err = self._call(self._load(yaml_for_tests()), str(gone))
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertTrue(err.startswith(f"parse_yaml: {gone}: "), err)

    def test_a_directory_is_reported_as_an_error(self) -> None:
        code, _, err = self._call(self._load(yaml_for_tests()), str(self.dir))
        self.assertEqual(1, code)
        self.assertTrue(err.startswith(f"parse_yaml: {self.dir}: "), err)

    def test_run_as_a_program_it_exits_with_the_parse_verdict(self) -> None:
        sys.modules["yaml"] = yaml_for_tests()
        script = SCRIPTS_LIB / "parse_yaml.py"
        good = self._file("good.yaml", "a: 1\n")
        self.assertEqual((0, "", ""), run_guard(script, [str(script), str(good)]))
        bad = self._file("bad.yaml", "a: [\n")
        code, _, err = run_guard(script, [str(script), str(bad)])
        self.assertEqual(1, code)
        self.assertIn(f"parse_yaml: {bad}: ", err)
        self.assertEqual(
            (1, "", "usage: parse_yaml.py FILE [FILE...]\n"),
            run_guard(script, [str(script)]),
        )

    def test_the_yaml_the_helper_sees_rejects_the_same_text(self) -> None:
        """The stand-in and the real package agree, so both runs mean the same thing."""
        modules: list[tuple[str, types.ModuleType]] = [("stub", StubYaml())]
        if _REAL_YAML is not None:
            modules.append(("pyyaml", _REAL_YAML))
        for label, module in modules:
            with self.subTest(yaml=label):
                self.assertTrue(module.safe_load(io.StringIO("a: 1\nb: [2, 3]\n")))
                with self.assertRaises(module.YAMLError):
                    module.safe_load(io.StringIO("a: [\n"))


if __name__ == "__main__":
    unittest.main()
