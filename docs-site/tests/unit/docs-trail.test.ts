/**
 * Tests for the breadcrumb above the page title.
 *
 * The left menu shows every section of the tree beside the reader's own page, so the trail is
 * the one control that says which section they are standing in and how deep the page sits. Two
 * regressions are visible to a reader and invisible to a build: a trail that names the page
 * before its folders, and a folder rendered as a link, which would let a click jump sideways
 * out of the section the reader was reading. Both are asserted here, along with the leaf being
 * the only addressable crumb.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { DocsTrail } from "../../components/docs-trail";
import type { NavTrail } from "../../lib/nav";
import { callsFor, resetStubs } from "./helpers/fumadocs-stub";

vi.mock("next/link", async () => {
  const { LinkStub: link } = await import("./helpers/fumadocs-stub");
  return { default: link };
});

beforeEach(() => {
  resetStubs();
});

/** Section and folders the nav resolved for a page. */
const TRAIL: NavTrail = { tab: "Operate", groups: ["Daily"], label: "Dashboard" };

/** Render the trail for one page and return the emitted markup. */
function render(page = "Dashboard", url = "/operate/dashboard/"): string {
  return renderToStaticMarkup(createElement(DocsTrail, { trail: TRAIL, page, url }));
}

/** Visible text of each crumb, in document order. */
function crumbs(html: string): string[] {
  return [...html.matchAll(/<(?:span|a)[^>]*>([^<>]+)<\/(?:span|a)>/gu)].map((match) => match[1] ?? "");
}

describe("DocsTrail", () => {
  it("announces itself as a breadcrumb to a screen reader", () => {
    expect(render()).toContain('aria-label="Breadcrumb"');
  });

  it("reads section, then folder, then page", () => {
    expect(crumbs(render())).toEqual(["Operate", "Daily", "Dashboard"]);
  });

  it("links only the page, leaving the section and folders as plain text", () => {
    render();
    const [call] = callsFor("Link");
    expect(call?.props.href).toBe("/operate/dashboard/");
    expect(callsFor("Link")).toHaveLength(1);
  });

  it("separates the crumbs so the depth is legible", () => {
    const separators = (render().match(/aria-hidden="true"/gu) ?? []).length;
    expect(separators).toBe(2);
  });

  it("names a page that sits directly under a section", () => {
    const html = renderToStaticMarkup(
      createElement(DocsTrail, { trail: { tab: "Contribute", groups: [], label: "Branching" }, page: "Branching", url: "/branching/" })
    );
    expect(crumbs(html)).toEqual(["Contribute", "Branching"]);
  });

  it("keeps a truncated crumb readable on hover", () => {
    expect(render()).toContain('title="Daily"');
  });
});
