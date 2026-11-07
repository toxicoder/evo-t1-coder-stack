/**
 * Tests for the search index location.
 *
 * The static export is published under `/<repo>/<alias>/`, and the Orama client in the search
 * dialog fetches the index the build wrote out. A hardcoded `/api/search` asks the Pages host
 * root, which 404s, and the dialog reports nothing found with no error anywhere. The context
 * below is how the server layout hands the client the prefixed path, so the two things worth
 * pinning are the default (a local `npm run dev` has no prefix) and that an override actually
 * reaches the consumer.
 */

import { createElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { describe, expect, it } from "vitest";

import { SearchFromContext, useSearchFrom } from "../../components/search-from";

/** Renders the path the consumer sees, so the markup is the assertion. */
function Probe(): ReactNode {
  return createElement("span", null, useSearchFrom());
}

/** Render the probe, optionally wrapped in the provider the layout uses. */
function render(within?: (children: ReactNode) => ReactNode): string {
  const tree = within ? within(createElement(Probe)) : createElement(Probe);
  return renderToStaticMarkup(tree);
}

describe("useSearchFrom", () => {
  it("reads the unprefixed index outside any provider", () => {
    expect(render()).toContain("/api/search");
  });

  it("reads the path the layout published", () => {
    const html = render((children) =>
      createElement(SearchFromContext.Provider, { value: "/evo-t1-coder-stack/latest/api/search" }, children)
    );
    expect(html).toContain("/evo-t1-coder-stack/latest/api/search");
    expect(html).not.toContain('>/api/search<');
  });

  it("prefers the innermost provider, which is what nests a page override", () => {
    const html = render((children) =>
      createElement(
        SearchFromContext.Provider,
        { value: "/outer/api/search" },
        createElement(SearchFromContext.Provider, { value: "/inner/api/search" }, children)
      )
    );
    expect(html).toContain("/inner/api/search");
  });
});
