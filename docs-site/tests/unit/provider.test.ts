/**
 * Tests for the framework wiring around the docs chrome.
 *
 * `RootProvider` is what gives the theme switch the `.dark` class the token block in
 * `app/global.css` keys off, and it is what mounts the search dialog. A wrong `attribute`
 * leaves every page stuck on one scheme; a missing `SearchDialog` drops the dialog that the
 * static export relies on, and neither failure shows up until someone loads the published
 * site. The provider itself is mocked here: the real one pulls in Radix and wants a DOM.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { Provider } from "../../components/provider";
import { SearchDialog } from "../../components/search-dialog";
import { callsFor, resetStubs } from "./helpers/fumadocs-stub";

vi.mock("fumadocs-ui/provider/next", async () => {
  const { wrapperStub } = await import("./helpers/fumadocs-stub");
  return { RootProvider: wrapperStub("RootProvider") };
});

// The provider imports the dialog through the `@/` alias, which has no Vitest resolver entry;
// registering the alias with the real module is what lets the component load at all, and
// keeps the assertion below about the component the provider actually passes.
vi.mock("@/components/search-dialog", async () => {
  const actual = await vi.importActual<typeof import("../../components/search-dialog")>(
    "../../components/search-dialog"
  );
  return { ...actual };
});

beforeEach(() => {
  resetStubs();
});

/** Render the provider around a marker child and return the emitted markup. */
function renderProvider(): string {
  return renderToStaticMarkup(createElement(Provider, null, createElement("p", null, "page body")));
}

describe("Provider", () => {
  it("keeps the page inside the fumadocs root provider", () => {
    expect(renderProvider()).toContain("<p>page body</p>");
  });

  it("drives theming through a class attribute with the system default", () => {
    renderProvider();
    const [call] = callsFor("RootProvider");
    expect(call?.props.theme).toEqual({ attribute: "class", defaultTheme: "system" });
  });

  it("hands the static search dialog to the search slot", () => {
    renderProvider();
    const [call] = callsFor("RootProvider");
    const search = call?.props.search as { SearchDialog: unknown } | undefined;
    expect(search?.SearchDialog).toBe(SearchDialog);
  });

  it("does not invent search options the client does not take", () => {
    renderProvider();
    const [call] = callsFor("RootProvider");
    expect(Object.keys(call?.props as Record<string, unknown>)).toEqual(["theme", "search", "children"]);
  });

  it("renders an empty tree when Next mounts it without children", () => {
    expect(renderToStaticMarkup(createElement(Provider))).toContain('data-stub="RootProvider"');
  });
});
