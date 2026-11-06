// @ts-check
/*
 * Static-export verifier for the Fumadocs documentation site.
 *
 * The published artifact is a directory of `index.html` files served by GitHub Pages, so the
 * failures that reach an operator are all structural: a navigation page that never got
 * emitted, a link that kept its `.md` suffix and 404s, or an asset href baked without the
 * alias prefix (every stylesheet then 404s). This checks the export for exactly those, with
 * no browser: `npm run build` and then `npm run verify`.
 *
 * Usage:
 *   npm run verify                     # checks docs-site/out
 *   npm run verify -- out-latest       # checks another export directory
 *   DOCS_ALIAS=latest npm run verify   # also require the alias prefix on asset hrefs
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Node strips the types, so these are the same basePath() and extension rule the export used.
import { basePath as publishedBasePath } from "../lib/site.ts";
import { withoutExtension } from "../lib/href.ts";

const packageRoot = dirname(fileURLToPath(import.meta.url));
const siteRoot = resolve(packageRoot, "..");

const exportRoot = resolve(siteRoot, process.argv[2] ?? "out");
const basePath = publishedBasePath();

/** One entry of `lib/nav.json`, as far as this verifier reads it. */
/** @typedef {{ pages: { path: string }[] }} NavTab */

/** @type {string[]} */
const problems = [];

/** Report one assertion; the detail is a failure diagnostic, so it prints only on failure.
 *
 * @param {string} name What was checked.
 * @param {boolean} ok Whether it passed.
 * @param {string} [detail] Diagnostic printed with a failure.
 * @returns {void}
 */
function check(name, ok, detail) {
  console.log(`${ok ? "ok  " : "FAIL"}  ${name}${ok || !detail ? "" : `  ::  ${detail}`}`);
  if (!ok) problems.push(name);
}

/** Address a page publishes at: no extension, no trailing `index`, trailing slash.
 *
 * @param {string} path Page path as `lib/nav.json` names it.
 * @returns {string} The URL the page is published at.
 */
function urlFor(path) {
  const segments = withoutExtension(path)
    .split("/")
    .filter((segment) => segment.length > 0 && segment !== "index");
  return segments.length > 0 ? `/${segments.join("/")}/` : "/";
}

/** Read a file, reporting rather than throwing so one bad page does not stop the run.
 *
 * @param {string} file File to read.
 * @returns {string | undefined} Its contents, or nothing when it cannot be read.
 */
function readHtml(file) {
  try {
    return readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
}

if (!existsSync(exportRoot)) {
  console.error(`verify_site: no export at ${exportRoot} — run npm run build first`);
  process.exit(1);
}

// JSON.parse has no static type, so the file is pinned to the shape this verifier reads.
/** @type {NavTab[]} */
const nav = JSON.parse(readFileSync(join(siteRoot, "lib", "nav.json"), "utf8"));
const pages = nav.flatMap((tab) => tab.pages);

check("export has a root index.html", existsSync(join(exportRoot, "index.html")));

for (const page of pages) {
  const url = urlFor(page.path);
  const htmlPath = join(exportRoot, url, "index.html");
  const html = readHtml(htmlPath);
  if (html === undefined) {
    check(`page ${page.path} is exported at ${url}`, false, "missing");
    continue;
  }
  // A site-internal link that kept its content extension never became a route: href.ts
  // could not find the page, so the reader would get a 404 (or a raw markdown download).
  // Off-site hrefs keep their `.md` on purpose — those are the source links to GitHub.
  const leftovers = [...html.matchAll(/href="(?!https?:|\/\/)[^"]*\.(?:md|mdx)(?:#[^"]*)?"/giu)].map(
    (match) => match[0]
  );
  if (leftovers.length > 0) {
    check(`page ${page.path} has no unresolved .md links`, false, leftovers.slice(0, 3).join(", "));
  }
  if (basePath.length > 0) {
    // Every Next-emitted asset must sit under the alias, or Pages serves it from the root.
    const bare = [...html.matchAll(/(?:href|src)="(\/_next\/[^"]*)"/giu)].map((match) => match[1]);
    if (bare.length > 0) {
      const [firstBare = ""] = bare;
      check(`page ${page.path} prefixes its assets with ${basePath}`, false, firstBare);
    }
  }
}

if (basePath.length > 0) {
  const index = readHtml(join(exportRoot, "index.html")) ?? "";
  check(
    `assets are served under ${basePath}`,
    index.includes(`${basePath}/_next/`),
    "no matching href in the exported index"
  );
}

check("nav.json declares pages", pages.length > 0, `${pages.length} pages in nav.json`);

if (problems.length > 0) {
  console.error(`verify_site: ${problems.length} problem(s)`);
  process.exit(1);
}
console.log(`verify_site: ${pages.length} exported pages check out${basePath ? ` under ${basePath}` : ""}.`);
