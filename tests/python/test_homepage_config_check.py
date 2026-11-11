#!/usr/bin/env python3
"""Unit tests for tests/homepage_config_check.py, the dashboard payload gate.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

tests/bats/homepage-config.bats pins the CLI: the shipped payload passes, and each rule
still fires against a broken scratch tree. This file pins the pure decisions underneath,
where a regression is cheapest to name and hardest to see in the CLI:

  named_entries    a card is a single-key mapping whose key is the card's title. Reading
                   the fields off the outer mapping instead makes every card rule a
                   silent pass, which is the failure mode a payload gate most needs to
                   survive.
  url_host         the two URL spaces are told apart by host, so a port, a missing
                   scheme or an unsubstituted token has to come back non-matching.
  check_tokens     both directions, because an unfilled token and an unused key are
                   different faults with different fixes.
  check_layout     columns counts cards, not widgets or subgroups.
  check_bookmarks  the shape the app actually reads.
  check_widgets    the four-row block cap, and the display: escape from it.
  check_widgets_file  the file's `- search:` shape, not the client's type/options shape.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest
from typing import cast

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_module() -> types.ModuleType:
    """Import tests/homepage_config_check.py by path, the way the Bats suite runs it."""
    path = REPO_ROOT / "tests" / "homepage_config_check.py"
    spec = importlib.util.spec_from_file_location("homepage_config_check", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["homepage_config_check"] = module
    spec.loader.exec_module(module)
    return module


CHECKER = load_module()


def rule(name: str, *args: object) -> list[object]:
    """Call one checker rule by name and return its raw findings."""
    rule_fn: object = getattr(CHECKER, name)
    if not callable(rule_fn):
        raise AssertionError("%s is not a rule" % name)
    value = rule_fn(*args)
    if not isinstance(value, list):
        raise AssertionError("%s did not return a list" % name)
    return list(value)


def findings(name: str, *args: object) -> list[str]:
    """Call one checker rule by name and return its findings as text."""
    return [str(item) for item in rule(name, *args)]


def pairs(name: str, *args: object) -> list[tuple[str, dict[str, object]]]:
    """Call a rule whose findings are (title, fields) pairs, typed for the asserts."""
    return cast("list[tuple[str, dict[str, object]]]", rule(name, *args))


class NamedEntriesTest(unittest.TestCase):
    """The card unwrap every card rule depends on."""

    def test_reads_the_title_off_the_outer_key(self) -> None:
        found = pairs("named_entries", [{"Kasm": {"href": "https://kasm.example/"}}])
        self.assertEqual(1, len(found))
        self.assertEqual("Kasm", found[0][0])

    def test_reads_the_fields_off_the_inner_mapping(self) -> None:
        cards: list[object] = [{"Coder": {"href": "{{HOMEPAGE_VAR_CODER_URL}}", "siteMonitor": "http://coder:3000/x"}}]
        _title, fields = pairs("named_entries", cards)[0]
        self.assertEqual("{{HOMEPAGE_VAR_CODER_URL}}", fields["href"])

    def test_ignores_a_bare_scalar_entry(self) -> None:
        self.assertEqual([], rule("named_entries", ["just-a-string"]))

    def test_a_card_with_no_fields_still_names_itself(self) -> None:
        # A card the author left empty has no fields to read but is still a card, and
        # row-columns has to count it.
        self.assertEqual([("Kasm", {})], rule("named_entries", [{"Kasm": None}]))


class UrlHostTest(unittest.TestCase):
    """What separates the browser URL space from the compose one."""

    def test_plain_url(self) -> None:
        self.assertEqual("searxng", CHECKER.url_host("http://searxng:8181/healthz"))

    def test_unsubstituted_token_is_not_a_host(self) -> None:
        self.assertEqual("", CHECKER.url_host("{{HOMEPAGE_VAR_CODER_URL}}"))

    def test_scheme_relative_and_bare_are_not_hosts(self) -> None:
        self.assertEqual("", CHECKER.url_host("kasm:4443"))


class TokensTest(unittest.TestCase):
    """A token with no key, and a key with no token."""

    def test_undeclared_token_is_reported(self) -> None:
        found = findings("check_tokens", {"services.yaml": "{{HOMEPAGE_VAR_NOPE}}"}, "nothing here")
        self.assertEqual(1, len(found))
        self.assertIn("token-declared", found[0])
        self.assertIn("HOMEPAGE_VAR_NOPE", found[0])

    def test_unused_key_is_reported(self) -> None:
        found = findings("check_tokens", {"services.yaml": "{{HOMEPAGE_VAR_USED}}"}, "      HOMEPAGE_VAR_USED:\n      HOMEPAGE_VAR_IDLE:")
        self.assertEqual(1, len(found))
        self.assertIn("token-used", found[0])
        self.assertIn("HOMEPAGE_VAR_IDLE", found[0])

    def test_a_paired_token_and_key_pass(self) -> None:
        self.assertEqual([], findings("check_tokens", {"widgets.yaml": "{{HOMEPAGE_VAR_SEARCH_URL}}"}, "      HOMEPAGE_VAR_SEARCH_URL: x"))


class LayoutTest(unittest.TestCase):
    """layout must name every group, and columns must count cards."""

    @staticmethod
    def settings(layout: object) -> dict[str, object]:
        return {"layout": layout}

    def test_group_without_a_layout_entry(self) -> None:
        found = findings("check_layout", self.settings({}), {"Host": [{"Hermes": {}}]}, {})
        self.assertEqual(1, len(found))
        self.assertIn("layout-group", found[0])
        self.assertIn("Host", found[0])

    def test_stale_layout_key(self) -> None:
        found = findings("check_layout", self.settings({"Ghost": {}}), {}, {})
        self.assertIn("Ghost", findings("check_layout", self.settings({"Ghost": {}}), {}, {})[0])
        self.assertEqual(1, len(found))

    def test_columns_must_equal_the_card_count(self) -> None:
        services: dict[str, object] = {"Models": [{"LiteLLM": {}}, {"Ollama": {}}]}
        found = findings("check_layout", self.settings({"Models": {"style": "row", "columns": 3}}), services, {})
        self.assertEqual(1, len(found))
        self.assertIn("row-columns", found[0])

    def test_matching_columns_pass(self) -> None:
        services: dict[str, object] = {"Models": [{"LiteLLM": {}}, {"Ollama": {}}]}
        self.assertEqual([], findings("check_layout", self.settings({"Models": {"style": "row", "columns": 2}}), services, {}))

    def test_a_column_group_is_not_counted(self) -> None:
        services: dict[str, object] = {"Host": [{"Hermes": {}}, {"SearXNG": {}}]}
        self.assertEqual([], findings("check_layout", self.settings({"Host": {}}), services, {}))


class BookmarkShapeTest(unittest.TestCase):
    """The app reads a name over a list of {abbr, href}; a bare mapping loads blank."""

    def test_bare_mapping_is_reported(self) -> None:
        found = findings("check_bookmarks", {"Stack docs": [{"Homepage": {"abbr": "HP", "href": "https://gethomepage.dev/"}}]})
        self.assertEqual(1, len(found))
        self.assertIn("bookmark-shape", found[0])

    def test_list_form_passes(self) -> None:
        groups = {"Stack docs": [{"Homepage": [{"abbr": "HP", "href": "https://gethomepage.dev/"}]}]}
        self.assertEqual([], findings("check_bookmarks", groups))

    def test_missing_href_is_reported(self) -> None:
        groups = {"Repo": [{"This stack": [{"abbr": "STK"}]}]}
        found = findings("check_bookmarks", groups)
        self.assertEqual(1, len(found))
        self.assertIn("href", found[0])


class BlockMappingsTest(unittest.TestCase):
    """The shipped bundle slices a block widget to four mappings."""

    @staticmethod
    def card(mappings: list[object], display: str | None = None) -> dict[str, object]:
        widget: dict[str, object] = {"type": "customapi", "url": "http://coder:3000/x", "mappings": mappings}
        if display is not None:
            widget["display"] = display
        return {"Group": [{"Card": {"widgets": [widget]}}]}

    def test_a_fifth_mapping_is_reported(self) -> None:
        card = self.card([{"field": "f%d" % i, "label": "L%d" % i} for i in range(5)])
        found = findings("check_widgets", card)
        self.assertEqual(1, len(found))
        self.assertIn("block-mappings", found[0])

    def test_four_mappings_pass(self) -> None:
        card = self.card([{"field": "f%d" % i, "label": "L%d" % i} for i in range(4)])
        self.assertEqual([], findings("check_widgets", card))

    def test_a_non_block_display_is_exempt(self) -> None:
        card = self.card([{"field": "f%d" % i, "label": "L%d" % i} for i in range(6)], display="list")
        self.assertEqual([], findings("check_widgets", card))

    def test_the_single_widget_spelling_is_read_too(self) -> None:
        card: dict[str, object] = {
            "Group": [
                {
                    "Card": {
                        "widget": {
                            "type": "customapi",
                            "url": "http://coder:3000/x",
                            "mappings": [{"field": "f%d" % i, "label": "L%d" % i} for i in range(5)],
                        }
                    }
                }
            ]
        }
        self.assertEqual(1, len(findings("check_widgets", card)))


class SearchWidgetTest(unittest.TestCase):
    """`provider: custom` gets the query appended, so its url has to end open."""

    def test_url_without_an_open_query_is_reported(self) -> None:
        doc: list[object] = [{"search": {"provider": "custom", "url": "http://searxng:8181/search"}}]
        found = findings("check_widgets_file", doc)
        self.assertEqual(1, len(found))
        self.assertIn("search-url", found[0])

    def test_url_ending_at_the_query_param_passes(self) -> None:
        doc: list[object] = [{"search": {"provider": "custom", "url": "{{HOMEPAGE_VAR_SEARCH_URL}}/search?q="}}]
        self.assertEqual([], findings("check_widgets_file", doc))

    def test_a_named_provider_needs_no_url(self) -> None:
        doc: list[object] = [{"search": {"provider": "duckduckgo", "target": "_blank"}}]
        self.assertEqual([], findings("check_widgets_file", doc))


class IconPathTest(unittest.TestCase):
    """Only /icons/ survives the sign-in redirect."""

    def test_a_local_path_outside_icons_is_reported(self) -> None:
        settings: dict[str, object] = {"favicon": "/assets/evo-t1.svg"}
        found = findings("check_icons", settings, {}, [])
        self.assertEqual(1, len(found))
        self.assertIn("icon-path", found[0])

    def test_a_cdn_icon_name_is_not_a_path(self) -> None:
        services: dict[str, object] = {"Coder": [{"Coder": {"icon": "si-coder"}}]}
        self.assertEqual([], findings("check_icons", {}, services, []))

    def test_the_logo_widget_is_checked_too(self) -> None:
        widgets: list[object] = [{"logo": {"icon": "/images/evo-t1.svg"}}]
        found = findings("check_icons", {}, {}, widgets)
        self.assertEqual(1, len(found))
        self.assertIn("widgets logo icon", found[0])


if __name__ == "__main__":
    unittest.main()
