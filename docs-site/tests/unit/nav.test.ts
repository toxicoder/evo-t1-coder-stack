/**
 * Tests for the declared navigation.
 *
 * The tree comes from `scripts/gen_nav.py` rather than the filesystem because most pages sit
 * flat in `docs/` while belonging to different sections, and because the prev/next footer
 * follows an editorial reading order. Each section therefore has to be a plain folder (a root
 * folder would turn the sidebar into a one-section dropdown), a declared folder has to collapse
 * with its children in order, every declared path has to resolve to a real page, and the footer
 * has to walk past the end of a folder and a section rather than dead-ending there.
 */

import type { Node, Root } from "fumadocs-core/page-tree";

import { describe, expect, it } from "vitest";

import navData from "../../lib/nav.json";
import {
  buildPageTree,
  NAVIGATED_PATHS,
  navTabsSchema,
  neighborsOf,
  trailFor,
  type NavSource
} from "../../lib/nav";

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

/** The section folders, in declared order. */
function tabs(source: NavSource): Node[] {
  return buildPageTree(source).children;
}

/** The section at `index`, failing the test when it is not a folder. */
function folderAt(source: NavSource, index: number) {
  const tab = tabs(source)[index];
  if (!tab || tab.type !== "folder") throw new Error(`section ${index} is not a folder`);
  return tab;
}

/** The collapsible folder named `title` inside the section at `index`. */
function groupAt(source: NavSource, tabIndex: number, title: string) {
  const folder = folderAt(source, tabIndex).children.find(
    (child) => child.type === "folder" && child.name === title
  );
  if (!folder || folder.type !== "folder") throw new Error(`section ${tabIndex} has no folder "${title}"`);
  return folder;
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
  it("wraps the declared sections in a single documentation root", () => {
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

  it("keeps every section a plain folder so the sidebar lists them all at once", () => {
    // A root folder becomes a layout tab, and fumadocs then shows only the current section
    // in the sidebar; plain folders are what keep one vertical menu of expandable sections.
    for (const index of [0, 1, 2, 3]) {
      const tab = folderAt(completeSource(), index);
      expect(tab.root).toBeUndefined();
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

  it("gives a section whose first page is an index that page as its folder index", () => {
    const learn = folderAt(completeSource(), 1);
    expect(learn.index).toEqual(learn.children[0]);
    expect(pageName(learn.index)).toBe("Learn overview");
  });

  it("leaves a section that opens on a folder unindexed", () => {
    expect(folderAt(completeSource(), 3).index).toBeUndefined();
  });

  it("renders a declared folder as a collapsed folder holding its leaves in order", () => {
    const loop = groupAt(completeSource(), 2, "Everyday loop");
    expect(loop.defaultOpen).toBe(false);
    expect(loop.$id).toContain("Everyday loop");
    expect(loop.children.map((child) => child.name)).toEqual([
      "Dashboard",
      "Observability bundle",
      "Config updates",
      "New projects from the template"
    ]);
    expect(loop.children.every((child) => child.type === "page")).toBe(true);
  });

  it("nests a folder beside the leaves of its section rather than replacing them", () => {
    const learn = folderAt(completeSource(), 1);
    const [first, ...groups] = learn.children;
    expect(pageName(first)).toBe("Learn overview");
    expect(groups.map((group) => group.name)).toEqual([
      "How the stack works",
      "The agent and the host",
      "Conventions"
    ]);
  });

  it("gives a folder whose first page is an index that page as its folder index", () => {
    // No shipped folder opens on an index, so the shape is handed in rather than read from
    // the committed tree.
    const source = navSource([
      { path: "loop/index.md", url: "/loop" },
      { path: "loop/one.md", url: "/one" }
    ]);
    const root = buildPageTree(source, [
      {
        title: "Operate",
        pages: [
          {
            title: "Everyday loop",
            pages: [
              { title: "Loop overview", path: "loop/index.md" },
              { title: "One", path: "loop/one.md" }
            ]
          }
        ]
      }
    ]);
    const section = root.children[0];
    if (!section || section.type !== "folder") throw new Error("the section is not a folder");
    const group = section.children[0];
    if (!group || group.type !== "folder") throw new Error("the group is not a folder");
    expect(group.index).toEqual(group.children[0]);
    expect(pageName(group.index)).toBe("Loop overview");
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
    expect(pageUrl(operate.children[0])).toBe("/page-10");
  });

  it("names the section and the missing page when a declared path has no page behind it", () => {
    expect(() => buildPageTree(navSource([]))).toThrow(
      /navigation references a page that is not in the content source: index\.mdx \(section "Start"\)/u
    );
  });

  it("names the section and the page missing from inside a folder", () => {
    const withoutGroup = navSource(
      NAVIGATED_PATHS.filter((path) => path !== "dashboard.md").map((path, index) => ({
        path,
        url: `/page-${index}`
      }))
    );
    expect(() => buildPageTree(withoutGroup)).toThrow(
      /navigation references a page that is not in the content source: dashboard\.md \(section "Operate"\)/u
    );
  });
});

describe("navTabsSchema", () => {
  it("accepts the committed tree, folders included", () => {
    // lib/nav.ts parses this at import, so a tree that fails here would take the sidebar down
    // with it; the assertion is that the committed file still satisfies the declared shape.
    expect(() => navTabsSchema.parse(navData)).not.toThrow();
    expect(navTabsSchema.parse(navData)[0]?.pages.length).toBeGreaterThan(0);
  });

  it("rejects a leaf without a path and a folder without pages", () => {
    expect(() => navTabsSchema.parse([{ title: "Start", pages: [{ title: "Ghost" }] }])).toThrow();
    expect(() => navTabsSchema.parse([{ title: "Start", pages: [{ title: "Loop", path: 1 }] }])).toThrow();
  });
});

describe("NAVIGATED_PATHS", () => {
  it("lists every declared page in menu order, folders traversed in place", () => {
    expect(NAVIGATED_PATHS.slice(0, 3)).toEqual(["index.mdx", "getting-started.mdx", "learn/index.md"]);
    // Conventions holds three pages (conventions, branching, the trunk refactor workflow),
    // so the Operate run starts at 10 rather than 9.
    expect(NAVIGATED_PATHS.slice(10, 15)).toEqual([
      "operate/index.md",
      "dashboard.md",
      "observability.md",
      "config-updates.md",
      "new-repo.md"
    ]);
    expect(NAVIGATED_PATHS.at(-1)).toBe("contribute/navigate-with-bazel.md");
  });

  it("reaches every page exactly once, folders and all", () => {
    expect(new Set(NAVIGATED_PATHS).size).toBe(NAVIGATED_PATHS.length);
  });

  it("names pages by their file, extension included", () => {
    expect(NAVIGATED_PATHS.every((path) => /\.(?:md|mdx)$/u.test(path))).toBe(true);
  });
});

describe("neighborsOf", () => {
  it("walks forward from the first page", () => {
    expect(neighborsOf(completeSource(), "index.mdx")).toEqual({
      next: { name: "Getting started", url: "/page-1" }
    });
  });

  it("omits a neighbour that does not exist rather than setting it undefined", () => {
    expect("previous" in neighborsOf(completeSource(), "index.mdx")).toBe(false);
    expect("next" in neighborsOf(completeSource(), "contribute/navigate-with-bazel.md")).toBe(false);
  });

  it("walks backward and forward inside a folder", () => {
    expect(neighborsOf(completeSource(), "coder-templates.md")).toEqual({
      previous: { name: "Learn overview", url: "/page-2" },
      next: { name: "LiteLLM routing", url: "/page-4" }
    });
  });

  it("carries the reader out of a folder into the next one", () => {
    expect(neighborsOf(completeSource(), "litellm-routing.md").next).toEqual({
      name: "Grok Build and the agents file",
      url: "/page-5"
    });
  });

  it("carries the reader over a section boundary", () => {
    expect(neighborsOf(completeSource(), "getting-started.mdx").next).toEqual({
      name: "Learn overview",
      url: "/page-2"
    });
  });

  it("ends the run at either edge of the reading order", () => {
    expect(neighborsOf(completeSource(), "index.mdx").previous).toBeUndefined();
    expect(neighborsOf(completeSource(), "contribute/navigate-with-bazel.md").next).toBeUndefined();
  });

  it("finds a page given without its extension", () => {
    expect(neighborsOf(completeSource(), "dashboard").next).toEqual({
      name: "Observability bundle",
      url: "/page-12"
    });
    expect(neighborsOf(completeSource(), "observability").next).toEqual({
      name: "Config updates",
      url: "/page-13"
    });
  });

  it("returns nothing for a page the navigation does not declare", () => {
    expect(neighborsOf(completeSource(), "somewhere-else.md")).toEqual({});
  });

  it("reports a missing page rather than a broken footer link", () => {
    expect(() => neighborsOf(navSource([]), "index.mdx")).toThrow(/section "Start"/u);
  });
});

describe("trailFor", () => {
  it("names the section, every folder above the page, and the sidebar label", () => {
    expect(trailFor("config-updates.md")).toEqual({
      tab: "Operate",
      groups: ["Everyday loop"],
      label: "Config updates"
    });
  });

  it("returns an empty group list for a page filed directly under a section", () => {
    expect(trailFor("index.mdx")).toEqual({ tab: "Start", groups: [], label: "Overview" });
  });

  it("accepts a path given without its extension", () => {
    expect(trailFor("contribute/strong-types")?.label).toBe("Strong types");
    expect(trailFor("contribute/strong-types")?.groups).toEqual(["Set up and conventions"]);
  });

  it("says nothing about a page the menu does not file", () => {
    expect(trailFor("not-in-the-menu.md")).toBeUndefined();
  });
});
