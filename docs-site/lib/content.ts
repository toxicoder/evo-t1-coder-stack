/**
 * Content source for the documentation site.
 *
 * The pages are read straight out of the repository's `docs/` tree — nothing is copied into
 * this package — so contributors keep editing markdown where the README links point.
 */

import { z } from "zod";
import { defineDocs } from "fumadocs-mdx/macro";
import { metaSchema, pageSchema } from "fumadocs-core/source/schema";

/**
 * Frontmatter of a hand-written page.
 *
 * `pageSchema` strips unknown keys, so `tags` has to be declared here or the contributor
 * tags would silently disappear from the search index.
 */
export const docSchema = pageSchema.extend({
  tags: z.union([z.string(), z.array(z.string())]).optional()
});

/**
 * Both extensions are listed because the corpus mixes them: pages that carry JSX components
 * are `.mdx` (the compiler drops literal JSX in `.md`), the rest stay plain `.md`.
 *
 * `includes/**` holds inputs to pages rather than pages themselves.
 *
 * The list has to stay inline string literals: the bundler macro reads it statically to
 * decide which files to bundle, and rejects anything computed.
 */
export const docs = defineDocs({
  dir: "../docs",
  docs: {
    files: ["**/*.md", "**/*.mdx", "!includes/**"],
    schema: docSchema
  },
  meta: {
    schema: metaSchema
  }
});
