/**
 * Tests for the documentation-bug issue URL.
 *
 * Every heading on a published page carries a control that opens a prefilled GitHub issue, and
 * the reader submits what this function built. Two things break quietly in production: a field
 * that keeps its raw newlines and turns the query string into junk GitHub renders as an empty
 * body, and a body long enough to pass GitHub's URL limit, which makes the control open an
 * error page instead of an issue. The clipping and the two fallbacks below are what prevent
 * each, so the suite asserts on the decoded query the reader would actually land on.
 */

import { describe, expect, it } from "vitest";

import { docsBugHref, type DocsBugReport } from "../../lib/docs-bug";
import { REPO_URL } from "../../lib/site";

/** A report whose fields all carry something worth reading. */
function report(overrides: Partial<DocsBugReport> = {}): DocsBugReport {
  return {
    pageUrl: "https://toxicoder.github.io/evo-t1-coder-stack/latest/operate/dashboard/#lights",
    pageTitle: "Dashboard",
    heading: "Lights out",
    headingId: "lights",
    sourcePath: "docs/dashboard.md",
    sourceUrl: "https://github.com/toxicoder/evo-t1-coder-stack/blob/main/docs/dashboard.md",
    gitRef: "a1b2c3d",
    docsAlias: "latest",
    userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0",
    viewport: "1440x900",
    colorScheme: "dark",
    selection: "the refresh row",
    ...overrides
  };
}

/** The decoded `title` and `body` the issue opener received. */
function query(href: string): { title: string; body: string; labels: string | null } {
  const url = new URL(href);
  return {
    title: url.searchParams.get("title") ?? "",
    body: url.searchParams.get("body") ?? "",
    labels: url.searchParams.get("labels")
  };
}

describe("docsBugHref", () => {
  it("opens a new issue on this repository", () => {
    expect(docsBugHref(report()).startsWith(`${REPO_URL}/issues/new?`)).toBe(true);
  });

  it("titles the issue with the page and the heading", () => {
    expect(query(docsBugHref(report())).title).toBe("Docs: Dashboard - Lights out");
  });

  it("labels the issue so it lands in the docs queue", () => {
    expect(query(docsBugHref(report())).labels).toBe("documentation");
  });

  it("names the page, heading, alias, ref and source the reader was looking at", () => {
    const { body } = query(docsBugHref(report()));
    for (const line of [
      "- Page: https://toxicoder.github.io/evo-t1-coder-stack/latest/operate/dashboard/#lights",
      "- Heading: Lights out (`#lights`)",
      "- Docs alias: latest",
      "- Git ref: a1b2c3d",
      "- Source file: docs/dashboard.md",
      `- Source: ${REPO_URL}/blob/main/docs/dashboard.md`,
      "- Viewport: 1440x900",
      "- Color scheme: dark",
      "- User agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0"
    ]) {
      expect(body).toContain(line);
    }
    for (const heading of ["## What is wrong", "## What it should say", "## Browser"]) {
      expect(body).toContain(heading);
    }
  });

  it("quotes the text the reader had selected", () => {
    expect(query(docsBugHref(report())).body).toContain("- Selected text: the refresh row");
  });

  it("leaves the selection out when the reader selected nothing", () => {
    expect(query(docsBugHref(report({ selection: "   " }))).body).not.toContain("Selected text");
  });

  it("collapses the newlines a block selection carries into single spaces", () => {
    const quoted = query(docsBugHref(report({ selection: "  first\n\tsecond  \n" }))).body.match(
      /- Selected text: (.*)/u
    )?.[1];
    expect(quoted).toBe("first second");
  });

  it("caps the quoted selection so one long block cannot swamp the body", () => {
    const quoted = query(docsBugHref(report({ selection: "x".repeat(900) }))).body.match(
      /- Selected text: (.*)/u
    )?.[1];
    expect(quoted).toBe(`${"x".repeat(397)}...`);
    expect(quoted).toHaveLength(400);
  });

  it("caps the title at the length GitHub still renders", () => {
    const title = query(docsBugHref(report({ pageTitle: "P".repeat(400) }))).title;
    expect(title).toBe(`Docs: ${"P".repeat(131)}...`);
    expect(title).toHaveLength(140);
  });

  it("drops the quoted selection first when the body outgrows the URL limit", () => {
    // 4700 filler characters keep the body under GitHub's limit on its own, so only the
    // quoted selection is what pushes the first build past it.
    const long = "https://example.com/" + "s".repeat(4700);
    const href = docsBugHref(report({ sourceUrl: long, selection: "y".repeat(400) }));
    const { body } = query(href);
    expect(href.length).toBeLessThanOrEqual(5500);
    expect(body).not.toContain("Selected text");
    expect(body).toContain("- User agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0");
    expect(body).toContain(`- Source: ${long}`);
  });

  it("drops the user agent too when the body is still too long", () => {
    const href = docsBugHref(report({ sourceUrl: "https://example.com/" + "s".repeat(7000) }));
    const { body } = query(href);
    expect(body).toContain("- User agent: ");
    expect(body.match(/- User agent: (.*)/u)?.[1]).toBe("");
    expect(body).not.toContain("Selected text");
    expect(body).toContain("- Git ref: a1b2c3d");
  });

  it("keeps every field when nothing needs clipping", () => {
    const { body } = query(docsBugHref(report({ selection: "" })));
    expect(body).not.toContain("...");
  });
});
