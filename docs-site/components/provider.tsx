"use client";

import { RootProvider } from "fumadocs-ui/provider/next";
import type { ReactNode } from "react";

import { SearchDialog } from "@/components/search-dialog";
import { SearchFromContext } from "@/components/search-from";

/**
 * Wires the framework contexts the docs chrome needs.
 *
 * `next-themes` is enabled so the light/dark switch drives the `.dark` class that the
 * Voltage token block in `app/global.css` keys off.  Search uses the static Orama/ZBSearch
 * client, which fetches the exported index. `searchFrom` is the base-path-aware
 * path (`/api/search` locally, `/ez-comfy-stack/<alias>/api/search` when published).
 */
export function Provider({
  children,
  searchFrom = "/api/search"
}: {
  children: ReactNode;
  searchFrom?: string;
}) {
  return (
    <SearchFromContext.Provider value={searchFrom}>
      <RootProvider theme={{ attribute: "class", defaultTheme: "system" }} search={{ SearchDialog }}>
        {children}
      </RootProvider>
    </SearchFromContext.Provider>
  );
}
