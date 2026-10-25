/**
 * Page loader and search index for the `docs/` collection declared in `content.ts`.
 */

import { loader, PathUtils } from "fumadocs-core/source";
import { createFromSource } from "fumadocs-core/search/server";
import type { AdvancedIndex } from "fumadocs-core/search/server";
import type { Page } from "fumadocs-core/source";

import { resolveHrefWith } from "./href";
import { docs } from "./content";

/**
 * Route prefix of the pages.
 *
 * The site is mounted at the application root (`app/[[...slug]]`), so a page's URL is its
 * slug path.  The published aliases add their own prefix through `basePath` in
 * `next.config.ts`, which is why the URLs here stay root-relative.
 */
const DOCS_ROUTE = "/";

/** A link target that has been resolved to something renderable. */
interface ResolvedHref {
  href: string | undefined;
  /** Set for targets that leave the site, so the caller can add `target`/`rel`. */
  external?: boolean;
}

/**
 * Resolve an intra-docs link against the page it was written on.
 *
 * The resolution rules live in `resolveHrefWith` (`lib/href.ts`); this supplies the lookup
 * against the loaded collection so the rules stay testable without a bundler-time macro.
 *
 * @param href Raw `href` from the markdown.
 * @param page Page the link appears on, used to resolve file-relative targets.
 * @returns The href to render, unchanged for anchors and off-site targets.
 */
export function resolveDocHref(href: string | undefined, page: Page): ResolvedHref {
  return resolveHrefWith(href, page, (segments) =>
    source.getPage(PathUtils.splitPath(segments.join("/")))
  );
}

export const source = loader({
  baseUrl: DOCS_ROUTE,
  source: docs.toFumadocsSource()
});

/**
 * Index a page for search.
 *
 * The built-in index builder covers title, description and body; it has no notion of
 * `tags`, so a reader could not find a page by one.  Structured data is resolved here
 * because the compiled document is loaded on demand.
 *
 * @param page A page from {@link source}.
 * @returns The record to insert into the search database.
 */
export async function buildSearchIndex(page: Page): Promise<AdvancedIndex> {
  const data = page.data as {
    title?: string;
    description?: string;
    tags?: string[];
    structuredData?: AdvancedIndex["structuredData"] | (() => Promise<AdvancedIndex["structuredData"]>);
  };
  const structured =
    typeof data.structuredData === "function" ? await data.structuredData() : data.structuredData;
  if (!structured) throw new Error(`cannot build a search index for ${page.path}: no structured data`);

  return {
    id: page.url,
    title: data.title ?? page.path,
    description: data.description,
    url: page.url,
    structuredData: structured,
    // An empty list would index as a blank facet.
    tag: data.tags?.length ? data.tags : undefined
  };
}

/**
 * Server-side search API, also able to export its database for the static client.
 *
 * `staticGET` is what `app/api/search/route.ts` exposes so the exported build can search in
 * the browser without a server.
 */
export const search = createFromSource(source, { buildIndex: buildSearchIndex });
