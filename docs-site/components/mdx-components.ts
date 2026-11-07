/**
 * Component map handed to every compiled MDX page.
 *
 * The MDX compiler emits `_createMdxContent(props)` and destructures the components a page
 * uses out of `props.components`, so the page files import nothing: the map is passed once
 * by `app/[[...slug]]/page.tsx`.  Anything a page can reference has to be listed here,
 * otherwise the compiler's missing-reference guard throws at render time.
 *
 * The Fumadocs defaults (headings, images, tables, code blocks, callouts, cards) are spread
 * in first so the entries below add to them rather than replace them.
 */

import { createElement } from "react";
import Link from "fumadocs-core/link";
import defaultMdxComponents from "fumadocs-ui/mdx";

import { DocsH1, DocsH2, DocsH3, DocsH4, DocsH5, DocsH6 } from "@/components/docs-heading";
import { EzTerm } from "@/components/ez-term";
import { Mermaid } from "@/components/mermaid";
import { PageBrief } from "@/components/page-brief";
import { resolveDocHref } from "@/lib/source";
import type { Page } from "fumadocs-core/source";

/**
 * Build the component map for one page.
 *
 * @param page Page being rendered; links in its content resolve relative to it.
 * @returns The `components` object for the compiled MDX component.
 */
export function mdxComponentsFor(page: Page) {
  /**
   * Anchor used by links inside page content.
   *
   * The built-in one only rewrites `./`-style hrefs; the pages also use bare
   * file-relative targets (`../public-access.md`) that have to become real routes, while
   * off-site links keep opening in a new tab.
   */
  function ContentLink(props: { href?: string } & Record<string, unknown>) {
    const { href, ...rest } = props;
    const resolved = resolveDocHref(href, page);
    if (resolved.external) {
      return createElement("a", { href: resolved.href, rel: "noreferrer noopener", target: "_blank", ...rest });
    }
    return createElement(Link, { href: resolved.href, ...rest });
  }

  return {
    ...defaultMdxComponents,
    // The headings carry the anchor-copy and file-a-bug controls, and `DocsH1` is the page
    // title: the layout prints no title of its own, so the authored `# H1` is the one title
    // and the frontmatter description becomes its lead paragraph.
    h1: DocsH1,
    h2: DocsH2,
    h3: DocsH3,
    h4: DocsH4,
    h5: DocsH5,
    h6: DocsH6,
    a: ContentLink,
    // Callout, Banner, Tabs and the rest of the authoring primitives already come from the
    // fumadocs defaults spread above; these three are the site's own.
    Mermaid,
    EzTerm,
    PageBrief
  };
}
