/**
 * Tests for the declared navigation.
 *
 * The tree comes from `scripts/gen_nav.py` rather than the filesystem because most pages sit
 * flat in `docs/` while belonging to different tabs, and because the prev/next footer follows
 * an editorial reading order. Each tab therefore has to become a root folder (that is what
 * puts it in the tab strip), every declared path has to resolve to a real page, and the footer
 * has to walk past the end of a tab rather than dead-ending at its last page.
 */

import type { Node, Root } from "fumadocs-core/page-tree";

import { describe, expect, it } from "vitest";

import { buildPageTree, NAVIGATED_PATHS, neighborsOf, type NavSource } from "../../lib/nav";

/** What the loader hands the navigation; only `path` and `url` are read. */
type LoadedPage = ReturnType<NavSource["getPages"]>[number];

/** Content loader stand-in that serves exactly the given pages. */
function navSource(pages: { path: string; url: string }[]): NavSource {
  return { getPages: () => pages as unknown as LoadedPage[] };
}

/** The whole declared corpus, so every declared path resolves. */
function completeSource(): NavSource {
  return navSource(NAVIGATED_PATHS.map((path, index) => ({ path, url: `/page-${index}` })));
}

/** The root folders, in tab order. */
function tabs(source: NavSource): Node[] {
  return buildPageTree(source).children;
}

/** The tab at `index`, failing the test when it is not the root folder the layout expects. */
function folderAt(source: NavSource, index: number) {
  const tab = tabs(source)[index];
  if (!tab || tab.type !== "folder") throw new Error(`tab ${index} is not a root folder`);
  return tab;
}

/** URL of a sidebar entry, failing the test when the node is not a page. */
function pageUrl(node: Node | undefined): string {
  if (!node || node.type !== "page") throw new Error("the sidebar entry is not a page");
  return node.url;
}

/** Sidebar label of an entry. */
function pageName(node: Node | undefined): unknown {
  if (!node || node.type !== "page") throw new Error("the sidebar entry is not a page");
  return node.name;
}

describe("buildPageTree", () => {
  it("wraps the declared tabs in a single documentation root", () => {
    const root: Root = buildPageTree(completeSource());
    expect(root.$id).toBe("root");
    expect(root.type).toBe("root");
    expect(root.name).toBe("Documentation");
    expect(tabs(completeSource()).map((tab) => tab.name)).toEqual([
      "Start",
      "Learn",
      "Operate",
      "Contribute"
    ]);
  });

  it("makes every tab a root folder so it reaches the tab strip", () => {
    for (const index of [0, 1, 2, 3]) {
      const tab = folderAt(completeSource(), index);
      expect(tab.root).toBe(true);
      expect(tab.defaultOpen).toBe(true);
      expect(tab.$id).toContain(`tab:${index}:`);
      expect(tab.children.length).toBeGreaterThan(0);
    }
  });

  it("points each sidebar entry at the URL the loader publishes", () => {
    const [start] = folderAt(completeSource(), 0).children;
    expect(start).toMatchObject({
      type: "page",
      name: "Overview",
      url: "/page-0",
      $ref: "index.mdx",
      $id: "page:index.mdx"
    });
  });

  it("gives a tab whose first page is an index that page as its folder index", () => {
    const learn = folderAt(completeSource(), 1);
    expect(learn.index).toEqual(learn.children[0]);
    expect(pageName(learn.index)).toBe("Learn overview");
  });

  it("leaves a tab without an overview page unindexed", () => {
    expect(folderAt(completeSource(), 3).index).toBeUndefined();
  });

  it("matches a declared path whichever content extension it was written with", () => {
    const source = navSource(
      NAVIGATED_PATHS.map((path, index) => ({
        path: path === "operate/index.md" ? "operate/index.mdx" : path,
        url: `/page-${index}`
      }))
    );
    const operate = folderAt(source, 2);
    expect(operate.index).toEqual(operate.children[0]);
    expect(pageUrl(operate.children[0])).toBe("/page-9");
  });

  it("names the tab and the missing page when a declared path has no page behind it", () => {
    expect(() => buildPageTree(navSource([]))).toThrow(
      /navigation references a page that is not in the content source: index\.mdx \(tab "Start"\)/u
    );
  });
});

describe("NAVIGATED_PATHS", () => {
  it("lists every declared page in tab order", () => {
    expect(NAVIGATED_PATHS.slice(0, 3)).toEqual(["index.mdx", "getting-started.mdx", "learn/index.md"]);
    expect(NAVIGATED_PATHS.at(-1)).toBe("contribute/test-with-bazel.md");
  });

  it("names pages by their file, extension included", () => {
    expect(NAVIGATED_PATHS.every((path) => /\.(?:md|mdx)$/u.test(path))).toBe(true);
  });
});

describe("neighborsOf", () => {
  it("walks forward from the first page", () => {
    expect(neighborsOf(completeSource(), "index.mdx")).toEqual({
      previous: undefined,
      next: { name: "Getting started", url: "/page-1" }
    });
  });

  it("walks backward and forward inside a tab", () => {
    expect(neighborsOf(completeSource(), "coder-templates.md")).toEqual({
      previous: { name: "Learn overview", url: "/page-2" },
      next: { name: "LiteLLM routing", url: "/page-4" }
    });
  });

  it("carries the reader over a tab boundary", () => {
    expect(neighborsOf(completeSource(), "getting-started.mdx").next).toEqual({
      name: "Learn overview",
      url: "/page-2"
    });
  });

  it("ends the run at either edge of the reading order", () => {
    expect(neighborsOf(completeSource(), "index.mdx").previous).toBeUndefined();
    expect(neighborsOf(completeSource(), "contribute/test-with-bazel.md").next).toBeUndefined();
  });

  it("finds a page given without its extension", () => {
    expect(neighborsOf(completeSource(), "dashboard").next).toEqual({
      name: "Config updates",
      url: "/page-11"
    });
  });

  it("returns nothing for a page the navigation does not declare", () => {
    expect(neighborsOf(completeSource(), "somewhere-else.md")).toEqual({});
  });

  it("reports a missing page rather than a broken footer link", () => {
    expect(() => neighborsOf(navSource([]), "index.mdx")).toThrow(/tab "Start"/u);
  });
});
