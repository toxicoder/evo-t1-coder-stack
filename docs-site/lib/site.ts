/**
 * Site-wide configuration for the documentation app.
 *
 * Every published alias lives under the repository's GitHub Pages root, so the values here
 * are what keeps asset URLs, "Edit this page" links and the repository button pointed at the
 * right place for whichever branch produced the export.
 */

/** Name of the project, shown as the docs subtitle under the wordmark. */
export const SITE_NAME = "evo-t1-coder-stack";

/** Secondary brand voice shown in the wordmark. */
export const BRAND = "overeazy";

/** Repository URL, used for the header button and the source links. */
export const REPO_URL = "https://github.com/toxicoder/evo-t1-coder-stack";

/** Owner/repository, parsed from {@link REPO_URL} for building source links. */
export const REPO = { user: "toxicoder", repo: "evo-t1-coder-stack" } as const;

/**
 * Alias this build publishes under, as set by the publisher (`latest`, or a sanitized
 * branch name). Empty for the unprefixed local export.
 */
export function docsAlias(): string {
  return (process.env.DOCS_ALIAS ?? "").trim();
}

/**
 * Git ref that "Edit this page" and source links point at.
 *
 * The `latest` alias is the `main` export, so a reader there must open the `main` copy of a
 * file. Any other alias is a branch export, and its own branch name is the ref: the
 * publisher passes the unsanitized `GITHUB_REF_NAME` (a `/`-bearing branch name is a valid
 * ref, while the alias in the URL has had its slashes replaced).
 */
export function gitRef(): string {
  if (docsAlias() === "latest") return "main";
  const ref = (process.env.GITHUB_REF_NAME ?? process.env.EVO_DOCS_GIT_REF ?? "").trim();
  return ref || "main";
}

/**
 * Public base path of the deployed site, e.g. `/evo-t1-coder-stack/feat-foo`.
 *
 * GitHub project Pages serves this repository at `/<repo>/`, so every alias build has to
 * bake that prefix into its asset URLs or every stylesheet 404s. `DOCS_ALIAS` is what the
 * publisher sets, and it is not a closed set: `main` publishes `latest` and any other
 * docs-touching branch publishes its own sanitized name. `NEXT_BASE_PATH` stays the
 * explicit override (`/` means none); with neither set the export is unprefixed, which is
 * what `next dev` and the local preview use.
 */
export function basePath(): string {
  const explicit = (process.env.NEXT_BASE_PATH ?? "").trim();
  if (explicit === "/") return "";
  if (explicit.length > 0) return explicit.replace(/\/$/, "");
  const alias = docsAlias();
  if (alias.length > 0) return `/${REPO.repo}/${alias}`;
  return "";
}

/** URL of a file in the repository at the active ref. */
export function repoFileUrl(path: string): string {
  return `${REPO_URL}/blob/${gitRef()}/${path.replace(/^\/+/, "")}`;
}
