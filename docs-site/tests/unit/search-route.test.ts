/**
 * Tests for the search route the static export ships.
 *
 * `output: "export"` leaves no Node server at runtime, so this file is the whole search
 * backend of the published site: `dynamic` is what makes the exporter evaluate the handler at
 * build time instead of failing on a dynamic route, and `GET` has to be `search.staticGET`
 * itself, which answers with the serialized index that the browser client in
 * `components/search-dialog.tsx` fetches. Either binding drifting is a failed build or a
 * search box that silently finds nothing.
 *
 * The search API is doubled here, because the real one is built over the compiled content
 * collection (a bundler-time macro). The suite therefore pins the two exported bindings and
 * the pass-through, not Orama. Run it from `docs-site/` with `npm run unit`, or
 * `npm run unit:coverage` for the gate.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Double for `search` from `lib/source`.
 *
 * Built through `vi.hoisted` so it exists before `vi.mock` runs, and the recorded arguments
 * plus the served body live on the same object the assertions read.
 */
const searchDouble = vi.hoisted(() => {
  const index = { pages: [{ id: "/operate", title: "Operate", tags: ["operate"] }] };
  const args: unknown[][] = [];
  return {
    index,
    args,
    staticGET: async (request?: Request) => {
      args.push([request]);
      return Response.json(index);
    }
  };
});

vi.mock("@/lib/source", async () => ({
  search: { staticGET: searchDouble.staticGET }
}));

import { dynamic, GET } from "../../app/api/search/route";

/** Next calls a route handler with the incoming Request; the static handler ignores it. */
const GET_WITH_REQUEST: (request: Request) => Promise<Response> = GET;

beforeEach(() => {
  searchDouble.args.length = 0;
});

describe("app/api/search/route", () => {
  it("asks the exporter to evaluate the route during the build", () => {
    expect(dynamic).toBe("force-static");
  });

  it("exposes the backend's own static handler as GET", () => {
    expect(GET).toBe(searchDouble.staticGET);
  });

  it("answers a search request with the exported index", async () => {
    const request = new Request("http://localhost/api/search?q=bazel");

    const response = await GET_WITH_REQUEST(request);

    expect(searchDouble.args).toEqual([[request]]);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/json");
    await expect(response.json()).resolves.toEqual(searchDouble.index);
  });
});
