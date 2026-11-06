#!/usr/bin/env python3
"""Read a Grok Build config and report the state of its MCP lanes.

This is the parsing half of scripts/mcp-check.sh: TOML and JSON are read here so
the caller stays shell. It prints one tab-separated finding per line and decides
nothing about exit codes, HTTP, or how a finding is worded to an operator.

Line shape:  lane \t check \t status \t detail
  check   one of declared|command|args_config|url_env|api_key|doctor|extra
  status  one of ok|warn|error|note

A missing or unparseable config is reported as a single error line rather than a
traceback, so the caller always has something to print.

Who owns the file is the caller's call, not this parser's: it is told with
--unmanaged when no stack ownership marker survived in the config, which is what
decides whether a lane missing from the render blames a push gate or an unmanaged
file.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tomllib
from collections.abc import Mapping, Sequence
from typing import Literal, TypedDict, Union, cast

# The two fixed vocabularies the module docstring names, written as Literals so a
# check or status the caller's awk does not know is a gate failure rather than a
# line an operator never sees. The list is exactly what this module emits, which
# is narrower than the vocabulary it once documented: the ownership marker is read
# by the caller and so is never emitted from here, and a proxy's cache file is
# reported under `args_config`, not a `cache_config` check. `extra` is main()'s
# note line for a server the operator declared that no required lane covers.
LaneCheck = Literal["declared", "command", "args_config", "url_env",
                    "api_key", "doctor", "extra"]
LaneStatus = Literal["ok", "warn", "error", "note"]

# The two unstructured trees the readers hand back, named so no signature has to
# widen to Any. tomllib has no null and json does, which is the only difference
# between the shapes; narrow to a table or an array with isinstance.
TomlValue = Union["TomlTable", "TomlArray", str, int, float, bool]
TomlTable = dict[str, "TomlValue"]
TomlArray = list["TomlValue"]
JsonValue = Union["JsonDict", "JsonArray", str, int, float, bool, None]
JsonDict = dict[str, "JsonValue"]
JsonArray = list["JsonValue"]


class LaneRequirement(TypedDict, total=False):
    """What one lane needs beyond its block being present.

    The keys differ per lane: an http lane has no binary and no key to settle,
    and only the context7 proxy has a cache file worth reading through, so every
    key is optional here rather than the table being two parallel shapes.
    """

    transport: Literal["stdio", "http"]
    env_key: str
    cache_config: bool


# The lanes this stack ships, and what each one needs beyond being declared.
# A stdio lane's `command` is baked into the golden image, so a missing file is
# drift between the image and the template rather than a broken config. The
# install advice an operator gets is built in the caller from
# images/dev/tool-versions.env, which keeps one source of package truth.
LANE_REQUIREMENTS: dict[str, LaneRequirement] = {
    "searxng": {"transport": "stdio", "env_key": "SEARXNG_URL"},
    "context7": {
        "transport": "stdio",
        "env_key": "CONTEXT7_API_KEY",
        "cache_config": True,
    },
    "github": {"transport": "http"},
}


def emit(lane: str, check: LaneCheck, status: LaneStatus, detail: object) -> None:
    """Print one finding, with tab and newline kept out of the detail text."""
    # detail is whatever the caller has to hand - a path, a key name, a sentence -
    # so it is stringified here rather than constrained at every call site.
    clean = " ".join(str(detail).split())
    sys.stdout.write("\t".join([lane, check, status, clean]) + "\n")


def load_config(path: str) -> tuple[TomlTable | None, str | None]:
    """Return (config, error). error is None when the file parsed."""
    if not os.path.isfile(path):
        return None, "no config file at %s" % path
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle), None
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return None, "%s does not parse: %s" % (path, exc)


def read_doctor(path: str) -> JsonDict | None:
    """Return the doctor report as a dict, or None when it is absent or unreadable."""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            report: JsonValue = json.load(handle)
    except (OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def declared_servers(config: TomlTable) -> TomlTable:
    """Return the [mcp_servers.*] table, empty when the config declares none."""
    servers = config.get("mcp_servers")
    return servers if isinstance(servers, dict) else {}


def missing_lane_detail(path: str, unmanaged: bool) -> str:
    """Say why a required lane is absent, blaming whoever owns the file.

    The caller decides `unmanaged` by looking for the stack ownership marker:
    only a file the stack renders can be blamed on a gate or an old template.
    """
    if unmanaged:
        return ("not declared in %s - this file carries no stack ownership "
                "marker, so nothing re-renders it; re-materialize it with "
                "'bazelisk run //scripts:seed-dev-env -- --force'" % path)
    return ("not declared in %s - the default render declares it, so a push "
            "passed its gate false or the template is old" % path)


def check_command(lane: str, command: str) -> bool:
    """Report one stdio lane's `command` binary."""
    if not command:
        emit(lane, "command", "error", "declared with no command= to launch")
        return False
    if os.path.isabs(command):
        if os.path.isfile(command) and os.access(command, os.X_OK):
            emit(lane, "command", "ok", command)
            return True
        emit(lane, "command", "warn", "missing %s" % command)
        return False
    # A bare name is a PATH lookup; the caller's remedy text names the package.
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(entry, command)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            emit(lane, "command", "ok", candidate)
            return True
    emit(lane, "command", "warn", "missing %s (not on PATH)" % command)
    return False


def cache_target(args: Sequence[str]) -> str | None:
    """Return the file a proxy's --config/-c argument names, or None."""
    target: str | None = None
    for index, item in enumerate(args):
        if item in ("--config", "-c") and index + 1 < len(args):
            target = args[index + 1]
    return target


def check_cache_config(lane: str, server: TomlTable) -> bool:
    """Report the mcp-cache-proxy config a context7 block points its --config at."""
    # The template renders args as a list of strings, so the cast states that
    # contract rather than filtering anything out of the block.
    target = cache_target(cast("list[str]", server.get("args") or []))
    if target is None:
        emit(lane, "args_config", "warn", "no --config argument; the proxy has no cache file to read")
        return False
    if os.path.isfile(target):
        emit(lane, "args_config", "ok", target)
        return True
    emit(lane, "args_config", "warn", "missing %s (startup seeds it only while absent)" % target)
    return False


def check_upstream(lane: str, cache_config_path: str | None) -> None:
    """Report the server the cache proxy itself launches."""
    if not cache_config_path or not os.path.isfile(cache_config_path):
        return
    try:
        with open(cache_config_path, "r", encoding="utf-8") as handle:
            proxy: JsonValue = json.load(handle)
    except (OSError, ValueError):
        emit(lane, "command", "warn", "%s does not parse as the proxy config it is" % cache_config_path)
        return
    servers = proxy.get("servers") if isinstance(proxy, dict) else None
    if not isinstance(servers, dict):
        return
    for name, spec in servers.items():
        # A proxy server's command is a path by convention; the cast says so and
        # leaves the value flowing exactly as it did untyped, isfile/access and
        # the %s detail text included.
        command = cast("str | None",
                       spec.get("command") if isinstance(spec, dict) else None)
        if not command:
            continue
        if os.path.isfile(command) and os.access(command, os.X_OK):
            emit(lane, "command", "ok", "%s (upstream of %s)" % (command, name))
        else:
            emit(lane, "command", "warn", "missing %s (upstream of %s)" % (command, name))


def check_environment(lane: str, server: TomlTable, environ: Mapping[str, str]) -> None:
    """Report the credential or address a lane reads out of the environment."""
    needs = LANE_REQUIREMENTS.get(lane, {})
    key = needs.get("env_key")
    if not key:
        return
    # The isinstance guard is what makes the cast safe: an env block that is not
    # a table is replaced by the empty dict, so inline is a table either way.
    inline = cast("TomlTable",
                  server.get("env") if isinstance(server.get("env"), dict) else {})
    value = inline.get(key) or environ.get(key) or ""
    # The template renders a reference, not a value, so the string surviving to
    # here is a name the CLI expands later; only the process env settles it.
    if isinstance(value, str) and value.startswith("$"):
        value = environ.get(key, "")
    if value:
        emit(lane, "api_key" if key == "CONTEXT7_API_KEY" else "url_env", "ok", key)
    elif key == "CONTEXT7_API_KEY":
        # The Context7 key is optional: it only decorates the outbound calls,
        # so an empty one is a warning about rate limits, not reachability.
        emit(lane, "api_key", "warn",
             "%s is empty; the key is optional and only decorates the outbound "
             "calls to the Context7 API, so the lane still handshakes and "
             "answers at the public rate limits, with private libraries out of "
             "reach" % key)
    else:
        emit(lane, "url_env", "warn", "%s is empty; this lane cannot reach its backend" % key)


def check_doctor(lane: str, report: JsonDict | None) -> None:
    """Report what a live handshake said about one lane, when a report was taken."""
    if report is None:
        return
    # A capture is whatever `grok mcp doctor --json` wrote, so the only thing
    # known here is that servers is a list; each entry is tested below.
    for server in cast("JsonArray", report.get("servers") or []):
        if not isinstance(server, dict) or server.get("name") != lane:
            continue
        if server.get("healthy"):
            emit(lane, "doctor", "ok", "handshake OK")
            return
        failing = [str(check.get("label"))
                   for check in cast("JsonArray", server.get("checks") or [])
                   if isinstance(check, dict) and not check.get("passed")]
        emit(lane, "doctor", "error", "handshake failed: %s" % ("; ".join(failing) or "no detail"))
        return
    emit(lane, "doctor", "note", "not in the doctor report")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True, help="path to ~/.grok/config.toml")
    parser.add_argument("--lanes", default="searxng,context7",
                        help="comma-separated lanes to require")
    parser.add_argument("--doctor", default="",
                        help="a `grok mcp doctor --json` capture to fold in")
    parser.add_argument("--unmanaged", action="store_true",
                        help="the caller found no stack ownership marker in --config")
    args = parser.parse_args()

    lanes: list[str] = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
    config, error = load_config(args.config)
    if config is None:
        emit("config", "declared", "error", error)
        return 0

    servers = declared_servers(config)
    for lane in lanes:
        server = servers.get(lane)
        if not isinstance(server, dict):
            emit(lane, "declared", "error",
                 missing_lane_detail(args.config, args.unmanaged))
            continue
        emit(lane, "declared", "ok", "block present")
        if LANE_REQUIREMENTS.get(lane, {}).get("transport") == "stdio":
            # command= is a string in every render; the cast is the same
            # assertion check_upstream makes about a proxy's command.
            check_command(lane, cast("str", server.get("command")))
            if LANE_REQUIREMENTS[lane].get("cache_config"):
                if check_cache_config(lane, server):
                    check_upstream(lane, cache_target(
                        cast("list[str]", server.get("args") or [])))
        check_environment(lane, server, os.environ)
        check_doctor(lane, read_doctor(args.doctor))

    report = read_doctor(args.doctor)
    for name in sorted(set(servers) - set(lanes)):
        emit(name, "extra", "note", "declared, but not a lane this run requires")
        # Not required, still worth one honest line: a server the operator left
        # declared and that will not handshake is something they can act on.
        # The capture's servers list is only known to be a list; the entry guard
        # below is what decides whether it is a table. It is typed as a TOML
        # table tree because this loop shares its `server` binding with the
        # config table above, and past the guard the two are the same shape.
        for server in cast("TomlArray", (report or {}).get("servers") or []):
            if not isinstance(server, dict) or server.get("name") != name:
                continue
            if server.get("healthy"):
                emit(name, "extra", "note", "handshake OK")
            else:
                failing = [str(check.get("label"))
                           for check in cast("TomlArray", server.get("checks") or [])
                           if isinstance(check, dict) and not check.get("passed")]
                emit(name, "extra", "note",
                     "not healthy: %s" % ("; ".join(failing) or "no detail"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
