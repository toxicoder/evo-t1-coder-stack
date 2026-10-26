/**
 * Tests for the page loader and the search index.
 *
 * Two contracts live here. `resolveDocHref` is the only thing that turns a file-relative link
 * in the markdown into a real route, so a regression 404s it on GitHub Pages; and
 * `buildSearchIndex` is what puts a page's title, description and `tags` into the exported
 * index the static dialog searches, with the structured data resolved lazily by the compiler.
 * The collection itself comes from a bundler-time macro, so it is stubbed.
 */

import type { AdvancedIndex } from "fumadocs-core/search/server";
import type { Page } from "fumadocs-core/source";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { buildSearchIndex, resolveDocHref, search, source } from "../../lib/source";
import {
  createFromSourceStub,
  loaderCalls,
  loaderLookups,
  loaderPages,
  resetStubs
} from "./helpers/fumadocs-stub";

vi.mock("fumadocs-core/source", async (importOriginal) => {
  const actual = await importOriginal<typeof import("fumadocs-core/source")>();
  const { loaderStub } = await import("./helpers/fumadocs-stub");
  return { ...actual, loader: loaderStub };
});

vi.mock("fumadocs-core/search/server", async () => {
  const { createFromSourceStub: createFromSource } = await import("./helpers/fumadocs-stub");
  return { createFromSource };
});

// The real collection is produced by the fumadocs bundler macro.
vi.mock("../../lib/content", async () => {
  const { docsStub } = await import("./helpers/fumadocs-stub");
  return { docs: docsStub };
});

/** Page stand-in: link resolution reads `path`, the index builder reads `url` and `data`. */
function pageAt(path: string, url = "/operate", data: Record<string, unknown> = {}): Page {
  return { path, url, data } as unknown as Page;
}

/** Structured data of the shape the compiler emits for a rendered page. */
const structured = { top: [{ content: "Operate", id: "operate", tags: [] }] } as unknown as AdvancedIndex["structuredData"];

beforeEach(() => {
  resetStubs();
  loaderPages.set("operate/dashboard", { url: "/operate/dashboard", path: "operate/dashboard.md" });
  loaderPages.set("public-access", { url: "/public-access", path: "public-access.md" });
});

/** Options the loader received while `lib/source.ts` was imported. */
const loaderOptions = loaderCalls[0];

describe("source", () => {
  it("mounts the collection at the application root", () => {
    expect(loaderOptions).toMatchObject({ baseUrl: "/", source: { kind: "fumadocs-source" } });
  });

  it("gives the loader the declared collection", () => {
    expect(source).toBeTruthy();
  });
});

describe("search", () => {
  it("builds the server API over the loader with the custom index builder", () => {
    expect(search).toEqual({ kind: "search-api" });
    expect(createFromSourceStub).toHaveBeenCalledWith(source, { buildIndex: buildSearchIndex });
  });
});

describe("resolveDocHref", () => {
  it("resolves a sibling link against the page it was written on", () => {
    expect(resolveDocHref("dashboard.md", pageAt("operate/index.md"))).toEqual({
      href: "/operate/dashboard"
    });
  });

  it("asks the loader for the page's own directory", () => {
    resolveDocHref("dashboard.md", pageAt("operate/index.md"));
    expect(loaderLookups).toContainEqual(["operate", "dashboard"]);
  });

  it("resolves a parent-relative link to a page at the content root", () => {
    expect(resolveDocHref("../public-access.md", pageAt("operate/index.md"))).toEqual({
      href: "/public-access"
    });
  });

  it("keeps the fragment attached to the resolved route", () => {
    expect(resolveDocHref("dashboard.md#sidecar", pageAt("operate/index.md")).href).toBe(
      "/operate/dashboard#sidecar"
    );
  });

  it("flags an off-site target so the caller can open a new tab", () => {
    expect(resolveDocHref("https://github.com/toxicoder/evo-t1-coder-stack", pageAt("index.mdx"))).toEqual({
      href: "https://github.com/toxicoder/evo-t1-coder-stack",
      external: true
    });
  });

  it("passes a bare anchor through without consulting the loader", () => {
    loaderLookups.length = 0;
    expect(resolveDocHref("#what-this-enables", pageAt("index.mdx"))).toEqual({
      href: "#what-this-enables"
    });
    expect(loaderLookups).toEqual([]);
  });

  it("leaves a target with no page behind it unchanged", () => {
    expect(resolveDocHref("nope.md", pageAt("index.mdx"))).toEqual({ href: "nope.md" });
  });

  it("handles a link with no href at all", () => {
    expect(resolveDocHref(undefined, pageAt("index.mdx"))).toEqual({ href: undefined });
  });
});

describe("buildSearchIndex", () => {
  it("indexes the page under its own URL", async () => {
    const index = await buildSearchIndex(
      pageAt("/operate", "/operate", { title: "Operate", structuredData: structured })
    );
    expect(index.id).toBe("/operate");
    expect(index.url).toBe("/operate");
    expect(index.title).toBe("Operate");
  });

  it("carries the description a reader searches on", async () => {
    const index = await buildSearchIndex(
      pageAt("/operate", "/operate", { title: "Operate", description: "Run the stack", structuredData: structured })
    );
    expect(index.description).toBe("Run the stack");
  });

  it("falls back to the path when a page declares no title", async () => {
    const index = await buildSearchIndex(pageAt("/operate", "/operate", { structuredData: structured }));
    expect(index.title).toBe("/operate");
  });

  it("resolves the structured data the compiler left as a thunk", async () => {
    const loader = vi.fn(async () => structured);
    const index = await buildSearchIndex(pageAt("/operate", "/operate", { structuredData: loader }));
    expect(loader).toHaveBeenCalled();
    expect(index.structuredData).toBe(structured);
  });

  it("indexes the contributor tags", async () => {
    const index = await buildSearchIndex(
      pageAt("/operate", "/operate", { title: "Operate", tags: ["docker", "kasm"], structuredData: structured })
    );
    expect(index.tag).toEqual(["docker", "kasm"]);
  });

  it("omits an empty tag list rather than indexing a blank facet", async () => {
    const empty = await buildSearchIndex(pageAt("/operate", "/operate", { tags: [], structuredData: structured }));
    expect(empty.tag).toBeUndefined();
    const missing = await buildSearchIndex(pageAt("/operate", "/operate", { structuredData: structured }));
    expect(missing.tag).toBeUndefined();
  });

  it("names the page when there is no structured data to index", async () => {
    await expect(buildSearchIndex(pageAt("/operate", "/operate", {}))).rejects.toThrow(
      /cannot build a search index for \/operate: no structured data/u
    );
  });
});
