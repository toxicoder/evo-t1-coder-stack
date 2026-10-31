#!/usr/bin/env python3
"""Read a Grok Build config and report the state of its MCP lanes.

This is the parsing half of scripts/mcp-check.sh: TOML and JSON are read here so
the caller stays shell. It prints one tab-separated finding per line and decides
nothing about exit codes, HTTP, or how a finding is worded to an operator.

Line shape:  lane \t check \t status \t detail
  check   one of declared|marker|command|args_config|url_env|api_key|cache_config|doctor
  status  one of ok|warn|error|note

A missing or unparseable config is reported as a single error line rather than a
traceback, so the caller always has something to print.

Who owns the file is the caller's call, not this parser's: it is told with
--unmanaged when no stack ownership marker survived in the config, which is what
decides whether a lane missing from the render blames a push gate or an unmanaged
file.
"""

import argparse
import json
import os
import sys
import tomllib

# The lanes this stack ships, and what each one needs beyond being declared.
# A stdio lane's `command` is baked into the golden image, so a missing file is
# drift between the image and the template rather than a broken config. The
# install advice an operator gets is built in the caller from
# images/dev/tool-versions.env, which keeps one source of package truth.
LANE_REQUIREMENTS = {
    "searxng": {"transport": "stdio", "env_key": "SEARXNG_URL"},
    "context7": {
        "transport": "stdio",
        "env_key": "CONTEXT7_API_KEY",
        "cache_config": True,
    },
    "github": {"transport": "http"},
}


def emit(lane, check, status, detail):
    """Print one finding, with tab and newline kept out of the detail text."""
    clean = " ".join(str(detail).split())
    sys.stdout.write("\t".join([lane, check, status, clean]) + "\n")


def load_config(path):
    """Return (config, error). error is None when the file parsed."""
    if not os.path.isfile(path):
        return None, "no config file at %s" % path
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle), None
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return None, "%s does not parse: %s" % (path, exc)


def read_doctor(path):
    """Return the doctor report as a dict, or None when it is absent or unreadable."""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def declared_servers(config):
    """Return the [mcp_servers.*] table, empty when the config declares none."""
    servers = config.get("mcp_servers")
    return servers if isinstance(servers, dict) else {}


def missing_lane_detail(path, unmanaged):
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


def check_command(lane, command):
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


def cache_target(args):
    """Return the file a proxy's --config/-c argument names, or None."""
    target = None
    for index, item in enumerate(args):
        if item in ("--config", "-c") and index + 1 < len(args):
            target = args[index + 1]
    return target


def check_cache_config(lane, server):
    """Report the mcp-cache-proxy config a context7 block points its --config at."""
    target = cache_target(server.get("args") or [])
    if target is None:
        emit(lane, "args_config", "warn", "no --config argument; the proxy has no cache file to read")
        return False
    if os.path.isfile(target):
        emit(lane, "args_config", "ok", target)
        return True
    emit(lane, "args_config", "warn", "missing %s (startup seeds it only while absent)" % target)
    return False


def check_upstream(lane, cache_config_path):
    """Report the server the cache proxy itself launches."""
    if not cache_config_path or not os.path.isfile(cache_config_path):
        return
    try:
        with open(cache_config_path, "r", encoding="utf-8") as handle:
            proxy = json.load(handle)
    except (OSError, ValueError):
        emit(lane, "command", "warn", "%s does not parse as the proxy config it is" % cache_config_path)
        return
    servers = proxy.get("servers") if isinstance(proxy, dict) else None
    if not isinstance(servers, dict):
        return
    for name, spec in servers.items():
        command = spec.get("command") if isinstance(spec, dict) else None
        if not command:
            continue
        if os.path.isfile(command) and os.access(command, os.X_OK):
            emit(lane, "command", "ok", "%s (upstream of %s)" % (command, name))
        else:
            emit(lane, "command", "warn", "missing %s (upstream of %s)" % (command, name))


def check_environment(lane, server, environ):
    """Report the credential or address a lane reads out of the environment."""
    needs = LANE_REQUIREMENTS.get(lane, {})
    key = needs.get("env_key")
    if not key:
        return
    inline = server.get("env") if isinstance(server.get("env"), dict) else {}
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


def check_doctor(lane, report):
    """Report what a live handshake said about one lane, when a report was taken."""
    if report is None:
        return
    for server in report.get("servers") or []:
        if not isinstance(server, dict) or server.get("name") != lane:
            continue
        if server.get("healthy"):
            emit(lane, "doctor", "ok", "handshake OK")
            return
        failing = [str(check.get("label")) for check in (server.get("checks") or [])
                   if isinstance(check, dict) and not check.get("passed")]
        emit(lane, "doctor", "error", "handshake failed: %s" % ("; ".join(failing) or "no detail"))
        return
    emit(lane, "doctor", "note", "not in the doctor report")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True, help="path to ~/.grok/config.toml")
    parser.add_argument("--lanes", default="searxng,context7",
                        help="comma-separated lanes to require")
    parser.add_argument("--doctor", default="",
                        help="a `grok mcp doctor --json` capture to fold in")
    parser.add_argument("--unmanaged", action="store_true",
                        help="the caller found no stack ownership marker in --config")
    args = parser.parse_args()

    lanes = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
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
            check_command(lane, server.get("command"))
            if LANE_REQUIREMENTS[lane].get("cache_config"):
                if check_cache_config(lane, server):
                    check_upstream(lane, cache_target(server.get("args") or []))
        check_environment(lane, server, os.environ)
        check_doctor(lane, read_doctor(args.doctor))

    report = read_doctor(args.doctor)
    for name in sorted(set(servers) - set(lanes)):
        emit(name, "extra", "note", "declared, but not a lane this run requires")
        # Not required, still worth one honest line: a server the operator left
        # declared and that will not handshake is something they can act on.
        for server in (report or {}).get("servers") or []:
            if not isinstance(server, dict) or server.get("name") != name:
                continue
            if server.get("healthy"):
                emit(name, "extra", "note", "handshake OK")
            else:
                failing = [str(check.get("label")) for check in (server.get("checks") or [])
                           if isinstance(check, dict) and not check.get("passed")]
                emit(name, "extra", "note",
                     "not healthy: %s" % ("; ".join(failing) or "no detail"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
