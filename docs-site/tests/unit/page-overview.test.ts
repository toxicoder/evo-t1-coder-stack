/**
 * Tests for the two-column page-overview panel.
 *
 * `remarkPageOverview` rewrites the opening **What's on this page** / **What this enables**
 * pair into these components, so the panel is the reader's first sight of every page and the
 * marks are the only visual cue that separates the two columns. Both columns come from one
 * component with a `kind` prop, which makes a swapped mark easy to ship by accident.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { describe, expect, it } from "vitest";

import { PageOverview, PageOverviewColumn } from "../../components/page-overview";

/** The list glyph the contents column is meant to draw. */
const CONTENTS_PATH = "M2 3.25h12v1.5H2";
/** The check glyph the enables column is meant to draw. */
const ENABLES_PATH = "M6.2 12.35";

describe("PageOverview", () => {
  it("labels the section and stays out of the prose flow", () => {
    const html = renderToStaticMarkup(createElement(PageOverview, null, "columns"));
    expect(html).toContain('aria-label="Page overview"');
    expect(html).toContain("page-overview not-prose");
    expect(html).toContain(">columns<");
  });

  it("renders nothing but the section when the plugin emitted no columns", () => {
    expect(renderToStaticMarkup(createElement(PageOverview))).toBe(
      '<section class="page-overview not-prose" aria-label="Page overview"></section>'
    );
  });
});

describe("PageOverviewColumn", () => {
  it("renders the copied label and the list that followed it", () => {
    const html = renderToStaticMarkup(
      createElement(PageOverviewColumn, {
        title: "What's on this page",
        kind: "contents",
        children: "a bullet list"
      })
    );
    expect(html).toContain('class="page-overview-label"');
    expect(html).toContain("<span>What&#x27;s on this page</span>");
    expect(html).toContain(">a bullet list<");
  });

  it("marks the contents column with the list glyph", () => {
    const html = renderToStaticMarkup(
      createElement(PageOverviewColumn, { title: "What's on this page", kind: "contents", children: null })
    );
    expect(html).toContain('data-kind="contents"');
    expect(html).toContain(`d="${CONTENTS_PATH}`);
    expect(html).not.toContain(ENABLES_PATH);
  });

  it("marks the enables column with the check glyph", () => {
    const html = renderToStaticMarkup(
      createElement(PageOverviewColumn, { title: "What this enables", kind: "enables", children: null })
    );
    expect(html).toContain('data-kind="enables"');
    expect(html).toContain(`d="${ENABLES_PATH}`);
    expect(html).not.toContain(CONTENTS_PATH);
  });

  it("hides the decorative mark from the accessibility tree", () => {
    const html = renderToStaticMarkup(
      createElement(PageOverviewColumn, { title: "What this enables", kind: "enables", children: null })
    );
    expect(html).toContain('class="page-overview-mark"');
    expect(html).toContain("aria-hidden");
  });
});
