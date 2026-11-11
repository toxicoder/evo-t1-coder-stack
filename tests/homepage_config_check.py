#!/usr/bin/env python3
"""Program purpose: fail when the Homepage dashboard payload breaks one of its own rules.

`homepage/config/*.yaml` is bind-mounted into the dashboard file by file, and nothing else
in this repository reads it: `//:validate` only proves the five files parse. These are the
invariants that a parse cannot catch, each one learned from a real dashboard failure or
from the shipped v2.4.0 bundle:

  token-declared   every `{{HOMEPAGE_VAR_X}}` a config file uses has a `HOMEPAGE_VAR_X:`
                   key in docker-compose.yml. An undeclared token renders literally, so a
                   card links to the string `{{HOMEPAGE_VAR_CODER_URL}}`.
  token-used       every `HOMEPAGE_VAR_X:` compose declares is used by some config file.
                   A dead one reads like a seam the dashboard still has.
  layout-group     every group named in services.yaml / bookmarks.yaml has a `layout`
                   entry in settings.yaml, and every `layout` key names a real group.
                   An unlisted group is invisible the moment any group carries `tab`, and
                   a stale layout key is a row of blank cells.
  row-columns      a group listed with `style: row` has `columns` equal to the cards it
                   actually has, which is what keeps the band from leaving a gap.
  href-browser     a card `href` is a `{{HOMEPAGE_VAR_*}}` token or a public URL. The
                   browser cannot resolve a compose service name, so `http://coder:3000`
                   in an href is a link that only the dashboard server could follow.
  monitor-network  a `siteMonitor` or widget `url` is a compose service name or a token,
                   and never a loopback or LAN-address literal: those bake the LAN into
                   git, which is the mistake the two URL spaces exist to avoid.
  block-mappings   no customapi widget declares more than four mappings in block display:
                   the shipped bundle slices the list, so a fifth row never renders.
  bookmark-shape   a bookmark's value is a list of single-key mappings carrying both
                   `abbr` and `href`. Written as a plain mapping instead, the entry loads
                   with a name and nothing else; the app drops the keys it did not ask
                   for and the tile renders blank.
  icon-path        a local `icon:` path lives under `/icons/`, the one path the auth
                   middleware exempts from the sign-in redirect.
  search-url       a `search` widget with `provider: custom` carries a url ending in `=`.
                   v2.4.0 appends the encoded query to the string it is given; there is
                   no `{{query}}` token to place it.

Usage: homepage_config_check.py [--root DIR] [--quiet]

Reads homepage/config/{settings,services,widgets,bookmarks}.yaml and docker-compose.yml
under --root (default: the current directory). Writes nothing; exit 0 clean, 1 on findings.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Union, cast

JsonValue = Union["JsonDict", "JsonList", str, int, float, bool, None]
JsonDict = dict[str, "JsonValue"]
JsonList = list["JsonValue"]

# The four files the dashboard reads, in the order the app reads them.
CONFIG_FILES = ("settings.yaml", "services.yaml", "widgets.yaml", "bookmarks.yaml")
TOKEN_RE = re.compile(r"\{\{(HOMEPAGE_(?:VAR|FILE)_[A-Z0-9_]+)\}\}")
COMPOSE_VAR_RE = re.compile(r"^[ \t]+(HOMEPAGE_(?:VAR|FILE)_[A-Z0-9_]+):")
# The two URL spaces the payload keeps apart. An address literal in a committed dashboard
# file is the classic mix-up: it is either a browser link that only works on the box, or
# a server probe that breaks with the LAN.
ADDRESS_LITERAL_RE = re.compile(r"^[a-z][a-z0-9+.-]*://(?:localhost|127\.(?:\d{1,3}\.){2}\d{1,3}|(?:10|192\.168)\.|172\.(?:1[6-9]|2\d|3[01])\.)", re.I)
# compose service names, which resolve only inside the container's network.
COMPOSE_SERVICES = frozenset(
    {
        "coder",
        "db",
        "hermes",
        "hermes-init",
        "homepage",
        "homepage-proxy",
        "kasm",
        "litellm",
        "ollama",
        "router",
        "searxng",
    }
)
MAX_BLOCK_MAPPINGS = 4


class PayloadError(Exception):
    """One payload file could not be read or parsed.

    The YAML parser is imported inside load_yaml rather than at module scope so the rules
    below stay importable on an interpreter with no PyYAML: the unit tests drive them
    directly, and the CLI reports this error in its own voice rather than a traceback.
    """


def read_text(path: str) -> str:
    """Read one payload file as text."""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise PayloadError(f"{path}: {exc.strerror or exc}") from exc


def load_yaml(path: str) -> JsonValue:
    """Parse one payload file, naming it in any failure."""
    try:
        import yaml
    except ImportError as exc:
        raise PayloadError(f"{path}: PyYAML is not installed") from exc
    try:
        parsed = yaml.safe_load(read_text(path))
    except yaml.YAMLError as exc:
        raise PayloadError(f"{path}: {exc}") from exc
    return cast("JsonValue", parsed)


def as_dict(value: JsonValue) -> JsonDict:
    """Narrow to a mapping, treating anything else as empty."""
    return value if isinstance(value, dict) else {}


def as_list(value: JsonValue) -> JsonList:
    """Narrow to a list, treating anything else as empty."""
    return value if isinstance(value, list) else []


def groups_of(document: JsonValue) -> dict[str, JsonList]:
    """Flatten the `- Group: - Card:` shape into group name to card entries.

    Both services.yaml and bookmarks.yaml are a list of single-key mappings whose value
    is a list; the difference is only what the card entries hold.
    """
    groups: dict[str, JsonList] = {}
    for entry in as_list(document):
        for name, cards in as_dict(entry).items():
            groups[name] = as_list(cards)
    return groups


def card_widgets(card: JsonDict) -> list[JsonDict]:
    """Return a card's widgets from either spelling, `widget:` or `widgets:`."""
    single = card.get("widget")
    many = card.get("widgets")
    found: list[JsonDict] = []
    if isinstance(single, dict):
        found.append(single)
    found.extend(widget for widget in as_list(many) if isinstance(widget, dict))
    return found


def named_entries(items: JsonList) -> list[tuple[str, JsonDict]]:
    """Unwrap the `- Name: <fields>` entries a payload list is built from.

    A card is not a mapping with a `name` key: the list holds single-key mappings whose
    key is the card's title and whose value carries the fields. Reading the fields off
    the outer mapping is the mistake that makes every card check a silent no-op.
    """
    found: list[tuple[str, JsonDict]] = []
    for item in items:
        for title, fields in as_dict(item).items():
            found.append((str(title), as_dict(fields)))
    return found


def url_host(url: str) -> str:
    """The host part of a URL, or an empty string when it is not a plain URL."""
    match = re.match(r"^[a-z][a-z0-9+.-]*://([^/?#]+)", url, re.I)
    if match is None:
        return ""
    return match.group(1).split(":")[0]


def check_tokens(config_text: dict[str, str], compose_text: str) -> list[str]:
    """Pair the `{{HOMEPAGE_VAR_*}}` tokens with the keys compose fills in."""
    used: set[str] = set()
    for text in config_text.values():
        used.update(TOKEN_RE.findall(text))
    declared: set[str] = set()
    for line in compose_text.splitlines():
        match = COMPOSE_VAR_RE.match(line)
        if match is not None:
            declared.add(match.group(1))
    findings = [
        f"error: token-declared: {name} is used by the dashboard but docker-compose.yml declares no such key"
        for name in sorted(used - declared)
    ]
    findings += [
        f"error: token-used: docker-compose.yml declares {name}, which no dashboard config file uses"
        for name in sorted(declared - used)
    ]
    return findings


def check_layout(settings: JsonDict, service_groups: dict[str, JsonList], bookmark_groups: dict[str, JsonList]) -> list[str]:
    """Keep settings.yaml's layout block and the group names in the payload in step."""
    layout = as_dict(settings.get("layout"))
    groups = {**service_groups, **bookmark_groups}
    findings = [f"error: layout-group: group '{name}' has no layout entry in settings.yaml" for name in sorted(set(groups) - set(layout))]
    findings += [f"error: layout-group: layout names '{name}', which no service or bookmark group defines" for name in sorted(set(layout) - set(groups))]
    for name, entry in sorted(layout.items()):
        spec = as_dict(entry)
        if spec.get("style") != "row":
            continue
        cards = groups.get(name, [])
        columns = spec.get("columns")
        if not isinstance(columns, int) or columns != len(cards):
            findings.append(f"error: row-columns: group '{name}' is style: row with columns={columns!r} but holds {len(cards)} card(s)")
    return findings


def check_hrefs(service_groups: dict[str, JsonList], bookmark_groups: dict[str, JsonList]) -> list[str]:
    """An href is what the browser opens, so it may not name a compose service."""
    findings: list[str] = []
    for group, cards in sorted(service_groups.items()):
        for name, card in named_entries(cards):
            href = card.get("href")
            if not isinstance(href, str):
                continue
            if href.startswith("{{") and href.endswith("}}"):
                continue
            host = url_host(href)
            if host in COMPOSE_SERVICES or ADDRESS_LITERAL_RE.match(href):
                findings.append(f"error: href-browser: {group}/{name} href '{href}' resolves only inside the compose network")
    for group, entries in sorted(bookmark_groups.items()):
        for bookmark in entries:
            for title, body in as_dict(bookmark).items():
                for item in as_list(body):
                    href = as_dict(item).get("href")
                    if isinstance(href, str) and (url_host(href) in COMPOSE_SERVICES or ADDRESS_LITERAL_RE.match(href)):
                        findings.append(f"error: href-browser: {group}/{title} bookmark points at '{href}', which no browser can resolve")
    return findings


def check_monitors(service_groups: dict[str, JsonList]) -> list[str]:
    """A probe is fetched server-side, so it uses compose DNS and never an address literal."""
    findings: list[str] = []
    for group, cards in sorted(service_groups.items()):
        for name, card in named_entries(cards):
            targets: list[tuple[str, str]] = []
            monitor = card.get("siteMonitor")
            if isinstance(monitor, str):
                targets.append(("siteMonitor", monitor))
            for widget in card_widgets(card):
                url = widget.get("url")
                if isinstance(url, str):
                    targets.append(("widget url", url))
            for kind, target in targets:
                if ADDRESS_LITERAL_RE.match(target):
                    findings.append(f"error: monitor-network: {group}/{name} {kind} hard-codes the address '{target}'")
    return findings


def check_widgets(service_groups: dict[str, JsonList]) -> list[str]:
    """Per-widget rules from the shipped v2.4.0 component."""
    findings: list[str] = []
    for group, cards in sorted(service_groups.items()):
        for name, card in named_entries(cards):
            for widget in card_widgets(card):
                if str(widget.get("type", "")) != "customapi":
                    continue
                if "display" in widget and widget.get("display") != "block":
                    continue
                mappings = as_list(widget.get("mappings"))
                if len(mappings) > MAX_BLOCK_MAPPINGS:
                    findings.append(
                        f"error: block-mappings: {group}/{name} declares {len(mappings)} mappings; "
                        f"block display renders the first {MAX_BLOCK_MAPPINGS}"
                    )
    return findings


def check_bookmarks(bookmark_groups: dict[str, JsonList]) -> list[str]:
    """A bookmark is a name over a list of {abbr, href} mappings, not a bare mapping."""
    findings: list[str] = []
    for group, entries in sorted(bookmark_groups.items()):
        for bookmark in entries:
            for title, body in as_dict(bookmark).items():
                if isinstance(body, dict):
                    findings.append(
                        f"error: bookmark-shape: {group}/{title} is a mapping; the app reads a list of "
                        "single-key mappings and drops keys it did not ask for, so the tile renders blank"
                    )
                    continue
                items = as_list(body)
                if not items:
                    findings.append(f"error: bookmark-shape: {group}/{title} has no bookmark entry")
                for item in items:
                    fields = as_dict(item)
                    missing = [key for key in ("abbr", "href") if not isinstance(fields.get(key), str)]
                    if missing:
                        findings.append(f"error: bookmark-shape: {group}/{title} entry is missing {' and '.join(missing)}")
    return findings


def check_icons(settings: JsonDict, service_groups: dict[str, JsonList], widgets_doc: JsonValue) -> list[str]:
    """Anything served from the app's own static tree has to sit under the exempt path."""
    findings: list[str] = []
    wanted: list[tuple[str, str]] = []
    favicon = settings.get("favicon")
    if isinstance(favicon, str):
        wanted.append(("settings favicon", favicon))
    background = as_dict(settings.get("background")).get("image")
    if isinstance(background, str):
        wanted.append(("settings background.image", background))
    for group, cards in sorted(service_groups.items()):
        for name, card in named_entries(cards):
            icon = card.get("icon")
            if isinstance(icon, str):
                wanted.append((f"{group}/{name} icon", icon))
    for entry in as_list(widgets_doc):
        for name, spec in as_dict(entry).items():
            icon = as_dict(spec).get("icon")
            if isinstance(icon, str):
                wanted.append((f"widgets {name} icon", icon))
    for label, value in wanted:
        if value.startswith("/") and not value.startswith("/icons/"):
            findings.append(f"error: icon-path: {label} '{value}' sits outside /icons/, which the auth middleware exempts")
    return findings


def check_widgets_file(document: JsonValue) -> list[str]:
    """Rules that belong to the info-widget list rather than to a card.

    widgets.yaml holds `- <name>: <options>` mappings; the `type`/`options` pair seen on
    the wire is what the app hands the client, not what the file says.
    """
    findings: list[str] = []
    for entry in as_list(document):
        for name, spec in as_dict(entry).items():
            options = as_dict(spec)
            if name != "search" or options.get("provider") != "custom":
                continue
            url = options.get("url")
            if not isinstance(url, str) or not url.endswith("="):
                findings.append("error: search-url: provider: custom needs a url ending in the query parameter, e.g. .../search?q=")
    return findings


def main(argv: list[str]) -> int:
    """Run every check against one checkout and print the findings."""
    parser = argparse.ArgumentParser(prog="homepage_config_check.py", description="Pin the Homepage dashboard payload invariants.")
    parser.add_argument("--root", default=".", help="checkout to inspect (default: the current directory)")
    parser.add_argument("--quiet", action="store_true", help="print only the summary line")
    args = parser.parse_args(argv[1:])

    config_dir = os.path.join(args.root, "homepage", "config")
    compose_path = os.path.join(args.root, "docker-compose.yml")
    missing = [p for p in [os.path.join(config_dir, name) for name in CONFIG_FILES] + [compose_path] if not os.path.isfile(p)]
    if missing:
        for path in missing:
            sys.stdout.write(f"error: missing: {path} is not in the tree\n")
        sys.stdout.write("summary: 1 check failed (missing payload)\n")
        return 1

    try:
        text = {name: read_text(os.path.join(config_dir, name)) for name in CONFIG_FILES}
        settings = as_dict(load_yaml(os.path.join(config_dir, "settings.yaml")))
        services = load_yaml(os.path.join(config_dir, "services.yaml"))
        widgets = load_yaml(os.path.join(config_dir, "widgets.yaml"))
        bookmarks = load_yaml(os.path.join(config_dir, "bookmarks.yaml"))
        compose = read_text(compose_path)
    except PayloadError as exc:
        sys.stdout.write(f"error: parse: {exc}\n")
        sys.stdout.write("summary: 1 check failed (payload did not parse)\n")
        return 1

    service_groups = groups_of(services)
    bookmark_groups = groups_of(bookmarks)
    findings: list[str] = []
    findings += check_tokens(text, compose)
    findings += check_layout(settings, service_groups, bookmark_groups)
    findings += check_hrefs(service_groups, bookmark_groups)
    findings += check_monitors(service_groups)
    findings += check_widgets(service_groups)
    findings += check_bookmarks(bookmark_groups)
    findings += check_icons(settings, service_groups, widgets)
    findings += check_widgets_file(widgets)

    if not args.quiet:
        for line in findings:
            sys.stdout.write(line + "\n")
    sys.stdout.write(f"summary: {len(findings)} findings\n")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
