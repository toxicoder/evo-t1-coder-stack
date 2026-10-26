#!/usr/bin/env python3
"""Unit tests for scripts/lib/mcp_lane_report.py, the MCP lane parser.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

The module is the parsing half of scripts/mcp-check.sh, so the contract under
test is the line shape it hands back: `lane`, `check`, `status`, `detail`, one
finding per line, tab-separated, with tabs and newlines squeezed out of the
detail. It decides nothing about exit codes or HTTP, so nothing here asserts
either. scripts/lib is not a package, so the module is loaded by file path with
importlib, and the shipped `if __name__ == "__main__"` guard is executed with
runpy rather than skipped.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import json
import os
import pathlib
import runpy
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_LIB = REPO_ROOT / "scripts" / "lib"
MODULE_PATH = SCRIPTS_LIB / "mcp_lane_report.py"

_module_ids = itertools.count()


def load_module():
    """Import the parser by file path under a throwaway name."""
    name = "mcp_lane_report_%d" % next(_module_ids)
    spec = importlib.util.spec_from_file_location(name, MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


def capture(call, *args, **kwargs):
    """Run one check function and return the finding lines it printed."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        call(*args, **kwargs)
    return buf.getvalue()


def lines(text):
    """Split captured output into finding tuples, dropping the trailing blank."""
    return [tuple(line.split("\t")) for line in text.splitlines() if line]


def executable_path():
    """A path that is certainly a file and executable, for the command checks."""
    return str(pathlib.Path(sys.executable).resolve())


class TempFileMixin:
    """Write scratch files under a per-test temporary directory."""

    def make_file(self, name, content, mode=0o644):
        path = pathlib.Path(self.tmp.name) / name  # type: ignore[attr-defined]
        path.write_text(content, encoding="utf-8")
        path.chmod(mode)
        return str(path)


class EmitTest(unittest.TestCase):
    """emit() owns the line shape the caller parses."""

    def test_tabs_and_newlines_are_squeezed_out_of_the_detail(self):
        text = capture(MODULE.emit, "searxng", "command", "warn", "a\tb\nc   d")
        self.assertEqual([("searxng", "command", "warn", "a b c d")], lines(text))

    def test_a_non_string_detail_is_stringified(self):
        text = capture(MODULE.emit, "context7", "args_config", "note", 404)
        self.assertEqual([("context7", "args_config", "note", "404")], lines(text))


class LoadConfigTest(TempFileMixin, unittest.TestCase):
    """load_config() turns a config into data or into one sentence."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_a_missing_file_is_a_named_error(self):
        config, error = MODULE.load_config(str(pathlib.Path(self.tmp.name) / "absent.toml"))
        self.assertIsNone(config)
        self.assertIn("no config file at", error)

    def test_a_readable_config_comes_back_as_data(self):
        path = self.make_file("ok.toml", '[mcp_servers.searxng]\ncommand = "/bin/true"\n')
        config, error = MODULE.load_config(path)
        self.assertIsNone(error)
        self.assertEqual("/bin/true", config["mcp_servers"]["searxng"]["command"])

    def test_an_unparsable_config_reports_instead_of_raising(self):
        path = self.make_file("bad.toml", "this is = = not toml [[[\n")
        config, error = MODULE.load_config(path)
        self.assertIsNone(config)
        self.assertIn("does not parse", error)

    def test_an_unreadable_file_reports_instead_of_raising(self):
        path = self.make_file("locked.toml", "x = 1\n")
        with mock.patch("builtins.open", side_effect=OSError("locked")):
            config, error = MODULE.load_config(path)
        self.assertIsNone(config)
        self.assertIn("does not parse: locked", error)


class ReadDoctorTest(TempFileMixin, unittest.TestCase):
    """read_doctor() is optional input: every bad shape is a plain None."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_no_path_and_a_missing_file_are_both_absent(self):
        self.assertIsNone(MODULE.read_doctor(""))
        self.assertIsNone(MODULE.read_doctor(str(pathlib.Path(self.tmp.name) / "none.json")))

    def test_a_report_comes_back_as_a_dict(self):
        path = self.make_file("d.json", json.dumps({"servers": []}))
        self.assertEqual({"servers": []}, MODULE.read_doctor(path))

    def test_a_broken_report_is_absent(self):
        path = self.make_file("broken.json", "{not json")
        self.assertIsNone(MODULE.read_doctor(path))

    def test_a_json_that_is_not_an_object_is_absent(self):
        path = self.make_file("list.json", "[1, 2]")
        self.assertIsNone(MODULE.read_doctor(path))

    def test_an_unreadable_report_is_absent(self):
        path = self.make_file("locked.json", "{}")
        with mock.patch("builtins.open", side_effect=OSError("locked")):
            self.assertIsNone(MODULE.read_doctor(path))


class DeclaredServersTest(unittest.TestCase):
    """declared_servers() tolerates a config with no mcp_servers table."""

    def test_the_table_passes_through(self):
        self.assertEqual({"a": {}}, MODULE.declared_servers({"mcp_servers": {"a": {}}}))

    def test_a_missing_or_wrong_typed_table_is_empty(self):
        self.assertEqual({}, MODULE.declared_servers({}))
        self.assertEqual({}, MODULE.declared_servers({"mcp_servers": "nope"}))


class CheckCommandTest(TempFileMixin, unittest.TestCase):
    """check_command() separates a broken config from image drift."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_a_block_with_no_command_is_an_error(self):
        text = capture(MODULE.check_command, "searxng", "")
        self.assertEqual([("searxng", "command", "error", "declared with no command= to launch")],
                         lines(text))

    def test_an_absolute_binary_that_exists_is_ok(self):
        text = capture(MODULE.check_command, "searxng", executable_path())
        self.assertEqual([("searxng", "command", "ok", executable_path())], lines(text))

    def test_an_absolute_binary_that_is_gone_is_a_warning(self):
        gone = str(pathlib.Path(self.tmp.name) / "not-baked")
        text = capture(MODULE.check_command, "searxng", gone)
        self.assertEqual([("searxng", "command", "warn", "missing %s" % gone)], lines(text))

    def test_a_bare_name_is_resolved_on_the_path(self):
        bin_dir = pathlib.Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        binary = bin_dir / "searxng-mcp-server"
        binary.write_text("#!/bin/sh\n", encoding="utf-8")
        binary.chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": str(bin_dir)}):
            text = capture(MODULE.check_command, "searxng", "searxng-mcp-server")
        self.assertEqual([("searxng", "command", "ok", str(binary))], lines(text))

    def test_a_bare_name_that_is_not_on_the_path_is_a_warning(self):
        with mock.patch.dict(os.environ, {"PATH": self.tmp.name}):
            text = capture(MODULE.check_command, "searxng", "searxng-mcp-server")
        self.assertEqual(
            [("searxng", "command", "warn", "missing searxng-mcp-server (not on PATH)")],
            lines(text))


class CacheTargetTest(unittest.TestCase):
    """cache_target() reads the proxy's own config path out of the args."""

    def test_no_flag_names_nothing(self):
        self.assertIsNone(MODULE.cache_target([]))
        self.assertIsNone(MODULE.cache_target(["--config"]))
        self.assertIsNone(MODULE.cache_target(["--verbose"]))

    def test_either_flag_style_names_the_file(self):
        self.assertEqual("/tmp/c.json", MODULE.cache_target(["--config", "/tmp/c.json"]))
        self.assertEqual("/tmp/c.json", MODULE.cache_target(["-c", "/tmp/c.json"]))


class CheckCacheConfigTest(TempFileMixin, unittest.TestCase):
    """check_cache_config() reports the cache file the proxy was told to read."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_args_without_a_config_flag_warn(self):
        text = capture(MODULE.check_cache_config, "context7", {"args": ["--verbose"]})
        self.assertEqual(
            [("context7", "args_config", "warn",
              "no --config argument; the proxy has no cache file to read")],
            lines(text))

    def test_a_missing_cache_file_warns(self):
        gone = str(pathlib.Path(self.tmp.name) / "cache.json")
        text = capture(MODULE.check_cache_config, "context7", {"args": ["--config", gone]})
        self.assertEqual(
            [("context7", "args_config", "warn",
              "missing %s (startup seeds it only while absent)" % gone)],
            lines(text))

    def test_a_present_cache_file_is_ok(self):
        path = self.make_file("cache.json", '{"servers": {}}')
        text = capture(MODULE.check_cache_config, "context7", {"args": ["--config", path]})
        self.assertEqual([("context7", "args_config", "ok", path)], lines(text))


class CheckUpstreamTest(TempFileMixin, unittest.TestCase):
    """check_upstream() reads through the proxy to the server it launches."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write_proxy(self, payload):
        return self.make_file("proxy.json", json.dumps(payload))

    def test_no_path_and_a_missing_file_say_nothing(self):
        self.assertEqual("", capture(MODULE.check_upstream, "context7", None))
        self.assertEqual("", capture(MODULE.check_upstream, "context7",
                                     str(pathlib.Path(self.tmp.name) / "gone")))

    def test_a_proxy_config_that_does_not_parse_warns(self):
        path = self.make_file("proxy.json", "{not json")
        text = capture(MODULE.check_upstream, "context7", path)
        self.assertEqual(
            [("context7", "command", "warn",
              "%s does not parse as the proxy config it is" % path)],
            lines(text))

    def test_a_json_shape_without_servers_says_nothing(self):
        self.assertEqual("", capture(MODULE.check_upstream, "context7", self.write_proxy([1])))
        self.assertEqual("", capture(MODULE.check_upstream, "context7", self.write_proxy({})))

    def test_a_server_entry_without_a_command_is_skipped(self):
        path = self.write_proxy({"servers": {"a": "string", "b": {"args": []}}})
        self.assertEqual("", capture(MODULE.check_upstream, "context7", path))

    def test_the_upstream_binary_is_reported_present_or_missing(self):
        gone = str(pathlib.Path(self.tmp.name) / "context7-mcp")
        path = self.write_proxy({"servers": {"context7": {"command": executable_path()},
                                             "other": {"command": gone}}})
        text = capture(MODULE.check_upstream, "context7", path)
        self.assertEqual(
            [("context7", "command", "ok", "%s (upstream of context7)" % executable_path()),
             ("context7", "command", "warn", "missing %s (upstream of other)" % gone)],
            lines(text))


class CheckEnvironmentTest(unittest.TestCase):
    """check_environment() settles a credential from the process, never the literal."""

    def test_a_lane_that_needs_nothing_says_nothing(self):
        self.assertEqual("", capture(MODULE.check_environment, "github", {}, {}))

    def test_an_inline_address_satisfies_the_url_lane(self):
        server = {"env": {"SEARXNG_URL": "http://searx.test:8181"}}
        text = capture(MODULE.check_environment, "searxng", server, {})
        self.assertEqual([("searxng", "url_env", "ok", "SEARXNG_URL")], lines(text))

    def test_a_non_dict_env_table_is_treated_as_empty(self):
        text = capture(MODULE.check_environment, "searxng", {"env": "nope"}, {})
        self.assertEqual(
            [("searxng", "url_env", "warn",
              "SEARXNG_URL is empty; this lane cannot reach its backend")],
            lines(text))

    def test_a_dollar_reference_is_resolved_from_the_environment(self):
        server = {"env": {"CONTEXT7_API_KEY": "$CONTEXT7_API_KEY"}}
        text = capture(MODULE.check_environment, "context7", server,
                       {"CONTEXT7_API_KEY": "ctx7sk-real"})
        self.assertEqual([("context7", "api_key", "ok", "CONTEXT7_API_KEY")], lines(text))

    def test_a_dollar_reference_that_resolves_to_nothing_warns(self):
        server = {"env": {"CONTEXT7_API_KEY": "$CONTEXT7_API_KEY"}}
        text = capture(MODULE.check_environment, "context7", server, {})
        self.assertEqual(
            [("context7", "api_key", "warn",
              "CONTEXT7_API_KEY is empty; this lane cannot reach its backend")],
            lines(text))

    def test_a_credential_only_the_process_carries_counts(self):
        text = capture(MODULE.check_environment, "context7", {},
                       {"CONTEXT7_API_KEY": "ctx7sk-real"})
        self.assertEqual([("context7", "api_key", "ok", "CONTEXT7_API_KEY")], lines(text))


class CheckDoctorTest(unittest.TestCase):
    """check_doctor() folds one server's handshake into that lane's findings."""

    def test_no_report_says_nothing(self):
        self.assertEqual("", capture(MODULE.check_doctor, "searxng", None))

    def test_a_healthy_server_is_reported(self):
        report = {"servers": [{"name": "searxng", "healthy": True}, "junk",
                              {"name": "other", "healthy": True}]}
        text = capture(MODULE.check_doctor, "searxng", report)
        self.assertEqual([("searxng", "doctor", "ok", "handshake OK")], lines(text))

    def test_a_failing_server_carries_its_failing_labels(self):
        report = {"servers": [{"name": "searxng", "healthy": False, "checks": [
            {"label": "command not found", "passed": False},
            {"label": "config readable", "passed": True},
            "junk",
        ]}]}
        text = capture(MODULE.check_doctor, "searxng", report)
        self.assertEqual(
            [("searxng", "doctor", "error", "handshake failed: command not found")],
            lines(text))

    def test_a_failing_server_without_detail_says_so(self):
        report = {"servers": [{"name": "searxng", "healthy": False}]}
        text = capture(MODULE.check_doctor, "searxng", report)
        self.assertEqual([("searxng", "doctor", "error", "handshake failed: no detail")],
                         lines(text))

    def test_a_lane_the_report_omits_is_a_note(self):
        text = capture(MODULE.check_doctor, "context7", {"servers": []})
        self.assertEqual([("context7", "doctor", "note", "not in the doctor report")],
                         lines(text))

    def test_a_report_without_a_servers_list_is_a_missing_lane(self):
        text = capture(MODULE.check_doctor, "context7", {})
        self.assertEqual([("context7", "doctor", "note", "not in the doctor report")],
                         lines(text))


class MainTest(TempFileMixin, unittest.TestCase):
    """main() is the CLI contract: one line per finding, and it always returns 0."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_main(self, argv, environ=None):
        env = {"PATH": os.environ.get("PATH", "")}
        env.update(environ or {})
        buf = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(sys, "argv", ["mcp_lane_report.py"] + argv), \
                contextlib.redirect_stdout(buf):
            status = MODULE.main()
        self.assertEqual(0, status)
        found = lines(buf.getvalue())
        # Each finding is measured once and printed once; a duplicated line would
        # double the caller's counters.
        self.assertEqual(len(found), len(set(found)), "a finding printed twice: %s" % found)
        return found

    def test_a_missing_config_is_one_error_line_naming_the_path(self):
        absent = str(pathlib.Path(self.tmp.name) / "absent.toml")
        found = self.run_main(["--config", absent])
        self.assertEqual(1, len(found))
        self.assertEqual(("config", "declared", "error"), found[0][:3])
        self.assertIn("no config file at", found[0][3])

    def test_a_lane_the_config_never_declared_is_an_error(self):
        cfg = self.make_file("c.toml", '[mcp_servers.github]\nurl = "https://x/mcp"\n')
        found = self.run_main(["--config", cfg, "--lanes", " searxng , ,context7 "])
        self.assertEqual(
            [("searxng", "declared", "error"), ("context7", "declared", "error"),
             ("github", "extra", "note")],
            [line[:3] for line in found])
        self.assertIn("the default render declares it", found[0][3])
        # The declared-but-not-required server still gets its one honest line.
        self.assertEqual("declared, but not a lane this run requires", found[-1][3])

    def test_a_healthy_stdio_run_reports_every_check(self):
        upstream = executable_path()
        cache = self.make_file("cache.json", json.dumps({"servers": {"context7": {"command": upstream}}}))
        cfg = self.make_file(
            "c.toml",
            "[mcp_servers.searxng]\n"
            'command = "%s"\n'
            'env = { SEARXNG_URL = "http://searx.test:8181" }\n\n'
            "[mcp_servers.context7]\n"
            'command = "%s"\n'
            'args = ["--config", "%s"]\n'
            'env = { CONTEXT7_API_KEY = "$CONTEXT7_API_KEY" }\n\n'
            "[mcp_servers.github]\n"
            'url = "https://x/mcp"\n' % (upstream, upstream, cache),
        )
        doctor = self.make_file("d.json", json.dumps({"servers": [
            {"name": "searxng", "healthy": True},
            {"name": "context7", "healthy": True},
            {"name": "github", "healthy": True},
            "junk",
            {"name": "unrelated", "healthy": False},
        ]}))
        found = self.run_main(["--config", cfg, "--lanes", "searxng,context7",
                               "--doctor", doctor],
                              environ={"CONTEXT7_API_KEY": "ctx7sk-real"})
        tuples = [line[:3] for line in found]
        self.assertIn(("searxng", "declared", "ok"), tuples)
        self.assertIn(("searxng", "command", "ok"), tuples)
        self.assertIn(("searxng", "url_env", "ok"), tuples)
        self.assertIn(("searxng", "doctor", "ok"), tuples)
        self.assertIn(("context7", "args_config", "ok"), tuples)
        self.assertIn(("context7", "api_key", "ok"), tuples)
        self.assertIn(("context7", "doctor", "ok"), tuples)
        self.assertIn(("github", "extra", "note"), tuples)
        details = [line[3] for line in found if line[0] == "github"]
        self.assertIn("handshake OK", details)

    def test_an_unhealthy_extra_lane_says_what_failed(self):
        cfg = self.make_file("c.toml", '[mcp_servers.github]\nurl = "https://x/mcp"\n')
        doctor = self.make_file("d.json", json.dumps({"servers": [
            {"name": "github", "healthy": False, "checks": [
                {"label": "Auth required", "passed": False}]}]}))
        found = self.run_main(["--config", cfg, "--lanes", "searxng", "--doctor", doctor])
        self.assertEqual(("github", "extra", "note", "not healthy: Auth required"), found[-1])

    def test_a_required_http_lane_skips_the_stdio_checks(self):
        cfg = self.make_file("c.toml", '[mcp_servers.github]\nurl = "https://x/mcp"\n')
        found = self.run_main(["--config", cfg, "--lanes", "github,custom"])
        self.assertEqual(
            [("github", "declared", "ok"),
             ("custom", "declared", "error")],
            [line[:3] for line in found])
        self.assertIn("not declared in", found[1][3])
        # An http lane has no binary to bake, and an unknown lane needs no
        # credential: neither gets a stdio-only check.
        self.assertNotIn("command", [line[1] for line in found])
        self.assertNotIn("url_env", [line[1] for line in found])

    def test_a_stdio_lane_with_a_broken_cache_setup_warns_its_way_through(self):
        cfg = self.make_file(
            "c.toml",
            "[mcp_servers.context7]\n"
            'command = "%s"\n'
            'args = ["--verbose"]\n' % executable_path(),
        )
        found = self.run_main(["--config", cfg, "--lanes", "context7"])
        tuples = [line[:3] for line in found]
        self.assertIn(("context7", "command", "ok"), tuples)
        self.assertIn(("context7", "args_config", "warn"), tuples)
        self.assertIn(("context7", "api_key", "warn"), tuples)
        # No --doctor means no handshake was taken, so the lane reports nothing
        # about one rather than a note that pretends a probe ran.
        self.assertNotIn("doctor", [line[1] for line in found])


class MainGuardTest(TempFileMixin, unittest.TestCase):
    """The shipped __main__ guard is a real code path: the shell runs the file."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_running_the_file_exits_with_the_parser_status(self):
        cfg = self.make_file("c.toml", '[mcp_servers.searxng]\ncommand = "%s"\n'
                             % executable_path())
        with mock.patch.object(sys, "argv", ["mcp_lane_report.py", "--config", cfg,
                                             "--lanes", "searxng"]), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(MODULE_PATH), run_name="__main__")
        self.assertEqual(0, caught.exception.code)


if __name__ == "__main__":
    unittest.main()
