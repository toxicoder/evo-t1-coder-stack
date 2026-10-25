#!/usr/bin/env python3
"""Generate the Fumadocs navigation tree (``docs-site/lib/nav.json``).

The sidebar cannot be inferred from the filesystem here: most pages sit flat in ``docs/``
while belonging to different top-level tabs, and the reading order a prev/next footer needs
is an editorial decision. So the tree is declared once in :data:`NAV` below and written out
as the JSON the page-tree builder imports.

The declaration names each page by its on-disk spelling. ``validate`` accepts either suffix
for a page, because a page that needed JSX is ``.mdx`` and the rest are ``.md``.

Usage:
    python3 docs-site/scripts/gen_nav.py [--check] [--print]

Options:
    --check   Exit 1 if the committed nav.json differs from this declaration.
    --print   Print the JSON to stdout without writing.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT_JSON = REPO_ROOT / "docs-site" / "lib" / "nav.json"
DOCS_DIR = REPO_ROOT / "docs"

#: ``(tab title, [(page title, path relative to docs/), ...])`` in sidebar order.
NAV: list[tuple[str, list[tuple[str, str]]]] = [
    (
        "Start",
        [
            ("Overview", "index.mdx"),
            ("Getting started", "getting-started.mdx"),
        ],
    ),
    (
        "Learn",
        [
            ("Learn overview", "learn/index.md"),
            ("Coder workspace templates", "coder-templates.md"),
            ("LiteLLM routing", "litellm-routing.md"),
            ("Grok Build and the agents file", "grok-build-and-agents.md"),
            ("Hermes host assistant", "hermes.md"),
            ("Project conventions", "project-conventions.md"),
            ("Branching", "branching.md"),
        ],
    ),
    (
        "Operate",
        [
            ("Operate overview", "operate/index.md"),
            ("Dashboard", "dashboard.md"),
            ("Config updates", "config-updates.md"),
            ("Public access", "public-access.md"),
            ("Troubleshooting", "troubleshooting.md"),
        ],
    ),
    (
        "Contribute",
        [
            ("Building with Bazel", "contribute/building-with-bazel.md"),
            ("Testing with Bazel", "contribute/test-with-bazel.md"),
        ],
    ),
]


def to_tree(declared: list[tuple[str, list[tuple[str, str]]]]) -> list[dict[str, object]]:
    """Convert :data:`NAV` into the tab/page layout the site imports.

    Args:
        declared: Tab declarations, each a title and its ordered ``(title, path)`` pages.

    Returns:
        One entry per tab: ``{"title", "pages"}`` with ``pages`` holding ordered
        ``{"title", "path"}`` leaves.
    """
    return [
        {"title": tab_title, "pages": [{"title": title, "path": path} for title, path in pages]}
        for tab_title, pages in declared
    ]


def serialize(tabs: list[dict[str, object]]) -> str:
    """Render the tree as the exact text written to ``nav.json``.

    Args:
        tabs: Output of :func:`to_tree`.

    Returns:
        Pretty-printed JSON with a trailing newline.
    """
    return json.dumps(tabs, indent=2, ensure_ascii=False) + "\n"


def validate(tabs: list[dict[str, object]]) -> list[str]:
    """Check the tree against the files on disk.

    Args:
        tabs: Output of :func:`to_tree`.

    Returns:
        Human-readable problems; empty when the tree is consistent.
    """
    problems: list[str] = []
    seen: set[str] = set()
    for tab in tabs:
        for page in tab["pages"]:  # type: ignore[index]
            path = str(page["path"])  # type: ignore[index]
            declared = DOCS_DIR / path
            if not declared.is_file() and not declared.with_suffix(".mdx").is_file():
                problems.append(f"nav page missing on disk: docs/{path}")
            if path in seen:
                problems.append(f"nav page listed twice: docs/{path}")
            seen.add(path)
    return problems


def main(argv: list[str] | None = None) -> int:
    """Generate or verify ``docs-site/lib/nav.json``.

    Args:
        argv: Argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        ``0`` on success, ``1`` on a validation problem or ``--check`` drift.
    """
    parser = argparse.ArgumentParser(description="Generate or verify docs-site/lib/nav.json.")
    parser.add_argument("--check", action="store_true", help="fail if the committed file is stale")
    parser.add_argument("--print", action="store_true", dest="print_only", help="write to stdout")
    args = parser.parse_args(argv)

    tabs = to_tree(NAV)
    problems = validate(tabs)
    if problems:
        for problem in problems:
            print(f"nav problem: {problem}", file=sys.stderr)
        return 1

    payload = serialize(tabs)
    if args.print_only:
        sys.stdout.write(payload)
        return 0

    existing = OUT_JSON.read_text(encoding="utf-8") if OUT_JSON.is_file() else None
    if args.check:
        if existing != payload:
            print("docs-site/lib/nav.json is stale; run docs-site/scripts/gen_nav.py", file=sys.stderr)
            return 1
        print("nav.json is up to date.")
        return 0
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(payload, encoding="utf-8")
    pages = sum(len(tab["pages"]) for tab in tabs)
    print(f"wrote {OUT_JSON.relative_to(REPO_ROOT)} ({len(tabs)} tabs, {pages} pages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
