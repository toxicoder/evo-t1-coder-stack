/**
 * Tests for the two-column scan card.
 *
 * `remarkPageBrief` hands this component the four source nodes it lifted out of the page, and
 * the component's whole job is to put each one in the right column: the scan list beside the
 * scan label, the gains list beside the gains label. Swap the two and every page in the site
 * reads wrong at a glance, with nothing failing to build. The card also has to survive the
 * single-child shape React gives a component invoked with one node, which is the case a
 * hand-written `<PageBrief>` in an MDX page produces.
 */

import { createElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { describe, expect, it } from "vitest";

import { PageBrief } from "../../components/page-brief";

/** Render the card around whatever the transform handed it. */
function render(children: ReactNode | ReactNode[]): string {
  return renderToStaticMarkup(createElement(PageBrief, null, ...(Array.isArray(children) ? children : [children])));
}

/** The four nodes the plugin moves in, as MDX would hand them over. */
function fourNodes(): ReactNode[] {
  return [
    createElement("strong", { key: "a" }, "What's on this page"),
    createElement("ul", { key: "b" }, createElement("li", null, "the menu")),
    createElement("strong", { key: "c" }, "What this enables"),
    createElement("ul", { key: "d" }, createElement("li", null, "the work"))
  ];
}

describe("PageBrief", () => {
  it("renders a card with one column per list", () => {
    const html = render(fourNodes());
    expect(html).toContain('class="ez-page-brief"');
    expect(html).toContain('class="ez-page-brief__col ez-page-brief__on-page"');
    expect(html).toContain('class="ez-page-brief__col ez-page-brief__enables"');
  });

  it("puts the scan label and the scan list in the first column", () => {
    const html = render(fourNodes());
    const first = html.slice(html.indexOf("__on-page"), html.indexOf("__enables"));
    expect(first).toContain("on this page");
    expect(first).toContain("the menu");
    expect(first).not.toContain("the work");
  });

  it("puts the gains label and the gains list in the second column", () => {
    const html = render(fourNodes());
    const second = html.slice(html.indexOf("__enables"));
    expect(second).toContain("What this enables");
    expect(second).toContain("the work");
    expect(second).not.toContain("the menu");
  });

  it("marks each column with the icon that tells the two apart", () => {
    const html = render(fourNodes());
    expect((html.match(/class="ez-page-brief__icon"/gu) ?? []).length).toBe(2);
    expect((html.match(/aria-hidden="true"/gu) ?? []).length).toBe(2);
  });

  it("keeps a card authored by hand with one child readable", () => {
    const html = render(createElement("ul", { key: "b" }, createElement("li", null, "only list")));
    expect(html).toContain("only list");
    expect(html).toContain('class="ez-page-brief__label">');
  });
});
