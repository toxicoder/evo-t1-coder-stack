/**
 * Tests for the page contract every file under `docs/` has to keep.
 *
 * The layout, the sidebar and the overview panel are all driven by frontmatter and by the
 * opening label/list pairs, so a page that drifts from the contract loses its sidebar entry
 * description, its two-column opening, or its syntax highlighting — silently, at build time.
 * Checking the corpus here is what keeps those visible.
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "docs");

interface Page {
  path: string;
  body: string;
  frontmatter: Record<string, string | undefined>;
}

/** Every markdown page, minus `includes/`, which holds inputs rather than pages. */
function contentPages(dir: string, prefix = ""): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const abs = join(dir, entry);
    const rel = prefix.length > 0 ? `${prefix}/${entry}` : entry;
    if (statSync(abs).isDirectory()) {
      return entry === "includes" ? [] : contentPages(abs, rel);
    }
    return /\.(?:md|mdx)$/u.test(entry) ? [rel] : [];
  });
}

/** Split frontmatter out of a page: the delimited `---` block, then the body after it. */
function parse(path: string): Page {
  const raw = readFileSync(join(docsRoot, path), "utf8");
  const match = /^---\n([\s\S]*?)\n---\n/u.exec(raw);
  if (!match) return { path, body: raw, frontmatter: {} };
  const frontmatter: Record<string, string | undefined> = {};
  for (const line of match[1].split("\n")) {
    const pair = /^(title|description|tags):[ \t]*(.*)$/u.exec(line);
    if (pair) frontmatter[pair[1]] = pair[2].trim();
  }
  return { path, body: raw.slice(match[0].length), frontmatter };
}

/** The page body with fenced code blocks removed, so fences cannot satisfy a body check. */
function withoutFences(body: string): string {
  return body.replace(/^[ \t]*```[\s\S]*?^[ \t]*```[ \t]*$/gmu, "");
}

/** Opening pairs are a label paragraph followed by its list, blank line allowed. */
function hasOpeningPair(body: string, label: string): boolean {
  const pattern = new RegExp(
    `^\\*\\*${label}\\*\\*[ \\t]*\\n(?:[ \\t]*\\n)?(?:[ \\t]*[-*][ \\t]+.+\\n?)+`,
    "mu"
  );
  return pattern.test(withoutFences(body));
}

/**
 * Language of each fence opener. Fences toggle, so only every second ``` line opens
 * one — scanning every line would flag each well-formed closer as an unlabelled fence.
 */
function fenceLanguages(body: string): string[] {
  const languages: string[] = [];
  let open = false;
  for (const line of body.split("\n")) {
    if (!/^[ \t]*```/u.test(line)) continue;
    if (open) {
      open = false;
      continue;
    }
    open = true;
    languages.push(line.trim().slice(3).trim());
  }
  return languages;
}

/** Links into the corpus, which are written file-relative the way href.ts resolves them. */
function contentLinks(body: string): string[] {
  return [...withoutFences(body).matchAll(/\]\(([^)\s]+)\)/gmu)]
    .map((match) => match[1])
    .filter((target) => !target.includes(":") && !target.startsWith("#"));
}

const pages = contentPages(docsRoot).map(parse);

describe("docs page contract", () => {
  it("finds the pages the sidebar is built from", () => {
    expect(pages.length).toBeGreaterThan(10);
  });

  for (const page of pages) {
    describe(page.path, () => {
      it("carries title, description and tags", () => {
        expect(page.frontmatter.title, "title").toBeTruthy();
        expect(page.frontmatter.description, "description").toBeTruthy();
        expect(page.frontmatter.tags, "tags").toBeTruthy();
      });

      it("has no level-1 heading, because the title comes from frontmatter", () => {
        expect(withoutFences(page.body)).not.toMatch(/^# /mu);
      });

      it("starts its headings at level 2", () => {
        const levels = [...withoutFences(page.body).matchAll(/^(#{1,6})[ \t]/gmu)].map((m) => m[1].length);
        for (const level of levels) expect(level).toBeGreaterThanOrEqual(2);
      });

      it("labels every fenced code block with a language", () => {
        for (const language of fenceLanguages(page.body)) {
          expect(language, `fence language in ${page.path}`).toBeTruthy();
        }
      });

      it("opens with the two overview lists the layout renders", () => {
        const body = withoutFences(page.body);
        expect(hasOpeningPair(body, "What's on this page"), "What's on this page").toBe(true);
        expect(hasOpeningPair(body, "What this enables"), "What this enables").toBe(true);
      });

      it("links the corpus by file-relative paths that resolve", () => {
        for (const target of contentLinks(page.body)) {
          const file = target.split("#")[0];
          expect(/\.(?:md|mdx)$/u.test(file), `link target ${target} is not a docs page`).toBe(true);
          const abs = resolve(docsRoot, dirname(page.path), file);
          expect(existsSync(abs), `dead link ${target} in ${page.path}`).toBe(true);
        }
      });
    });
  }
});
