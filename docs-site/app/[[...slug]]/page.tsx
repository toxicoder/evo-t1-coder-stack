import type { Metadata } from "next";
import { notFound } from "next/navigation";
import type { ReactNode } from "react";
import type { TOCItemType } from "fumadocs-core/toc";

import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { DocsBody, DocsPage, EditOnGitHub } from "fumadocs-ui/layouts/docs/page";
import { Banner } from "fumadocs-ui/components/banner";

import { DocsPageProvider } from "@/components/docs-heading";
import { DocsTrail } from "@/components/docs-trail";
import { mdxComponentsFor } from "@/components/mdx-components";
import { PublishedChip } from "@/components/published-chip";
import { TableChrome } from "@/components/table-chrome";
import { Wordmark } from "@/components/wordmark";
import { buildPageTree, neighborsOf, trailFor } from "@/lib/nav";
import { formatPublishedLabel, publishedAt } from "@/lib/published";
import { docsAlias, gitRef, isDevelopmentAlias, REPO_URL, repoFileUrl } from "@/lib/site";
import { source } from "@/lib/source";

/**
 * Enumerate every documentation page for the static export.
 *
 * The published site is `output: "export"`, so each page has to be listed up front;
 * without this the catch-all route would only ever produce the root page.
 */
export function generateStaticParams() {
  return source.generateParams("slug");
}

const tree = buildPageTree(source);

/** "Edit this page" target, honouring the branch-aware ref the alias was built from. */
function editUrl(path: string): string {
  return repoFileUrl(`docs/${path}`);
}

interface PageProps {
  params: Promise<{ slug?: string[] }>;
}

/**
 * Render one documentation page.
 *
 * The compiled MDX module exposes its component through `body` and its table of contents
 * through `toc`; components come from {@link mdxComponentsFor} because the compiled module
 * reads them from `props.components` rather than importing them.
 */
export default async function DocsRoute({ params }: PageProps) {
  const { slug = [] } = await params;
  const page = source.getPage(slug);
  if (!page) notFound();

  const data = page.data as unknown as {
    title?: string;
    description?: string;
    full?: boolean;
    body: (props: { components: Record<string, unknown> }) => ReactNode;
    toc: TOCItemType[];
  };

  const Body = data.body;
  const title = data.title ?? page.path;
  const stamp = publishedAt();
  const trail = trailFor(page.path);

  return (
    <DocsLayout tree={tree} githubUrl={REPO_URL} nav={{ title: Wordmark }}>
      {isDevelopmentAlias() && (
        <Banner id="branch-preview" variant="normal" changeLayout={false}>
          <span className="font-medium">
            Preview docs - these pages track the <code>{docsAlias()}</code> branch and may
            describe work that is not released yet. Prefer{" "}
            <a href="../latest/">latest</a> for production-ready guidance.
          </span>
        </Banner>
      )}
      <DocsPage
        toc={data.toc}
        full={data.full}
        // The trail is the reader's cue for which section and which sidebar folder they are
        // in, since the left menu keeps every other section folded beside their own.
        // fumadocs' own breadcrumb prints page titles, so it names neither the section nor
        // the menu's wording for the leaf; `component` replaces the slot with a trail that
        // does both.
        breadcrumb={
          trail
            ? {
                component: <DocsTrail trail={trail} page={trail.label || title} url={page.url} />
              }
            : { includePage: true }
        }
        footer={{
          items: neighborsOf(source, page.path),
          children: (
            <div className="flex flex-wrap items-center gap-4 pt-6">
              <EditOnGitHub href={editUrl(page.path)} className="ms-auto">
                Edit this page
              </EditOnGitHub>
            </div>
          )
        }}
      >
        <DocsBody>
          {stamp ? (
            <PublishedChip iso={stamp.toISOString()} label={formatPublishedLabel(stamp)} />
          ) : null}
          {/* Title and lead paragraph come from the page's own H1 (see DocsH1), so the header
              prints neither and the page opens with exactly one title. */}
          <DocsPageProvider
            facts={{
              title,
              description: data.description ?? "",
              sourcePath: `docs/${page.path}`,
              sourceUrl: editUrl(page.path),
              gitRef: gitRef(),
              docsAlias: docsAlias()
            }}
          >
            <TableChrome />
            <Body components={mdxComponentsFor(page)} />
          </DocsPageProvider>
        </DocsBody>
      </DocsPage>
    </DocsLayout>
  );
}

/** Metadata for one page: title falls back to the site title, description is the frontmatter's. */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug = [] } = await params;
  const page = source.getPage(slug);
  if (!page) return {};
  const data = page.data as unknown as { title?: string; description?: string };
  return {
    title: data.title ?? page.path,
    description: data.description
  };
}
