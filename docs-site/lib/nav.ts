/**
 * Sidebar menu structure for the documentation site, hand-shaped in `lib/nav.json`.
 *
 * The tree is declared rather than inferred from the filesystem because most pages sit flat
 * in `docs/` while belonging to different sections, which a directory-derived tree cannot
 * express, and because the reading order the prev/next footer needs is an editorial decision.
 * `scripts/gen_nav.py` holds the declaration and writes this JSON; `--check` fails on drift.
 *
 * A section is one top-level entry, and inside it pages are collected into collapsible
 * folders that read as a progression: Operate runs everyday loop to recovery, Contribute runs
 * environment to Bazel. A folder is `{ title, pages }` with no `path`, and its leaves keep
 * their order and nest to any depth. Keep each folder short enough to scan in one glance: a
 * flat list of twenty siblings tells a reader nothing about where they are.
 *
 * Every page under `docs/` has to appear in the tree exactly once; the page contract in
 * `tests/unit/docs-content.test.ts` fails an orphan or a stale entry.
 */

import type { Folder, Item, Node, Root } from "fumadocs-core/page-tree";
import type { ReactNode } from "react";
import type { LoaderOutput } from "fumadocs-core/source";
import { z } from "zod";

import navData from "./nav.json";
import { withoutExtension } from "./href";

/**
 * The slice of the content loader the navigation needs.
 *
 * Declared structurally (rather than as a bare `LoaderOutput`) so the loader instance built
 * in `lib/source.ts` (whose page type is the specialised one from the collection schemas) is
 * accepted without a variance complaint.
 */
export type NavSource = Pick<LoaderOutput, "getPages">;

/** One leaf of the menu: the label the sidebar shows and the file it points at. */
export interface NavPage {
  /** Label shown in the sidebar. */
  title: string;
  /** Path of the page relative to `docs/`, e.g. `operate/dashboard.md`. */
  path: string;
}

/** A collapsible sidebar folder; its pages nest to any depth. */
export interface NavGroup {
  title: string;
  pages: NavNode[];
}

export type NavNode = NavPage | NavGroup;

/** One top-level section of the menu. */
export interface NavTab {
  title: string;
  pages: NavNode[];
}

/**
 * The runtime shape `lib/nav.json` has to satisfy.
 *
 * `nav.json` is a JSON import, so TypeScript sees only the inferred literal shape and a wrong
 * key would surface as `undefined` deep in the sidebar. These schemas parse it once at import
 * time instead, and the `z.ZodType<...>` annotations tie the schema to the declared interfaces
 * above: a field added to one side and not the other fails `npm run typecheck`.
 */
const navPageSchema = z.object({ title: z.string(), path: z.string() });

const navNodeSchema: z.ZodType<NavNode> = z.lazy(() =>
  z.union([navPageSchema, z.object({ title: z.string(), pages: z.array(navNodeSchema) })])
);

export const navTabsSchema: z.ZodType<NavTab[]> = z.array(
  z.object({ title: z.string(), pages: z.array(navNodeSchema) })
);

/** A folder is the variant that carries `pages`; a leaf is the one that carries `path`. */
function isGroup(node: NavNode): node is NavGroup {
  return "pages" in node;
}

function isPage(node: NavNode): node is NavPage {
  return "path" in node;
}

const STATIC_NAV: NavTab[] = navTabsSchema.parse(navData);

/**
 * Resolve one `docs/`-relative path to a sidebar page node.
 *
 * @param source Content loader used to obtain the canonical URL of the page.
 * @param tabTitle Section the page belongs to, used in the diagnostic when the page is missing.
 * @param path Path of the page relative to `docs/`.
 * @param title Sidebar label for the page.
 * @returns A page node whose URL matches the route the page is served from.
 */
function toItem(source: NavSource, tabTitle: string, path: string, title: string): Item {
  const page = source.getPages().find((candidate) => withoutExtension(candidate.path) === withoutExtension(path));
  if (!page) {
    throw new Error(
      `navigation references a page that is not in the content source: ${path} (section "${tabTitle}")`
    );
  }
  return { $id: `page:${path}`, type: "page", name: title, url: page.url, $ref: page.path };
}

/**
 * Turn declared nodes into page-tree nodes, recursing through folders.
 *
 * A folder whose first child is an index page gets that page as its index, so the folder label
 * itself lands on the overview rather than opening on a list of children.
 *
 * @param source Content loader to resolve page URLs against.
 * @param tabTitle Section the nodes belong to, for the missing-page diagnostic.
 * @param nodes Declared nodes at this level.
 * @param idPrefix Stable prefix that keeps sibling ids unique.
 * @returns The page-tree nodes for `children`.
 */
function toNodes(source: NavSource, tabTitle: string, nodes: NavNode[], idPrefix: string): Node[] {
  return nodes.map((node, index) => {
    if (isGroup(node)) {
      const children = toNodes(source, tabTitle, node.pages, `${idPrefix}/${index}`);
      const folder: Folder = {
        $id: `folder:${idPrefix}/${index}:${node.title}`,
        type: "folder",
        name: node.title,
        defaultOpen: false,
        children
      };
      const first = node.pages[0];
      if (first && isPage(first) && /(^|\/)index$/u.test(withoutExtension(first.path))) {
        folder.index = toItem(source, tabTitle, first.path, first.title);
      }
      return folder;
    }
    return toItem(source, tabTitle, node.path, node.title);
  });
}

/**
 * Build the page tree the docs layout renders.
 *
 * Every section is a plain collapsible folder, deliberately not a root folder. fumadocs turns
 * each root folder into a layout tab and shows those tabs as a dropdown above the sidebar,
 * which leaves the sidebar holding only the current section. Without root folders the sidebar
 * is one vertical menu: every section listed at once, each expandable, the reader's own
 * section opened by fumadocs. The right-hand table of contents comes from `DocsPage`'s `toc`
 * prop and is untouched by this choice.
 *
 * @param source Content loader to resolve page URLs against.
 * @param nav Menu data to render; defaults to the committed tree. A caller passes it in a
 *            test to exercise a shape the shipped corpus does not use.
 * @returns The root node for `DocsLayout`.
 */
export function buildPageTree(source: NavSource, nav: NavTab[] = STATIC_NAV): Root {
  const children: Node[] = nav.map((tab, index) => {
    const pages = toNodes(source, tab.title, tab.pages, `tab:${index}`);
    const folder: Folder = {
      $id: `tab:${index}:${tab.title}`,
      type: "folder",
      name: tab.title,
      defaultOpen: true,
      children: pages
    };
    const first = tab.pages[0];
    // A section whose first page is its overview gets it as the folder index, so the section
    // label itself lands on the overview page.
    if (first && isPage(first) && /(^|\/)index$/u.test(withoutExtension(first.path))) {
      folder.index = toItem(source, tab.title, first.path, first.title);
    }
    return folder;
  });

  return { $id: "root", type: "root", name: "Documentation", children };
}

/**
 * Flatten the declared nodes into their leaves, in menu order.
 *
 * @param nodes Nodes at this level.
 * @returns Every leaf below them, folders traversed in place.
 */
function flattenPages(nodes: NavNode[]): NavPage[] {
  const out: NavPage[] = [];
  for (const node of nodes) {
    if (isPage(node)) out.push(node);
    else out.push(...flattenPages(node.pages));
  }
  return out;
}

/** Paths of every page in the navigation, in menu order; the page contract pins it. */
export const NAVIGATED_PATHS: string[] = STATIC_NAV.flatMap((tab) =>
  flattenPages(tab.pages).map((page) => page.path)
);

/** A prev/next footer entry shaped the way the footer slot expects. */
export interface PageNodeEntry {
  name: ReactNode;
  url: string;
}

/**
 * Previous and next pages in reading order.
 *
 * The footer walks the pages in the order they are declared in the navigation, folders
 * traversed in place, so reading order follows the sidebar rather than the filesystem.
 *
 * @param source Content loader used to resolve each path to its page node.
 * @param path Path of the current page relative to `docs/`.
 * @returns The neighbouring entries; a key is omitted at either end of the run rather than
 *          set to `undefined`, so the footer slot can take this object as-is.
 */
export function neighborsOf(
  source: NavSource,
  path: string
): { previous?: PageNodeEntry; next?: PageNodeEntry } {
  const wanted = withoutExtension(path);
  const flat = STATIC_NAV.flatMap((tab) =>
    flattenPages(tab.pages).map((page) => ({ tab: tab.title, page }))
  );
  const index = flat.findIndex((entry) => withoutExtension(entry.page.path) === wanted);
  if (index === -1) return {};
  const at = (offset: number): PageNodeEntry | undefined => {
    const entry = flat[index + offset];
    if (!entry) return undefined;
    const item = toItem(source, entry.tab, entry.page.path, entry.page.title);
    return { name: item.name, url: item.url };
  };
  const previous = at(-1);
  const next = at(1);
  // exactOptionalPropertyTypes: omit the key when there is no neighbour so consumers can
  // pass this straight into a footer slot that declares `previous?: PageNodeEntry`.
  return { ...(previous ? { previous } : {}), ...(next ? { next } : {}) };
}

/** Where a page sits in the sidebar menu: its section, then each collapsible folder above it. */
export interface NavTrail {
  /** Title of the section the page is filed under. */
  tab: string;
  /** Folder titles between the section and the page, outermost first. */
  groups: string[];
  /** Label the sidebar shows for the page, so the trail and the sidebar agree. */
  label: string;
}

/**
 * Sidebar location of one page, for the breadcrumb above the title.
 *
 * fumadocs' own breadcrumb prints page titles, so it cannot name the section the reader is in
 * or agree with the wording the menu rows use. This walks the same tree the sidebar renders
 * and returns both.
 *
 * @param path Page path relative to `docs/`, with or without its extension.
 * @returns The section, folder titles, and sidebar label, or `undefined` when the page is not
 *          filed in the tree.
 */
export function trailFor(path: string): NavTrail | undefined {
  const wanted = withoutExtension(path);
  const walk = (nodes: NavNode[], groups: string[]): NavTrail | undefined => {
    for (const node of nodes) {
      if (isPage(node)) {
        if (withoutExtension(node.path) === wanted) return { tab: "", groups, label: node.title };
        continue;
      }
      const found = walk(node.pages, [...groups, node.title]);
      if (found) return found;
    }
    return undefined;
  };
  for (const tab of STATIC_NAV) {
    const found = walk(tab.pages, []);
    if (found) return { tab: tab.title, groups: found.groups, label: found.label };
  }
  return undefined;
}
