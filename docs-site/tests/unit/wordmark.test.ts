/**
 * Tests for the header wordmark.
 *
 * The header title is a component rather than a string so the brand and the repository name
 * can stack; both are also the only thing that names the site for a screen reader. The route
 * to the repository is not the wordmark's job: `DocsLayout` renders it from its `githubUrl`.
 * Both render without a DOM through `renderToStaticMarkup`, which is what the exported build
 * ships.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { describe, expect, it, vi } from "vitest";

import { Wordmark } from "../../components/wordmark";
import { BRAND, SITE_NAME } from "../../lib/site";

// The wordmark imports the brand through the `@/` alias, which has no Vitest resolver entry;
// registering the alias with the real module is what lets the component load at all.
vi.mock("@/lib/site", async () => {
  const actual = await vi.importActual<typeof import("../../lib/site")>("../../lib/site");
  return { ...actual };
});

describe("Wordmark", () => {
  it("stacks the brand above the project name", () => {
    const html = renderToStaticMarkup(createElement(Wordmark));
    expect(html).toContain(`>${BRAND}<`);
    expect(html).toContain(`>${SITE_NAME}<`);
    expect(html.indexOf(`>${BRAND}<`)).toBeLessThan(html.indexOf(`>${SITE_NAME}<`));
  });

  it("names the pair for the accessibility tree", () => {
    expect(renderToStaticMarkup(createElement(Wordmark))).toContain(`aria-label="${BRAND} ${SITE_NAME}"`);
  });

  it("keeps the brand lowercase so it matches the logo lockup", () => {
    expect(renderToStaticMarkup(createElement(Wordmark))).toContain("lowercase");
  });

  it("appends a class the caller passes", () => {
    const html = renderToStaticMarkup(createElement(Wordmark, { className: "mx-2" }));
    expect(html).toContain('class="flex flex-col leading-none mx-2"');
  });

  it("renders with no class at all", () => {
    expect(renderToStaticMarkup(createElement(Wordmark))).toContain('class="flex flex-col leading-none "');
  });
});
