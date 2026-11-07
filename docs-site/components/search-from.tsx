"use client";

import { createContext, useContext } from "react";

/**
 * Path the static search client fetches.
 *
 * Default is the unprefixed export. The server layout overrides it with
 * `searchIndexPath()` so a published alias does not request the host root.
 */
const SearchFromContext = createContext("/api/search");

/** Base-path-aware search index URL for this build. */
export function useSearchFrom(): string {
  return useContext(SearchFromContext);
}

export { SearchFromContext };
