/**
 * Tests for the content collection declaration.
 *
 * `defineDocs` is a bundler-time macro, so a wrong `dir` or a dropped extension is a build
 * that quietly ships an empty site, and the pages live in the sibling `docs/` tree rather than
 * in this package. `tags` is the other silent one: `pageSchema` strips unknown keys, so
 * frontmatter tags vanish from the search index the moment the `extend` is removed.
 */

import { metaSchema, pageSchema } from "fumadocs-core/source/schema";

import { describe, expect, it, vi } from "vitest";

import { docs, docSchema } from "../../lib/content";
import { docsConfigs } from "./helpers/fumadocs-stub";

// The real macro only works when the fumadocs bundler plugin has compiled this module.
vi.mock("fumadocs-mdx/macro", async () => {
  const { defineDocsStub: defineDocs } = await import("./helpers/fumadocs-stub");
  return { defineDocs };
});

/**
 * The declarations `lib/content.ts` made while the module loaded.
 *
 * Taken here rather than in a `beforeEach`: the collection is declared once, at import.
 */
const declarations: Record<string, unknown>[] = [...docsConfigs];

/** The single collection declaration `lib/content.ts` makes. */
function declared(): Record<string, unknown> {
  const [config] = declarations;
  if (!config) throw new Error("the collection was never declared");
  return config;
}

function docsSection(): Record<string, unknown> {
  return declared().docs as Record<string, unknown>;
}

describe("docSchema", () => {
  it("keeps the contributor tags the base schema would strip", () => {
    expect(Object.keys(pageSchema.shape)).not.toContain("tags");
    expect(docSchema.parse({ title: "Operate", tags: ["docker", "kasm"] })).toEqual({
      title: "Operate",
      tags: ["docker", "kasm"]
    });
  });

  it("leaves tags optional for a page that carries none", () => {
    expect(docSchema.parse({ title: "Operate" }).tags).toBeUndefined();
  });

  it("keeps the base frontmatter it inherits", () => {
    expect(docSchema.parse({ title: "Operate", description: "Run the stack", icon: "Server" })).toEqual({
      title: "Operate",
      description: "Run the stack",
      icon: "Server"
    });
  });

  it("still strips keys nobody declared", () => {
    expect(docSchema.parse({ title: "Operate", sidebarPosition: 3 })).toEqual({ title: "Operate" });
  });

  it("requires the title the sidebar and the search index both need", () => {
    expect(() => docSchema.parse({ tags: ["docker"] })).toThrow();
  });

  it("refuses tags that are not a list of strings", () => {
    expect(() => docSchema.parse({ title: "Operate", tags: "docker" })).toThrow();
    expect(() => docSchema.parse({ title: "Operate", tags: [3] })).toThrow();
  });
});

describe("docs", () => {
  it("reads the pages out of the repository docs tree", () => {
    expect(declared().dir).toBe("../docs");
  });

  it("bundles both extensions and leaves the include fragments out", () => {
    expect(docsSection().files).toEqual(["**/*.md", "**/*.mdx", "!includes/**"]);
  });

  it("applies the extended schema to pages and the stock one to meta.json", () => {
    expect(docsSection().schema).toBe(docSchema);
    expect((declared().meta as Record<string, unknown>).schema).toBe(metaSchema);
  });

  it("hands the collection to the loader in lib/source.ts", () => {
    expect(docs.toFumadocsSource()).toEqual({ kind: "fumadocs-source" });
    expect(declarations).toHaveLength(1);
  });
});
