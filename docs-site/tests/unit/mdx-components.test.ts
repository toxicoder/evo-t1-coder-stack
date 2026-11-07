/**
 * Tests for the component map handed to every compiled MDX page.
 *
 * A compiled page imports nothing: the compiler reads the components it references out of the
 * map `app/[[...slug]]/page.tsx` passes, so an entry that is missing or points at the wrong
 * component throws at render time on the reader's side. The links are the subtle entry: the
 * built-in anchor only rewrites `./`-style targets, while the pages also name bare files
 * (`../public-access.md`) that have to become routes, and off-site links still have to open in
 * a new tab with the referrer dropped.
 */

import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { Page } from "fumadocs-core/source";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { mdxComponentsFor } from "../../components/mdx-components";
import { DocsH1, DocsH2, DocsH3, DocsH4, DocsH5, DocsH6 } from "../../components/docs-heading";
import { EzTerm } from "../../components/ez-term";
import { Mermaid } from "../../components/mermaid";
import { PageBrief } from "../../components/page-brief";
import {
  defaultMdxComponentsStub,
  hrefLookups,
  hrefResolution,
  LinkStub,
  resetStubs,
  type ElementLike
} from "./helpers/fumadocs-stub";

vi.mock("fumadocs-ui/mdx", async () => {
  const { defaultMdxComponentsStub: defaults } = await import("./helpers/fumadocs-stub");
  return { default: defaults };
});

vi.mock("fumadocs-core/link", async () => {
  const { LinkStub: Link } = await import("./helpers/fumadocs-stub");
  return { default: Link, Link };
});

// The page link resolver needs the compiled content collection, which a test run does not have.
vi.mock("@/lib/source", async () => {
  const { resolveDocHrefStub } = await import("./helpers/fumadocs-stub");
  return { resolveDocHref: resolveDocHrefStub };
});

// The widget modules are imported through the `@/` alias, which has no Vitest resolver entry;
// registering each alias with the real module is what lets the map load.
vi.mock("@/components/docs-heading", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("../../components/docs-heading");
  return { ...actual };
});

// docs-heading reaches for the bug-link builder through the same alias; without this the
// module graph cannot resolve `@/lib/docs-bug` and the map never loads.
vi.mock("@/lib/docs-bug", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("../../lib/docs-bug");
  return { ...actual };
});

vi.mock("@/components/ez-term", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("../../components/ez-term");
  return { ...actual };
});

vi.mock("@/components/mermaid", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("../../components/mermaid");
  return { ...actual };
});

vi.mock("@/components/page-brief", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("../../components/page-brief");
  return { ...actual };
});

/** Page whose links the map resolves. */
const page = { path: "operate/index.md" } as unknown as Page;

/** The map's anchor, called with one raw href from the markdown. */
function contentLink(href: string, rest: Record<string, unknown> = {}): ElementLike {
  const { a: ContentLink } = mdxComponentsFor(page);
  return ContentLink({ href, ...rest }) as unknown as ElementLike;
}

/** Markup the map's anchor emits for one raw href from the markdown. */
function renderLink(href: string, rest: Record<string, unknown> = {}): string {
  return renderToStaticMarkup(contentLink(href, rest) as unknown as ReactElement);
}

beforeEach(() => {
  resetStubs();
});

describe("mdxComponentsFor", () => {
  it("keeps the fumadocs defaults a page still references", () => {
    const map = mdxComponentsFor(page);
    expect(map.Callout).toBe(defaultMdxComponentsStub.Callout);
    expect(map.Card).toBe(defaultMdxComponentsStub.Card);
  });

  it("routes the markup the remark plugins emit to the site widgets", () => {
    const map = mdxComponentsFor(page);
    expect(map.Mermaid).toBe(Mermaid);
    expect(map.EzTerm).toBe(EzTerm);
    expect(map.PageBrief).toBe(PageBrief);
  });

  it("hands every heading level to the chrome that owns the title and the anchors", () => {
    const map = mdxComponentsFor(page);
    // h1 is the page title: the layout prints none of its own, so a heading missing here
    // would leave the page with no title and no lead paragraph at all.
    expect(map.h1).toBe(DocsH1);
    expect(map.h2).toBe(DocsH2);
    expect(map.h3).toBe(DocsH3);
    expect(map.h4).toBe(DocsH4);
    expect(map.h5).toBe(DocsH5);
    expect(map.h6).toBe(DocsH6);
  });

  it("replaces the plain anchor with its own component", () => {
    expect(Object.keys(mdxComponentsFor(page)).sort()).toEqual(
      [
        "a",
        "Callout",
        "Card",
        "EzTerm",
        "Mermaid",
        "PageBrief",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6"
      ].sort()
    );
  });
});

describe("the content anchor", () => {
  it("resolves the href against the page the map was built for", () => {
    renderLink("dashboard.md");
    expect(hrefLookups).toEqual([{ href: "dashboard.md", path: "operate/index.md" }]);
  });

  it("renders a resolved internal link through the fumadocs link", () => {
    hrefResolution.current = { href: "/operate/dashboard" };
    const html = renderLink("dashboard.md", { children: "Dashboard" });
    expect(html).toContain('data-stub="Link"');
    expect(html).toContain('href="/operate/dashboard"');
    expect(html).toContain(">Dashboard<");
  });

  it("drops the referrer and opens an off-site link in a new tab", () => {
    hrefResolution.current = { href: "https://github.com/toxicoder", external: true };
    const html = renderLink("https://github.com/toxicoder", { children: "repository" });
    expect(html).toContain('target="_blank"');
    expect(html).toContain('rel="noreferrer noopener"');
    expect(html).toContain('href="https://github.com/toxicoder"');
    expect(html).not.toContain('data-stub="Link"');
  });

  it("keeps the attributes the compiler passed beside href", () => {
    hrefResolution.current = { href: "/operate" };
    const props = contentLink("index.md", { className: "fd-card", children: "Operate" }).props;
    expect(props.href).toBe("/operate");
    expect(props.className).toBe("fd-card");
    expect(props.children).toBe("Operate");
  });

  it("lets the markdown win over the attributes the anchor adds", () => {
    hrefResolution.current = { href: "https://example.com", external: true };
    const props = contentLink("https://example.com", { target: "_self" }).props;
    expect(props.target).toBe("_self");
  });

  it("renders a target that resolves to nothing through the fumadocs link", () => {
    hrefResolution.current = { href: "nope.md" };
    expect(contentLink("nope.md").type).toBe(LinkStub);
  });
});
