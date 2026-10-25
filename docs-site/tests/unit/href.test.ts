/**
 * Tests for file-relative link resolution.
 *
 * The corpus names a page by the file it lives in and keeps the content suffix —
 * `[Troubleshooting](troubleshooting.md)` — because that is how the pages were written
 * beside the README. Those links are the only route readers have between pages, so a
 * regression here silently 404s them on GitHub Pages.
 */

import { describe, expect, it } from "vitest";

import { resolveHrefWith } from "../../lib/href";
import type { HrefTarget } from "../../lib/href";

/**
 * Page lookup standing in for the content source.
 *
 * URLs follow `keepAuthorSlugs`: the extension is gone and an `index` page is addressed by
 * its directory, which is exactly how the site publishes them.
 */
const PAGES: HrefTarget[] = [
  { url: "/" },
  { url: "/getting-started" },
  { url: "/learn" },
  { url: "/operate" },
  { url: "/operate/dashboard" },
  { url: "/troubleshooting" },
  { url: "/contribute/building-with-bazel" }
];

const PATHS: Record<string, string> = {
  "/": "index.mdx",
  "/getting-started": "getting-started.mdx",
  "/learn": "learn/index.md",
  "/operate": "operate/index.md",
  "/operate/dashboard": "operate/dashboard.md",
  "/troubleshooting": "troubleshooting.md",
  "/contribute/building-with-bazel": "contribute/building-with-bazel.md"
};

function find(segments: string[]): HrefTarget | undefined {
  const url = `/${segments.join("/")}`;
  const path = PATHS[url];
  if (!path) return undefined;
  return PAGES.find((page) => page.url === url);
}

describe("resolveHrefWith", () => {
  it("resolves a sibling file link written with its .md suffix", () => {
    const { href } = resolveHrefWith("troubleshooting.md", { path: "operate/index.md" }, find);
    expect(href).toBe("/troubleshooting");
  });

  it("resolves a sibling .mdx link", () => {
    const { href } = resolveHrefWith("getting-started.mdx", { path: "index.mdx" }, find);
    expect(href).toBe("/getting-started");
  });

  it("resolves a ../-relative link across directories", () => {
    const { href } = resolveHrefWith("../troubleshooting.md", { path: "operate/index.md" }, find);
    expect(href).toBe("/troubleshooting");
  });

  it("resolves a link that names an index page explicitly", () => {
    const { href } = resolveHrefWith("learn/index.md", { path: "index.mdx" }, find);
    expect(href).toBe("/learn");
  });

  it("resolves an index link reached through ..", () => {
    const { href } = resolveHrefWith("../operate/index.md", { path: "contribute/building-with-bazel.md" }, find);
    expect(href).toBe("/operate");
  });

  it("keeps the fragment attached", () => {
    const { href } = resolveHrefWith("troubleshooting.md#coder", { path: "operate/index.md" }, find);
    expect(href).toBe("/troubleshooting#coder");
  });

  it("flags off-site links so they open out", () => {
    const result = resolveHrefWith("https://example.com/a", { path: "index.mdx" }, find);
    expect(result.external).toBe(true);
    expect(result.href).toBe("https://example.com/a");
  });

  it("passes bare anchors through untouched", () => {
    expect(resolveHrefWith("#section", { path: "index.mdx" }, find).href).toBe("#section");
  });

  it("leaves an unresolvable target alone rather than emitting a broken route", () => {
    expect(resolveHrefWith("nope.md", { path: "index.mdx" }, find).href).toBe("nope.md");
  });

  it("handles an empty href", () => {
    expect(resolveHrefWith("", { path: "index.mdx" }, find).href).toBe("");
  });
});
