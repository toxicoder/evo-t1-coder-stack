/**
 * Tests for the static-export verifier.
 *
 * The published artifact is a directory of `index.html` files handed to GitHub Pages, so what
 * reaches an operator is always structural: a navigation page the export never emitted, a
 * content link that kept its `.md` suffix and 404s in the browser, or an asset href baked
 * without the alias prefix, which 404s every stylesheet on an alias build. Each of those is a
 * `FAIL` line and a non-zero exit, and the run has to keep going past the first bad page
 * instead of throwing on it.
 *
 * The verifier is a CLI, so each case re-imports it against its own scratch export tree under
 * the OS temp directory (the real `lib/nav.json` decides which pages it must find) and reads
 * back the lines it printed. Run it from `docs-site/` with `npm run unit`, or
 * `npm run unit:coverage` for the gate.
 */

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { basePath as publishedBasePath } from "../../lib/site";

/** One tab of `lib/nav.json`, as the verifier reads it. */
interface NavTab {
  pages: { path: string }[];
}

const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** The declared corpus: the verifier fails any one of these that the export omitted. */
const navPages = (
  JSON.parse(readFileSync(join(siteRoot, "lib", "nav.json"), "utf8")) as NavTab[]
).flatMap((tab) => tab.pages);

/** Stands in for the CLI's own `process.exit`, which would take the test worker with it. */
class VerifierExit extends Error {}

/** A page's published address: no extension, no trailing `index`, trailing slash. */
function exportedUrl(path: string): string {
  const segments = path
    .replace(/\.(?:md|mdx)$/iu, "")
    .split("/")
    .filter((segment) => segment.length > 0 && segment !== "index");
  return segments.length > 0 ? `/${segments.join("/")}/` : "/";
}

/** Where the verifier expects to read a page from. */
function exportedFile(exportDir: string, path: string): string {
  return join(exportDir, exportedUrl(path), "index.html");
}

/** HTML of a page the export emitted correctly: prefixed asset, resolved internal link. */
function cleanPageHtml(basePath: string): string {
  return [
    "<!doctype html><html><head>",
    `<link href="${basePath}/_next/static/css/app.css" rel="stylesheet">`,
    "</head><body>",
    `<a href="${basePath}/operate/dashboard/">Dashboard</a>`,
    "</body></html>"
  ].join("");
}

/** What one `console.log` line reported. */
interface Report {
  name: string;
  detail: string | undefined;
}

/** Names of the checks that passed, in the order the verifier ran them. */
function passed(lines: string[]): string[] {
  return lines.filter((line) => line.startsWith("ok")).map((line) => line.replace(/^ok\s+/u, ""));
}

/** The checks that failed, with the diagnostic the verifier attached. */
function failed(lines: string[]): Report[] {
  return lines
    .filter((line) => line.startsWith("FAIL"))
    .map((line) => {
      const [name, detail] = line.replace(/^FAIL\s+/u, "").split("  ::  ");
      return { name: name ?? "", detail };
    });
}

let baseDir = "";
let exportDir = "";

/** Point the verifier's alias detection at `alias` and report the base path that implies. */
function useAlias(alias: string | undefined): string {
  delete process.env.DOCS_ALIAS;
  delete process.env.NEXT_BASE_PATH;
  if (alias) process.env.DOCS_ALIAS = alias;
  return publishedBasePath();
}

/**
 * Lay out an export directory.
 *
 * `pages` overrides one declared page: a string is written in its place and `null` leaves the
 * page out of the export entirely, which is how a page that never got emitted is reproduced.
 */
function writeExport(
  directory: string,
  basePath: string,
  options: { pages?: Record<string, string | null> } = {}
): void {
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  for (const page of navPages) {
    const override = options.pages?.[page.path];
    if (override === null) continue;
    const file = exportedFile(directory, page.path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, override ?? cleanPageHtml(basePath));
  }
}

/** Run the verifier the way the CLI runs it: fresh module, own argv, output and exit captured. */
async function runVerifier(
  directory = exportDir
): Promise<{ lines: string[]; errors: string[]; exitCode: number | undefined }> {
  const lines: string[] = [];
  const errors: string[] = [];
  const logSpy = vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => {
    lines.push(args.join(" "));
  });
  const errorSpy = vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    errors.push(args.join(" "));
  });
  const originalExit = process.exit;
  const originalArgv = process.argv;
  let exitCode: number | undefined;
  process.exit = ((code?: number | string) => {
    exitCode = typeof code === "number" ? code : 1;
    throw new VerifierExit("verify_site exited");
  }) as typeof process.exit;
  process.argv = ["node", "verify_site.mjs", directory];

  vi.resetModules();
  try {
    // The CLI is untyped JavaScript imported for its side effects, so the specifier is widened
    // to `string` to keep tsc from demanding a declaration file for it.
    await import("../../scripts/verify_site.mjs" as string);
  } catch (error) {
    if (!(error instanceof VerifierExit)) throw error;
  } finally {
    process.exit = originalExit;
    process.argv = originalArgv;
    logSpy.mockRestore();
    errorSpy.mockRestore();
  }

  return { lines, errors, exitCode };
}

beforeAll(() => {
  baseDir = mkdtempSync(join(tmpdir(), "verify-site-"));
  exportDir = join(baseDir, "out");
});

afterEach(() => {
  delete process.env.DOCS_ALIAS;
  delete process.env.NEXT_BASE_PATH;
});

afterAll(() => {
  rmSync(baseDir, { recursive: true, force: true });
});

describe("verify_site", () => {
  it("passes an export that emitted every declared page", async () => {
    writeExport(exportDir, useAlias(undefined));

    const result = await runVerifier();

    expect(result.exitCode).toBeUndefined();
    expect(result.errors).toEqual([]);
    expect(failed(result.lines)).toEqual([]);
    expect(passed(result.lines)).toEqual([
      "export has a root index.html",
      "nav.json declares pages"
    ]);
    expect(result.lines.at(-1)).toBe(`verify_site: ${navPages.length} exported pages check out.`);
  });

  it("reports every page the export omitted at the address it should have used", async () => {
    const basePath = useAlias(undefined);
    writeExport(exportDir, basePath, {
      pages: Object.fromEntries(navPages.map((page) => [page.path, null] as const))
    });

    const result = await runVerifier();

    expect(passed(result.lines)).toEqual(["nav.json declares pages"]);
    const reports = failed(result.lines);
    expect(reports).toHaveLength(navPages.length + 1);
    for (const name of [
      "page index.mdx is exported at /",
      "page getting-started.mdx is exported at /getting-started/",
      "page learn/index.md is exported at /learn/",
      "page operate/index.md is exported at /operate/",
      "page contribute/test-with-bazel.md is exported at /contribute/test-with-bazel/"
    ]) {
      expect(reports).toContainEqual({ name, detail: "missing" });
    }
    expect(reports).toContainEqual({ name: "export has a root index.html", detail: undefined });
    expect(result.errors).toEqual([`verify_site: ${navPages.length + 1} problem(s)`]);
    expect(result.exitCode).toBe(1);
  });

  it("names the address a page the export omitted should have been published at", async () => {
    writeExport(exportDir, useAlias(undefined), { pages: { "learn/index.md": null } });

    const result = await runVerifier();

    expect(failed(result.lines)).toEqual([
      { name: "page learn/index.md is exported at /learn/", detail: "missing" }
    ]);
    expect(result.errors).toEqual(["verify_site: 1 problem(s)"]);
    expect(result.exitCode).toBe(1);
  });

  it("reports a page that is a directory rather than throwing on it", async () => {
    const basePath = useAlias(undefined);
    writeExport(exportDir, basePath);
    const page = exportedFile(exportDir, "operate/index.md");
    rmSync(page);
    mkdirSync(page, { recursive: true });

    const result = await runVerifier();

    expect(failed(result.lines)).toEqual([
      { name: "page operate/index.md is exported at /operate/", detail: "missing" }
    ]);
    expect(result.exitCode).toBe(1);
  });

  it("keeps reading past a bad page and reports every problem it found", async () => {
    const basePath = useAlias(undefined);
    writeExport(exportDir, basePath, {
      pages: {
        "getting-started.mdx": null,
        "hermes.md": `${cleanPageHtml(basePath)}<a href="../operate/index.md">Operate</a>`
      }
    });

    const result = await runVerifier();

    expect(failed(result.lines).map((report) => report.name)).toEqual([
      "page getting-started.mdx is exported at /getting-started/",
      "page hermes.md has no unresolved .md links"
    ]);
    expect(result.errors).toEqual(["verify_site: 2 problem(s)"]);
    expect(result.exitCode).toBe(1);
  });

  it("fails a page that kept its content link and quotes the first three", async () => {
    const basePath = useAlias(undefined);
    const leftovers = ['href="../operate/index.md"', 'href="devcontainer.mdx"', 'href="a.md"', 'href="b.md"'];
    writeExport(exportDir, basePath, {
      pages: {
        "index.mdx": `${cleanPageHtml(basePath)}${leftovers.map((href) => `<a ${href}>x</a>`).join("")}`
      }
    });

    const result = await runVerifier();

    const report = failed(result.lines).find(
      (entry) => entry.name === "page index.mdx has no unresolved .md links"
    );
    expect(report?.detail).toBe(leftovers.slice(0, 3).join(", "));
    expect(result.exitCode).toBe(1);
  });

  it("leaves an off-site source link alone", async () => {
    const basePath = useAlias(undefined);
    writeExport(exportDir, basePath, {
      pages: {
        "hermes.md": `${cleanPageHtml(
          basePath
        )}<a href="https://github.com/toxicoder/evo-t1-coder-stack/blob/main/docs/hermes.md">source</a>`
      }
    });

    const result = await runVerifier();

    expect(failed(result.lines)).toEqual([]);
    expect(result.lines.at(-1)).toBe(`verify_site: ${navPages.length} exported pages check out.`);
    expect(result.exitCode).toBeUndefined();
  });

  it("passes an alias export whose assets all sit under the prefix", async () => {
    const basePath = useAlias("latest");
    expect(basePath).toBe("/evo-t1-coder-stack/latest");
    writeExport(exportDir, basePath);

    const result = await runVerifier();

    expect(failed(result.lines)).toEqual([]);
    expect(passed(result.lines)).toContain("assets are served under /evo-t1-coder-stack/latest");
    expect(result.lines.at(-1)).toBe(
      `verify_site: ${navPages.length} exported pages check out under /evo-t1-coder-stack/latest.`
    );
    expect(result.exitCode).toBeUndefined();
  });

  it("fails a page whose asset skipped the alias prefix", async () => {
    const basePath = useAlias("latest");
    writeExport(exportDir, basePath, {
      pages: {
        "hermes.md": `${cleanPageHtml(basePath)}<script src="/_next/static/chunks/main.js"></script>`
      }
    });

    const result = await runVerifier();

    expect(failed(result.lines)).toContainEqual({
      name: "page hermes.md prefixes its assets with /evo-t1-coder-stack/latest",
      detail: "/_next/static/chunks/main.js"
    });
    expect(result.exitCode).toBe(1);
  });

  it("fails an export whose root index never mentions the alias prefix", async () => {
    const basePath = useAlias("latest");
    writeExport(exportDir, basePath, {
      pages: { "index.mdx": "<!doctype html><html><body>no assets here</body></html>" }
    });

    const result = await runVerifier();

    expect(failed(result.lines)).toContainEqual({
      name: "assets are served under /evo-t1-coder-stack/latest",
      detail: "no matching href in the exported index"
    });
    expect(result.errors).toEqual(["verify_site: 1 problem(s)"]);
    expect(result.exitCode).toBe(1);
  });

  it("treats an unreadable root index as an export that shipped no assets", async () => {
    const basePath = useAlias("latest");
    writeExport(exportDir, basePath);
    // The root check only tests that the path exists, so a directory there reads as no HTML.
    const index = exportedFile(exportDir, "index.mdx");
    rmSync(index);
    mkdirSync(index, { recursive: true });

    const result = await runVerifier();

    expect(passed(result.lines)).toContain("export has a root index.html");
    expect(failed(result.lines)).toContainEqual({
      name: "assets are served under /evo-t1-coder-stack/latest",
      detail: "no matching href in the exported index"
    });
    expect(result.exitCode).toBe(1);
  });

  it("stops at a missing export directory and says how to build one", async () => {
    useAlias(undefined);
    const missing = join(baseDir, "never-built");
    expect(existsSync(missing)).toBe(false);

    const result = await runVerifier(missing);

    expect(result.lines).toEqual([]);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain(`no export at ${missing}`);
    expect(result.errors[0]).toContain("run npm run build first");
    expect(result.exitCode).toBe(1);
  });

  it("verifies the export directory the operator named instead of the default", async () => {
    const basePath = useAlias(undefined);
    const named = join(baseDir, "out-latest");
    rmSync(exportDir, { recursive: true, force: true });
    writeExport(named, basePath);

    const result = await runVerifier(named);

    expect(failed(result.lines)).toEqual([]);
    expect(result.exitCode).toBeUndefined();
  });
});
