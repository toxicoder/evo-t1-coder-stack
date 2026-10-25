import path from "node:path";
import { fileURLToPath } from "node:url";

import { createMDX } from "fumadocs-mdx/next";
import type { NextConfig } from "next";

import { basePath as publishedBasePath } from "./lib/site";

/** Directory of this config file, i.e. the `docs-site/` package. */
const packageRoot = fileURLToPath(new URL(".", import.meta.url));

/**
 * Base path of the published site.
 *
 * GitHub project Pages serves the repository under `/<repo>/`, and every branch that touches
 * the docs publishes its own alias (`main` as `latest`, anything else as its sanitized
 * branch name). Each alias is a separate export built with `DOCS_ALIAS` set, so its asset
 * hrefs carry `/<repo>/<alias>/_next/...` instead of asking the Pages root for them.
 */
const basePath = publishedBasePath();

/** Where the static export is written; `NEXT_DIST_DIR` lets a wrapper build stay out of the way. */
const distDir = process.env.NEXT_DIST_DIR || "out";

const withMDX = createMDX();

const nextConfig: NextConfig = {
  basePath: basePath === "/" ? "" : basePath,
  /** Static export: the site is published to GitHub Pages, so there is no Node server. */
  output: "export",
  distDir,
  /** Images are served from the same static export, so no optimisation loader is available. */
  images: { unoptimized: true },
  /**
   * Publish pages as `<slug>/index.html` rather than `<slug>.html`.
   *
   * The README and the Pages aliases link the trailing-slash form, so exporting flat files
   * would turn each of those into a 404.
   */
  trailingSlash: true,
  reactStrictMode: true,
  turbopack: {
    /**
     * Pin the bundler root to the repository.
     *
     * The bundler infers the root by walking up looking for a lockfile, and a lockfile from
     * something else can sit above the checkout. It also cannot read content above the root
     * it picks, and the pages live in `docs/` beside this package.
     */
    root: path.resolve(packageRoot, "..")
  }
};

export default withMDX(nextConfig);
