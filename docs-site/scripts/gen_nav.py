#!/usr/bin/env python3
"""Generate the Fumadocs navigation tree (``docs-site/lib/nav.json``).

The sidebar cannot be inferred from the filesystem here: most pages sit flat in ``docs/``
while belonging to different sections, and the reading order a prev/next footer needs is an
editorial decision. So the tree is declared once in :data:`NAV` below and written out as the
JSON the page-tree builder imports.

A section holds an ordered mix of leaves and collapsible folders. A leaf is
``(label, path)`` and a folder is ``(label, [child, ...])``, so a folder reads as a
progression the reader can scan (Operate runs everyday loop to recovery, Contribute runs
environment to Bazel). Folders nest to any depth, and a folder or section whose first entry
is an index page gets that page as its clickable label in the sidebar.

The declaration names each page by its on-disk spelling. ``validate`` accepts either suffix
for a page, because a page that needed JSX is ``.mdx`` and the rest are ``.md``.

Usage:
    python3 docs-site/scripts/gen_nav.py [--check]

Options:
    --check   Exit 1 if the committed nav.json differs from this declaration.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Sequence, TypedDict, TypeGuard, Union, cast

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT_JSON = REPO_ROOT / "docs-site" / "lib" / "nav.json"
DOCS_DIR = REPO_ROOT / "docs"


class NavPage(TypedDict):
    """One sidebar leaf as the site imports it: the label and the docs-relative file."""

    title: str
    path: str


class NavGroup(TypedDict):
    """One collapsible sidebar folder as the site imports it: its label and its children."""

    title: str
    pages: list["NavNode"]


NavNode = Union[NavPage, NavGroup]


def is_page(node: NavNode) -> TypeGuard[NavPage]:
    """Whether a tree node is a leaf.

    Args:
        node: One node of the tree :func:`to_tree` produced.

    Returns:
        ``True`` for a leaf, which is the node that carries a ``path``.
    """
    return "path" in node


def is_group(node: NavNode) -> TypeGuard[NavGroup]:
    """Whether a tree node is a collapsible folder.

    Args:
        node: One node of the tree :func:`to_tree` produced.

    Returns:
        ``True`` for a folder, which is the node that carries ``pages``.
    """
    return "pages" in node


class NavTab(TypedDict):
    """One top-level section as the site imports it: its label and its ordered entries.

    The committed ``nav.json`` is a list of these, so the two names are also the on-disk
    schema, which is what lets :func:`validate` walk the tree without a cast at every
    subscript.
    """

    title: str
    pages: list[NavNode]


#: A declared leaf is ``(label, path)``; a declared folder is ``(label, [child, ...])``.
#:
#: The children are a ``Sequence`` so a literal ``[...]`` of leaves is a declared folder:
#: ``list`` is invariant, so ``list[tuple[str, str]]`` would not be a ``list[DeclaredNode]``.
DeclaredNode = Union[tuple[str, str], tuple[str, Sequence["DeclaredNode"]]]

#: ``(section title, [entries, ...])`` in sidebar order.
NAV: list[tuple[str, list[DeclaredNode]]] = [
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
            (
                "How the stack works",
                [
                    ("Coder workspace templates", "coder-templates.md"),
                    ("LiteLLM routing", "litellm-routing.md"),
                ],
            ),
            (
                "The agent and the host",
                [
                    ("Grok Build and the agents file", "grok-build-and-agents.md"),
                    ("Hermes host assistant", "hermes.md"),
                ],
            ),
            (
                "Conventions",
                [
                    ("Project conventions", "project-conventions.md"),
                    ("Branching", "branching.md"),
                    ("Trunk-based + flags refactor", "workflows/trunk-feature-flags-refactor.md"),
                ],
            ),
        ],
    ),
    (
        "Operate",
        [
            ("Operate overview", "operate/index.md"),
            (
                "Everyday loop",
                [
                    ("Dashboard", "dashboard.md"),
                    ("Config updates", "config-updates.md"),
                    ("New projects from the template", "new-repo.md"),
                ],
            ),
            (
                "Access and recovery",
                [
                    ("Public access", "public-access.md"),
                    ("Unlock an encrypted host remotely", "luks-unlock.md"),
                    ("Troubleshooting", "troubleshooting.md"),
                ],
            ),
        ],
    ),
    (
        "Contribute",
        [
            (
                "Set up and conventions",
                [
                    ("Contributor environment", "contribute/devcontainer.md"),
                    ("Strong types", "contribute/strong-types.md"),
                    # What the docs contract enforces, so a page that fails a gate is a
                    # page whose author knew the rule and skipped it.
                    ("Writing documentation", "contribute/docs-style.md"),
                ],
            ),
            (
                "Bazel",
                [
                    ("Building with Bazel", "contribute/building-with-bazel.md"),
                    ("Testing with Bazel", "contribute/test-with-bazel.md"),
                    # Graph navigation closes the tab: it is how a contributor finds their
                    # way around once the build and test rules above are second nature.
                    ("Navigating the codebase with Bazel", "contribute/navigate-with-bazel.md"),
                ],
            ),
        ],
    ),
]


def is_declared_group(entry: DeclaredNode) -> bool:
    """Whether a declared entry is a folder (its second element is children, not a path).

    Args:
        entry: One declared entry, a leaf or a folder.

    Returns:
        ``True`` for a folder, ``False`` for a leaf.
    """
    return not isinstance(entry[1], str)


def to_node(entry: DeclaredNode) -> NavNode:
    """Convert one declared entry into the leaf or folder layout the site imports.

    Args:
        entry: ``(label, path)`` for a leaf, ``(label, [child, ...])`` for a folder.

    Returns:
        A ``{"title", "path"}`` leaf or a ``{"title", "pages"}`` folder, with the children
        converted the same way.
    """
    title, value = entry
    if isinstance(value, str):
        return {"title": title, "path": value}
    return {"title": title, "pages": [to_node(child) for child in value]}


def to_tree(declared: list[tuple[str, list[DeclaredNode]]]) -> list[NavTab]:
    """Convert :data:`NAV` into the section/entry layout the site imports.

    Args:
        declared: Section declarations, each a title and its ordered entries.

    Returns:
        One entry per section: ``{"title", "pages"}`` with ``pages`` holding ordered leaves
        and folders.
    """
    return [{"title": tab_title, "pages": [to_node(entry) for entry in pages]} for tab_title, pages in declared]


def count_pages(tabs: list[NavTab]) -> int:
    """Count the leaves of the tree, which is the number of pages the sidebar reaches.

    Args:
        tabs: Output of :func:`to_tree`.

    Returns:
        Total leaf count across every section and folder.
    """

    def walk(nodes: list[NavNode]) -> int:
        total = 0
        for node in nodes:
            if is_group(node):
                total += walk(node["pages"])
            else:
                total += 1
        return total

    return sum(walk(tab["pages"]) for tab in tabs)


def serialize(tabs: list[NavTab]) -> str:
    """Render the tree as the exact text written to ``nav.json``.

    Args:
        tabs: Output of :func:`to_tree`.

    Returns:
        Pretty-printed JSON with a trailing newline.
    """
    return json.dumps(tabs, indent=2, ensure_ascii=False) + "\n"


def validate(tabs: list[NavTab]) -> list[str]:
    """Check the tree against the files on disk.

    Args:
        tabs: Output of :func:`to_tree`.

    Returns:
        Human-readable problems; empty when the tree is consistent. A folder with no children
        is a problem because it renders as a control that opens onto nothing.
    """
    problems: list[str] = []
    seen: set[str] = set()

    def walk(nodes: list[NavNode], where: str) -> None:
        if not nodes:
            problems.append(f"nav folder has no pages: {where}")
            return
        for node in nodes:
            if is_group(node):
                walk(node["pages"], f"{where} / {node['title']}")
                continue
            # A declared node is a page or a folder, so whatever the folder test rejected is
            # a page. A TypeGuard narrows only its positive side, hence the cast.
            page = cast("NavPage", node)
            path = str(page["path"])
            declared = DOCS_DIR / path
            if not declared.is_file() and not declared.with_suffix(".mdx").is_file():
                problems.append(f"nav page missing on disk: docs/{path}")
            if path in seen:
                problems.append(f"nav page listed twice: docs/{path}")
            seen.add(path)

    for tab in tabs:
        walk(tab["pages"], tab["title"])
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
    args = parser.parse_args(argv)

    tabs = to_tree(NAV)
    problems = validate(tabs)
    if problems:
        for problem in problems:
            print(f"nav problem: {problem}", file=sys.stderr)
        return 1

    payload = serialize(tabs)

    existing = OUT_JSON.read_text(encoding="utf-8") if OUT_JSON.is_file() else None
    if args.check:
        if existing != payload:
            print("docs-site/lib/nav.json is stale; run docs-site/scripts/gen_nav.py", file=sys.stderr)
            return 1
        print("nav.json is up to date.")
        return 0
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(payload, encoding="utf-8")
    print(f"wrote {OUT_JSON.relative_to(REPO_ROOT)} ({len(tabs)} tabs, {count_pages(tabs)} pages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
