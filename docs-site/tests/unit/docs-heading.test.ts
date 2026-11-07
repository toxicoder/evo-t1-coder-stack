// @vitest-environment jsdom
/**
 * Tests for the heading chrome.
 *
 * Every heading on a published page carries two controls a reader uses without thinking: copy a
 * deep link, and file a bug about that heading. Both are assembled in the browser from the page
 * facts the server handed down, so a regression is invisible until someone clicks: an anchor
 * button that copies the page without the hash, a bug link built at render time (before
 * `window` exists) instead of when the pointer goes down, and a page title printed twice now
 * that the authored `# H1` is the only title. The lead paragraph under the title is the other
 * half of the contract, and it appears only when the heading really is the frontmatter title.
 */

import { createElement, type ReactNode } from "react";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  DocsH1,
  DocsH2,
  DocsH3,
  DocsH4,
  DocsH5,
  DocsH6,
  DocsPageProvider,
  type DocsPageFacts
} from "../../components/docs-heading";
import { REPO_URL } from "../../lib/site";
import { interact, mount, settle, unmount, waitMs } from "./helpers/dom-harness";

// The heading imports the issue-URL builder through the `@/` alias, which has no Vitest
// resolver entry; registering the alias against the real module is what lets it load.
vi.mock("@/lib/docs-bug", async () => {
  const actual = await vi.importActual<typeof import("../../lib/docs-bug")>("../../lib/docs-bug");
  return { ...actual };
});

/** What the server knew about the page the heading sits on. */
const FACTS: DocsPageFacts = {
  title: "Dashboard",
  description: "What the dashboard shows and what each row can change.",
  sourcePath: "docs/dashboard.md",
  sourceUrl: `${REPO_URL}/blob/main/docs/dashboard.md`,
  gitRef: "a1b2c3d",
  docsAlias: "latest"
};

/** What a heading's controls look like once the effect has run. */
function bugLink(): HTMLAnchorElement {
  const el = document.querySelector<HTMLAnchorElement>("a[data-docs-bug]");
  if (!el) throw new Error("the bug control did not render");
  return el;
}

/** The anchor-copy control of the heading. */
function copyButton(): HTMLButtonElement {
  const el = document.querySelector<HTMLButtonElement>("button[aria-label*='anchor link']");
  if (!el) throw new Error("the copy control did not render");
  return el;
}

/** Render one heading inside the provider the page layout supplies. */
async function mountHeading(node: ReactNode, facts: DocsPageFacts | null = FACTS): Promise<void> {
  const heading = facts
    ? createElement(DocsPageProvider, { facts, children: node })
    : node;
  mount(heading);
  await settle();
}

/** Decode the `body` the bug control points at. */
function bugBody(): string {
  return new URL(bugLink().href).searchParams.get("body") ?? "";
}

beforeEach(() => {
  Object.defineProperty(window.navigator, "clipboard", {
    value: undefined,
    configurable: true,
    writable: true
  });
});

afterEach(() => {
  unmount();
  vi.restoreAllMocks();
  document.documentElement.classList.remove("dark");
});

/** Give the browser a clipboard that records what the copy control wrote. */
function giveClipboard(): ReturnType<typeof vi.fn> {
  const writeText = vi.fn().mockResolvedValue(undefined);
  Object.defineProperty(window.navigator, "clipboard", {
    value: { writeText },
    configurable: true,
    writable: true
  });
  return writeText;
}

describe("heading chrome", () => {
  it("keeps a heading without an id plain, the way Fumadocs does", async () => {
    await mountHeading(createElement(DocsH2, null, "No anchor"));
    const h2 = document.querySelector("h2");
    expect(h2?.textContent).toBe("No anchor");
    expect(h2?.className).toBe("");
    expect(document.querySelector("a[data-card]")).toBeNull();
    expect(document.querySelector("a[data-docs-bug]")).toBeNull();
  });

  it("wraps an anchored heading in the group the stylesheet reveals on hover", async () => {
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    const h2 = document.querySelector("h2");
    expect(h2?.id).toBe("rows");
    expect(h2?.className).toContain("group/heading");
    expect(h2?.className).toContain("scroll-m-28");
    expect(document.querySelector("a[data-card]")?.getAttribute("href")).toBe("#rows");
  });

  it("names both controls for a screen reader", async () => {
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    expect(copyButton().getAttribute("aria-label")).toBe("Copy anchor link");
    expect(bugLink().getAttribute("aria-label")).toBe("File a documentation bug");
    expect(bugLink().getAttribute("target")).toBe("_blank");
  });

  it("builds the bug link in the browser from the page facts", async () => {
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    const link = bugLink();
    expect(link.getAttribute("href")).toContain(`${REPO_URL}/issues/new?`);
    const body = bugBody();
    expect(body).toContain("- Heading: Rows (`#rows`)");
    expect(body).toContain("- Docs alias: latest");
    expect(body).toContain("- Git ref: a1b2c3d");
    expect(body).toContain("- Source file: docs/dashboard.md");
    expect(body).toContain("- Color scheme: light");
    expect(body).toMatch(/- User agent: \S/u);
    const title = new URL(link.href).searchParams.get("title");
    expect(title).toBe("Docs: Dashboard - Rows");
  });

  it("points the bug link at the address and hash the reader is looking at", async () => {
    window.history.replaceState(null, "", "/docs/operate/dashboard/#rows");
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    expect(bugBody()).toContain(`- Page: ${window.location.href}`);
    expect(new URL(bugLink().href).hash).toBe("");
    expect(bugBody()).toContain("#rows");
  });

  it("reports the dark scheme when the theme switch set the class", async () => {
    document.documentElement.classList.add("dark");
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    expect(bugBody()).toContain("- Color scheme: dark");
  });

  it("quotes the text the reader had selected", async () => {
    const selection = { toString: () => "the refresh row" };
    vi.spyOn(window, "getSelection").mockReturnValue(selection as unknown as Selection);
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    expect(bugBody()).toContain("- Selected text: the refresh row");
  });

  it("rebuilds the bug link when the pointer goes down on it", async () => {
    window.history.replaceState(null, "", "/docs/operate/dashboard/");
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    const link = bugLink();
    const before = link.href;
    window.history.replaceState(null, "", "/docs/operate/second-page/");
    await interact(() => {
      link.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    });
    expect(link.href).not.toBe(before);
    expect(decodeURIComponent(link.href)).toContain("/docs/operate/second-page/");
  });

  it("flattens the text a heading shows into the issue title", async () => {
    await mountHeading(
      createElement(
        DocsH2,
        { id: "mixed" },
        "Run ",
        createElement("code", null, "dev-stack"),
        " ",
        7,
        " times",
        null
      )
    );
    const title = new URL(bugLink().href).searchParams.get("title");
    expect(title).toBe("Docs: Dashboard - Run dev-stack 7 times");
  });

  it("copies the page address with the heading hash", async () => {
    const writeText = giveClipboard();
    window.history.replaceState(null, "", "/docs/operate/dashboard/");
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    await interact(() => {
      copyButton().click();
    });
    await settle();
    expect(writeText).toHaveBeenCalledWith(`${window.location.href}#rows`);
  });

  it("says the anchor was copied, then goes back to the link icon", async () => {
    giveClipboard();
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"));
    await interact(() => {
      copyButton().click();
    });
    await settle();
    expect(copyButton().getAttribute("aria-label")).toBe("Copied anchor link");
    await waitMs(1600);
    expect(copyButton().getAttribute("aria-label")).toBe("Copy anchor link");
  });

  it("renders every level with its own tag", async () => {
    const levels = [
      [DocsH1, "h1"],
      [DocsH2, "h2"],
      [DocsH3, "h3"],
      [DocsH4, "h4"],
      [DocsH5, "h5"],
      [DocsH6, "h6"]
    ] as const;
    for (const [Component, tag] of levels) {
      unmount();
      await mountHeading(createElement(Component, { id: `section-${tag}` }, `Section ${tag}`));
      const heading = document.querySelector(tag);
      expect(heading?.id).toBe(`section-${tag}`);
      expect(heading?.textContent).toContain(`Section ${tag}`);
    }
  });
});

describe("DocsH1 lead paragraph", () => {
  it("prints the frontmatter description under the page title", async () => {
    await mountHeading(createElement(DocsH1, { id: "dashboard" }, "Dashboard"));
    const lead = document.querySelector("h1 + p");
    expect(lead?.textContent).toBe(FACTS.description);
    expect(lead?.className).toContain("text-fd-muted-foreground");
  });

  it("matches the title however the author capitalised it", async () => {
    await mountHeading(createElement(DocsH1, { id: "dashboard" }, "dashboard"));
    expect(document.querySelector("h1 + p")?.textContent).toBe(FACTS.description);
  });

  it("leaves a section heading that is not the title without a lead", async () => {
    await mountHeading(createElement(DocsH1, { id: "other" }, "Some other heading"));
    expect(document.querySelector("h1 + p")).toBeNull();
  });

  it("leaves a title page with no description without a lead", async () => {
    await mountHeading(
      createElement(DocsH1, { id: "dashboard" }, "Dashboard"),
      { ...FACTS, description: undefined }
    );
    expect(document.querySelector("h1 + p")).toBeNull();
  });

  it("still renders the controls when no page facts reached it", async () => {
    await mountHeading(createElement(DocsH1, { id: "dashboard" }, "Dashboard"), null);
    expect(document.querySelector("h1 + p")).toBeNull();
    expect(document.querySelector("a[data-docs-bug]")).not.toBeNull();
    expect(bugBody()).toContain("- Docs alias: local");
    expect(bugBody()).toContain(`- Page: ${window.location.href}`);
  });

  it("falls back to the document title when the page facts have none", async () => {
    document.title = "Operate | Docs";
    await mountHeading(createElement(DocsH2, { id: "rows" }, "Rows"), { ...FACTS, title: "" });
    expect(new URL(bugLink().href).searchParams.get("title")).toBe("Docs: Operate | Docs - Rows");
  });
});
