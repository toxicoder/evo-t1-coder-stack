/**
 * Tests for the search dialog over the exported index.
 *
 * The build is a static export, so the dialog has to search an index fetched from
 * `/api/search` rather than a server: `staticClient` gets the active locale, and the results
 * the hook reports are what the list renders. A regression that drops the locale, or that
 * hands the list the `"empty"` sentinel instead of `null`, is a dialog that silently finds
 * nothing on GitHub Pages. The fumadocs dialog parts are mocked because the real ones are
 * Radix primitives that want a DOM.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { SearchDialog } from "../../components/search-dialog";
import { callsFor, docsSearchState, resetStubs, searchClientArgs } from "./helpers/fumadocs-stub";

vi.mock("fumadocs-ui/components/dialog/search", async () => {
  const { wrapperStub: stub } = await import("./helpers/fumadocs-stub");
  return {
    SearchDialog: stub("SearchDialogRoot"),
    SearchDialogClose: stub("SearchDialogClose"),
    SearchDialogContent: stub("SearchDialogContent"),
    SearchDialogHeader: stub("SearchDialogHeader"),
    SearchDialogIcon: stub("SearchDialogIcon"),
    SearchDialogInput: stub("SearchDialogInput"),
    SearchDialogList: stub("SearchDialogList"),
    SearchDialogOverlay: stub("SearchDialogOverlay")
  };
});

vi.mock("fumadocs-core/search/client", async () => {
  const { useDocsSearchStub: hook } = await import("./helpers/fumadocs-stub");
  return { useDocsSearch: hook };
});

vi.mock("fumadocs-core/search/client/orama-static", async () => {
  const { staticClientStub: client } = await import("./helpers/fumadocs-stub");
  return { staticClient: client };
});

vi.mock("fumadocs-ui/contexts/i18n", async () => {
  const { useI18nStub: i18n } = await import("./helpers/fumadocs-stub");
  return { useI18n: i18n };
});

const results = [{ id: "1", url: "/operate", title: "Operate" }];

beforeEach(() => {
  resetStubs();
  docsSearchState.query = { data: results, isLoading: false };
});

/** Props the layout's search provider hands the dialog. */
function dialogProps() {
  return { open: true, onOpenChange: vi.fn() };
}

/** Props the dialog received from the component under test. */
function rootProps(): Record<string, unknown> {
  const [call] = callsFor("SearchDialogRoot");
  if (!call) throw new Error("the dialog shell was never rendered");
  return call.props;
}

describe("SearchDialog", () => {
  it("renders the dialog parts around the results", () => {
    const html = renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    for (const part of [
      "SearchDialogRoot",
      "SearchDialogOverlay",
      "SearchDialogContent",
      "SearchDialogHeader",
      "SearchDialogList"
    ]) {
      expect(html).toContain(`data-stub="${part}"`);
    }
  });

  it("keeps the chrome in the order the stylesheet expects", () => {
    const html = renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    expect(html.indexOf('data-stub="SearchDialogIcon"')).toBeLessThan(
      html.indexOf('data-stub="SearchDialogInput"')
    );
    expect(html.indexOf('data-stub="SearchDialogInput"')).toBeLessThan(
      html.indexOf('data-stub="SearchDialogClose"')
    );
  });

  it("passes the rows the query returned to the list", () => {
    renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    const [list] = callsFor("SearchDialogList");
    expect(list?.props.items).toBe(results);
  });

  it("passes null rather than the empty sentinel", () => {
    docsSearchState.query = { data: "empty", isLoading: false };
    renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    const [list] = callsFor("SearchDialogList");
    expect(list?.props.items).toBeNull();
  });

  it("forwards the query state to the dialog shell", () => {
    docsSearchState.search = "kasm";
    docsSearchState.query = { data: results, isLoading: true };
    const props = dialogProps();
    renderToStaticMarkup(createElement(SearchDialog, props));
    expect(rootProps().search).toBe("kasm");
    expect(rootProps().isLoading).toBe(true);
    expect(rootProps().open).toBe(true);
    expect(rootProps().onOpenChange).toBe(props.onOpenChange);
  });

  it("routes the dialog's edits back through the hook", () => {
    renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    (rootProps().onSearchChange as (value: string) => void)("bazel");
    expect(docsSearchState.search).toBe("bazel");
  });

  it("builds the static client for the active locale", () => {
    renderToStaticMarkup(createElement(SearchDialog, dialogProps()));
    expect(searchClientArgs[0]).toEqual({ locale: "en" });
    expect(searchClientArgs[1]).toEqual({ client: { kind: "static-client" } });
  });
});
